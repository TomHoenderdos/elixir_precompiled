# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Layer1Test do
  use ExUnit.Case, async: true

  alias ChainTest.{AttackerRoot, Signed}
  alias ChainTest.Mirror.{BatchSignatures, OlderBatch, RootSwap, Transform}

  @moduletag :tmp_dir

  defp decode(envelope) do
    %{"payload" => p, "signatures" => sigs} = JSON.decode!(envelope)
    {Base.url_decode64!(p, padding: false), sigs}
  end

  defp verifies?(payload, %{"sig" => sig}, {pub, _priv}),
    do:
      :crypto.verify(:eddsa, :none, payload, Base.url_decode64!(sig, padding: false), [
        pub,
        :ed25519
      ])

  describe "BatchSignatures" do
    setup do
      key = Signed.key()
      %{key: key, batch: Signed.batch(key, sequence: 9)}
    end

    test "flip_bit flips one bit of the first signature and keeps the payload", ctx do
      assert {200, out} = BatchSignatures.transform("batch.json", ctx.batch, %{change: :flip_bit})
      {payload, [sig]} = decode(out)
      {orig_payload, [orig]} = decode(ctx.batch)

      assert payload == orig_payload
      assert sig["keyid"] == orig["keyid"]
      refute verifies?(payload, sig, ctx.key)

      a = Base.url_decode64!(sig["sig"], padding: false)
      b = Base.url_decode64!(orig["sig"], padding: false)
      diff = :crypto.exor(a, b)
      assert for(<<bit::1 <- diff>>, bit == 1, reduce: 0, do: (n -> n + 1)) == 1
    end

    test "remove serves no signature at all", ctx do
      assert {200, out} = BatchSignatures.transform("batch.json", ctx.batch, %{change: :remove})
      assert {_payload, []} = decode(out)
    end

    test "every other path is served unchanged", ctx do
      assert BatchSignatures.transform("root.json", "x", %{change: :remove}) == {200, "x"}

      assert BatchSignatures.transform("batches/9.json", ctx.batch, %{change: :remove}) ==
               {200, ctx.batch}
    end

    test "bytes that are not an envelope raise, so the case fails naming it" do
      assert_raise ArgumentError, fn ->
        BatchSignatures.transform("batch.json", "not json", %{change: :remove})
      end
    end

    test "args: flip_bit or remove, nothing else; no needs" do
      for change <- [:flip_bit, :remove],
          do: assert(Transform.valid?({BatchSignatures, %{change: change}}))

      refute Transform.valid?({BatchSignatures, %{change: :other}})
      refute Transform.valid?({BatchSignatures, %{}})
      refute Transform.valid?({BatchSignatures, %{change: :remove, extra: 1}})
      refute Transform.valid?({BatchSignatures, %{change: :duplicate}})
      assert Transform.needs({BatchSignatures, %{change: :flip_bit}}) == []
    end
  end

  describe "OlderBatch" do
    setup %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "batches"))
      File.write!(Path.join(tmp, "batches/6.json"), "six")
      File.write!(Path.join(tmp, "batches/3.json"), "three")

      snap = %{
        dir: tmp,
        previous: {:ok, %{sequence: 6, path: "batches/6.json"}},
        old: {:ok, %{sequence: 3, path: "batches/3.json"}}
      }

      %{snap: snap}
    end

    defp older(path, args, snap, mirror \\ 1),
      do:
        Transform.fun({OlderBatch, args}, %{mirror: mirror, second_url: nil, snapshot: snap}).(
          path,
          "seven"
        )

    test "serves the older batch's stored bytes as batch.json", ctx do
      assert older("batch.json", %{batch: :previous}, ctx.snap) == {200, "six"}
      assert older("batch.json", %{batch: :old}, ctx.snap) == {200, "three"}
      assert older("v2/manifests/jason.json", %{batch: :old}, ctx.snap) == {200, "seven"}
    end

    test "the second mirror of a two-mirror case serves unchanged", ctx do
      assert older("batch.json", %{batch: :previous, mirrors: 2}, ctx.snap, 2) == {200, "seven"}
      assert older("batch.json", %{batch: :previous, mirrors: 2}, ctx.snap, 1) == {200, "six"}
    end

    test "an older batch the snapshot lacks raises", ctx do
      snap = %{ctx.snap | old: {:missing, "pruned"}}
      assert_raise ArgumentError, ~r/pruned/, fn -> older("batch.json", %{batch: :old}, snap) end
    end

    test "args and needs: a case expecting hits from N-1 needs N's manifests in it" do
      assert Transform.needs({OlderBatch, %{batch: :old}}) == [:old]
      assert Transform.needs({OlderBatch, %{batch: :previous}}) == [:previous]

      assert Transform.needs({OlderBatch, %{batch: :previous, hits: true}}) ==
               [:previous, :previous_manifests]

      assert Transform.valid?({OlderBatch, %{batch: :previous, hits: true, mirrors: 2}})
      refute Transform.valid?({OlderBatch, %{batch: :old, hits: true}})
      refute Transform.valid?({OlderBatch, %{batch: :newer}})
      refute Transform.valid?({OlderBatch, %{batch: :previous, hits: 1}})
      refute Transform.valid?({OlderBatch, %{batch: :previous, other: 1}})
    end
  end

  describe "RootSwap and AttackerRoot" do
    test "serves a newer root signed by a key of its own instead of root.json" do
      real_key = Signed.key()
      real = Signed.root(real_key, version: 3)

      assert {200, out} = RootSwap.transform("root.json", real, %{})
      {payload, [sig]} = decode(out)
      root = JSON.decode!(payload)

      assert root["version"] == 4
      assert root["roles"]["root"]["keyids"] == [sig["keyid"]]
      assert root["roles"]["batch"]["keyids"] == [sig["keyid"]]
      refute sig["keyid"] == Signed.keyid(real_key)
      refute verifies?(payload, sig, real_key)

      # It verifies under its own key: a client following it would trust the attacker.
      pub = Base.url_decode64!(root["keys"][sig["keyid"]]["public"], padding: false)
      assert verifies?(payload, sig, {pub, nil})
      assert Signed.keyid({pub, nil}) == sig["keyid"]
      {:ok, expires, _} = DateTime.from_iso8601(root["expires"])
      assert DateTime.compare(expires, DateTime.utc_now()) == :gt
    end

    test "every other path is served unchanged" do
      assert RootSwap.transform("batch.json", "x", %{}) == {200, "x"}
      assert Transform.valid?({RootSwap, %{}})
      refute Transform.valid?({RootSwap, %{x: 1}})
    end

    test "AttackerRoot.envelope/1 is a fresh key every time" do
      {p1, [s1]} = decode(AttackerRoot.envelope(2))
      {_p2, [s2]} = decode(AttackerRoot.envelope(2))
      refute s1["keyid"] == s2["keyid"]
      assert JSON.decode!(p1)["version"] == 2
    end
  end
end
