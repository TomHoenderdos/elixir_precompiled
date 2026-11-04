# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.ConformanceTest do
  use ExUnit.Case, async: true

  alias ChainTest.{Conformance, HTTP, Result, Synthetic}

  @moduletag :tmp_dir

  @t0 %{
    id: "T0",
    description: "Served unchanged.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{}
  }

  @status %{
    id: "N5-manifest-500",
    description: "A 500 on jason's manifest.",
    transform: {ChainTest.Mirror.Status, %{paths: ["v2/manifests/jason.json"], status: 500}},
    client: %{default: :snapshot, deps: %{jason: {:miss, "manifest unavailable:"}}},
    harness: %{"build/hit:jason" => :fail}
  }

  setup %{tmp_dir: tmp} do
    snap_dir = Path.join(tmp, "snap")
    File.mkdir_p!(Path.join(snap_dir, "v2/manifests"))
    File.write!(Path.join(snap_dir, "batch.json"), "{}")
    File.write!(Path.join(snap_dir, "v2/manifests/jason.json"), "{}")

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

    opts = %{
      target: "rpi4",
      source: "https://portal.invalid",
      cases: Path.join(tmp, "cases.exs"),
      only: nil,
      snapshot_dir: nil,
      report_dir: Path.join(tmp, "reports"),
      fixture_dir: fixture
    }

    %{opts: opts, snapshot: snapshot, tmp: tmp}
  end

  defp cases!(opts, cases), do: File.write!(opts.cases, inspect(cases, limit: :infinity))

  # A fake client: fetches jason's manifest through the case's mirror, as the
  # client does, and reports a hit on 200 or the client's miss detail.
  defp steps(test, snapshot) do
    %{
      snapshot: fn input ->
        send(test, {:snapshot, input})
        {:ok, snapshot}
      end,
      build: fn input ->
        send(test, {:build, input})

        line =
          case HTTP.get(input.source <> "/v2/manifests/jason.json", 5_000) do
            {:ok, _} ->
              {"jason", "1.4.5", "hit", "0.3 MB"}

            {:error, _} ->
              {"jason", "1.4.5", "miss", "manifest unavailable: Status 500 Internal Server Error"}
          end

        class = if elem(line, 2) == "hit", do: :pass, else: :fail

        {[
           %Result{step: :build, check: "compile", class: :pass},
           %Result{step: :build, check: "hit:jason", class: class}
         ],
         %{report: Synthetic.report([line]), build_lib: "/nonexistent", fw_path: nil, sequence: 7}}
      end,
      integrity: fn input ->
        send(test, {:integrity, input})
        [%Result{step: :integrity, check: "integrity", class: :pass}]
      end,
      compiled: fn _ -> [%Result{step: :compiled, check: "compiled_here", class: :pass}] end
    }
  end

  test "T0 and the example case pass; per-case and summary reports are written", ctx do
    cases!(ctx.opts, [@t0, @status])
    {verdicts, meta} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot))

    assert [%Result{check: "T0", class: :pass}, %Result{check: "N5-manifest-500", class: :pass}] =
             verdicts

    assert Result.exit_code(verdicts) == 0
    assert meta.batch_sequence_step1 == 7
    assert [_] = Path.wildcard(Path.join(ctx.opts.report_dir, "rpi4-T0-*.json"))
    assert [_] = Path.wildcard(Path.join(ctx.opts.report_dir, "rpi4-N5-manifest-500-*.json"))
  end

  test "the client gets the case mirror, compile, a site config and a fresh home; integrity the reference mirror",
       ctx do
    cases!(ctx.opts, [@t0])
    Conformance.run(ctx.opts, steps(self(), ctx.snapshot))

    assert_received {:build, build}
    assert_received {:integrity, integrity}
    assert build.command == ["compile"]
    assert build.trust == ctx.snapshot.info
    refute Map.has_key?(build, :home)
    assert String.starts_with?(build.source, "http://127.0.0.1:")
    assert File.read!(build.target_config) =~ "import Config"
    assert String.starts_with?(integrity.source, "http://127.0.0.1:")
    refute integrity.source == build.source
    assert integrity.recheck.() == nil
  end

  test "a case whose expectation is not met fails the run", ctx do
    wrong = %{@status | client: %{default: :snapshot, deps: %{jason: :hit}}}
    cases!(ctx.opts, [wrong])
    {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot))

    assert [%Result{class: :fail, detail: detail}] = verdicts
    assert detail =~ "jason"
    assert Result.exit_code(verdicts) == 1
  end

  test "a bad case file stops before the snapshot", ctx do
    cases!(ctx.opts, [Map.put(@t0, :typo, 1)])
    {verdicts, _} = Conformance.run(ctx.opts, steps(self(), ctx.snapshot))

    assert [%Result{check: "setup", class: :not_exercised}] = verdicts
    refute_received {:snapshot, _}
  end

  test "--only runs the named cases; an unknown id stops before the snapshot", ctx do
    cases!(ctx.opts, [@t0, @status])

    {verdicts, _} = Conformance.run(%{ctx.opts | only: ["T0"]}, steps(self(), ctx.snapshot))
    assert [%Result{check: "T0"}] = verdicts

    {verdicts, _} = Conformance.run(%{ctx.opts | only: ["T9"]}, steps(self(), ctx.snapshot))
    assert [%Result{check: "setup", class: :not_exercised, detail: detail}] = verdicts
    assert detail =~ "T9"
  end

  test "a snapshot that cannot be taken stops the run", ctx do
    cases!(ctx.opts, [@t0])
    s = Map.put(steps(self(), ctx.snapshot), :snapshot, fn _ -> {:error, "production moved"} end)

    assert {[%Result{check: "setup", class: :not_exercised, detail: "production moved"}], _} =
             Conformance.run(ctx.opts, s)
  end

  test "parse!/1 defaults and refusals" do
    opts = Conformance.parse!([])
    assert opts.target == "rpi4"
    assert opts.source == ChainTest.CLI.default_source()
    assert opts.cases == Path.join(ChainTest.CLI.root(), "conformance/cases.exs")
    assert opts.only == nil
    assert String.starts_with?(opts.report_dir, Path.expand(System.tmp_dir!()))
    assert Conformance.parse!(["--only", "T0,N5-manifest-500"]).only == ["T0", "N5-manifest-500"]
    assert_raise Mix.Error, fn -> Conformance.parse!(["--target", "bbb"]) end
    assert_raise Mix.Error, fn -> Conformance.parse!(["extra"]) end
  end
end
