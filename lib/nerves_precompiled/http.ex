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
defmodule NervesPrecompiled.HTTP do
  @moduledoc false
  # A streaming :httpc GET with a byte cap and an optional same-origin rule
  # for redirects, on its own httpc profile. Derived from Nerves.HTTPClient
  # (nerves 2.0.0-pre.4) so the client runs where nerves does not: inside a
  # firmware.
  #
  # Two clocks stop a request: the inactivity timer (no message for
  # inactivity_ms) and an overall deadline (deadline_ms from the first
  # request, across redirects), so a server that drips a byte just inside
  # the inactivity window still ends.
  #
  # Known gap: the max_bytes cap is enforced on streamed 2xx bodies only.
  # httpc buffers a non-2xx body whole before answering, and its handler's
  # max_body_size limit is not settable: inets 9.7.1 (OTP 29) ignores
  # max_body_size as a request or profile option ("Invalid option ...
  # ignored"). Such a body is still bounded by the deadline.

  @max_redirects 5
  @profile :nerves_precompiled
  @user_agent ~c"nerves_precompiled/#{Mix.Project.config()[:version]}"
  @connect_timeout 30_000
  @inactivity_ms 60_000
  @deadline_ms 300_000

  @type opts :: [
          max_bytes: pos_integer() | :infinity,
          same_origin: boolean(),
          inactivity_ms: pos_integer(),
          deadline_ms: pos_integer()
        ]
  @type error ::
          String.t()
          | :too_many_redirects
          | :cross_origin_redirect
          | {:too_large, pos_integer()}
          | term()

  @spec get(String.t(), opts()) :: {:ok, binary()} | {:error, error()}
  def get(url, opts \\ []) when is_binary(url) do
    _ = Keyword.validate!(opts, [:max_bytes, :same_origin, :inactivity_ms, :deadline_ms])
    deadline_ms = Keyword.get(opts, :deadline_ms, @deadline_ms)
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    with :ok <- start_httpc(),
         {:ok, cacerts} <- cacerts() do
      url
      |> start_request(opts, cacerts, 0, {deadline, deadline_ms})
      |> await_response()
    end
  end

  @doc false
  # :public_key.cacerts_get/0 raises when the OS has no certificate store; a
  # device without one must get a readable error line, not an exception.
  @spec cacerts((-> [term()])) :: {:ok, [term()]} | {:error, String.t()}
  def cacerts(loader \\ &:public_key.cacerts_get/0) do
    {:ok, loader.()}
  rescue
    _ -> {:error, "no CA certificate store on this system"}
  end

  defp start_request(_url, _opts, _cacerts, redirects, _deadline)
       when redirects > @max_redirects do
    {:done, {:error, :too_many_redirects}}
  end

  defp start_request(url, opts, cacerts, redirects, deadline) do
    http_opts =
      [
        timeout: :infinity,
        connect_timeout: @connect_timeout,
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
           {String.to_charlist(url), [{~c"User-Agent", @user_agent}]},
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
        case content_length(headers) do
          {:ok, content_length} ->
            if exceeds?(content_length, state.max_bytes),
              do: too_large(request_ref, state),
              else:
                await_response({:await, request_ref, %{state | content_length: content_length}})

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
        {:ok, IO.iodata_to_binary(state.acc)}

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

        if state.same_origin and cross_origin?(state.uri, next_uri) do
          {:error, :cross_origin_redirect}
        else
          next_uri
          |> URI.to_string()
          |> start_request(state.opts, state.cacerts, state.redirects + 1, state.deadline)
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

  defp cross_origin?(%URI{host: h, scheme: s, port: p}, %URI{host: h, scheme: s, port: p}),
    do: false

  defp cross_origin?(_from, _to), do: true

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
  defp start_httpc() do
    with {:ok, _} <- Application.ensure_all_started([:inets, :ssl]),
         {:ok, _} <- start_profile() do
      :httpc.set_options(
        [max_sessions: 8, max_keep_alive_length: 4, keep_alive_timeout: 120_000] ++
          proxy_httpc_options(),
        @profile
      )
    else
      {:error, reason} -> {:error, "httpc could not start: #{inspect(reason)}"}
    end
  end

  defp start_profile() do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp proxy_request_options(url) do
    case URI.parse(url) do
      %URI{scheme: "http"} -> proxy_auth("HTTP_PROXY")
      %URI{scheme: "https"} -> proxy_auth("HTTPS_PROXY")
      _ -> []
    end
  end

  defp proxy_httpc_options() do
    add_httpc_proxy(:proxy, "HTTP_PROXY") ++ add_httpc_proxy(:https_proxy, "HTTPS_PROXY")
  end

  defp proxy_auth(env_key) do
    case parse_proxy_env(env_key) do
      %URI{userinfo: auth} when is_binary(auth) ->
        destructure [user, pass], String.split(auth, ":", parts: 2)
        user = String.to_charlist(user)
        pass = String.to_charlist(pass || "")
        [proxy_auth: {user, pass}]

      _ ->
        []
    end
  end

  defp add_httpc_proxy(key, env_key) do
    case parse_proxy_env(env_key) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        [{key, {{String.to_charlist(host), port}, []}}]

      _ ->
        []
    end
  end

  defp parse_proxy_env(key) do
    case System.get_env(key) do
      nil -> nil
      uri -> URI.parse(uri)
    end
  end
end
