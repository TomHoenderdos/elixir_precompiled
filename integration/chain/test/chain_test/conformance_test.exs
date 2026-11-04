# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.ConformanceTest do
  use ExUnit.Case, async: true

  alias ChainTest.{Conformance, HTTP, Result, Synthetic, Trust}
  alias ChainTest.Conformance.Setup

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

  # A fake client: fetches the batch and jason's manifest through the case's mirror, as the
  # client does, and reports a hit on 200 or the client's miss detail.
  defp steps(test, snapshot) do
    %{
      snapshot: fn input ->
        send(test, {:snapshot, input})
        {:ok, snapshot}
      end,
      build: fn input ->
        send(test, {:build, input})
        {:ok, _} = HTTP.get(input.source <> "/batch.json", 5_000)

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
    assert build.home_prepared
    assert build.client_config == nil
    assert String.starts_with?(build.home, Path.expand(System.tmp_dir!()))
    refute File.exists?(build.home), "the case home outlives the case"
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
    assert_raise Mix.Error, ~r/--only/, fn -> Conformance.parse!(["--only", ""]) end
    assert_raise Mix.Error, ~r/--only/, fn -> Conformance.parse!(["--only", ","]) end
  end

  test "an empty --only list stops before the snapshot", ctx do
    cases!(ctx.opts, [@t0])

    assert {[%Result{check: "setup", class: :not_exercised}], _} =
             Conformance.run(%{ctx.opts | only: []}, steps(self(), ctx.snapshot))

    refute_received {:snapshot, _}
  end

  test "a snapshot the run took is removed afterwards; one in --snapshot-dir is kept", ctx do
    cases!(ctx.opts, [@t0])
    Conformance.run(ctx.opts, steps(self(), ctx.snapshot))
    refute File.exists?(ctx.snapshot.dir)

    File.mkdir_p!(Path.join(ctx.snapshot.dir, "v2/manifests"))
    File.write!(Path.join(ctx.snapshot.dir, "batch.json"), "{}")
    File.write!(Path.join(ctx.snapshot.dir, "v2/manifests/jason.json"), "{}")

    {verdicts, _} =
      Conformance.run(%{ctx.opts | snapshot_dir: ctx.snapshot.dir}, steps(self(), ctx.snapshot))

    assert [%Result{class: :pass}] = verdicts
    assert File.exists?(Path.join(ctx.snapshot.dir, "batch.json"))
  end

  test "a case that raises fails; the other cases still run", ctx do
    cases!(ctx.opts, [@status, @t0])
    s = steps(self(), ctx.snapshot)

    build = fn input ->
      if String.ends_with?(input.source, "/crash"), do: raise("boom"), else: s.build.(input)
    end

    # The first mirror the case runner starts is the reference mirror; the
    # next is N5's, whose url this test marks so its build raises.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    mirror = fn dir, opts ->
      {:ok, m} = ChainTest.Mirror.start(dir, opts)
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      if n == 1, do: {:ok, %{m | url: m.url <> "/crash"}}, else: {:ok, m}
    end

    {verdicts, _} = Conformance.run(ctx.opts, %{s | build: build} |> Map.put(:mirror, mirror))

    assert [
             %Result{check: "N5-manifest-500", class: :fail, detail: detail},
             %Result{check: "T0", class: :pass}
           ] = verdicts

    assert detail =~ "boom"
    assert Result.exit_code(verdicts) == 1
  end

  test "a reference mirror that cannot start stops the run", ctx do
    cases!(ctx.opts, [@t0])
    s = Map.put(steps(self(), ctx.snapshot), :mirror, fn _dir, _opts -> {:error, :eaddrinuse} end)

    assert {[%Result{check: "setup", class: :not_exercised, detail: detail}], _} =
             Conformance.run(ctx.opts, s)

    assert detail =~ "eaddrinuse"
    refute_received {:build, _}
  end

  test "a case mirror that cannot start leaves that case not exercised", ctx do
    cases!(ctx.opts, [@t0, @status])

    mirror = fn dir, opts ->
      if Keyword.has_key?(opts, :transform),
        do: {:error, :emfile},
        else: ChainTest.Mirror.start(dir, opts)
    end

    s = Map.put(steps(self(), ctx.snapshot), :mirror, mirror)

    assert {[
              %Result{check: "T0", class: :not_exercised, detail: detail},
              %Result{check: "N5-manifest-500", class: :not_exercised}
            ], _} = Conformance.run(ctx.opts, s)

    assert detail =~ "emfile"
    refute_received {:build, _}
  end

  describe "case model v2" do
    # The fake build of steps/2, which also records the home it found and
    # writes the client's state for its source, as the client does after
    # accepting batch 7.
    defp v2_steps(test, snapshot, opts \\ []) do
      s = steps(test, snapshot)

      build = fn input ->
        send(test, {:home_at_build, File.ls!(input.home)})
        source = (input.client_config || %{})[:source] || input.source

        if Keyword.get(opts, :write_state, true) do
          {:ok, dir} = Setup.state_dir(input.home, source, Trust.library_root_path())
          File.mkdir_p!(dir)
          File.write!(Path.join(dir, "state"), "7")
        end

        s.build.(input)
      end

      %{s | build: build}
    end

    defp v2(c, extra), do: Map.merge(c, extra)

    test "setup runs in the case's home before the build, with the case's context", ctx do
      Process.register(self(), :conformance_v2_test)

      c =
        v2(@t0, %{
          setup:
            {ChainTest.TestSetup,
             %{files: %{"files/planted" => "x"}, notify: :conformance_v2_test}}
        })

      cases!(ctx.opts, [c])
      {[verdict], _} = Conformance.run(ctx.opts, v2_steps(self(), ctx.snapshot))

      assert %Result{class: :pass} = verdict
      assert_received {:setup, home, snap}
      assert_received {:home_at_build, ["files"]}
      assert_received {:build, build}
      assert build.home == home
      assert snap.case.source == build.source
      assert snap.case.root == Trust.library_root_path()
      assert snap.case.mirrors == [build.source]
      assert snap.sequence == 7
    end

    test "a setup that fails fails the case without a build", ctx do
      failing = v2(@t0, %{id: "S1", setup: {ChainTest.TestSetup, %{fail: "no space"}}})
      cases!(ctx.opts, [failing, @t0])
      {verdicts, _} = Conformance.run(ctx.opts, v2_steps(self(), ctx.snapshot))

      assert [%Result{check: "S1", class: :fail, detail: detail}, %Result{class: :pass}] =
               verdicts

      assert detail =~ "no space"
      assert_received {:build, _}
      refute_received {:build, _}
    end

    test "client_config reaches that case's build only, and names the case's source", ctx do
      Process.register(self(), :conformance_v2_test)
      source = "http://127.0.0.1:9"

      first =
        v2(@t0, %{
          id: "C1",
          client_config: %{clock_offset_seconds: 60, source: source},
          setup: {ChainTest.TestSetup, %{notify: :conformance_v2_test}}
        })

      cases!(ctx.opts, [first, @t0])
      Conformance.run(ctx.opts, v2_steps(self(), ctx.snapshot))

      assert_received {:build, %{client_config: %{clock_offset_seconds: 60}}}
      assert_received {:build, %{client_config: nil}}
      assert_received {:setup, _home, %{case: %{source: ^source}}}
    end

    test "after: post-conditions are checked against the case home and _build", ctx do
      pass = v2(@t0, %{id: "A1", after: %{state_sequence: :snapshot, cache: :untouched}})
      fail = v2(@t0, %{id: "A2", after: %{state_sequence: :unchanged}})
      cases!(ctx.opts, [pass, fail])

      {verdicts, _} = Conformance.run(ctx.opts, v2_steps(self(), ctx.snapshot))

      assert [
               %Result{check: "A1", class: :pass},
               %Result{check: "A2", class: :fail, detail: detail}
             ] = verdicts

      assert detail =~ "state_sequence"
    end

    test "after installed reads the provenance files under the target's _build", ctx do
      build_lib = Path.join(ctx.tmp, "fixture/_build/rpi4_dev/lib")
      s = v2_steps(self(), ctx.snapshot)

      build = fn input ->
        Synthetic.dep(build_lib, :jason, %{"ebin/x.beam" => "x"}, :installed)
        {rows, info} = s.build.(input)
        {rows, %{info | build_lib: build_lib}}
      end

      cases!(ctx.opts, [
        v2(@t0, %{id: "I1", after: %{installed: :snapshot}}),
        v2(@t0, %{id: "I2", after: %{installed: :none}})
      ])

      {verdicts, _} = Conformance.run(ctx.opts, %{s | build: build})

      assert [
               %Result{check: "I1", class: :pass},
               %Result{check: "I2", class: :fail, detail: detail}
             ] = verdicts

      assert detail =~ "jason"
    end

    test "a case needing an older batch the snapshot lacks is not testable here, unbuilt",
         ctx do
      c = v2(@t0, %{setup: {ChainTest.TestSetup, %{needs: [:old]}}})
      t = %{@t0 | id: "T2", transform: {ChainTest.TestTransform, %{needs: [:previous]}}}
      cases!(ctx.opts, [c, t])

      snapshot = Map.put(ctx.snapshot, :old, {:missing, "the portal keeps no old batch"})

      assert {[
                %Result{check: "T0", class: :not_exercised, detail: detail},
                %Result{check: "T2", class: :not_exercised, detail: detail2}
              ], _} = Conformance.run(ctx.opts, v2_steps(self(), snapshot))

      assert detail =~ "not testable here"
      assert detail =~ "the portal keeps no old batch"
      assert detail2 =~ "previous"
      refute_received {:build, _}
    end

    test "mirrors: 2 starts a second mirror the case mirror knows; both are stopped", ctx do
      test = self()

      mirror = fn dir, opts ->
        {:ok, m} = ChainTest.Mirror.start(dir, opts)
        send(test, {:mirror, m})
        {:ok, m}
      end

      build = fn input ->
        send(test, {:build, input})
        {:ok, _} = HTTP.get(input.source <> "/v2/manifests/jason.json", 5_000)
        {:error, why} = HTTP.get(input.source <> "/batch.json", 5_000)
        send(test, {:batch, why})

        {:ok, {{_, 302, _}, headers, _}} =
          :httpc.request(:get, {~c"#{input.source}/batch.json", []}, [autoredirect: false], [])

        send(test, {:location, to_string(:proplists.get_value(~c"location", headers))})

        {[%Result{step: :build, check: "compile", class: :pass}],
         %{report: Synthetic.report([]), build_lib: "/nonexistent", fw_path: nil, sequence: 7}}
      end

      c = %{@t0 | id: "N1", transform: {ChainTest.TestTransform, %{mirrors: 2}}}
      cases!(ctx.opts, [c])

      s = v2_steps(self(), ctx.snapshot) |> Map.merge(%{mirror: mirror, build: build})
      Conformance.run(ctx.opts, s)

      assert_received {:mirror, _reference}
      assert_received {:mirror, second}
      assert_received {:mirror, case_mirror}
      assert_received {:build, %{source: source}}
      assert source == case_mirror.url
      assert_received {:batch, why}
      assert why =~ "302"
      assert_received {:location, location}
      assert location == second.url <> "/batch.json"

      refute Process.alive?(second.pid)
      refute Process.alive?(case_mirror.pid)
    end
  end

  describe "typo'd transforms" do
    for bad <- ChainTest.BadTransform.shapes() do
      test "#{bad} fails a miss-expecting case and names the transform error", ctx do
        c = %{@status | transform: {ChainTest.BadTransform, %{bad: unquote(bad)}}}
        cases!(ctx.opts, [c])

        assert {[%Result{check: "N5-manifest-500", class: :fail, detail: detail}], _} =
                 Conformance.run(ctx.opts, steps(self(), ctx.snapshot))

        assert detail =~ "transform error"
        assert detail =~ "v2/manifests/jason.json"
      end
    end
  end
end
