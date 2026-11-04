# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.AttackerRoot do
  @moduledoc """
  A root document an attacker could serve or plant: well formed, signed by
  a key of its own, generated per call and never kept anywhere. It names
  that key for both roles, so a client that took it as its trust anchor
  would refuse the portal's real batches.
  """

  @doc "A self-signed root envelope (JSON) at `version`, expiring a year from now."
  @spec envelope(pos_integer()) :: String.t()
  def envelope(version) when is_integer(version) and version > 0 do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    keyid = Base.encode16(:crypto.hash(:sha256, pub), case: :lower)
    expires = DateTime.utc_now() |> DateTime.add(365, :day) |> DateTime.to_iso8601()

    payload =
      JSON.encode!(%{
        "version" => version,
        "expires" => expires,
        "keys" => %{
          keyid => %{"type" => "ed25519", "public" => Base.url_encode64(pub, padding: false)}
        },
        "roles" => %{
          "root" => %{"keyids" => [keyid], "threshold" => 1},
          "batch" => %{"keyids" => [keyid], "threshold" => 1}
        }
      })

    sig = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

    JSON.encode!(%{
      "payload" => Base.url_encode64(payload, padding: false),
      "signatures" => [%{"keyid" => keyid, "sig" => Base.url_encode64(sig, padding: false)}]
    })
  end
end
