# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.ConformanceLayer2Test do
  use ExUnit.Case, async: true

  alias ChainTest.{Conformance, HTTP, Result, Signed, Synthetic, Trust}
  alias ChainTest.Conformance.Setup

  @moduletag :tmp_dir

  @t0 %{
    id: "T0",
    description: "Served unchanged.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{}
  }

  @l2_t0 %{
    id: "L2-T0",
    description: "The test-signed copy, unchanged.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{},
    client_config: %{root: {:test_root, :v1}}
  }

  # Accepted under the threshold-2 root; the double client hits whatever
  # it is served.
  @l2_pair %{
    id: "T3-pair",
    description: "Both keys of the threshold-2 root.",
    transform: {ChainTest.Mirror.TestBatch, %{signers: [:pair_a, :pair_b]}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{},
    client_config: %{root: {:test_root, :threshold_2}}
  }

  setup %{tmp_dir: tmp} do
    snap_dir = Path.join(tmp, "snap")
    File.mkdir_p!(Path.join(snap_dir, "v2/manifests"))
    File.write!(Path.join(snap_dir, "batch.json"), "real batch")
    File.write!(Path.join(snap_dir, "v2/manifests/jason.json"), "{}")

    l2_base = Path.join(tmp, "chain_layer2-test")
    l2_dir = Path.join(l2_base, "snapshot")
    v1_key = Signed.key()
    l2_batch = Signed.envelope(~s({"sequence":7}), [v1_key])
    File.mkdir_p!(Path.join(l2_dir, "v2/manifests"))
    File.write!(Path.join(l2_dir, "batch.json"), l2_batch)
    File.write!(Path.join(l2_dir, "v2/manifests/jason.json"), "{}")

    trust = Path.join(l2_base, "trust")
    File.mkdir_p!(trust)
    roots = %{v1: Path.join(trust, "root-v1.json"), threshold_2: Path.join(trust, "root-t2.json")}
    File.write!(roots.v1, Signed.root(v1_key))
    File.write!(roots.threshold_2, Signed.root(Signed.key()))

    fixture = Path.join(tmp, "fixture")
    Synthetic.tree(fixture, "rpi4", %{jason: {"1.4.5", String.duplicate("a", 64)}})
    File.write!(Path.join(fixture, "expected.exs"), "%{hits: [:jason], never: []}\n")

    snapshot = %{
      dir: snap_dir,
      source: "https://portal.invalid",
      target: "rpi4",
      sequence: 7,
      info: Synthetic.info(7, %{}),
      taken_at: DateTime.utc_now(),
      deps: %{
        "jason" => %{
          version: "1.4.5",
          manifest: "v2/manifests/jason.json",
          sha256: nil,
          builds: 1,
          files: 1
        }
      }
    }

    test_material = %{
      sign: fn _signer, _payload -> %{"keyid" => "k", "sig" => "s"} end,
      payload: "{}",
      rotated_v2: "{}",
      unchained_v2: "{}",
      keyids: [Signed.keyid(v1_key)]
    }

    l2 = %{
      dir: l2_base,
      snapshot:
        Map.merge(snapshot, %{dir: l2_dir, info: Synthetic.info(7, %{}), test: test_material}),
      roots: roots,
      keyids: [Signed.keyid(v1_key)]
    }

    opts = %{
      target: "rpi4",
      source: "https://portal.invalid",
      cases: Path.join(tmp, "cases.exs"),
      only: nil,
      snapshot_dir: nil,
      report_dir: Path.join(tmp, "reports"),
      fixture_dir: fixture
    }

    %{opts: opts, snapshot: snapshot, l2: l2, l2_batch: l2_batch}
  end

  defp cases!(opts, cases), do: File.write!(opts.cases, inspect(cases, limit: :infinity))

  # A fake client: reads the batch and jason's manifest through the case's
  # mirror and hits jason, unless `miss_batch` is the batch it was served.
  # `plant.(input)` runs first, to leave something in the home.
  defp steps(test, snapshot, l2, opts \\ []) do
    plant = Keyword.get(opts, :plant, fn _ -> :ok end)

    %{
      snapshot: fn _ -> {:ok, snapshot} end,
      layer2: fn snap ->
        send(test, {:layer2, snap})
        Keyword.get(opts, :layer2, {:ok, l2})
      end,
      build: fn input ->
        plant.(input)
        {:ok, batch} = HTTP.get(input.source <> "/batch.json", 5_000)
        {:ok, _} = HTTP.get(input.source <> "/v2/manifests/jason.json", 5_000)
        send(test, {:build, input, batch})

        {status, class} =
          if batch == Keyword.get(opts, :miss_batch), do: {"miss", :miss}, else: {"hit", :pass}

        {[
           %Result{step: :build, check: "compile", class: :pass},
           %Result{step: :build, check: "hit:jason", class: class}
         ],
         %{
           report: Synthetic.report([{"jason", "1.4.5", status, "x"}]),
           build_lib: "/nonexistent",
           fw_path: nil,
           sequence: 7
         }}
      end,
      integrity: fn _ -> [%Result{step: :integrity, check: "integrity", class: :pass}] end,
      compiled: fn _ -> [%Result{step: :compiled, check: "compiled_here", class: :pass}] end
    }
  end

  defp builds() do
    receive do
      {:build, input, batch} -> [{input, batch} | builds()]
    after
      0 -> []
    end
  end

  test "layer-2 cases run against the test-signed copy, pinned to the test root, the control first",
       ctx do
    cases!(ctx.opts, [@t0, @l2_pair, @l2_t0])
    {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot, ctx.l2))

    assert [{"T0", :pass}, {"T3-pair", :pass}, {"L2-T0", :pass}] =
             Enum.map(verdicts, &{&1.check, &1.class})

    assert_received {:layer2, %{dir: dir}}
    assert dir == ctx.snapshot.dir

    l2_batch = ctx.l2_batch
    assert [{real, "real batch"}, {control, ^l2_batch}, {pair, pair_batch}] = builds()
    assert real.client_config == nil
    assert real.trust == ctx.snapshot.info
    assert control.client_config == %{root: ctx.l2.roots.v1}
    assert control.trust == ctx.l2.snapshot.info
    assert pair.client_config == %{root: ctx.l2.roots.threshold_2}
    assert pair_batch =~ ~s("keyid":"k")
  end

  test "a failed control leaves every other layer-2 case not exercised", ctx do
    cases!(ctx.opts, [@t0, @l2_t0, @l2_pair])
    s = steps(self(), ctx.snapshot, ctx.l2, miss_batch: ctx.l2_batch)
    {verdicts, _} = Conformance.run(ctx.opts, s)

    assert [
             %Result{check: "T0", class: :pass},
             %Result{check: "L2-T0", class: :fail},
             %Result{check: "T3-pair", class: :not_exercised, detail: detail}
           ] = verdicts

    assert detail =~ "L2-T0"
    assert Result.exit_code(verdicts) == 1
    assert length(builds()) == 2
  end

  test "test-key material that cannot be prepared leaves the layer-2 cases not exercised",
       ctx do
    cases!(ctx.opts, [@t0, @l2_t0, @l2_pair])
    s = steps(self(), ctx.snapshot, ctx.l2, layer2: {:error, "no batch"})
    {verdicts, _} = Conformance.run(ctx.opts, s)

    assert [
             %Result{check: "T0", class: :pass},
             %Result{check: "L2-T0", class: :not_exercised, detail: d1},
             %Result{check: "T3-pair", class: :not_exercised}
           ] = verdicts

    assert d1 =~ "no batch"
  end

  test "--only a layer-2 case runs its control too; no layer-2 case prepares nothing", ctx do
    cases!(ctx.opts, [@t0, @l2_t0, @l2_pair])

    {verdicts, _} =
      Conformance.run(%{ctx.opts | only: ["T3-pair"]}, steps(self(), ctx.snapshot, ctx.l2))

    assert ["L2-T0", "T3-pair"] == Enum.map(verdicts, & &1.check)

    {verdicts, _} =
      Conformance.run(%{ctx.opts | only: ["T0"]}, steps(self(), ctx.snapshot, ctx.l2))

    assert ["T0"] == Enum.map(verdicts, & &1.check)
    assert_received {:layer2, _}
    refute_received {:layer2, _}
  end

  test "the test-key material is removed after the run", ctx do
    cases!(ctx.opts, [@l2_t0])
    Conformance.run(ctx.opts, steps(self(), ctx.snapshot, ctx.l2))
    refute File.exists?(ctx.l2.dir)
  end

  describe "isolation" do
    test "a real-root case whose home holds a test root's state dir fails", ctx do
      cases!(ctx.opts, [@t0, @l2_t0])

      plant = fn input ->
        if input.client_config == nil do
          {:ok, dir} = Setup.state_dir(input.home, input.source, ctx.l2.roots.v1)
          File.mkdir_p!(dir)
          File.write!(Path.join(dir, "state"), "7")
        end
      end

      {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot, ctx.l2, plant: plant))
      assert [%Result{check: "T0", class: :fail, detail: d}, %Result{class: :pass}] = verdicts
      assert d =~ "test root"
    end

    test "a real-root case whose home holds a file naming a test key fails", ctx do
      cases!(ctx.opts, [@t0, @l2_t0])
      [kid] = ctx.l2.keyids

      plant = fn input ->
        if input.client_config == nil do
          File.mkdir_p!(Path.join(input.home, "abc"))
          File.write!(Path.join(input.home, "abc/roots.json"), ~s([{"keyid":"#{kid}"}]))
        end
      end

      {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot, ctx.l2, plant: plant))
      assert [%Result{check: "T0", class: :fail, detail: d}, _] = verdicts
      assert d =~ "test key"
    end

    test "the cache is portal bytes, not the client's trust state: not scanned", ctx do
      cases!(ctx.opts, [@t0, @l2_t0])
      [kid] = ctx.l2.keyids

      plant = fn input ->
        File.mkdir_p!(Path.join(input.home, "files"))
        File.write!(Path.join(input.home, "files/#{String.duplicate("b", 64)}"), kid)
      end

      {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot, ctx.l2, plant: plant))
      assert [%Result{check: "T0", class: :pass}, _] = verdicts
    end

    test "a layer-2 case whose home holds the real root's state dir fails", ctx do
      cases!(ctx.opts, [@l2_t0])

      plant = fn input ->
        {:ok, dir} = Setup.state_dir(input.home, input.source, Trust.library_root_path())
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "state"), "7")
      end

      {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot, ctx.l2, plant: plant))
      assert [%Result{check: "L2-T0", class: :fail, detail: d}] = verdicts
      assert d =~ "real root"
    end
  end
end
