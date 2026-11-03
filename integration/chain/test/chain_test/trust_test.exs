# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.TrustTest do
  use ExUnit.Case, async: true

  alias ChainTest.{LocalServer, Result, Signed, Trust}

  @moduletag :tmp_dir

  @checks ~w(root_pin root_signature root_expiry served_root batch_signature batch_threshold
             batch_format batch_expiry batch_freshness batch_lifetime)

  setup %{tmp_dir: tmp} do
    served = Path.join(tmp, "served")
    File.mkdir_p!(served)
    {base, pid} = LocalServer.serve(served)
    on_exit(fn -> LocalServer.stop(pid) end)
    %{served: served, source: base, key: Signed.key()}
  end

  # Writes the pinned root (also the "library" root unless overridden), the
  # served root and the served batch, then runs the check.
  defp run(ctx, root, batch, opts \\ []) do
    pinned = Path.join(ctx.tmp_dir, "pinned_root.json")
    File.write!(pinned, root)
    File.write!(Path.join(ctx.served, "root.json"), Keyword.get(opts, :served_root, root))
    if batch, do: File.write!(Path.join(ctx.served, "batch.json"), batch)

    Trust.check(%{
      source: ctx.source,
      root_path: pinned,
      library_root_path: Keyword.get(opts, :library_root_path, pinned)
    })
  end

  defp by_check(results), do: Map.new(results, &{&1.check, &1})
  defp class(results, check), do: Map.fetch!(by_check(results), check).class

  test "a correctly signed root and batch pass every check", ctx do
    v2 = %{"jason" => String.duplicate("b", 64)}
    {results, info} = run(ctx, Signed.root(ctx.key), Signed.batch(ctx.key, manifests_v2: v2))

    assert Enum.map(results, & &1.check) == @checks
    assert Enum.all?(results, &match?(%Result{step: :trust, class: :pass}, &1)), inspect(results)
    assert Result.exit_code(results) == 0

    assert %{sequence: 7, root_version: 1, manifests: %{"jason" => _}, manifests_v2: ^v2} = info
  end

  test "a batch without manifests_v2 reports nil for it", ctx do
    {_, info} = run(ctx, Signed.root(ctx.key), Signed.batch(ctx.key))
    assert info.manifests_v2 == nil
  end

  test "one flipped bit in the batch signature fails batch_signature", ctx do
    env = JSON.decode!(Signed.batch(ctx.key))
    [%{"sig" => sig} = s] = env["signatures"]
    <<first, rest::binary>> = Base.url_decode64!(sig, padding: false)
    flipped = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
    batch = JSON.encode!(%{env | "signatures" => [%{s | "sig" => flipped}]})

    {results, info} = run(ctx, Signed.root(ctx.key), batch)

    assert class(results, "batch_signature") == :fail
    assert class(results, "batch_threshold") == :fail
    assert class(results, "batch_expiry") == :not_exercised
    assert info == nil
    assert Result.exit_code(results) == 1
  end

  test "a batch signed by a key the root does not name fails", ctx do
    {results, info} = run(ctx, Signed.root(ctx.key), Signed.batch(Signed.key()))

    %{"batch_signature" => sig} = by_check(results)
    assert sig.class == :fail
    assert sig.detail =~ "not named"
    assert class(results, "batch_threshold") == :fail
    assert info == nil
  end

  test "a root key that is not in the batch role cannot sign a batch", ctx do
    root = Signed.root(ctx.key, batch_key: Signed.key())
    {results, _} = run(ctx, root, Signed.batch(ctx.key))
    assert class(results, "batch_signature") == :fail
  end

  test "one valid signature under a threshold of two fails batch_threshold", ctx do
    other = Signed.key()
    root = Signed.root(ctx.key, batch_keys: [ctx.key, other], batch_threshold: 2)
    {results, info} = run(ctx, root, Signed.batch(ctx.key))

    assert class(results, "batch_signature") == :pass
    assert class(results, "batch_threshold") == :fail
    assert info == nil
  end

  test "two valid signatures meet a threshold of two", ctx do
    other = Signed.key()
    root = Signed.root(ctx.key, batch_keys: [ctx.key, other], batch_threshold: 2)
    {results, info} = run(ctx, root, Signed.batch([ctx.key, other]))

    assert class(results, "batch_threshold") == :pass
    assert info.sequence == 7
  end

  test "a bad signature from a named key next to a valid one fails batch_signature", ctx do
    other = Signed.key()
    root = Signed.root(ctx.key, batch_keys: [ctx.key, other])
    env = JSON.decode!(Signed.batch([ctx.key, other]))
    [good, bad] = env["signatures"]
    bad = %{bad | "sig" => Base.url_encode64(:binary.copy(<<0>>, 64), padding: false)}
    {results, info} = run(ctx, root, JSON.encode!(%{env | "signatures" => [good, bad]}))

    assert class(results, "batch_signature") == :fail
    assert class(results, "batch_threshold") == :pass
    assert info.sequence == 7
  end

  test "a key listed under a keyid that is not its sha256 cannot sign a batch", ctx do
    {pub, _} = signer = Signed.key()
    fake_id = String.duplicate("c", 64)
    root_env = JSON.decode!(Signed.root(ctx.key))
    payload = Base.url_decode64!(root_env["payload"], padding: false) |> JSON.decode!()

    payload =
      payload
      |> put_in(["keys", fake_id], %{
        "type" => "ed25519",
        "public" => Base.url_encode64(pub, padding: false)
      })
      |> put_in(["roles", "batch", "keyids"], [fake_id])

    root = Signed.envelope(JSON.encode!(payload), [ctx.key])

    # The batch signature claims the listed (wrong) keyid.
    env = JSON.decode!(Signed.batch(signer))
    sigs = Enum.map(env["signatures"], &%{&1 | "keyid" => fake_id})
    batch = JSON.encode!(%{env | "signatures" => sigs})

    {results, info} = run(ctx, root, batch)

    assert class(results, "root_signature") == :pass
    assert class(results, "batch_signature") == :fail
    assert class(results, "batch_threshold") == :fail
    assert info == nil
  end

  test "two signatures from the same key count once against the threshold", ctx do
    other = Signed.key()
    root = Signed.root(ctx.key, batch_keys: [ctx.key, other], batch_threshold: 2)
    {results, info} = run(ctx, root, Signed.batch([ctx.key, ctx.key]))

    assert %Result{class: :fail, detail: detail} = by_check(results)["batch_threshold"]
    assert detail =~ "1 valid"
    assert info == nil
  end

  test "a batch that expires before it was issued fails batch_lifetime", ctx do
    now = DateTime.utc_now()
    batch = Signed.batch(ctx.key, issued: now, expires: DateTime.add(now, -1, :second))
    {results, _} = run(ctx, Signed.root(ctx.key), batch)

    assert %Result{class: :fail, detail: detail} = by_check(results)["batch_lifetime"]
    assert detail =~ "not after"
  end

  test "a lifetime of exactly 24 h passes batch_lifetime", ctx do
    now = DateTime.utc_now()
    batch = Signed.batch(ctx.key, issued: now, expires: DateTime.add(now, 24, :hour))
    {results, _} = run(ctx, Signed.root(ctx.key), batch)
    assert class(results, "batch_lifetime") == :pass
  end

  test "an expired batch fails batch_expiry", ctx do
    now = DateTime.utc_now()

    batch =
      Signed.batch(ctx.key,
        issued: DateTime.add(now, -2, :hour),
        expires: DateTime.add(now, -1, :hour)
      )

    {results, _} = run(ctx, Signed.root(ctx.key), batch)

    assert class(results, "batch_expiry") == :fail
    assert class(results, "batch_freshness") == :pass
    assert class(results, "batch_lifetime") == :pass
  end

  test "a batch issued 25 hours ago fails batch_freshness", ctx do
    issued = DateTime.add(DateTime.utc_now(), -25, :hour)
    batch = Signed.batch(ctx.key, issued: issued, expires: DateTime.add(issued, 24, :hour))
    {results, _} = run(ctx, Signed.root(ctx.key), batch)

    assert %Result{class: :fail, detail: detail} = by_check(results)["batch_freshness"]
    assert detail =~ "24 h"
  end

  test "a batch issued more than 300 s ahead fails batch_freshness", ctx do
    batch = Signed.batch(ctx.key, issued: DateTime.add(DateTime.utc_now(), 400, :second))
    {results, _} = run(ctx, Signed.root(ctx.key), batch)
    assert class(results, "batch_freshness") == :fail
  end

  test "a batch issued 60 s ahead passes batch_freshness", ctx do
    batch = Signed.batch(ctx.key, issued: DateTime.add(DateTime.utc_now(), 60, :second))
    {results, _} = run(ctx, Signed.root(ctx.key), batch)
    assert class(results, "batch_freshness") == :pass
  end

  test "a 7-day lifetime fails batch_lifetime", ctx do
    issued = DateTime.utc_now()
    batch = Signed.batch(ctx.key, issued: issued, expires: DateTime.add(issued, 7, :day))
    {results, _} = run(ctx, Signed.root(ctx.key), batch)

    assert class(results, "batch_lifetime") == :fail
    assert class(results, "batch_expiry") == :pass
  end

  test "a malformed batch payload fails batch_format", ctx do
    batch = Signed.envelope(~s({"version": 1, "sequence": "seven"}), [ctx.key])
    {results, info} = run(ctx, Signed.root(ctx.key), batch)

    assert class(results, "batch_signature") == :pass
    assert class(results, "batch_format") == :fail
    assert class(results, "batch_expiry") == :not_exercised
    assert info == nil
  end

  test "an unavailable batch fails and leaves the rest not exercised", ctx do
    {results, info} = run(ctx, Signed.root(ctx.key), nil)

    assert %Result{class: :fail, detail: detail} = by_check(results)["batch_signature"]
    assert detail =~ "404"
    assert class(results, "batch_lifetime") == :not_exercised
    assert info == nil
  end

  test "a pinned root that does not verify fails root_signature", ctx do
    env = JSON.decode!(Signed.root(ctx.key))
    other_sig = JSON.decode!(Signed.root(Signed.key()))["signatures"]
    root = JSON.encode!(%{env | "signatures" => other_sig})
    {results, info} = run(ctx, root, Signed.batch(ctx.key))

    assert class(results, "root_signature") == :fail
    assert class(results, "batch_signature") == :not_exercised
    assert info == nil
  end

  test "an expired pinned root fails root_expiry", ctx do
    root = Signed.root(ctx.key, expires: DateTime.add(DateTime.utc_now(), -1, :day))
    {results, _} = run(ctx, root, Signed.batch(ctx.key))
    assert class(results, "root_expiry") == :fail
  end

  test "a different served root is a miss and the pinned root is used", ctx do
    served = Signed.root(Signed.key(), version: 2)
    {results, info} = run(ctx, Signed.root(ctx.key), Signed.batch(ctx.key), served_root: served)

    assert %Result{class: :miss, detail: "served root differs; pinned root used"} =
             by_check(results)["served_root"]

    assert class(results, "batch_signature") == :pass
    assert info.root_version == 1
  end

  test "the pinned root differing from the library's fails root_pin", ctx do
    other = Path.join(ctx.tmp_dir, "library_root.json")
    File.write!(other, Signed.root(Signed.key()))
    {results, _} = run(ctx, Signed.root(ctx.key), Signed.batch(ctx.key), library_root_path: other)

    assert %Result{class: :fail, detail: detail} = by_check(results)["root_pin"]
    assert detail =~ "differs"
  end

  test "the harness pins a byte copy of the library's root" do
    assert File.read!(Trust.pinned_root_path()) == File.read!(Trust.library_root_path())
  end

  test "the default check pins the shipped root and the library's" do
    cfg = Trust.config(%{source: "http://127.0.0.1:1"})
    assert cfg.root_path == Trust.pinned_root_path()
    assert cfg.library_root_path == Trust.library_root_path()
  end

  test "the real pinned root verifies under the harness's own code" do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)

    {results, info} = Trust.check(%{source: "http://127.0.0.1:#{port}", timeout_ms: 2_000})
    by = by_check(results)

    assert by["root_pin"].class == :pass
    assert by["root_signature"].class == :pass
    assert by["root_expiry"].class == :pass
    assert by["served_root"].class == :miss
    assert by["batch_signature"].class == :fail
    assert info == nil
  end

  describe "manifest_sha/2" do
    test "prefers the v2 document, as the client does" do
      info = %{manifests: %{"a" => "s1", "b" => "s2"}, manifests_v2: %{"a" => "v2a"}}
      assert Trust.manifest_sha(info, "a") == {"v2a", "v2/manifests"}
      assert Trust.manifest_sha(info, "b") == {"s2", "manifests"}
      assert Trust.manifest_sha(info, "c") == nil
    end

    test "uses format 1 when the batch has no v2 map" do
      info = %{manifests: %{"a" => "s1"}, manifests_v2: nil}
      assert Trust.manifest_sha(info, "a") == {"s1", "manifests"}
    end
  end
end
