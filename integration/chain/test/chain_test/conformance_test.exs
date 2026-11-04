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
                %Result{check: "T0", class: :not_testable, detail: detail},
                %Result{check: "T2", class: :not_testable, detail: detail2}
              ], _} = Conformance.run(ctx.opts, v2_steps(self(), snapshot))

      assert detail =~ "not testable here"
      assert detail =~ "the portal keeps no old batch"
      assert detail2 =~ "previous"
      refute_received {:build, _}
    end

    test "client_env reaches the build, a {:home, rel} path under the case home", ctx do
      c =
        v2(@t0, %{
          setup: {ChainTest.Conformance.Setup.PlantRoot, %{path: "attacker/root.json"}},
          client_env: %{
            "ELIXIR_PRECOMPILED_ROOT" => {:home, "attacker/root.json"},
            "NERVES_PRECOMPILED_ROOT" => "/abs/root.json"
          }
        })

      cases!(ctx.opts, [c, %{@t0 | id: "T0b"}])
      s = v2_steps(self(), ctx.snapshot)

      build = fn input ->
        if env = input.client_env,
          do:
            send(:conformance_env_test, {:planted, File.exists?(env["ELIXIR_PRECOMPILED_ROOT"])})

        s.build.(input)
      end

      Process.register(self(), :conformance_env_test)
      Conformance.run(ctx.opts, %{s | build: build})

      assert_received {:build, %{home: home, client_env: env}}
      assert env["ELIXIR_PRECOMPILED_ROOT"] == Path.join(home, "attacker/root.json")
      assert env["NERVES_PRECOMPILED_ROOT"] == "/abs/root.json"
      assert_received {:planted, true}
      assert_received {:build, %{client_env: nil}}
    end

    test "a clock age is resolved against the snapshot batch's issue, however old it is", ctx do
      issued = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

      File.write!(
        Path.join(ctx.snapshot.dir, "batch.json"),
        ChainTest.Signed.batch(ChainTest.Signed.key(), issued: issued)
      )

      cases!(ctx.opts, [
        v2(@t0, %{id: "R8", client_config: %{clock_offset_seconds: {:age, 23 * 3600}}}),
        v2(@t0, %{id: "R7", client_config: %{clock_offset_seconds: {:age, 25 * 3600}}})
      ])

      Conformance.run(ctx.opts, v2_steps(self(), ctx.snapshot))

      for age <- [23 * 3600, 25 * 3600] do
        assert_received {:build, %{client_config: %{clock_offset_seconds: offset}}}
        clock = DateTime.add(DateTime.utc_now(), offset, :second)
        assert_in_delta DateTime.diff(clock, issued), age, 5
      end
    end

    test "a case whose build crashes still removes its home", ctx do
      cases!(ctx.opts, [@t0])
      s = v2_steps(self(), ctx.snapshot)

      build = fn input ->
        send(self(), {:crash_home, input.home})
        raise "build blew up"
      end

      assert {[%Result{check: "T0", class: :fail, detail: detail}], _} =
               Conformance.run(ctx.opts, %{s | build: build})

      assert detail =~ "build blew up"
      assert_received {:crash_home, home}
      refute File.exists?(home), "the case home outlives a crashed case"
    end

    test "a case whose setup fails still removes its home", ctx do
      Process.register(self(), :conformance_home_test)

      c =
        v2(@t0, %{setup: {ChainTest.TestSetup, %{fail: "no", notify: :conformance_home_test}}})

      cases!(ctx.opts, [c])
      Conformance.run(ctx.opts, v2_steps(self(), ctx.snapshot))
      assert_received {:setup, home, _}
      refute File.exists?(home)
    end

    test "the build's output reaches the after log check", ctx do
      s = v2_steps(self(), ctx.snapshot)

      build = fn input ->
        {rows, info} = s.build.(input)
        {rows, Map.put(info, :log, "precompiled: state x is unreadable; treating it as 0\n")}
      end

      cases!(ctx.opts, [
        v2(@t0, %{id: "L1", after: %{log: "is unreadable; treating it as 0"}}),
        v2(@t0, %{id: "L2", after: %{log: "something the client never said"}})
      ])

      assert {[%Result{check: "L1", class: :pass}, %Result{check: "L2", class: :fail} = l2], _} =
               Conformance.run(ctx.opts, %{s | build: build})

      assert l2.detail =~ "something the client never said"
    end

    test "an older batch absent is not testable, unfetchable not exercised, invalid a fail",
         ctx do
      t = %{@t0 | id: "P", transform: {ChainTest.TestTransform, %{needs: [:previous]}}}
      cases!(ctx.opts, [t])

      for {kind, class, code} <- [
            {:missing, :not_testable, 0},
            {:unavailable, :not_exercised, 1},
            {:invalid, :fail, 1}
          ] do
        snapshot = Map.put(ctx.snapshot, :previous, {kind, "batches/6.json: #{kind}"})
        {verdicts, _} = Conformance.run(ctx.opts, v2_steps(self(), snapshot))
        assert [%Result{check: "P", class: ^class, detail: detail}] = verdicts
        assert detail =~ "batches/6.json: #{kind}"
        assert Result.exit_code(verdicts) == code, inspect(kind)
        refute_received {:build, _}
      end
    end

    test "not testable here does not fail the run's exit code", ctx do
      t = %{@t0 | id: "T2", transform: {ChainTest.TestTransform, %{needs: [:old]}}}
      cases!(ctx.opts, [@t0, t])
      snapshot = Map.put(ctx.snapshot, :old, {:missing, "pruned"})
      {verdicts, _} = Conformance.run(ctx.opts, v2_steps(self(), snapshot))
      assert [%Result{class: :pass}, %Result{class: :not_testable}] = verdicts
      assert Result.exit_code(verdicts) == 0
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

  describe "every mirror of a case" do
    # A fake client that reads batch.json from the case mirror and, when
    # `follow`, follows its redirect to the second mirror.
    defp two_steps(test, snapshot, follow) do
      s = steps(test, snapshot)

      build = fn input ->
        {:ok, {{_, 302, _}, headers, _}} =
          :httpc.request(:get, {~c"#{input.source}/batch.json", []}, [autoredirect: false], [])

        location = to_string(:proplists.get_value(~c"location", headers))
        if follow, do: HTTP.get(location, 5_000)

        line = {"jason", "1.4.5", "miss", "batch unavailable"}

        {[%Result{step: :build, check: "compile", class: :pass}],
         %{report: Synthetic.report([line]), build_lib: "/nonexistent", fw_path: nil, sequence: 7}}
      end

      %{s | build: build}
    end

    @n1 %{
      id: "N1",
      description: "Redirect to another origin.",
      transform: {ChainTest.TestTransform, %{mirrors: 2}},
      client: %{default: :snapshot, deps: %{jason: {:miss, "batch unavailable"}}},
      harness: %{},
      after: %{second_mirror: :untouched}
    }

    test "second_mirror: :untouched passes when the client did not follow", ctx do
      cases!(ctx.opts, [@n1])

      assert {[%Result{class: :pass}], _} =
               Conformance.run(ctx.opts, two_steps(self(), ctx.snapshot, false))
    end

    test "second_mirror: :untouched fails when the client followed to the second mirror",
         ctx do
      cases!(ctx.opts, [@n1])

      assert {[%Result{class: :fail, detail: detail}], _} =
               Conformance.run(ctx.opts, two_steps(self(), ctx.snapshot, true))

      assert detail =~ "second_mirror"
      assert detail =~ "batch.json"
    end

    test "a transform error on the second mirror fails the case", ctx do
      c = %{@n1 | transform: {ChainTest.TestTransform, %{mirrors: 2, second_bad: true}}}
      cases!(ctx.opts, [%{c | after: %{second_mirror: :requested}}])

      assert {[%Result{class: :fail, detail: detail}], _} =
               Conformance.run(ctx.opts, two_steps(self(), ctx.snapshot, true))

      assert detail =~ "second mirror"
      assert detail =~ "transform error"
    end
  end

  describe "layer-1 runner support" do
    @sha String.duplicate("b", 64)

    # A fake build that also runs `touch.(home)` against the case home.
    defp touching(test, snapshot, touch) do
      s = steps(test, snapshot)

      %{
        s
        | build: fn input ->
            touch.(input.home)
            s.build.(input)
          end
      }
    end

    # Runs twice in one test: keep the snapshot between them.
    defp kept(ctx), do: %{ctx.opts | snapshot_dir: ctx.snapshot.dir}

    defp planting(files),
      do: {ChainTest.TestSetup, %{files: files}}

    test "cache: :untouched sees bytes changed in a planted cache file", ctx do
      c =
        Map.merge(@t0, %{
          setup: planting(%{"files/#{@sha}" => "planted"}),
          after: %{cache: :untouched}
        })

      cases!(ctx.opts, [c])
      same = touching(self(), ctx.snapshot, fn _home -> :ok end)
      assert {[%Result{class: :pass}], _} = Conformance.run(kept(ctx), same)

      rewrite = fn home -> File.write!(Path.join(home, "files/#{@sha}"), "other") end

      assert {[%Result{class: :fail, detail: detail}], _} =
               Conformance.run(kept(ctx), touching(self(), ctx.snapshot, rewrite))

      assert detail =~ "files/#{@sha} changed"
    end

    test "cache: :untouched sees a re-pointed symlink, without following it", ctx do
      c =
        Map.merge(@t0, %{
          setup: {ChainTest.Conformance.Setup.Cache, %{plant: :link_entries}},
          after: %{cache: :untouched}
        })

      cases!(ctx.opts, [c])

      repoint = fn home ->
        [link | _] = Path.wildcard(Path.join(home, "files/*"))
        File.rm!(link)
        File.ln_s!("/nonexistent/elsewhere", link)
      end

      snapshot = with_file(ctx.snapshot)

      assert {[%Result{class: :fail, detail: detail}], _} =
               Conformance.run(kept(ctx), touching(self(), snapshot, repoint))

      assert detail =~ "/nonexistent/elsewhere"
    end

    test "outside: :untouched sees a write into the planted tree", ctx do
      c =
        Map.merge(@t0, %{
          setup: {ChainTest.Conformance.Setup.Cache, %{plant: :link_dir}},
          after: %{outside: :untouched}
        })

      cases!(ctx.opts, [c])
      snapshot = with_file(ctx.snapshot)

      assert {[%Result{class: :pass}], _} =
               Conformance.run(kept(ctx), touching(self(), snapshot, fn _ -> :ok end))

      # The client writes through the linked cache dir.
      write = fn home -> File.write!(Path.join(home, "files/#{@sha}"), "x") end

      assert {[%Result{class: :fail, detail: detail}], _} =
               Conformance.run(kept(ctx), touching(self(), snapshot, write))

      assert detail =~ "after outside"
    end

    test "cache: :verified knows which planted entries an install used (C1)", ctx do
      build_lib = Path.join(ctx.tmp, "fixture/_build/rpi4_dev/lib")
      used = :crypto.hash(:sha256, "x") |> Base.encode16(case: :lower)
      s = steps(self(), ctx.snapshot)

      build = fn input ->
        Synthetic.dep(build_lib, :jason, %{"ebin/x.beam" => "x"}, :installed)
        s.build.(input)
      end

      # Planted corrupt under the name of a file jason installed: not
      # fetched again, so the case fails. Under an unused name: allowed.
      for {name, class} <- [{used, :fail}, {@sha, :pass}] do
        c =
          Map.merge(@t0, %{
            setup: planting(%{"files/#{name}" => "corrupt"}),
            after: %{cache: :verified}
          })

        cases!(ctx.opts, [c])

        assert {[%Result{class: ^class}], _} = Conformance.run(kept(ctx), %{s | build: build}),
               name
      end
    end

    test "runs: 2 builds twice: first cold, served unchanged, in its own home; then warm",
         ctx do
      cases!(ctx.opts, [Map.put(@t0, :runs, 2)])

      assert {[%Result{class: :pass}], _} =
               Conformance.run(kept(ctx), steps(self(), ctx.snapshot))

      assert_received {:build, first}
      assert_received {:build, second}
      refute Map.get(first, :keep_build, false)
      assert second.keep_build == true
      assert first.home != second.home
      refute File.exists?(first.home)
      assert first.client_config == nil
    end

    test "runs: 2 fails the case, unjudged, when the warm build does not install", ctx do
      cases!(ctx.opts, [Map.put(@t0, :runs, 2)])
      s = steps(self(), ctx.snapshot)

      build = fn input ->
        {rows, info} = s.build.(input)

        if Map.get(input, :keep_build),
          do: {rows, info},
          else: {[%Result{step: :build, check: "hit:jason", class: :fail, detail: "no"}], info}
      end

      assert {[%Result{class: :fail, detail: detail}], _} =
               Conformance.run(kept(ctx), %{s | build: build})

      assert detail =~ "warm build"
      assert detail =~ "hit:jason"
    end

    test "a transform's stream_max_ms reaches its mirror, and only its own", ctx do
      test = self()

      mirror = fn dir, opts ->
        send(test, {:mirror_opts, opts})
        ChainTest.Mirror.start(dir, opts)
      end

      c = %{@t0 | transform: {ChainTest.Mirror.Drip, %{paths: :batch, stream_max_ms: 1_000}}}
      cases!(ctx.opts, [c])
      s = Map.put(steps(self(), ctx.snapshot), :mirror, mirror)
      Conformance.run(kept(ctx), s)

      assert_received {:mirror_opts, reference}
      assert_received {:mirror_opts, case_opts}
      refute Keyword.has_key?(reference, :stream_max_ms)
      assert case_opts[:stream_max_ms] == 1_000
    end
  end

  describe "TLS and transport cases" do
    # A fake client over TLS: trusts `trust_ca` alone when the build was
    # given one, else the OS store, as the real build does; a refused
    # handshake reports every dep `batch unavailable`, the client's own
    # reason. A source outside loopback over http: the client is off.
    defp tls_steps(test, snapshot) do
      s = steps(test, snapshot)

      build = fn input ->
        send(test, {:build, input})
        source = (input.client_config || %{})[:source] || input.source

        report =
          if String.starts_with?(source, "https://"),
            do: tls_report(source, input.trust_ca),
            else: %{}

        class = if report == %{} or hd(report["lines"])["status"] != "hit", do: :fail, else: :pass

        {[
           %Result{step: :build, check: "compile", class: :pass},
           %Result{step: :build, check: "hit:jason", class: class}
         ], %{report: report, build_lib: "/nonexistent", fw_path: nil, sequence: 7}}
      end

      %{s | build: build}
    end

    defp tls_report(source, trust_ca) do
      cacerts = if trust_ca, do: [trust_ca], else: :public_key.cacerts_get()

      line =
        case tls_get(source <> "/batch.json", cacerts) do
          :ok -> {"jason", "1.4.5", "hit", "0.3 MB"}
          :error -> {"jason", "1.4.5", "fail", "batch unavailable"}
        end

      if elem(line, 2) == "hit", do: :ok = tls_get(source <> "/v2/manifests/jason.json", cacerts)
      Synthetic.report([line])
    end

    defp tls_get(url, cacerts) do
      opts = [
        timeout: 5_000,
        ssl: [
          log_level: :none,
          verify: :verify_peer,
          cacerts: cacerts,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]

      case :httpc.request(:get, {to_charlist(url), []}, opts, []) do
        {:ok, {{_, 200, _}, _, _}} -> :ok
        _ -> :error
      end
    end

    @no_batch %{
      client: %{default: {:fail, "batch unavailable"}, deps: %{}},
      harness: %{"build/hit:jason" => :fail},
      after: %{installed: :none}
    }

    test "a tls case gets an https mirror; trust_ca hands its CA, and only then, to the build",
         ctx do
      control = %{
        @t0
        | id: "TLS-T0",
          transform: {ChainTest.Mirror.Identity, %{tls: :ip, trust_ca: true}}
      }

      n3 =
        Map.merge(@no_batch, %{
          id: "N3",
          description: "Untrusted.",
          transform: {ChainTest.Mirror.Identity, %{tls: :ip}},
          after: %{installed: :none, tls: {:rejected, :unknown_ca}}
        })

      cases!(ctx.opts, [control, n3])

      assert {[%Result{check: "TLS-T0", class: :pass}, %Result{check: "N3", class: :pass}], _} =
               Conformance.run(ctx.opts, tls_steps(self(), ctx.snapshot))

      assert_received {:build, trusted}
      assert_received {:build, untrusted}
      assert String.starts_with?(trusted.source, "https://127.0.0.1:")
      assert String.starts_with?(untrusted.source, "https://127.0.0.1:")
      assert is_binary(trusted.trust_ca)
      assert untrusted.trust_ca == nil
      assert trusted.http_proxy == nil
    end

    test "every tls case gets new certificates", ctx do
      a = %{@t0 | id: "A", transform: {ChainTest.Mirror.Identity, %{tls: :ip, trust_ca: true}}}
      cases!(ctx.opts, [a, %{a | id: "B"}])
      Conformance.run(ctx.opts, tls_steps(self(), ctx.snapshot))
      assert_received {:build, %{trust_ca: ca_a}}
      assert_received {:build, %{trust_ca: ca_b}}
      refute ca_a == ca_b
    end

    test "proxy: :mirror points the build's HTTP_PROXY at the case mirror", ctx do
      n2 = %{
        id: "N2",
        description: "Off.",
        transform: {ChainTest.Mirror.Identity, %{}},
        proxy: :mirror,
        client_config: %{source: "http://chain-n2.invalid"},
        client: %{default: :none, deps: %{}},
        harness: %{"build/hit:jason" => :fail},
        after: %{proxied: :none, installed: :none}
      }

      cases!(ctx.opts, [n2, @t0])

      assert {[%Result{check: "N2", class: :pass}, %Result{check: "T0"}], _} =
               Conformance.run(ctx.opts, tls_steps(self(), ctx.snapshot))

      assert_received {:build, proxied}
      assert_received {:build, plain}
      assert proxied.http_proxy == proxied.source
      assert String.starts_with?(proxied.http_proxy, "http://127.0.0.1:")
      assert plain.http_proxy == nil
      assert plain.trust_ca == nil
    end
  end

  describe "the summary's per-layer counts" do
    test "meta.layers counts each layer's verdicts by class", ctx do
      untestable = %{@t0 | id: "U", transform: {ChainTest.TestTransform, %{needs: [:old]}}}
      failing = %{@status | id: "F", client: %{default: :snapshot, deps: %{jason: :hit}}}
      cases!(ctx.opts, [@t0, untestable, failing])
      snapshot = Map.put(ctx.snapshot, :old, {:missing, "pruned"})

      {_verdicts, meta} = Conformance.run(ctx.opts, steps(self(), snapshot))

      assert meta.layers == [
               %{layer: "layer 1", cases: 3, pass: 1, fail: 1, not_testable: 1}
             ]
    end
  end

  describe "--policy" do
    test "parses alone, with --source and --report-dir; refuses case options" do
      opts = Conformance.parse!(["--policy", "--source", "https://p.invalid/api/"])
      assert opts.policy
      assert opts.source == "https://p.invalid/api"
      refute Conformance.parse!([]).policy

      for extra <- [["--only", "T0"], ["--cases", "x.exs"], ["--snapshot-dir", "d"]] do
        assert_raise Mix.Error, fn -> Conformance.parse!(["--policy" | extra]) end
      end
    end

    test "runs only the policy check, writes its report, and takes no snapshot", ctx do
      opts = Map.put(ctx.opts, :policy, true)
      cases!(ctx.opts, [@t0])
      test = self()

      row = %Result{step: :policy, check: "R20", class: :pass, detail: "ok"}

      s =
        Map.put(steps(test, ctx.snapshot), :policy, fn input ->
          send(test, {:policy, input})
          row
        end)

      assert {[^row], meta} = Conformance.run(opts, s)
      assert_received {:policy, %{source: "https://portal.invalid"}}
      refute_received {:snapshot, _}
      refute_received {:build, _}
      assert meta.batch_sequence_step1 == nil
    end
  end

  # The snapshot with one file of jason's build stored.
  defp with_file(snapshot) do
    File.mkdir_p!(Path.join(snapshot.dir, "files"))
    File.write!(Path.join(snapshot.dir, "files/" <> String.duplicate("b", 64)), "bytes")
    put_in(snapshot.deps["jason"][:file_shas], [String.duplicate("b", 64)])
  end
end
