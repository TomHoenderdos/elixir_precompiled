# SPDX-FileCopyrightText: 2016 Justin Schneck
# SPDX-FileCopyrightText: 2018 Michael Schmidt
# SPDX-FileCopyrightText: 2020 Tomasz Kazimierz Motyl
# SPDX-FileCopyrightText: 2021 Frank Hunleth
# SPDX-FileCopyrightText: 2021 Jon Carstens
# SPDX-FileCopyrightText: 2021 Jon Thacker
# SPDX-FileCopyrightText: 2022 Martin Wagner
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HTTP do
  @moduledoc false
  # A streaming :httpc GET with a byte cap and an optional same-origin rule
  # for redirects, on its own httpc profile. Derived from Nerves.HTTPClient
  # (nerves 2.0.0-pre.4) so the client runs where nerves does not: inside a
  # firmware.
  #
  # Two clocks stop a request: the inactivity timer (no message for
  # inactivity_ms) and an overall deadline (deadline_ms from the first
  # request, across redirects, or the run's deadline_at when that comes
  # first), so a server that drips a byte just inside the inactivity window
  # still ends.
  #
  # With same_origin, a redirect may only go to the request's own origin or
  # one of allowed_origins (content origins the signed batch or the project
  # names); an allowed origin counts only over https, or http on loopback.
  #
  # Offline (the :offline option, or PRECOMPILED_OFFLINE set) no
  # request is ever made: every call answers {:error, "offline"} before it
  # connects, whoever the caller is.
  #
  # The caller's headers are sent on every hop, to every allowed origin:
  # never pass credentials (Authorization, cookies) in them.
  #
  # Known gap: the max_bytes cap is enforced on streamed 2xx bodies only.
  # httpc buffers a non-2xx body whole before answering, and its handler's
  # max_body_size limit is not settable: inets 9.7.1 (OTP 29) ignores
  # max_body_size as a request or profile option ("Invalid option ...
  # ignored"). Such a body is still bounded by the deadline.
  #
  # post/3 sends a miss report: never redirected, https or loopback http
  # only, and its answer capped while it is read. A 200 is streamed and
  # counted chunk by chunk, as a GET's body is. Any other status httpc
  # buffers whole; where inets takes max_body_size as a request option
  # (9.8, OTP 29) that caps a sized or chunked body as it arrives, and
  # elsewhere, or for a body that only ends when the connection closes,
  # the deadline bounds it.

  @max_redirects 5
  @profile :precompiled
  @user_agent ~c"precompiled/#{Mix.Project.config()[:version]}"
  @connect_timeout 30_000
  @inactivity_ms 60_000
  @deadline_ms 300_000

  @loopback ["127.0.0.1", "::1", "localhost"]

  @type opts :: [
          max_bytes: pos_integer() | :infinity,
          same_origin: boolean(),
          inactivity_ms: pos_integer(),
          deadline_ms: pos_integer(),
          deadline_at: integer(),
          connect_timeout_ms: pos_integer(),
          headers: [{String.t(), String.t()}],
          allowed_origins: [String.t()],
          offline: boolean(),
          cacerts_path: Path.t()
        ]
  @type error ::
          String.t()
          | :too_many_redirects
          | :cross_origin_redirect
          | {:too_large, pos_integer()}
          | term()

  @keys [
    :max_bytes,
    :same_origin,
    :inactivity_ms,
    :deadline_ms,
    :deadline_at,
    :connect_timeout_ms,
    :headers,
    :allowed_origins,
    :offline,
    :cacerts_path
  ]

  @spec get(String.t(), opts()) :: {:ok, binary()} | {:error, error()}
  def get(url, opts \\ []) when is_binary(url) do
    case request(url, opts) do
      {:ok, body, _etag} -> {:ok, body}
      :not_modified -> {:error, format_error(304, ~c"Not Modified")}
      {:error, _} = error -> error
    end
  end

  @doc """
  GET `url`; the body comes back with the response's ETag (or nil), and a
  304 to a conditional request (`headers: [{"if-none-match", etag}]`) is
  `:not_modified`.
  """
  @spec request(String.t(), opts()) ::
          {:ok, binary(), String.t() | nil} | :not_modified | {:error, error()}
  def request(url, opts \\ []) when is_binary(url) do
    _ = Keyword.validate!(opts, @keys)
    now = System.monotonic_time(:millisecond)
    own = now + Keyword.get(opts, :deadline_ms, @deadline_ms)
    deadline = min(own, Keyword.get(opts, :deadline_at, own))

    with :ok <- online(opts),
         :ok <- before(deadline, now),
         :ok <- start_httpc(),
         {:ok, cacerts} <- cacerts_for(opts) do
      url
      |> start_request(opts, cacerts, 0, {deadline, deadline - now}, origins(url, opts))
      |> await_response()
    end
  end

  defp online(opts) do
    if Keyword.get(opts, :offline, false) or Precompiled.Config.offline?(),
      do: {:error, "offline"},
      else: :ok
  end

  defp before(deadline, now) when deadline > now, do: :ok
  defp before(_deadline, _now), do: {:error, "run deadline passed"}

  # The origins a same-origin request may be redirected to: its own and the
  # content origins the signed batch (or the project) allows. An allowed
  # origin must be https, or http on this machine: a redirect never
  # downgrades a request to plain http across the network.
  defp origins(url, opts) do
    allowed =
      for o <- Keyword.get(opts, :allowed_origins, []),
          uri = URI.parse(o),
          secure_origin?(uri),
          do: origin(uri)

    MapSet.new([origin(URI.parse(url)) | allowed])
  end

  defp secure_origin?(%URI{scheme: "https", host: h}) when is_binary(h) and h != "", do: true

  defp secure_origin?(%URI{scheme: "http", host: h}) when is_binary(h),
    do: String.downcase(h) in @loopback

  defp secure_origin?(_uri), do: false

  defp origin(%URI{scheme: s, host: h, port: p}), do: {s, h && String.downcase(h), p}

  @doc false
  # The CA certificates a request verifies the server with, in this order:
  # the :cacerts_path option, the environment's file (below), the OS store
  # (:public_key.cacerts_get/0), then CAStore's bundle when the CAStore
  # package is loaded. A file that is named but unusable is an error, never
  # a quiet fallback to another set.
  @spec cacerts_for(keyword()) :: {:ok, [term()]} | {:error, String.t()}
  def cacerts_for(opts) do
    case Keyword.get(opts, :cacerts_path) do
      path when is_binary(path) -> cacerts(fn -> file_cacerts(path) end)
      _ -> cacerts()
    end
  end

  @doc false
  # :public_key.cacerts_get/0 raises when the OS has no certificate store; a
  # device without one must get a readable error line, not an exception. No
  # certificates at all is an error too: TLS is never tried without any.
  @spec cacerts((-> [term()] | {:error, String.t()})) :: {:ok, [term()]} | {:error, String.t()}
  def cacerts(loader \\ &default_cacerts/0) do
    case loader.() do
      {:error, _} = error -> error
      [] -> {:error, "no CA certificates"}
      certs -> {:ok, certs}
    end
  rescue
    _ -> {:error, "no CA certificate store on this system"}
  end

  # A corporate TLS-intercepting proxy needs its own CA; Hex's variable is
  # honoured too, so one setting serves both. The file replaces the OS store
  # as Hex's does; verification itself is never turned off.
  defp default_cacerts() do
    case System.get_env("PRECOMPILED_CACERTS_PATH") || System.get_env("HEX_CACERTS_PATH") do
      nil -> store_cacerts(&:public_key.cacerts_get/0, CAStore)
      path -> file_cacerts(path)
    end
  end

  @doc false
  # The OS store, else (when it is empty or there is none) the bundle of
  # `castore`, the CAStore package, when that is loaded: a firmware has no
  # OS store but may carry CAStore. Called through apply/3, so this library
  # does not depend on it.
  @spec store_cacerts((-> [term()]), module()) :: [term()] | {:error, String.t()}
  def store_cacerts(os_loader, castore) do
    case os_store(os_loader) do
      [_ | _] = certs -> certs
      _ -> castore_cacerts(castore)
    end
  end

  defp os_store(loader) do
    loader.()
  rescue
    _ -> []
  end

  defp castore_cacerts(castore) do
    if Code.ensure_loaded?(castore),
      do: file_cacerts(apply(castore, :file_path, [])),
      else: {:error, "no CA certificates"}
  end

  defp file_cacerts(path) do
    pem_cacerts(path)
  rescue
    e -> {:error, "CA certificate file #{path}: #{Exception.message(e)}"}
  end

  @doc false
  @spec pem_cacerts(Path.t()) :: [binary()]
  def pem_cacerts(path) do
    case for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(File.read!(path)),
             do: der do
      [] -> raise ArgumentError, "no certificates in #{path}"
      ders -> ders
    end
  end

  defp start_request(_url, _opts, _cacerts, redirects, _deadline, _origins)
       when redirects > @max_redirects do
    {:done, {:error, :too_many_redirects}}
  end

  defp start_request(url, opts, cacerts, redirects, deadline, origins) do
    url = lower_case_host(url)

    headers =
      [{~c"User-Agent", @user_agent}] ++
        for {k, v} <- Keyword.get(opts, :headers, []),
            do: {String.to_charlist(k), String.to_charlist(v)}

    http_opts =
      [
        timeout: :infinity,
        connect_timeout: Keyword.get(opts, :connect_timeout_ms, @connect_timeout),
        autoredirect: false,
        ssl: ssl_opts(cacerts)
      ] ++ proxy_request_options(url)

    case :httpc.request(
           :get,
           {String.to_charlist(url), headers},
           http_opts,
           [stream: :self, receiver: self(), sync: false],
           @profile
         ) do
      {:ok, request_ref} ->
        {:await, request_ref,
         %{
           acc: [],
           received: 0,
           content_length: 0,
           etag: nil,
           origins: origins,
           max_bytes: Keyword.get(opts, :max_bytes, :infinity),
           same_origin: Keyword.get(opts, :same_origin, false),
           inactivity_ms: Keyword.get(opts, :inactivity_ms, @inactivity_ms),
           opts: opts,
           cacerts: cacerts,
           redirects: redirects,
           deadline: deadline,
           uri: URI.parse(url)
         }}

      {:error, reason} ->
        {:done, {:error, reason}}
    end
  end

  defp ssl_opts(cacerts),
    do: [
      verify: :verify_peer,
      cacerts: cacerts,
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

  @post_max_bytes 16_384
  @post_deadline_ms 15_000
  @post_keys [:max_bytes, :deadline_ms, :connect_timeout_ms, :cacerts_path, :offline]

  @doc """
  POST `body` as `application/json`. Only https, or http on loopback; never
  redirected. `{:ok, status, body}` for any final answer, so the caller
  decides what a 4xx means.
  """
  @spec post(String.t(), iodata(), keyword()) ::
          {:ok, pos_integer(), binary()} | {:error, term()}
  def post(url, body, opts \\ []) when is_binary(url) do
    _ = Keyword.validate!(opts, @post_keys)
    max = Keyword.get(opts, :max_bytes, @post_max_bytes)
    deadline_ms = Keyword.get(opts, :deadline_ms, @post_deadline_ms)
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    with :ok <- post_transport(url),
         :ok <- online(opts),
         :ok <- start_httpc(),
         {:ok, cacerts} <- cacerts_for(opts) do
      url = lower_case_host(url)
      headers = [{~c"User-Agent", @user_agent}, {~c"Accept", ~c"application/json"}]

      http_opts =
        [
          timeout: deadline_ms,
          connect_timeout: Keyword.get(opts, :connect_timeout_ms, @connect_timeout),
          autoredirect: false,
          ssl: ssl_opts(cacerts)
        ] ++ proxy_request_options(url)

      request =
        {String.to_charlist(url), headers, ~c"application/json", IO.iodata_to_binary(body)}

      case :httpc.request(
             :post,
             request,
             http_opts,
             [sync: false, receiver: self(), stream: :self, body_format: :binary] ++
               body_cap(max),
             @profile
           ) do
        {:ok, ref} ->
          await_post(ref, %{max: max, deadline: {deadline, deadline_ms}, received: 0, acc: []})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp post_transport(url) do
    if secure_origin?(URI.parse(url)),
      do: :ok,
      else: {:error, "plain http is only allowed on loopback"}
  end

  # httpc streams only a 200 or 206 body; every other answer arrives whole.
  defp await_post(ref, state) do
    {deadline, deadline_ms} = state.deadline
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http, {^ref, {:error, reason}}} ->
        post_error(reason, state.max)

      {:http, {^ref, :stream_start, headers}} ->
        case content_length(headers) do
          {:ok, n} ->
            if exceeds?(n, state.max),
              do: post_too_large(ref, state.max),
              else: await_post(ref, state)

          :error ->
            cancel_and_drain(ref)
            {:error, "invalid content-length"}
        end

      {:http, {^ref, :stream, data}} ->
        size = state.received + byte_size(data)

        if exceeds?(size, state.max),
          do: post_too_large(ref, state.max),
          else: await_post(ref, %{state | received: size, acc: [state.acc | data]})

      # A streamed answer does not carry its status; the report endpoint
      # never sends a partial-content 206, so it is the 200.
      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, 200, IO.iodata_to_binary(state.acc)}

      {:http, {^ref, {{_, status, _}, _headers, _body}}} when div(status, 100) == 3 ->
        {:error, :redirect}

      {:http, {^ref, {{_, _status, _}, _headers, body}}} when byte_size(body) > state.max ->
        {:error, {:too_large, state.max}}

      {:http, {^ref, {{_, status, _}, _headers, body}}} ->
        {:ok, status, body}
    after
      left ->
        cancel_and_drain(ref)
        {:error, "no response within #{format_seconds(deadline_ms)} s"}
    end
  end

  defp post_too_large(ref, max) do
    cancel_and_drain(ref)
    {:error, {:too_large, max}}
  end

  # httpc's own cap: :body_too_big for a sized body, body_too_long for a
  # chunked one.
  defp post_error(:body_too_big, max), do: {:error, {:too_large, max}}
  defp post_error({:body_too_long, _}, max), do: {:error, {:too_large, max}}
  defp post_error(reason, _max), do: {:error, reason}

  defp body_cap(max), do: if(capped_buffer?(), do: [max_body_size: max], else: [])

  @doc false
  # Whether httpc takes max_body_size as a request option, so a body it
  # buffers whole is capped while it arrives: inets 9.8 (OTP 29) does,
  # older ones log the option as invalid and ignore it.
  @spec capped_buffer?() :: boolean()
  def capped_buffer?() do
    _ = Application.load(:inets)

    case Application.spec(:inets, :vsn) do
      vsn when is_list(vsn) -> version_parts(vsn) >= [9, 8]
      _ -> false
    end
  end

  defp version_parts(vsn) do
    for part <- vsn |> List.to_string() |> String.split("."),
        do:
          part
          |> Integer.parse()
          |> then(fn
            {n, _} -> n
            :error -> 0
          end)
  end

  defp await_response({:done, result}), do: result

  defp await_response({:await, request_ref, state}) do
    {deadline, deadline_ms} = state.deadline
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http, {^request_ref, {:error, _} = err}} ->
        err

      {:http, {^request_ref, :stream_start, headers}} ->
        etag = with {_, v} <- List.keyfind(headers, ~c"etag", 0), do: List.to_string(v)

        case content_length(headers) do
          {:ok, content_length} ->
            if exceeds?(content_length, state.max_bytes),
              do: too_large(request_ref, state),
              else:
                await_response(
                  {:await, request_ref, %{state | content_length: content_length, etag: etag}}
                )

          :error ->
            cancel_and_drain(request_ref)
            {:error, "invalid content-length"}
        end

      {:http, {^request_ref, :stream, data}} ->
        size = byte_size(data) + state.received

        if exceeds?(size, state.max_bytes),
          do: too_large(request_ref, state),
          else:
            await_response(
              {:await, request_ref, %{state | received: size, acc: [state.acc | data]}}
            )

      {:http, {^request_ref, :stream_end, _headers}} ->
        {:ok, IO.iodata_to_binary(state.acc), state.etag}

      {:http, {^request_ref, {{_, 304, reason}, _headers, _body}}} ->
        if conditional?(state.opts),
          do: :not_modified,
          else: {:error, format_error(304, reason)}

      {:http, {^request_ref, {{_, status_code, reason}, headers, _body}}}
      when div(status_code, 100) == 3 ->
        redirect(headers, status_code, reason, state)

      {:http, {^request_ref, {{_, status_code, reason}, _headers, _body}}} ->
        {:error, format_error(status_code, reason)}
    after
      min(state.inactivity_ms, left) ->
        cancel_and_drain(request_ref)

        if left < state.inactivity_ms,
          do: {:error, "no response within #{format_seconds(deadline_ms)} s"},
          else: {:error, "no data for #{format_seconds(state.inactivity_ms)} s"}
    end
  end

  # NO_PROXY entries are lower-cased and httpc matches hosts as given, so
  # the request's host is lower-cased too: case never routes a NO_PROXY
  # host through the proxy. (httpc's own uri_string:normalize/1 does this
  # on OTP 27+ as well; this does not depend on it.)
  defp lower_case_host(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) ->
        URI.to_string(%{uri | host: String.downcase(host)})

      _ ->
        url
    end
  end

  defp redirect(headers, status_code, reason, state) do
    case List.keyfind(headers, ~c"location", 0) do
      {_, next_location} ->
        next_uri = URI.merge(state.uri, List.to_string(next_location))

        if state.same_origin and not MapSet.member?(state.origins, origin(next_uri)) do
          {:error, :cross_origin_redirect}
        else
          next_uri
          |> URI.to_string()
          |> start_request(
            state.opts,
            state.cacerts,
            state.redirects + 1,
            state.deadline,
            state.origins
          )
          |> await_response()
        end

      nil ->
        {:error, format_error(status_code, reason)}
    end
  end

  # A 304 answers only a conditional request; to any other it is an error.
  defp conditional?(opts) do
    Enum.any?(Keyword.get(opts, :headers, []), fn {k, _} ->
      String.downcase(k) == "if-none-match"
    end)
  end

  defp too_large(request_ref, state) do
    cancel_and_drain(request_ref)
    {:error, {:too_large, state.max_bytes}}
  end

  # httpc keeps delivering messages it already queued for a few moments after
  # :httpc.cancel_request/2 returns; wait until the mailbox has been quiet for
  # 100 ms rather than draining once, so none of them reach the caller.
  defp cancel_and_drain(request_ref) do
    :httpc.cancel_request(request_ref, @profile)
    drain(request_ref)
  end

  defp drain(request_ref) do
    receive do
      {:http, msg} when is_tuple(msg) and elem(msg, 0) == request_ref ->
        drain(request_ref)
    after
      100 -> :ok
    end
  end

  defp exceeds?(_size, :infinity), do: false
  defp exceeds?(size, max_bytes), do: size > max_bytes

  @doc false
  # A content-length that doesn't parse as a non-negative integer is a
  # malformed or hostile response; the caller gets an error, not a crash.
  @spec content_length([{charlist(), charlist()}]) :: {:ok, non_neg_integer()} | :error
  def content_length(headers) do
    case List.keyfind(headers, ~c"content-length", 0) do
      nil ->
        {:ok, 0}

      {_, value} ->
        case value |> to_string() |> Integer.parse() do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp format_error(status_code, reason), do: "Status #{status_code} #{reason}"

  defp format_seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)

  # :inets.start/2 answers {:ok, pid} or {:error, {:already_started, pid}} on
  # the happy paths and {:error, other} when inets itself is broken; the
  # fetch must not continue past that.
  #
  # The proxy settings are decided once per VM, on the first request, and
  # never change under requests in flight: httpc cannot unset a proxy, and
  # a kept-alive session keeps routing by the options it was opened with.
  defp start_httpc() do
    with {:ok, _} <- Application.ensure_all_started([:inets, :ssl]),
         {:ok, _} <- start_profile() do
      :httpc.set_options(
        [max_sessions: 8, max_keep_alive_length: 4, keep_alive_timeout: 120_000] ++
          proxy_config().httpc,
        @profile
      )
    else
      {:error, reason} -> {:error, "httpc could not start: #{inspect(reason)}"}
    end
  end

  @proxy_key {__MODULE__, :proxy_config}

  defp proxy_config() do
    case :persistent_term.get(@proxy_key, nil) do
      nil ->
        config = read_proxy_config()
        :persistent_term.put(@proxy_key, config)
        config

      config ->
        config
    end
  end

  @doc false
  # Tests only: forget the proxy decision and stop the profile, so the next
  # request reads the environment again. Never called during a run.
  @spec reset_proxy_config() :: :ok
  def reset_proxy_config() do
    _ = :persistent_term.erase(@proxy_key)
    _ = :inets.stop(:httpc, @profile)
    :ok
  end

  defp read_proxy_config() do
    case no_proxy() do
      :all ->
        %{httpc: [], auth: %{}}

      list ->
        schemes = [{"http", :proxy}, {"https", :https_proxy}]

        %{
          httpc: Enum.flat_map(schemes, fn {s, key} -> httpc_proxy(key, proxy_env(s), list) end),
          auth: Map.new(schemes, fn {s, _} -> {s, proxy_auth(proxy_env(s))} end)
        }
    end
  end

  defp start_profile() do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp proxy_env("https"), do: System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
  defp proxy_env("http"), do: System.get_env("HTTP_PROXY") || System.get_env("http_proxy")

  defp no_proxy(), do: no_proxy_list(System.get_env("NO_PROXY") || System.get_env("no_proxy"))

  # httpc sends proxy_auth only on a request it routes through the proxy,
  # so a NO_PROXY host never sees the proxy's credentials.
  defp proxy_request_options(url) do
    Map.get(proxy_config().auth, URI.parse(url).scheme, [])
  end

  defp proxy_auth(nil), do: []

  defp proxy_auth(value) do
    case URI.parse(value) do
      %URI{userinfo: auth} when is_binary(auth) ->
        destructure [user, pass], String.split(auth, ":", parts: 2)

        [
          proxy_auth:
            {String.to_charlist(URI.decode(user)), String.to_charlist(URI.decode(pass || ""))}
        ]

      _ ->
        []
    end
  end

  defp httpc_proxy(_key, nil, _no_proxy), do: []

  defp httpc_proxy(key, value, no_proxy) do
    case URI.parse(value) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        [{key, {{String.to_charlist(host), port}, no_proxy}}]

      _ ->
        []
    end
  end

  @doc false
  # NO_PROXY as httpc takes it: each host lower-cased and its subdomains
  # ("*.host"), an IP literal alone, ports dropped, "[v6]" unbracketed;
  # "*" means no proxy at all. CIDR ranges (10.0.0.0/8) are not supported
  # by httpc's matching and are dropped.
  @spec no_proxy_list(String.t() | nil) :: :all | [charlist()]
  def no_proxy_list(nil), do: []

  def no_proxy_list(value) do
    entries =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&no_proxy_entry/1)
      |> Enum.reject(&(&1 == "" or String.contains?(&1, "/")))

    if "*" in entries,
      do: :all,
      else: entries |> Enum.flat_map(&no_proxy_patterns/1) |> Enum.uniq()
  end

  defp no_proxy_entry(entry) do
    entry = entry |> String.trim() |> String.downcase()

    cond do
      # [v6] or [v6]:port
      match = Regex.run(~r/\A\[([^\]]*)\](?::\d*)?\z/, entry) ->
        Enum.at(match, 1)

      # host:port; a bare IPv6 address has more than one colon and no port
      length(String.split(entry, ":")) == 2 ->
        entry |> String.replace(~r/:\d*\z/, "") |> String.trim_leading(".")

      true ->
        String.trim_leading(entry, ".")
    end
  end

  defp no_proxy_patterns(entry) do
    case :inet.parse_address(String.to_charlist(entry)) do
      {:ok, _} -> [String.to_charlist(entry)]
      {:error, _} -> [String.to_charlist(entry), String.to_charlist("*." <> entry)]
    end
  end
end
