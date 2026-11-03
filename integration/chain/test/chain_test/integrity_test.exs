# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.IntegrityTest do
  use ExUnit.Case, async: true

  alias ChainTest.{Integrity, LocalServer, Result, Synthetic}

  @moduletag :tmp_dir

  @outer String.duplicate("a", 64)
  @beam "jason beam bytes"
  @app "{application,jason,[{vsn,\"1.4.5\"}]}."
  @files %{"ebin/Elixir.Jason.beam" => @beam, "ebin/jason.app" => @app}

  setup %{tmp_dir: tmp} do
    served = Path.join(tmp, "served")
    File.mkdir_p!(served)
    {base, pid} = LocalServer.serve(served)
    on_exit(fn -> LocalServer.stop(pid) end)

    build_lib = Synthetic.tree(Path.join(tmp, "fixture"), "rpi4", %{jason: {"1.4.5", @outer}})
    report = Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])
    %{served: served, source: base, build_lib: build_lib, report: report}
  end

  # Serves `builds` as jason's v2 manifest and installs `installed` files.
  defp arrange(ctx, builds, installed \\ @files, opts \\ []) do
    bytes = Synthetic.manifest("1.4.5", builds)
    Synthetic.serve_manifest(ctx.served, "v2/manifests", "jason", bytes)
    sha = Keyword.get(opts, :sha, Synthetic.sha(bytes))

    Synthetic.dep(ctx.build_lib, :jason, installed, :installed, %{
      "manifest_sha256" => sha,
      "manifest_path" => "v2/manifests",
      "batch_sequence" => 7
    })

    Synthetic.info(7, %{"jason" => sha})
  end

  defp run(ctx, trust, extra \\ %{}) do
    Integrity.run(
      Map.merge(
        %{build_lib: ctx.build_lib, report: ctx.report, trust: trust, source: ctx.source},
        extra
      )
    )
  end

  test "a hit whose installed files match the manifest passes", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])

    assert {[%Result{step: :integrity, check: "integrity:jason", class: :pass}], files} =
             run(ctx, trust)

    assert Enum.sort(files["jason"]) ==
             Enum.sort([
               %{path: "ebin/Elixir.Jason.beam", sha256: Synthetic.sha(@beam)},
               %{path: "ebin/jason.app", sha256: Synthetic.sha(@app)}
             ])
  end

  test "one byte changed in an installed beam is a disagreement naming the file", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.write!(Path.join(ctx.build_lib, "jason/ebin/Elixir.Jason.beam"), "jason beam bytez")

    assert {[%Result{class: :disagreement, detail: detail}], files} = run(ctx, trust)
    assert detail =~ "ebin/Elixir.Jason.beam"
    refute Map.has_key?(files, "jason")
  end

  test "a file in ebin the manifest does not list is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.write!(Path.join(ctx.build_lib, "jason/ebin/Elixir.Planted.beam"), "x")

    assert {[%Result{class: :disagreement, detail: detail}], _} = run(ctx, trust)
    assert detail =~ "ebin/Elixir.Planted.beam"
  end

  test "a listed file missing from _build is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.rm!(Path.join(ctx.build_lib, "jason/ebin/jason.app"))

    assert {[%Result{class: :disagreement, detail: detail}], _} = run(ctx, trust)
    assert detail =~ "ebin/jason.app"
  end

  test "an untrusted batch leaves every hit not exercised", ctx do
    _ = arrange(ctx, [Synthetic.build(@files, outer: @outer)])

    assert {[%Result{check: "integrity:jason", class: :not_exercised, detail: detail}], files} =
             run(ctx, nil)

    assert detail =~ "batch"
    assert files == %{}
  end

  test "a hit for a dep the verified batch does not name is a disagreement", ctx do
    _ = arrange(ctx, [Synthetic.build(@files, outer: @outer)])

    assert {[%Result{class: :disagreement, detail: detail}], _} =
             run(ctx, Synthetic.info(7, %{}))

    assert detail =~ "names no manifest"
  end

  test "manifest bytes that do not hash to the batch's sha are a disagreement", ctx do
    bogus = String.duplicate("b", 64)
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], @files, sha: bogus)

    assert {[%Result{class: :disagreement, detail: detail}], _} =
             run(ctx, trust, %{recheck: fn -> trust end})

    assert detail =~ bogus
  end

  test "a manifest that moved under a newer batch is a rerun", ctx do
    bogus = String.duplicate("b", 64)
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], @files, sha: bogus)
    newer = Synthetic.info(8, %{"jason" => String.duplicate("c", 64)})

    assert {[%Result{class: :rerun, detail: detail}], _} =
             run(ctx, trust, %{recheck: fn -> newer end})

    assert detail =~ "8"
  end

  test "a provenance file naming another manifest is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    other = String.duplicate("d", 64)

    File.write!(
      Path.join(ctx.build_lib, "jason/.mix/elixir_precompiled.json"),
      JSON.encode!(%{
        "manifest_sha256" => other,
        "manifest_path" => "v2/manifests",
        "batch_sequence" => 7
      })
    )

    assert {[%Result{class: :disagreement, detail: detail}], _} = run(ctx, trust)
    assert detail =~ "provenance"
  end

  test "the build for this system is selected, not another system's", ctx do
    so = "rpi4 nif"
    rpi4 = Map.put(@files, "priv/nif.so", so)
    rpi0 = Map.put(@files, "priv/nif.so", "rpi0_2 nif")

    builds = [
      Synthetic.build(rpi0,
        outer: @outer,
        target: "nerves_system_rpi0_2",
        system_version: "2.2.1",
        run_id: "z"
      ),
      Synthetic.build(rpi4,
        outer: @outer,
        target: "nerves_system_rpi4",
        system_version: "2.2.1",
        run_id: "a"
      )
    ]

    trust = arrange(ctx, builds, rpi4)
    assert {[%Result{class: :pass}], files} = run(ctx, trust)
    assert %{path: "priv/nif.so", sha256: Synthetic.sha(so)} in files["jason"]
  end

  test "installed files of a build the harness does not select are a disagreement", ctx do
    newer = Map.put(@files, "ebin/Elixir.Jason.beam", "newer build")

    builds = [
      Synthetic.build(@files, outer: @outer, run_id: "run-1"),
      Synthetic.build(newer, outer: @outer, run_id: "run-2")
    ]

    trust = arrange(ctx, builds, @files)
    assert {[%Result{class: :disagreement, detail: detail}], _} = run(ctx, trust)
    assert detail =~ "run-1"
    assert detail =~ "run-2"
  end

  test "a build with another package checksum is never selected", ctx do
    builds = [
      Synthetic.build(@files, outer: String.duplicate("f", 64), run_id: "run-9"),
      Synthetic.build(@files, outer: @outer, run_id: "run-1")
    ]

    trust = arrange(ctx, builds)
    assert {[%Result{class: :pass, detail: detail}], _} = run(ctx, trust)
    assert detail =~ "run-1"
  end

  test "a format-1 manifest from a batch without manifests_v2 is checked", ctx do
    entry = Synthetic.build(@files, outer: @outer) |> Map.delete("target")
    bytes = JSON.encode!(%{"versions" => %{"1.4.5" => %{"pure_elixir" => entry}}})
    Synthetic.serve_manifest(ctx.served, "manifests", "jason", bytes)
    sha = Synthetic.sha(bytes)

    Synthetic.dep(ctx.build_lib, :jason, @files, :installed, %{
      "manifest_sha256" => sha,
      "manifest_path" => "manifests",
      "batch_sequence" => 7
    })

    trust = %{sequence: 7, root_version: 1, manifests: %{"jason" => sha}, manifests_v2: nil}
    assert {[%Result{class: :pass}], %{"jason" => [_, _]}} = run(ctx, trust)
  end

  test "misses are not integrity-checked", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    report = Synthetic.report([{"jason", "1.4.5", "miss", "not built"}])

    assert {[%Result{check: "integrity", class: :not_exercised}], %{}} =
             Integrity.run(%{
               build_lib: ctx.build_lib,
               report: report,
               trust: trust,
               source: ctx.source
             })
  end
end
