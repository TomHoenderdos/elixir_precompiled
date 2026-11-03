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
  """

  @loopback ~w(127.0.0.1 ::1 localhost)

  @doc """
  GETs `url`. `{:ok, body}` on 200, `{:error, reason}` otherwise, where
  `reason` is a short human-readable string.
  """
  @spec get(String.t(), pos_integer()) :: {:ok, binary()} | {:error, String.t()}
  def get(url, timeout_ms) do
    case scheme(url) do
      "https" -> request(url, timeout_ms)
      "http" -> if loopback_allowed?(url), do: request(url, timeout_ms), else: refuse(url)
      _ -> {:error, "GET #{url} refused: only https (or plain http to loopback) is allowed"}
    end
  end

  defp refuse(url),
    do: {:error, "GET #{url} refused: plain http is only allowed to a loopback host"}

  defp request(url, timeout_ms) do
    http_opts =
      [timeout: timeout_ms, connect_timeout: timeout_ms, autoredirect: false] ++ ssl_opts(url)

    case :httpc.request(:get, {to_charlist(url), []}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _}} -> {:error, "GET #{url} answered #{status}"}
      {:error, reason} -> {:error, "GET #{url} failed: #{inspect(reason)}"}
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
