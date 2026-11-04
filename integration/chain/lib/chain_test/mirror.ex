# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror do
  @moduledoc """
  A plain-HTTP server on 127.0.0.1 serving a snapshot directory
  (`ChainTest.Snapshot`) under the portal's URL layout:

      /root.json  /batch.json  /batches/<n>.json
      /manifests/<name>.json  /v2/manifests/<name>.json  /files/<sha256>

  Any other path or a query string is a 404, a method other than GET a 405,
  a malformed request a 400; none of them reads a file. A routed path the
  snapshot holds as a regular file (no symlink anywhere below the snapshot
  directory) is passed through the transform, `(path, bytes) -> {status,
  bytes}`, with `path` relative to the snapshot, before it is sent; one it
  does not hold is a 404 that never reaches the transform. A transform that
  raises, throws or exits, or answers anything but a `t:response/0`, is
  answered 500 and logged.

  A transform answers one of (`status` is 100..599):

    * `{status, body}` - the response, with a `content-length`.
    * `{status, headers, body}` - the same plus `headers`, `[{name, value}]`
      (at most 32, token names, values up to 4096 bytes without CR, LF or
      NUL). A `content-type` among them replaces the mirror's; the mirror
      owns `content-length`, `connection` and `transfer-encoding`, which a
      transform may not name.
    * `{:redirect, 300..399, location}` - an empty body and `location`
      (up to 2048 bytes, without CR, LF or NUL).
    * `{:stream, status, chunks, delay_ms}` - no `content-length`; each
      chunk (a list of binaries) is sent after `delay_ms` (0..60000), then
      the connection is closed.
    * `{:truncate, status, body, n}` - declares `byte_size(body)` but sends
      only its first `n` bytes (`0 <= n < byte_size(body)`), then closes.
    * `:close` - closes the connection without a response.
    * `{:endless, status, chunk, delay_ms}` - no `content-length`; sends
      `chunk` (1 byte to 1 MiB) after every `delay_ms` (0..60000) until the
      client hangs up.

  A streamed body (`:stream`, `:endless`) is cut off, and the connection
  closed, at the mirror's caps: `:stream_max_bytes` (default 64 MiB) sent or
  `:stream_max_ms` (default 120 s) after the head, whichever comes first.

  Every request is logged in arrival order as `%{method, path, status,
  mutated}`, `mutated` true when the transform answered anything but
  `{200, bytes}` with the bytes it was given; `status` is 0 for `:close`.
  One request per connection (`connection: close`). Built on `:gen_tcp`
  rather than `:httpd` so a transform has the whole response in hand.

  A misbehaving client cannot hang a test run. Every line of the request
  head is capped at 8192 bytes (400), the request target at 1024
  bytes (414), the head at 100 headers (400), and the whole head must
  arrive within `:request_timeout_ms` (default 5 s) of the connection
  opening, or it is answered 408. At most `:max_connections` (default 64)
  are served at once; one past that is answered 503 straight away. A
  client that hangs up early only ends its own connection.
  """

  use GenServer

  @type status :: 100..599
  @type response ::
          {status(), binary()}
          | {status(), [{String.t(), String.t()}], binary()}
          | {:redirect, 300..399, String.t()}
          | {:stream, status(), [binary()], non_neg_integer()}
          | {:truncate, status(), binary(), non_neg_integer()}
          | :close
          | {:endless, status(), binary(), non_neg_integer()}
  @type transform :: (String.t(), binary() -> response())
  @type request :: %{
          method: String.t(),
          path: String.t(),
          status: non_neg_integer(),
          mutated: boolean()
        }
  @type t :: %{pid: pid(), port: :inet.port_number(), url: String.t()}

  @max_line 8192
  @max_target 1024
  @max_headers 100
  @request_timeout_ms 5_000
  @max_connections 64
  @send_timeout_ms 5_000
  @accept_backoff_ms 50
  @stream_max_bytes 64 * 1024 * 1024
  @stream_max_ms 120_000
  @max_delay_ms 60_000
  @max_chunk 1024 * 1024
  @max_response_headers 32
  @max_header_value 4096
  @max_location 2048
  @owned_headers ["content-length", "connection", "transfer-encoding"]

  @routes [
    ~r|\Aroot\.json\z|,
    ~r|\Abatch\.json\z|,
    ~r|\Abatches/[0-9]{1,12}\.json\z|,
    ~r|\A(v2/)?manifests/[a-z][a-z0-9_]{0,63}\.json\z|,
    ~r|\Afiles/[0-9a-f]{64}\z|
  ]

  @reasons %{
    200 => "OK",
    301 => "Moved Permanently",
    302 => "Found",
    400 => "Bad Request",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    408 => "Request Timeout",
    414 => "URI Too Long",
    500 => "Internal Server Error",
    502 => "Bad Gateway",
    503 => "Service Unavailable"
  }

  @doc "The transform that serves the snapshot unchanged."
  @spec identity() :: transform()
  def identity(), do: fn _path, bytes -> {200, bytes} end

  @doc "The default caps on a streamed body (see the moduledoc)."
  @spec stream_limits() :: %{max_bytes: pos_integer(), max_ms: pos_integer()}
  def stream_limits(), do: %{max_bytes: @stream_max_bytes, max_ms: @stream_max_ms}

  @doc """
  Starts a mirror over `dir` on a free port of 127.0.0.1. Options
  `:transform` (default `identity/0`), `:request_timeout_ms` (default
  5000), `:max_connections` (default 64), `:stream_max_bytes` and
  `:stream_max_ms` (`stream_limits/0`).
  """
  @spec start(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(dir, opts \\ []) do
    config = %{
      dir: Path.expand(dir),
      transform: Keyword.get(opts, :transform, identity()),
      timeout: Keyword.get(opts, :request_timeout_ms, @request_timeout_ms),
      max: Keyword.get(opts, :max_connections, @max_connections),
      stream_max_bytes: Keyword.get(opts, :stream_max_bytes, @stream_max_bytes),
      stream_max_ms: Keyword.get(opts, :stream_max_ms, @stream_max_ms)
    }

    case GenServer.start(__MODULE__, config) do
      {:ok, pid} ->
        port = GenServer.call(pid, :port)
        {:ok, %{pid: pid, port: port, url: "http://127.0.0.1:#{port}"}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Stops the mirror and every connection it is serving."
  @spec stop(t()) :: :ok
  def stop(%{pid: pid}) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @doc "Every request so far, in arrival order."
  @spec requests(t()) :: [request()]
  def requests(%{pid: pid}), do: GenServer.call(pid, :requests)

  @doc "The address the listening socket is bound to."
  @spec sockname(t()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def sockname(%{pid: pid}), do: GenServer.call(pid, :sockname)

  @doc "The snapshot path a request path maps to, or `:error` when it is not in the layout."
  @spec route(String.t()) :: {:ok, String.t()} | :error
  def route("/" <> rel) do
    if Enum.any?(@routes, &Regex.match?(&1, rel)), do: {:ok, rel}, else: :error
  end

  def route(_), do: :error

  @impl GenServer
  def init(config) do
    opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      send_timeout: @send_timeout_ms,
      send_timeout_close: true
    ]

    case :gen_tcp.listen(0, opts) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        server = self()
        acceptor = spawn_link(fn -> acceptor(listen, server, config) end)
        {:ok, %{listen: listen, port: port, acceptor: acceptor, log: []}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:sockname, _from, state), do: {:reply, :inet.sockname(state.listen), state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.log), state}

  def handle_call({:log, entry}, _from, state),
    do: {:reply, :ok, %{state | log: [entry | state.log]}}

  # Killing the acceptor kills, through their links, the connection
  # handlers too.
  @impl GenServer
  def terminate(_reason, state) do
    Process.unlink(state.acceptor)
    Process.exit(state.acceptor, :kill)
    :gen_tcp.close(state.listen)
    :ok
  end

  # The acceptor traps exits so a handler that dies (a client that hung up
  # mid-response) only ends its own connection, and counts the live ones.
  defp acceptor(listen, server, config) do
    Process.flag(:trap_exit, true)
    accept(listen, server, config, 0)
  end

  defp accept(listen, server, config, live) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        live = reap(server, live)

        if live >= config.max do
          entry = %{method: "?", path: "?", status: 503, mutated: false}
          log(server, entry)
          :gen_tcp.send(sock, head(503, [], 0, "?"))
          :gen_tcp.close(sock)
          accept(listen, server, config, live)
        else
          handover(sock, server, config)
          accept(listen, server, config, live + 1)
        end

      # The mirror is gone: exit so the linked handlers go with it.
      {:error, :closed} ->
        exit(:shutdown)

      # Out of file descriptors or similar: back off instead of spinning
      # on an accept that fails again at once.
      {:error, _} ->
        Process.sleep(@accept_backoff_ms)
        accept(listen, server, config, live)
    end
  end

  defp handover(sock, server, config) do
    pid =
      spawn_link(fn ->
        receive do
          :go -> serve(sock, server, config)
        end
      end)

    case :gen_tcp.controlling_process(sock, pid) do
      :ok ->
        send(pid, :go)

      {:error, _} ->
        Process.exit(pid, :kill)
        :gen_tcp.close(sock)
    end
  end

  defp reap(server, live) do
    receive do
      {:EXIT, ^server, reason} -> exit(reason)
      {:EXIT, _handler, _} -> reap(server, max(live - 1, 0))
    after
      0 -> live
    end
  end

  defp log(server, entry), do: GenServer.call(server, {:log, entry})

  # The request is logged before the response is sent, so a client that
  # has its answer always finds the request in `requests/1`. A client
  # that hung up before its head was complete sent no request and is not
  # logged.
  defp serve(sock, server, config) do
    deadline = System.monotonic_time(:millisecond) + config.timeout

    case read_request(sock, deadline) do
      :closed ->
        :ok

      result ->
        {reply, path, mutated} = answer(result, config)

        log(server, %{
          method: method_of(result),
          path: path,
          status: reply_status(reply),
          mutated: mutated
        })

        respond(sock, reply, path, config)
    end

    :gen_tcp.close(sock)
  end

  defp method_of({:ok, method, _target}), do: method
  defp method_of(_), do: "?"

  defp read_request(sock, deadline) do
    with {:ok, {:http_request, method, {:abs_path, target}, _vsn}, rest} <-
           next(sock, deadline, :http_bin, ""),
         {:ok, _body} <- skip_headers(sock, deadline, rest, @max_headers) do
      {:ok, to_string(method), target}
    else
      {:ok, _other_packet, _rest} -> :bad
      other -> other
    end
  end

  defp skip_headers(_sock, _deadline, _buf, 0), do: :bad

  defp skip_headers(sock, deadline, buf, left) do
    case next(sock, deadline, :httph_bin, buf) do
      {:ok, :http_eoh, rest} -> {:ok, rest}
      {:ok, {:http_header, _, _, _, _}, rest} -> skip_headers(sock, deadline, rest, left - 1)
      other -> other
    end
  end

  # The next line of the head, decoded as `type`, reading more until it is
  # whole. The buffer never holds more than one partial line of at most
  # @max_line bytes.
  defp next(sock, deadline, type, buf) do
    case :erlang.decode_packet(type, buf, packet_size: @max_line) do
      {:ok, {:http_error, _}, _} ->
        :bad

      {:ok, packet, rest} ->
        {:ok, packet, rest}

      {:more, _} when byte_size(buf) >= @max_line ->
        :bad

      {:more, _} ->
        case recv(sock, deadline) do
          {:ok, data} -> next(sock, deadline, type, buf <> data)
          {:error, :timeout} -> :timeout
          {:error, _} -> :closed
        end

      {:error, _} ->
        :bad
    end
  end

  defp recv(sock, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> :gen_tcp.recv(sock, 0, left)
      _ -> {:error, :timeout}
    end
  end

  defp answer(:bad, _config), do: {plain(400), "?", false}
  defp answer(:timeout, _config), do: {plain(408), "?", false}

  defp answer({:ok, _method, target}, _config) when byte_size(target) > @max_target,
    do: {plain(414), binary_part(target, 0, @max_target), false}

  defp answer({:ok, "GET", target}, config) do
    with false <- String.contains?(target, "?"),
         {:ok, rel} <- route(target),
         {:ok, bytes} <- read_inside(config.dir, rel) do
      transformed(rel, bytes, config.transform)
    else
      _ -> {plain(404), target, false}
    end
  end

  defp answer({:ok, _method, target}, _config), do: {plain(405), target, false}

  defp plain(status, body \\ ""), do: {:full, status, [], body}

  # Reads `rel` below `dir` only when every component below `dir` is a
  # directory or, the last, a regular file: a symlink is never followed.
  defp read_inside(dir, rel) do
    parts = Path.split(rel)

    {dirs, [_file]} = Enum.split(parts, -1)

    prefixes =
      parts
      |> Enum.scan(dir, &Path.join(&2, &1))
      |> Enum.zip(Enum.map(dirs, fn _ -> :directory end) ++ [:regular])

    if Enum.all?(prefixes, fn {path, type} -> lstat_type(path) == type end),
      do: File.read(Path.join(dir, rel)),
      else: :error
  end

  defp lstat_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      _ -> :missing
    end
  end

  defp transformed(rel, bytes, transform) do
    out = transform.(rel, bytes)

    case reply(out) do
      {:ok, reply} -> {reply, rel, out != {200, bytes}}
      :error -> {plain(500, "transform returned #{inspect(out, limit: 20)}"), rel, true}
    end
  rescue
    e -> {plain(500, Exception.message(e)), rel, true}
  catch
    kind, reason -> {plain(500, Exception.format_banner(kind, reason)), rel, true}
  end

  defguardp status?(s) when is_integer(s) and s in 100..599
  defguardp delay?(d) when is_integer(d) and d in 0..@max_delay_ms

  # A transform's answer as what `respond/4` sends, or `:error` when it is
  # not a `t:response/0`.
  defp reply({s, body}) when status?(s) and is_binary(body), do: {:ok, plain(s, body)}

  defp reply({s, headers, body}) when status?(s) and is_binary(body) do
    if headers?(headers), do: {:ok, {:full, s, headers, body}}, else: :error
  end

  defp reply({:redirect, s, location}) when is_integer(s) and s in 300..399 do
    if is_binary(location) and byte_size(location) <= @max_location and value?(location),
      do: {:ok, {:full, s, [{"location", location}], ""}},
      else: :error
  end

  defp reply({:stream, s, chunks, delay}) when status?(s) and is_list(chunks) and delay?(delay) do
    if Enum.all?(chunks, &is_binary/1), do: {:ok, {:stream, s, chunks, delay}}, else: :error
  end

  defp reply({:truncate, s, body, n})
       when status?(s) and is_binary(body) and is_integer(n) and n >= 0 and n < byte_size(body),
       do: {:ok, {:truncate, s, body, n}}

  defp reply(:close), do: {:ok, :close}

  defp reply({:endless, s, chunk, delay})
       when status?(s) and is_binary(chunk) and byte_size(chunk) in 1..@max_chunk and
              delay?(delay),
       do: {:ok, {:endless, s, chunk, delay}}

  defp reply(_), do: :error

  defp headers?(headers) when is_list(headers) and length(headers) <= @max_response_headers,
    do: Enum.all?(headers, &header?/1)

  defp headers?(_), do: false

  defp header?({name, value}) when is_binary(name) and is_binary(value) do
    name =~ ~r/\A[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}\z/ and
      String.downcase(name) not in @owned_headers and
      byte_size(value) <= @max_header_value and value?(value)
  end

  defp header?(_), do: false

  defp value?(v), do: not String.contains?(v, ["\r", "\n", <<0>>])

  defp reply_status(:close), do: 0
  defp reply_status(reply), do: elem(reply, 1)

  defp respond(sock, {:full, status, headers, body}, path, _config),
    do: :gen_tcp.send(sock, [head(status, headers, byte_size(body), path), body])

  defp respond(sock, {:truncate, status, body, n}, path, _config),
    do: :gen_tcp.send(sock, [head(status, [], byte_size(body), path), binary_part(body, 0, n)])

  defp respond(_sock, :close, _path, _config), do: :ok

  defp respond(sock, {:stream, status, chunks, delay}, path, config),
    do: stream(sock, head(status, [], nil, path), chunks, delay, config)

  defp respond(sock, {:endless, status, chunk, delay}, path, config),
    do: stream(sock, head(status, [], nil, path), {:repeat, chunk}, delay, config)

  # Sends the head, then each chunk after `delay` ms, until the chunks run
  # out, the client hangs up, or a cap is reached.
  defp stream(sock, head, chunks, delay, config) do
    deadline = System.monotonic_time(:millisecond) + config.stream_max_ms

    with :ok <- :gen_tcp.send(sock, head),
         do: drip(sock, chunks, delay, config.stream_max_bytes, deadline)
  end

  defp drip(_sock, [], _delay, _left, _deadline), do: :ok
  defp drip(_sock, _chunks, _delay, left, _deadline) when left <= 0, do: :ok

  defp drip(sock, chunks, delay, left, deadline) do
    {chunk, rest} = next_chunk(chunks)
    Process.sleep(max(min(delay, deadline - System.monotonic_time(:millisecond)), 0))

    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      part = binary_part(chunk, 0, min(byte_size(chunk), left))

      case :gen_tcp.send(sock, part) do
        :ok -> drip(sock, rest, delay, left - byte_size(part), deadline)
        {:error, _} -> :ok
      end
    end
  end

  defp next_chunk([chunk | rest]), do: {chunk, rest}
  defp next_chunk({:repeat, chunk} = repeat), do: {chunk, repeat}

  # `length` nil: a body that runs until the connection closes.
  defp head(status, headers, length, path) do
    type =
      if Enum.any?(headers, fn {k, _} -> String.downcase(k) == "content-type" end),
        do: [],
        else: [{"content-type", content_type(path)}]

    framing = if length, do: [{"content-length", Integer.to_string(length)}], else: []

    lines =
      Enum.map(type ++ headers ++ framing ++ [{"connection", "close"}], fn {k, v} ->
        k <> ": " <> v <> "\r\n"
      end)

    IO.iodata_to_binary([
      "HTTP/1.1 #{status} #{Map.get(@reasons, status, "Status")}\r\n",
      lines,
      "\r\n"
    ])
  end

  defp content_type(path) do
    if String.ends_with?(path, ".json"), do: "application/json", else: "application/octet-stream"
  end
end
