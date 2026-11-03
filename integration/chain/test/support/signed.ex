# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Signed do
  @moduledoc """
  Signed fixtures in the portal's envelope format:

      {"payload": base64url(bytes), "signatures": [{"keyid": hex(sha256(pub)), "sig": base64url}]}

  A key is `{public, private}` (raw Ed25519 bytes).
  """

  @doc "A fresh Ed25519 key."
  def key do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  @doc "The key id: lowercase hex sha256 of the raw public key."
  def keyid({pub, _priv}), do: Base.encode16(:crypto.hash(:sha256, pub), case: :lower)

  @doc "The envelope JSON over `payload`, one signature per key in `keys`."
  def envelope(payload, keys) when is_binary(payload) do
    sigs =
      Enum.map(keys, fn {_pub, priv} = key ->
        sig = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
        %{"keyid" => keyid(key), "sig" => Base.url_encode64(sig, padding: false)}
      end)

    JSON.encode!(%{
      "payload" => Base.url_encode64(payload, padding: false),
      "signatures" => sigs
    })
  end

  @doc """
  A root envelope signed by `root_key`, naming `root_key` for the root role
  and `opts[:batch_key]` (default `root_key`) for the batch role.

  Options: `:batch_key`, `:batch_keys` (a list, overrides `:batch_key`),
  `:batch_threshold` (1), `:version` (1), `:expires` (a year ahead).
  """
  def root(root_key, opts \\ []) do
    batch_keys = Keyword.get(opts, :batch_keys, [Keyword.get(opts, :batch_key, root_key)])
    expires = Keyword.get(opts, :expires, DateTime.add(DateTime.utc_now(), 365, :day))

    keys =
      for {pub, _} = k <- Enum.uniq([root_key | batch_keys]), into: %{} do
        {keyid(k), %{"type" => "ed25519", "public" => Base.url_encode64(pub, padding: false)}}
      end

    payload =
      JSON.encode!(%{
        "version" => Keyword.get(opts, :version, 1),
        "expires" => DateTime.to_iso8601(expires),
        "keys" => keys,
        "roles" => %{
          "root" => %{"keyids" => [keyid(root_key)], "threshold" => 1},
          "batch" => %{
            "keyids" => Enum.map(batch_keys, &keyid/1),
            "threshold" => Keyword.get(opts, :batch_threshold, 1)
          }
        }
      })

    envelope(payload, [root_key])
  end

  @doc """
  A batch payload (bytes), as the portal builds one: issued now, expiring
  24 hours later.

  Options: `:sequence` (7), `:issued`, `:expires`, `:manifests`,
  `:manifests_v2` (omitted when nil).
  """
  def batch_payload(opts \\ []) do
    issued = Keyword.get(opts, :issued, DateTime.utc_now())
    expires = Keyword.get(opts, :expires, DateTime.add(issued, 24, :hour))

    %{
      "version" => 1,
      "sequence" => Keyword.get(opts, :sequence, 7),
      "issued" => DateTime.to_iso8601(issued),
      "expires" => DateTime.to_iso8601(expires),
      "manifests" => Keyword.get(opts, :manifests, %{"jason" => String.duplicate("a", 64)})
    }
    |> then(fn m ->
      case Keyword.get(opts, :manifests_v2) do
        nil -> m
        v2 -> Map.put(m, "manifests_v2", v2)
      end
    end)
    |> JSON.encode!()
  end

  @doc "A batch envelope signed by `keys` (a key or a list of keys)."
  def batch(keys, opts \\ []), do: envelope(batch_payload(opts), List.wrap(keys))
end
