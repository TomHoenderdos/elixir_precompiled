# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.HTTP do
  @moduledoc """
  One `:httpc` GET. An `https://` URL is fetched with peer verification
  against the OS CA store and the https hostname check; there is no way to
  turn that off. Plain `http://` is allowed only to a loopback host (the
  tests' local server). Redirects are never followed: a 3xx is an error.
  A body is streamed and cut off past `max_bytes` (default 64 MiB; roots,
  batches and manifests are far smaller), which is an error.
  """

  @loopback ~w(127.0.0.1 ::1 localhost)
  @max_bytes 64 * 1024 * 1024

  @doc "The default body cap in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes(), do: @max_bytes

  @doc """
  GETs `url`. `{:ok, body}` on 200, `{:error, reason}` otherwise, where
  `reason` is a short human-readable string. `timeout_ms` bounds the whole
  request. Option `:max_bytes`.
  """
  @spec get(String.t(), pos_integer(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def get(url, timeout_ms, opts \\ []) do
    max = Keyword.get(opts, :max_bytes, @max_bytes)

    case scheme(url) do
      "https" -> request(url, timeout_ms, max)
      "http" -> if loopback_allowed?(url), do: request(url, timeout_ms, max), else: refuse(url)
      _ -> {:error, "GET #{url} refused: only https (or plain http to loopback) is allowed"}
    end
  end

  defp refuse(url),
    do: {:error, "GET #{url} refused: plain http is only allowed to a loopback host"}

  defp request(url, timeout_ms, max) do
    http_opts =
      [timeout: timeout_ms, connect_timeout: timeout_ms, autoredirect: false] ++ ssl_opts(url)

    opts = [sync: false, stream: :self, body_format: :binary]

    case :httpc.request(:get, {to_charlist(url), []}, http_opts, opts) do
      {:ok, ref} ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        receive_body(ref, url, deadline, max, [], 0)

      {:error, reason} ->
        {:error, "GET #{url} failed: #{inspect(reason)}"}
    end
  end

  # A 200 arrives as stream_start, parts, stream_end; anything else whole.
  defp receive_body(ref, url, deadline, max, acc, size) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        receive_body(ref, url, deadline, max, acc, size)

      {:http, {^ref, :stream, part}} ->
        size = size + byte_size(part)

        if size > max do
          :httpc.cancel_request(ref)
          {:error, "GET #{url}: body larger than #{max} bytes"}
        else
          receive_body(ref, url, deadline, max, [acc | part], size)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {:http, {^ref, {{_, 200, _}, _, body}}} ->
        if byte_size(body) > max,
          do: {:error, "GET #{url}: body larger than #{max} bytes"},
          else: {:ok, body}

      {:http, {^ref, {{_, status, _}, _, _}}} ->
        {:error, "GET #{url} answered #{status}"}

      {:http, {^ref, {:error, reason}}} ->
        {:error, "GET #{url} failed: #{inspect(reason)}"}
    after
      left ->
        :httpc.cancel_request(ref)
        {:error, "GET #{url} failed: timeout after the request's deadline"}
    end
  end

  @doc "Whether `url` is plain http to a loopback host."
  @spec loopback_allowed?(String.t()) :: boolean()
  def loopback_allowed?(url) do
    scheme(url) == "http" and String.downcase(URI.parse(url).host || "") in @loopback
  end

  defp scheme(url), do: (URI.parse(url).scheme || "") |> String.downcase()

  @doc false
  @spec ssl_opts(String.t()) :: keyword()
  def ssl_opts(url) do
    if scheme(url) == "https" do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 4,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    else
      []
    end
  end
end
