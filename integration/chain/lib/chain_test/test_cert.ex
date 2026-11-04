# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.TestCert do
  @moduledoc """
  Throwaway TLS certificates for the TLS mirror (N3, N6), made with
  `:public_key` in memory: no `openssl`, no file. Every call makes new
  P-256 keys, and a new CA where the kind has one; nothing is kept.

  Kinds:

    * `:ip` - a leaf for `127.0.0.1` (an IP address SAN), issued by a CA of
      its own. Valid for the mirror's URL to a client that trusts that CA.
    * `:wrong_host` - a leaf for `wrong-host.invalid` only (a DNS SAN, no IP
      address), issued by a CA of its own: wrong for `127.0.0.1` even to a
      client that trusts the CA.
    * `:self_signed` - a certificate for `127.0.0.1` that is its own issuer,
      with no CA anyone could be given.

  `server/1` answers `%{ssl: [cert: der, key: {:ECPrivateKey, der}], ca:
  der | nil}`: the `:ssl` server options and the CA certificate a client
  would have to trust (`nil` for `:self_signed`).
  """

  @san {2, 5, 29, 17}
  @kinds [:ip, :wrong_host, :self_signed]
  @localhost [iPAddress: <<127, 0, 0, 1>>]

  @type kind :: :ip | :wrong_host | :self_signed
  @type server :: %{ssl: keyword(), ca: binary() | nil}

  @doc "The certificate kinds."
  @spec kinds() :: [kind()]
  def kinds(), do: @kinds

  @doc "New server credentials of `kind` (see the moduledoc)."
  @spec server(kind()) :: server()
  def server(:self_signed) do
    cert =
      :public_key.pkix_test_root_cert(~c"chain-test self-signed", [
        {:key, curve()},
        {:digest, :sha256},
        {:extensions, [san(@localhost)]}
      ])

    %{ssl: [cert: cert.cert, key: key_entry(cert.key)], ca: nil}
  end

  def server(:ip), do: issued(@localhost)
  def server(:wrong_host), do: issued(dNSName: ~c"wrong-host.invalid")

  @doc "`der` as a PEM certificate."
  @spec pem(binary()) :: binary()
  def pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  # A leaf naming `names`, under a CA made for it alone.
  defp issued(names) do
    ca = :public_key.pkix_test_root_cert(~c"chain-test CA", [{:key, curve()}, {:digest, :sha256}])
    leaf = [{:key, curve()}, {:digest, :sha256}, {:extensions, [san(names)]}]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: ca, intermediates: [], peer: leaf},
        # Unused: pkix_test_data needs both chains.
        client_chain: %{root: [{:key, curve()}], intermediates: [], peer: [{:key, curve()}]}
      })

    server = data.server_config
    %{ssl: [cert: Keyword.fetch!(server, :cert), key: Keyword.fetch!(server, :key)], ca: ca.cert}
  end

  defp curve(), do: {:namedCurve, :secp256r1}

  defp san(names), do: {:Extension, @san, false, names}

  defp key_entry(key), do: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key)}
end
