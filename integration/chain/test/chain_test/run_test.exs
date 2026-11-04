# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.RunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ChainTest.{LocalServer, Result, Run, Signed, Synthetic, Trust}

  @moduletag :tmp_dir

  @trust_checks ~w(root_pin root_signature root_expiry served_root batch_signature
                   batch_threshold batch_format batch_expiry batch_freshness batch_lifetime)

  defp r(step, check, class, detail \\ ""),
    do: %Result{step: step, check: check, class: class, detail: detail}

  defp trust_ok(sequence) do
    {Enum.map(@trust_checks, &r(:trust, &1, :pass)), Synthetic.info(sequence, %{})}
  end

  @hit_report Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])

  # Fake steps: every one passes and records its input.
  defp steps(test_pid, overrides \\ %{}) do
    send_in = fn name, input -> send(test_pid, {name, input}) end

    Map.merge(
      %{
        preflight: fn opts ->
          send_in.(:preflight, opts)
          [r(:preflight, "ssh", :pass)]
        end,
        trust: fn input ->
          send_in.(:trust, input)
          trust_ok(7)
        end,
        build: fn input ->
          send_in.(:build, input)

          {[r(:build, "firmware", :pass), r(:build, "hit:jason", :pass), seq_result(input, 7)],
           %{
             report: @hit_report,
             build_lib: Path.join(input.fixture_dir, "_build/rpi4_dev/lib"),
             fw_path: "/fw/chain_fixture.fw",
             sequence: 7
           }}
        end,
        integrity: fn input ->
          send_in.(:integrity, input)
          [r(:integrity, "integrity:jason", :pass)]
        end,
        compiled: fn input ->
          send_in.(:compiled, input)
          [r(:compiled, "compiled_here", :pass)]
        end,
        deploy: fn input ->
          send_in.(:deploy, input)

          {[r(:deploy, "upload", :pass), r(:deploy, "active_uuid", :pass)],
           %{expected_uuid: "u-1"}}
        end,
        device: fn input ->
          send_in.(:device, input)
          [r(:device, "probe", :pass)]
        end,
        versions: fn _opts -> %{client_commit: "abc123", nerves_commit: "def456"} end
      },
      overrides
    )
  end

  # Build's own sequence check, as ChainTest.Build makes it.
  defp seq_result(%{trust: %{sequence: s}}, s), do: r(:build, "sequence", :pass)
  defp seq_result(%{trust: nil}, _), do: r(:build, "sequence", :not_exercised)
  defp seq_result(_, _), do: r(:build, "sequence", :rerun, "production moved")

  defp argv(ctx),
    do: ["--target", "rpi4", "--device", "dev.local", "--report-dir", ctx.reports]

  setup %{tmp_dir: tmp} do
    fixture = Path.join(tmp, "fixture")
    Synthetic.tree(fixture, "rpi4", %{"jason" => {"1.4.5", "ff"}}, "2.0.1")
    File.write!(Path.join(fixture, "expected.exs"), "%{hits: [:jason], never: [:nerves]}\n")
    %{reports: Path.join(tmp, "reports"), fixture: fixture}
  end

  defp main(ctx, steps) do
    opts = %{ChainTest.CLI.parse!(argv(ctx)) | fixture_dir: ctx.fixture}

    {code, out} =
      with_io(fn -> Run.main_with(opts, steps) end)

    {code, out}
  end

  defp report(ctx) do
    [json] = Path.wildcard(Path.join(ctx.reports, "rpi4-*.json"))
    [md] = Path.wildcard(Path.join(ctx.reports, "rpi4-*.md"))
    {JSON.decode!(File.read!(json)), File.read!(md)}
  end

  defp checks(doc), do: Enum.map(doc["results"], &"#{&1["step"]}/#{&1["check"]}")

  defp class_of(doc, id),
    do: Enum.find(doc["results"], &("#{&1["step"]}/#{&1["check"]}" == id))["class"]

  test "a chain where every step passes exits 0 and writes a report with every step", ctx do
    {code, out} = main(ctx, steps(self()))

    assert code == 0
    assert out =~ "report: "
    {doc, md} = report(ctx)

    steps = doc["results"] |> Enum.map(& &1["step"]) |> Enum.uniq()
    assert steps == ~w(preflight trust build integrity compiled deploy device)
    assert "trust/client_verdict" in checks(doc)
    assert class_of(doc, "trust/client_verdict") == "pass"
    assert doc["exit_code"] == 0

    assert doc["meta"]["batch_sequence_step1"] == 7
    assert doc["meta"]["batch_sequence_step2"] == 7
    assert doc["meta"]["root_version"] == 1
    assert doc["meta"]["client_commit"] == "abc123"
    assert doc["meta"]["nerves_commit"] == "def456"
    assert doc["meta"]["system_version"] == "nerves_system_rpi4 2.0.1"
    assert md =~ "# Chain test: rpi4 (PASS)"

    # The wiring: each step got the previous one's output.
    assert_received {:build, %{trust: %{sequence: 7}, target: "rpi4"}}
    assert_received {:integrity, %{trust: %{sequence: 7}, report: @hit_report}}
    assert_received {:deploy, %{fw_path: "/fw/chain_fixture.fw", device: "dev.local"}}
    assert_received {:device, device}
    assert device.expected_uuid == "u-1"
    assert device.apps == ["jason"]
    assert device.release_dir == Path.join(ctx.fixture, "_build/rpi4_dev/rel/chain_fixture")
    assert device.system == {"nerves_system_rpi4", "2.0.1"}
  end

  test "the device probes every reported hit, not only the expected ones", ctx do
    report =
      Synthetic.report([
        {"jason", "1.4.5", "hit", "x"},
        {"spark", "2.7.9", "hit", "x"},
        {"telemetry", "1.3.0", "miss", "no build"},
        {"Bad\"name", "1", "hit", "x"}
      ])

    build = fn input ->
      {[r(:build, "firmware", :pass), seq_result(input, 7)],
       %{report: report, build_lib: "/b/lib", fw_path: "/fw", sequence: 7}}
    end

    {code, _} = main(ctx, steps(self(), %{build: build}))

    assert_received {:device, device}
    assert device.apps == ["jason", "spark"]
    # A hit name that is not an app name cannot be probed: a failure, not skipped.
    {doc, _} = report(ctx)
    assert class_of(doc, ~s|device/app:"Bad\\"name"|) == "fail"
    assert code == 1
  end

  test "one disagreement anywhere exits 1", ctx do
    device = fn _ -> [r(:device, "files:jason", :disagreement, "differs")] end
    {code, _} = main(ctx, steps(self(), %{device: device}))

    assert code == 1
    {doc, md} = report(ctx)
    assert class_of(doc, "device/files:jason") == "disagreement"
    assert md =~ "(FAIL)"
  end

  test "a failed preflight builds nothing and still writes a report", ctx do
    preflight = fn _ -> [r(:preflight, "ssh", :fail, "host key changed")] end
    {code, _} = main(ctx, steps(self(), %{preflight: preflight}))

    assert code == 1
    refute_received {:build, _}
    refute_received {:deploy, _}
    {doc, _} = report(ctx)
    assert class_of(doc, "run/aborted") == "not_exercised"
  end

  test "a deploy that does not land leaves the device step not exercised", ctx do
    deploy = fn _ ->
      {[r(:deploy, "active_uuid", :fail, "expected a, device runs b")], %{expected_uuid: "a"}}
    end

    {code, _} = main(ctx, steps(self(), %{deploy: deploy}))

    assert code == 1
    refute_received {:device, _}
    {doc, _} = report(ctx)
    assert class_of(doc, "device/probe") == "not_exercised"
  end

  test "a batch the harness rejects but the client installed from is a disagreement", ctx do
    trust = fn _ ->
      {[r(:trust, "batch_signature", :fail, "no valid signature")], nil}
    end

    {code, _} = main(ctx, steps(self(), %{trust: trust}))

    assert code == 1
    {doc, _} = report(ctx)
    assert class_of(doc, "trust/client_verdict") == "disagreement"
  end

  test "a batch the harness verified but the client refused is a disagreement", ctx do
    report = Synthetic.report([{"jason", "1.4.5", "fail", "batch signature invalid: x"}])

    build = fn input ->
      {[r(:build, "hit:jason", :refused), seq_result(input, 7)],
       %{report: report, build_lib: "/b/lib", fw_path: nil, sequence: 7}}
    end

    {code, _} = main(ctx, steps(self(), %{build: build}))

    assert code == 1
    {doc, _} = report(ctx)
    assert class_of(doc, "trust/client_verdict") == "disagreement"
  end

  test "a revoked build refused under a verified batch is not a disagreement", ctx do
    report = Synthetic.report([{"jason", "1.4.5", "fail", "revoked: build run-1 withdrawn"}])

    build = fn input ->
      {[r(:build, "hit:jason", :refused), seq_result(input, 7)],
       %{report: report, build_lib: "/b/lib", fw_path: nil, sequence: 7}}
    end

    main(ctx, steps(self(), %{build: build}))
    {doc, _} = report(ctx)
    assert class_of(doc, "trust/client_verdict") == "pass"
    assert class_of(doc, "build/hit:jason") == "refused"
  end

  test "both rejecting the batch is a pass of the verdict check", ctx do
    trust = fn _ -> {[r(:trust, "batch_signature", :fail)], nil} end
    report = Synthetic.report([{"jason", "1.4.5", "fail", "batch signature invalid: x"}])

    build = fn input ->
      {[seq_result(input, 7)],
       %{report: report, build_lib: "/b/lib", fw_path: nil, sequence: nil}}
    end

    main(ctx, steps(self(), %{trust: trust, build: build}))
    {doc, _} = report(ctx)
    assert class_of(doc, "trust/client_verdict") == "pass"
  end

  describe "a client batch other than step 1's" do
    setup %{tmp_dir: tmp} do
      served = Path.join(tmp, "served")
      File.mkdir_p!(Path.join(served, "batches"))
      {base, pid} = LocalServer.serve(served)
      on_exit(fn -> LocalServer.stop(pid) end)

      key = Signed.key()
      root = Signed.root(key)
      pinned = Path.join(tmp, "pinned_root.json")
      File.write!(pinned, root)
      File.write!(Path.join(served, "root.json"), root)
      File.write!(Path.join(served, "batch.json"), Signed.batch(key, sequence: 7))

      # The real Trust check against the local server and pinned root.
      trust = fn input ->
        Trust.check(Map.merge(input, %{root_path: pinned, library_root_path: pinned}))
      end

      build = fn input ->
        {[r(:build, "firmware", :pass), seq_result(input, 9)],
         %{
           report: @hit_report,
           build_lib: "/b/lib",
           fw_path: "/fw",
           sequence: 9
         }}
      end

      %{served: served, source: base, key: key, trust: trust, build: build}
    end

    defp main_at(ctx, steps) do
      opts = %{
        ChainTest.CLI.parse!(argv(ctx) ++ ["--source", ctx.source])
        | fixture_dir: ctx.fixture
      }

      with_io(fn -> Run.main_with(opts, steps) end)
    end

    test "verified independently: the sequence passes and integrity uses that batch", ctx do
      v2 = %{"jason" => String.duplicate("c", 64)}

      File.write!(
        Path.join(ctx.served, "batches/9.json"),
        Signed.batch(ctx.key, sequence: 9, manifests_v2: v2)
      )

      {code, _} = main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build}))

      assert code == 0
      {doc, _} = report(ctx)
      assert class_of(doc, "build/sequence") == "pass"
      assert class_of(doc, "trust/client_batch:batch_signature") == "pass"
      assert class_of(doc, "trust/client_verdict") == "pass"
      assert doc["meta"]["batch_sequence_step1"] == 7
      assert doc["meta"]["batch_sequence_step2"] == 9
      assert_received {:integrity, %{trust: %{sequence: 9, manifests_v2: ^v2}}}
    end

    defp assert_rerun_run(ctx, code) do
      {doc, md} = report(ctx)
      assert class_of(doc, "build/sequence") == "rerun"

      client_rows =
        Enum.filter(doc["results"], &String.starts_with?(&1["check"], "client_batch:"))

      assert client_rows != []
      assert Enum.all?(client_rows, &(&1["class"] in ["rerun", "pass"])), inspect(client_rows)

      assert code == 0
      assert doc["exit_code"] == 0
      assert md =~ "# Chain test: rpi4 (RERUN)"
      doc
    end

    test "not fetchable: the sequence is a rerun", ctx do
      {code, _} = main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build}))

      doc = assert_rerun_run(ctx, code)
      assert class_of(doc, "trust/client_batch:batch_signature") == "rerun"
      assert class_of(doc, "trust/client_batch:batch_format") == "rerun"

      assert Enum.find(doc["results"], &(&1["check"] == "client_batch:batch_signature"))[
               "detail"
             ] =~ "batches/9.json"

      assert Enum.find(doc["results"], &(&1["check"] == "sequence"))["detail"] =~ "batches/9.json"
      assert_received {:integrity, %{trust: %{sequence: 7}}}
    end

    # A client batch the harness fetched and rejects: the client installed
    # from a batch the harness does not accept.
    defp assert_rejected_run(ctx, code) do
      {doc, md} = report(ctx)
      assert code == 1
      assert doc["exit_code"] == 1
      assert md =~ "# Chain test: rpi4 (FAIL)"
      assert class_of(doc, "build/sequence") == "fail"
      assert class_of(doc, "trust/client_verdict") == "disagreement"
      doc
    end

    test "badly signed: the client batch fails and the verdict is a disagreement", ctx do
      other = Signed.key()
      File.write!(Path.join(ctx.served, "batches/9.json"), Signed.batch(other, sequence: 9))

      {code, _} = main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build}))
      doc = assert_rejected_run(ctx, code)
      assert class_of(doc, "trust/client_batch:batch_signature") == "fail"
      assert class_of(doc, "trust/client_batch:batch_format") == "not_exercised"
    end

    test "a numbered batch whose payload names another sequence fails", ctx do
      File.write!(Path.join(ctx.served, "batches/9.json"), Signed.batch(ctx.key, sequence: 8))

      {code, _} = main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build}))
      doc = assert_rejected_run(ctx, code)
      assert Enum.find(doc["results"], &(&1["check"] == "sequence"))["detail"] =~ "sequence 8"
    end

    test "under a rejected client batch a batch mismatch stays a disagreement", ctx do
      other = Signed.key()
      File.write!(Path.join(ctx.served, "batches/9.json"), Signed.batch(other, sequence: 9))

      integrity = fn _ ->
        [
          %{
            r(:integrity, "integrity:jason", :disagreement, "provenance names another manifest")
            | cause: :batch_mismatch
          }
        ]
      end

      {code, _} =
        main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build, integrity: integrity}))

      doc = assert_rejected_run(ctx, code)
      assert class_of(doc, "integrity/integrity:jason") == "disagreement"
    end

    test "production moving twice: integrity's batch mismatch is a rerun, not a disagreement",
         ctx do
      # The client used batch 9 (not fetchable); by step 3 production is at
      # 11, which names neither manifest, so Integrity sees a mismatch.
      integrity = fn input ->
        send(self(), {:integrity, input})

        [
          %{
            r(:integrity, "integrity:jason", :disagreement, "provenance names another manifest")
            | cause: :batch_mismatch
          }
        ]
      end

      {code, _} =
        main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build, integrity: integrity}))

      doc = assert_rerun_run(ctx, code)
      assert class_of(doc, "integrity/integrity:jason") == "rerun"
    end

    test "a disagreement that only reads like a batch mismatch stays one", ctx do
      integrity = fn _ ->
        [
          r(
            :integrity,
            "integrity:jason",
            :disagreement,
            ~s|"ebin/and no newer verified batch names the recorded one": in _build, not listed|
          )
        ]
      end

      {code, _} =
        main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build, integrity: integrity}))

      assert code == 1
      {doc, md} = report(ctx)
      assert class_of(doc, "integrity/integrity:jason") == "disagreement"
      assert md =~ "(FAIL)"
    end

    test "a file mismatch under a rerun stays a disagreement", ctx do
      integrity = fn _ ->
        [r(:integrity, "integrity:jason", :disagreement, "1 files differ from build x")]
      end

      {code, _} =
        main_at(ctx, steps(self(), %{trust: ctx.trust, build: ctx.build, integrity: integrity}))

      assert code == 1
      {doc, _} = report(ctx)
      assert class_of(doc, "integrity/integrity:jason") == "disagreement"
    end
  end

  test "the default report dir is outside the repository" do
    opts = ChainTest.CLI.parse!(["--target", "rpi4", "--device", "d"])
    repo = Path.expand("../../../..", __DIR__)

    refute String.starts_with?(opts.report_dir, repo)
    assert String.starts_with?(opts.report_dir, Path.expand(System.tmp_dir!()))
  end
end
