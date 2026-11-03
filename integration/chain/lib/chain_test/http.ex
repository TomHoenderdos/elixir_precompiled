# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.HTTP do
  @moduledoc """
  One `:httpc` GET. An `https://` URL is fetched with peer verification
  against the OS CA store and the https hostname check; there is no way to
  turn that off.
  """

  @doc """
  GETs `url`. `{:ok, body}` on 200, `{:error, reason}` otherwise, where
  `reason` is a short human-readable string.
  """
  @spec get(String.t(), pos_integer()) :: {:ok, binary()} | {:error, String.t()}
  def get(url, timeout_ms) do
    http_opts = [timeout: timeout_ms, connect_timeout: timeout_ms] ++ ssl_opts(url)

    case :httpc.request(:get, {to_charlist(url), []}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _}} -> {:error, "GET #{url} answered #{status}"}
      {:error, reason} -> {:error, "GET #{url} failed: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec ssl_opts(String.t()) :: keyword()
  def ssl_opts("https://" <> _) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  def ssl_opts(_), do: []
end
