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
defmodule ElixirPrecompiled.HTTP do
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
  # Known gap: the max_bytes cap is enforced on streamed 2xx bodies only.
  # httpc buffers a non-2xx body whole before answering, and its handler's
  # max_body_size limit is not settable: inets 9.7.1 (OTP 29) ignores
  # max_body_size as a request or profile option ("Invalid option ...
  # ignored"). Such a body is still bounded by the deadline.

  @max_redirects 5
  @profile :elixir_precompiled
  @user_agent ~c"elixir_precompiled/#{Mix.Project.config()[:version]}"
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
          allowed_origins: [String.t()]
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
    :allowed_origins
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

    with :ok <- before(deadline, now),
         :ok <- start_httpc(),
         {:ok, cacerts} <- cacerts() do
      url
      |> start_request(opts, cacerts, 0, {deadline, deadline - now}, origins(url, opts))
      |> await_response()
    end
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
  defp secure_origin?(%URI{scheme: "http", host: h}) when h in @loopback, do: true
  defp secure_origin?(_uri), do: false

  defp origin(%URI{scheme: s, host: h, port: p}), do: {s, h && String.downcase(h), p}

  @doc false
  # :public_key.cacerts_get/0 raises when the OS has no certificate store; a
  # device without one must get a readable error line, not an exception.
  @spec cacerts((-> [term()] | {:error, String.t()})) :: {:ok, [term()]} | {:error, String.t()}
  def cacerts(loader \\ &default_cacerts/0) do
    case loader.() do
      {:error, _} = error -> error
      certs -> {:ok, certs}
    end
  rescue
    _ -> {:error, "no CA certificate store on this system"}
  end

  # A corporate TLS-intercepting proxy needs its own CA; Hex's variable is
  # honoured too, so one setting serves both. The file replaces the OS store
  # as Hex's does; verification itself is never turned off.
  defp default_cacerts() do
    case System.get_env("ELIXIR_PRECOMPILED_CACERTS_PATH") || System.get_env("HEX_CACERTS_PATH") do
      nil ->
        :public_key.cacerts_get()

      path ->
        try do
          pem_cacerts(path)
        rescue
          e -> {:error, "CA certificate file #{path}: #{Exception.message(e)}"}
        end
    end
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
    headers =
      [{~c"User-Agent", @user_agent}] ++
        for {k, v} <- Keyword.get(opts, :headers, []),
            do: {String.to_charlist(k), String.to_charlist(v)}

    http_opts =
      [
        timeout: :infinity,
        connect_timeout: Keyword.get(opts, :connect_timeout_ms, @connect_timeout),
        autoredirect: false,
        ssl: [
          verify: :verify_peer,
          cacerts: cacerts,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
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

      {:http, {^request_ref, {{_, 304, _}, _headers, _body}}} ->
        :not_modified

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
  # The proxy settings are read from the environment on every request.
  # httpc cannot unset a proxy through set_options, and a kept-alive session
  # goes on routing by the options it was opened with, so a profile whose
  # proxy settings differ from the environment's is restarted with them.
  defp start_httpc() do
    proxies = proxy_httpc_options()

    with {:ok, _} <- Application.ensure_all_started([:inets, :ssl]),
         {:ok, _} <- start_profile(),
         :ok <- restart_on_proxy_change(proxies) do
      :httpc.set_options(
        [max_sessions: 8, max_keep_alive_length: 4, keep_alive_timeout: 120_000] ++
          Enum.reject(proxies, &match?({_, {:undefined, _}}, &1)),
        @profile
      )
    else
      {:error, reason} -> {:error, "httpc could not start: #{inspect(reason)}"}
    end
  end

  defp restart_on_proxy_change(proxies) do
    case :httpc.get_options([:proxy, :https_proxy], @profile) do
      {:ok, current} ->
        if Enum.sort(current) == Enum.sort(proxies) do
          :ok
        else
          _ = :inets.stop(:httpc, @profile)
          with {:ok, _} <- start_profile(), do: :ok
        end

      _ ->
        :ok
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
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> proxy_auth(proxy_env(scheme))
      _ -> []
    end
  end

  defp proxy_httpc_options() do
    case no_proxy() do
      :all ->
        [proxy: {:undefined, []}, https_proxy: {:undefined, []}]

      list ->
        add_httpc_proxy(:proxy, proxy_env("http"), list) ++
          add_httpc_proxy(:https_proxy, proxy_env("https"), list)
    end
  end

  defp proxy_auth(nil), do: []

  defp proxy_auth(value) do
    case URI.parse(value) do
      %URI{userinfo: auth} when is_binary(auth) ->
        destructure [user, pass], String.split(auth, ":", parts: 2)
        [proxy_auth: {String.to_charlist(user), String.to_charlist(pass || "")}]

      _ ->
        []
    end
  end

  defp add_httpc_proxy(key, nil, _no_proxy), do: [{key, {:undefined, []}}]

  defp add_httpc_proxy(key, value, no_proxy) do
    case URI.parse(value) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        [{key, {{String.to_charlist(host), port}, no_proxy}}]

      _ ->
        [{key, {:undefined, []}}]
    end
  end

  @doc false
  # NO_PROXY as httpc takes it: each host and its subdomains ("*.host"),
  # ports dropped; "*" means no proxy at all.
  @spec no_proxy_list(String.t() | nil) :: :all | [charlist()]
  def no_proxy_list(nil), do: []

  def no_proxy_list(value) do
    entries =
      value
      |> String.split(",", trim: true)
      |> Enum.map(
        &(&1
          |> String.trim()
          |> String.replace(~r/:\d+\z/, "")
          |> String.trim_leading("."))
      )
      |> Enum.reject(&(&1 == ""))

    if "*" in entries,
      do: :all,
      else: Enum.flat_map(entries, &[String.to_charlist(&1), String.to_charlist("*." <> &1)])
  end
end
