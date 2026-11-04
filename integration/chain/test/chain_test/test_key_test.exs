# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.TestKeyTest do
  # Not async: one test counts the chain_layer2-* dirs in the system tmp dir.
  use ExUnit.Case, async: false

  alias ChainTest.{Layer2Fixture, Mirror, TestKey, Trust}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    snap = Layer2Fixture.snapshot(tmp)
    {:ok, l2} = TestKey.prepare(snap)
    on_exit(fn -> TestKey.cleanup(l2) end)
    %{snap: snap, l2: l2}
  end

  defp decode(envelope) do
    %{"payload" => p, "signatures" => sigs} = JSON.decode!(envelope)
    payload = Base.url_decode64!(p, padding: false)

    decoded =
      case JSON.decode(payload) do
        {:ok, doc} -> doc
        {:error, _} -> nil
      end

    {decoded, payload, sigs}
  end

  defp role(root, name), do: root["roles"][name]

  # Whether `envelope` carries a valid signature by every key id in `ids`,
  # each key taken from `root`'s keys.
  defp signed_by?(envelope, root, ids) do
    {_, payload, sigs} = decode(envelope)

    Enum.all?(ids, fn id ->
      pub = Base.url_decode64!(root["keys"][id]["public"], padding: false)

      Enum.any?(sigs, fn %{"keyid" => k, "sig" => s} ->
        k == id and
          :crypto.verify(:eddsa, :none, payload, Base.url_decode64!(s, padding: false), [
            pub,
            :ed25519
          ])
      end)
    end)
  end

  test "everything lies in one private tmp dir; cleanup removes it", %{l2: l2, snap: snap} do
    assert String.starts_with?(l2.dir, Path.expand(System.tmp_dir!()))
    assert {:ok, %File.Stat{mode: mode}} = File.stat(l2.dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert l2.snapshot.dir == Path.join(l2.dir, "snapshot")
    assert Path.dirname(l2.roots.v1) == Path.join(l2.dir, "trust")
    refute String.starts_with?(snap.dir, l2.dir)

    other = TestKey.prepare(snap) |> elem(1)
    TestKey.cleanup(other)
    refute File.exists?(other.dir)
  end

  test "no private key is kept anywhere but in the signing closure", %{l2: l2} do
    assert is_function(l2.snapshot.test.sign, 2)
    shown = inspect(l2, limit: :infinity, printable_limit: :infinity)
    # Every key's public id is public; the closure shows no bytes.
    assert shown =~ "#Function<"

    written =
      for path <- Path.wildcard(Path.join(l2.dir, "**"), match_dot: true),
          File.regular?(path),
          do: Path.relative_to(path, l2.dir)

    for path <- written do
      assert String.starts_with?(path, "trust/root-") or String.starts_with?(path, "snapshot/"),
             path
    end
  end

  test "the test-signed batch is the real payload, verified by the harness under the test root",
       %{l2: l2, snap: snap} do
    {_, real_payload, _} = decode(File.read!(Path.join(snap.dir, "batch.json")))

    {_, payload, [%{"keyid" => kid}]} =
      decode(File.read!(Path.join(l2.snapshot.dir, "batch.json")))

    assert payload == real_payload

    {root, _, _} = decode(File.read!(l2.roots.v1))
    assert role(root, "batch") == %{"keyids" => [kid], "threshold" => 1}
    assert root["version"] == 1

    {:ok, mirror} = Mirror.start(l2.snapshot.dir)

    try do
      {results, info} =
        Trust.check(%{source: mirror.url, root_path: l2.roots.v1, library_root_path: l2.roots.v1})

      assert Trust.accepted?(results, info)
      assert info.sequence == snap.sequence
      assert info.manifests_v2 == snap.info.manifests_v2

      # The real root does not accept it.
      {results, info} = Trust.check(%{source: mirror.url})
      refute Trust.accepted?(results, info)
    after
      Mirror.stop(mirror)
    end

    assert File.read!(Path.join(l2.snapshot.dir, "root.json")) == File.read!(l2.roots.v1)

    for rel <- [
          "v2/manifests/jason.json" | Enum.map(snap.deps["jason"].file_shas, &"files/#{&1}")
        ],
        do:
          assert(
            File.read!(Path.join(l2.snapshot.dir, rel)) == File.read!(Path.join(snap.dir, rel))
          )
  end

  test "the layer-2 snapshot keeps the real one's deps, has no older batch, and its info names root v1",
       %{l2: l2, snap: snap} do
    assert l2.snapshot.deps == snap.deps
    assert l2.snapshot.sequence == snap.sequence
    assert l2.snapshot.info.root_version == 1
    assert {:missing, _} = l2.snapshot.previous
    assert {:missing, _} = l2.snapshot.old
  end

  test "the threshold-2 root names two batch keys and needs both", %{l2: l2} do
    {root, _, _} = decode(File.read!(l2.roots.threshold_2))
    assert %{"keyids" => [a, b], "threshold" => 2} = role(root, "batch")
    assert a != b

    test = l2.snapshot.test
    both = TestKey.envelope(test, "x", [:pair_a, :pair_b])
    assert signed_by?(both, root, [a, b])
    twice = TestKey.envelope(test, "x", [:pair_a, :pair_a])
    assert [%{"keyid" => ^a}, %{"keyid" => ^a}] = elem(decode(twice), 2) |> Enum.sort()
  end

  test "rotated v2 chains from v1; unchained v2 does not", %{l2: l2} do
    {v1, _, _} = decode(File.read!(l2.roots.v1))
    test = l2.snapshot.test
    {rotated, _, _} = decode(test.rotated_v2)
    {unchained, _, _} = decode(test.unchained_v2)

    assert rotated["version"] == 2 and unchained["version"] == 2

    assert signed_by?(test.rotated_v2, v1, role(v1, "root")["keyids"])
    assert signed_by?(test.rotated_v2, rotated, role(rotated, "root")["keyids"])
    refute role(rotated, "batch") == role(v1, "batch")

    assert signed_by?(test.unchained_v2, unchained, role(unchained, "root")["keyids"])
    refute signed_by?(test.unchained_v2, v1, role(v1, "root")["keyids"])
  end

  test "the outside key is named by no test root", %{l2: l2} do
    test = l2.snapshot.test
    {_, _, [%{"keyid" => kid}]} = decode(TestKey.envelope(test, "x", [:outside]))
    assert kid in test.keyids

    for path <- Map.values(l2.roots) do
      {root, _, _} = decode(File.read!(path))
      refute Map.has_key?(root["keys"], kid)
    end

    assert_raise ArgumentError, fn -> TestKey.envelope(test, "x", [:root]) end
  end

  test "test!/1 refuses a snapshot signed with the real root", %{snap: snap, l2: l2} do
    assert_raise ArgumentError, fn -> TestKey.test!(snap) end
    assert TestKey.test!(l2.snapshot) == l2.snapshot.test
  end

  test "a snapshot without a batch is refused and leaves nothing", %{snap: snap, tmp_dir: tmp} do
    empty = Path.join(tmp, "empty")
    File.mkdir_p!(empty)
    before = Path.wildcard(Path.join(System.tmp_dir!(), "chain_layer2-*"))
    assert {:error, _} = TestKey.prepare(%{snap | dir: empty})
    assert Path.wildcard(Path.join(System.tmp_dir!(), "chain_layer2-*")) -- before == []
  end
end
