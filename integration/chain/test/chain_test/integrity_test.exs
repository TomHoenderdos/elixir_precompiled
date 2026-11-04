# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.IntegrityTest do
  use ExUnit.Case, async: true

  alias ChainTest.{Integrity, LocalServer, Result, Signed, Synthetic}

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

    assert [%Result{step: :integrity, check: "integrity:jason", class: :pass}] =
             run(ctx, trust)
  end

  test "one byte changed in an installed beam is a disagreement naming the file", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.write!(Path.join(ctx.build_lib, "jason/ebin/Elixir.Jason.beam"), "jason beam bytez")

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "ebin/Elixir.Jason.beam"
  end

  test "a file in ebin the manifest does not list is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.write!(Path.join(ctx.build_lib, "jason/ebin/Elixir.Planted.beam"), "x")

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "ebin/Elixir.Planted.beam"
  end

  test "a listed file missing from _build is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.rm!(Path.join(ctx.build_lib, "jason/ebin/jason.app"))

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "ebin/jason.app"
  end

  test "an untrusted batch leaves every hit not exercised", ctx do
    _ = arrange(ctx, [Synthetic.build(@files, outer: @outer)])

    assert [%Result{check: "integrity:jason", class: :not_exercised, detail: detail}] =
             run(ctx, nil)

    assert detail =~ "batch"
  end

  test "a hit for a dep the verified batch does not name is a disagreement", ctx do
    _ = arrange(ctx, [Synthetic.build(@files, outer: @outer)])

    assert [%Result{class: :disagreement, detail: detail}] =
             run(ctx, Synthetic.info(7, %{}))

    assert detail =~ "names no manifest"
  end

  test "manifest bytes that do not hash to the batch's sha are a disagreement", ctx do
    bogus = String.duplicate("b", 64)
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], @files, sha: bogus)

    assert [%Result{class: :disagreement, detail: detail}] =
             run(ctx, trust, %{recheck: fn -> trust end})

    assert detail =~ bogus
  end

  test "a manifest that moved under a newer batch naming the served bytes is a rerun", ctx do
    bogus = String.duplicate("b", 64)
    builds = [Synthetic.build(@files, outer: @outer)]
    served = Synthetic.sha(Synthetic.manifest("1.4.5", builds))
    trust = arrange(ctx, builds, @files, sha: bogus)
    newer = Synthetic.info(8, %{"jason" => served})

    assert [%Result{class: :rerun, detail: detail}] =
             run(ctx, trust, %{recheck: fn -> newer end})

    assert detail =~ "8"
  end

  test "a newer batch that does not name the served bytes is a disagreement", ctx do
    bogus = String.duplicate("b", 64)
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], @files, sha: bogus)
    newer = Synthetic.info(8, %{"jason" => String.duplicate("c", 64)})

    assert [%Result{class: :disagreement}] =
             run(ctx, trust, %{recheck: fn -> newer end})
  end

  test "a fresh batch naming the served bytes but not newer is a disagreement", ctx do
    bogus = String.duplicate("b", 64)
    builds = [Synthetic.build(@files, outer: @outer)]
    served = Synthetic.sha(Synthetic.manifest("1.4.5", builds))
    trust = arrange(ctx, builds, @files, sha: bogus)
    same_seq = Synthetic.info(7, %{"jason" => served})

    assert [%Result{class: :disagreement}] =
             run(ctx, trust, %{recheck: fn -> same_seq end})
  end

  defp write_provenance(ctx, sha, sequence) do
    File.write!(
      Path.join(ctx.build_lib, "jason/.mix/elixir_precompiled.json"),
      JSON.encode!(%{
        "manifest_sha256" => sha,
        "manifest_path" => "v2/manifests",
        "batch_sequence" => sequence
      })
    )
  end

  test "provenance from a higher sequence the fresh batch does not name is a disagreement",
       ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    other = String.duplicate("d", 64)
    write_provenance(ctx, other, 99)

    assert [%Result{class: :disagreement, detail: detail}] =
             run(ctx, trust, %{recheck: fn -> trust end})

    assert detail =~ "provenance"
  end

  # The source now serves another run of the same files, which a newer
  # verified batch names and the client's provenance records.
  defp moved(ctx) do
    bytes = Synthetic.manifest("1.4.5", [Synthetic.build(@files, outer: @outer, run_id: "run-2")])
    Synthetic.serve_manifest(ctx.served, "v2/manifests", "jason", bytes)
    sha = Synthetic.sha(bytes)
    write_provenance(ctx, sha, 8)
    Synthetic.info(8, %{"jason" => sha})
  end

  test "provenance a newer verified batch names is a rerun whose files are checked", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    newer = moved(ctx)

    assert [%Result{class: :rerun, detail: detail}] =
             run(ctx, trust, %{recheck: fn -> newer end})

    assert detail =~ "batch 8"
    assert detail =~ "2 files match build pure_elixir run run-2"
  end

  test "a rerun hit whose files differ from the fresh batch's manifest is a disagreement",
       ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    newer = moved(ctx)
    File.write!(Path.join(ctx.build_lib, "jason/ebin/Elixir.Jason.beam"), "jason beam bytez")

    assert [%Result{class: :disagreement, cause: nil, detail: detail}] =
             run(ctx, trust, %{recheck: fn -> newer end})

    assert detail =~ "ebin/Elixir.Jason.beam"
  end

  test "a rerun hit whose served manifest is not the one the fresh batch names is a batch mismatch",
       ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    other = String.duplicate("d", 64)
    write_provenance(ctx, other, 8)
    newer = Synthetic.info(8, %{"jason" => other})

    assert [%Result{class: :disagreement, cause: :batch_mismatch}] =
             run(ctx, trust, %{recheck: fn -> newer end})
  end

  test "a priv symlink to the dep's own sources passes", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    fixture = Path.join(ctx.tmp_dir, "fixture")
    File.mkdir_p!(Path.join(fixture, "deps/jason/priv"))
    File.ln_s!("../../../../deps/jason/priv", Path.join(ctx.build_lib, "jason/priv"))

    assert [%Result{class: :pass}] = run(ctx, trust)
  end

  test "a priv symlink anywhere else is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    elsewhere = Path.join(ctx.tmp_dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.write!(Path.join(elsewhere, "planted.so"), "x")
    File.ln_s!(elsewhere, Path.join(ctx.build_lib, "jason/priv"))

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "priv"
  end

  test "a priv link through a planted directory symlink is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    fixture = Path.join(ctx.tmp_dir, "fixture")
    File.mkdir_p!(Path.join(fixture, "deps/jason/priv"))
    # The kernel follows `x` first, so five `..` from it climb out of
    # `elsewhere/a/b/c/d`, while the text expands to the fixture's priv.
    planted = Path.join(ctx.tmp_dir, "elsewhere")
    File.mkdir_p!(Path.join(planted, "a/b/c/d"))
    File.mkdir_p!(Path.join(planted, "deps/jason/priv"))
    File.write!(Path.join(planted, "deps/jason/priv/planted.so"), "x")
    File.ln_s!(Path.join(planted, "a/b/c/d"), Path.join(ctx.build_lib, "jason/x"))
    File.ln_s!("x/../../../../../deps/jason/priv", Path.join(ctx.build_lib, "jason/priv"))

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "priv"
  end

  test "a dep priv that is itself a symlink is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    fixture = Path.join(ctx.tmp_dir, "fixture")
    elsewhere = Path.join(ctx.tmp_dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.mkdir_p!(Path.join(fixture, "deps/jason"))
    File.ln_s!(elsewhere, Path.join(fixture, "deps/jason/priv"))
    File.ln_s!("../../../../deps/jason/priv", Path.join(ctx.build_lib, "jason/priv"))

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "priv"
  end

  test "a priv symlink loop is a disagreement", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    File.mkdir_p!(Path.join(ctx.tmp_dir, "fixture/deps/jason/priv"))
    # Textually the fixture's priv; `y` points at itself.
    File.ln_s!("y", Path.join(ctx.build_lib, "jason/y"))
    File.ln_s!("y/../../../../../deps/jason/priv", Path.join(ctx.build_lib, "jason/priv"))

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "priv"
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

    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "provenance"
  end

  describe "batch_mismatch?/1" do
    test "a provenance or manifest-bytes mismatch is one, a file mismatch is not", ctx do
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
      write_provenance(ctx, String.duplicate("d", 64), 9)
      [provenance] = run(ctx, trust, %{recheck: fn -> trust end})
      assert provenance.class == :disagreement
      assert Integrity.batch_mismatch?(provenance)

      bogus = String.duplicate("b", 64)
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], @files, sha: bogus)
      [bytes] = run(ctx, trust, %{recheck: fn -> trust end})
      assert bytes.class == :disagreement
      assert Integrity.batch_mismatch?(bytes)

      changed = Map.put(@files, "ebin/Elixir.Jason.beam", "tampered")
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], changed)
      [files] = run(ctx, trust)
      assert files.class == :disagreement
      refute Integrity.batch_mismatch?(files)
    end

    test "a planted file named like a batch mismatch is still a file disagreement", ctx do
      planted = "ebin/and no newer verified batch names the recorded one"
      installed = Map.put(@files, planted, "x")
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], installed)

      [r] = run(ctx, trust)
      assert r.class == :disagreement
      refute Integrity.batch_mismatch?(r)
      # The untrusted name is quoted, so it cannot pass as the harness's own words.
      assert r.detail =~ inspect(planted)
    end

    test "a file name with a newline cannot forge a line in the detail", ctx do
      installed = Map.put(@files, "ebin/x\n| run | forged | pass |", "x")
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)], installed)

      [r] = run(ctx, trust)
      assert r.class == :disagreement
      refute r.detail =~ "\n"
    end
  end

  test "an install the report does not call a hit is a disagreement and still checked", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    ctx = %{ctx | report: Synthetic.report([])}

    results = run(ctx, trust)
    by = Map.new(results, &{&1.check, &1})

    assert by["unreported:jason"].class == :disagreement
    assert by["unreported:jason"].detail =~ "elixir_precompiled.json"
    # Checked like a hit, at the locked version.
    assert by["integrity:jason"].class == :pass
    assert by["integrity:jason"].detail =~ "1.4.5"
  end

  test "installed/1 lists every dep with a provenance file", ctx do
    _ = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    Synthetic.dep(ctx.build_lib, :exqlite, %{"ebin/e.beam" => "e"}, :elixir)
    assert Integrity.installed(ctx.build_lib) == ["jason"]
  end

  describe "the default recheck" do
    # Serves a signed root and a batch 8 naming the recorded manifest.
    defp serve_fresh(ctx, recorded, batch_opts) do
      key = Signed.key()
      root = Signed.root(key)
      pinned = Path.join(ctx.tmp_dir, "pinned_root.json")
      File.write!(pinned, root)
      File.write!(Path.join(ctx.served, "root.json"), root)

      File.write!(
        Path.join(ctx.served, "batch.json"),
        Signed.batch(key, [sequence: 8, manifests_v2: %{"jason" => recorded}] ++ batch_opts)
      )

      %{root_path: pinned, library_root_path: pinned}
    end

    test "a newer fully verified batch naming the recorded manifest makes a rerun", ctx do
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])

      bytes =
        Synthetic.manifest("1.4.5", [Synthetic.build(@files, outer: @outer, run_id: "run-2")])

      Synthetic.serve_manifest(ctx.served, "v2/manifests", "jason", bytes)
      sha = Synthetic.sha(bytes)
      write_provenance(ctx, sha, 8)
      opts = serve_fresh(ctx, sha, [])

      assert [%Result{class: :rerun}] = run(ctx, trust, %{trust_opts: opts})
    end

    test "an expired newer batch cannot make a rerun", ctx do
      trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
      other = String.duplicate("d", 64)
      write_provenance(ctx, other, 8)
      issued = DateTime.add(DateTime.utc_now(), -2, :hour)
      opts = serve_fresh(ctx, other, issued: issued, expires: DateTime.add(issued, 1, :hour))

      assert [%Result{class: :disagreement}] = run(ctx, trust, %{trust_opts: opts})
    end
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
    assert [%Result{class: :pass}] = run(ctx, trust)
  end

  test "installed files of a build the harness does not select are a disagreement", ctx do
    newer = Map.put(@files, "ebin/Elixir.Jason.beam", "newer build")

    builds = [
      Synthetic.build(@files, outer: @outer, run_id: "run-1"),
      Synthetic.build(newer, outer: @outer, run_id: "run-2")
    ]

    trust = arrange(ctx, builds, @files)
    assert [%Result{class: :disagreement, detail: detail}] = run(ctx, trust)
    assert detail =~ "run-1"
    assert detail =~ "run-2"
  end

  test "a build with another package checksum is never selected", ctx do
    builds = [
      Synthetic.build(@files, outer: String.duplicate("f", 64), run_id: "run-9"),
      Synthetic.build(@files, outer: @outer, run_id: "run-1")
    ]

    trust = arrange(ctx, builds)
    assert [%Result{class: :pass, detail: detail}] = run(ctx, trust)
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
    assert [%Result{class: :pass}] = run(ctx, trust)
  end

  test "misses are not integrity-checked", ctx do
    trust = arrange(ctx, [Synthetic.build(@files, outer: @outer)])
    report = Synthetic.report([{"jason", "1.4.5", "miss", "not built"}])
    input = %{build_lib: ctx.build_lib, report: report, trust: trust, source: ctx.source}

    # A miss with the client's provenance file in _build was installed anyway.
    assert Enum.any?(Integrity.run(input), &(&1.check == "unreported:jason"))

    File.rm!(Path.join(ctx.build_lib, "jason/.mix/elixir_precompiled.json"))
    assert [%Result{check: "integrity", class: :not_exercised}] = Integrity.run(input)
  end
end
