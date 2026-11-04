# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.CaseTest do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Case
  alias ChainTest.{Result, Synthetic}

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

  defp write(tmp, cases) do
    path = Path.join(tmp, "cases.exs")
    File.write!(path, inspect(cases, limit: :infinity, printable_limit: :infinity))
    path
  end

  defp snap(builds),
    do: %{
      deps:
        Map.new(builds, fn {n, b} -> {n, %{builds: b, manifest: "v2/manifests/#{n}.json"}} end)
    }

  # The mirror log of a client that read the batch and the manifests of `deps`.
  defp served(deps) do
    [get("batch.json")] ++ Enum.map(deps, &get("v2/manifests/#{&1}.json"))
  end

  defp get(path, status \\ 200, mutated \\ false),
    do: %{method: "GET", path: path, status: status, mutated: mutated}

  defp change(c, key, :delete), do: Map.delete(c, key)
  defp change(c, key, value), do: Map.put(c, key, value)

  defp row(step, check, class), do: %Result{step: step, check: check, class: class}

  describe "load/1" do
    test "loads a valid file", %{tmp_dir: tmp} do
      assert {:ok, [@t0, @status]} = Case.load(write(tmp, [@t0, @status]))
    end

    test "the repository's case file is valid" do
      path = Path.join(ChainTest.CLI.root(), "conformance/cases.exs")
      assert {:ok, [%{id: "T0"} | _]} = Case.load(path)
    end

    test "the repository's case file has the layer-1 batch and freshness cases" do
      {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
      ids = cases |> Enum.flat_map(&String.split(&1.id, ".")) |> MapSet.new()

      for id <- ~w(T0 R8 R0 T1 T3-removed T4 R3 T5 T6 T9 R1 R6 T10 R2 R4-previous
                   R4-old R5 R7 R12 R13 R19) do
        assert id in ids, "no case for #{id}"
      end
    end

    test "the repository's clock cases are ages from the batch's issue; R13 is stale" do
      {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
      by_id = Map.new(cases, &{&1.id, &1})

      for {id, age} <- [{"R7", 25 * 3600}, {"R8", 23 * 3600}, {"R13", 365 * 86_400}] do
        assert by_id[id].client_config == %{clock_offset_seconds: {:age, age}}, id
      end

      assert by_id["R13"].client.default == {:fail, "batch stale"}
      assert by_id["R12"].client.default == {:fail, "clock is before"}
      assert by_id["R2.R6.T10"].client.default == {:fail, "batch stale"}

      assert by_id["R4-previous"].after.log ==
               ["precompiled: sequence state ", "is unreadable; treating it as 0"]

      # A stale batch is refused before the state is read: nothing to log.
      refute Map.has_key?(by_id["R4-old"].after, :log)

      # T3's duplicated signature needs a threshold-2 root: a test-key case.
      assert by_id["T3-duplicated"].client_config.root == {:test_root, :threshold_2}
    end

    test "every refusal in the repository's case file leaves state, _build and cache alone (R14)" do
      {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
      # Batch-level: every dep fails for the batch's (or the clock's) sake.
      # A batch that never arrived (`batch unavailable`) is no refusal
      # reason, but leaves the same post-conditions.
      refusals =
        Enum.filter(cases, fn c ->
          match?(%{client: %{default: {:fail, "batch" <> _}}}, c) or
            match?(%{client: %{default: {:fail, "clock" <> _}}}, c)
        end)

      assert length(refusals) >= 11

      for c <- refusals do
        assert %{state_sequence: :unchanged, installed: :none, cache: :untouched} =
                 Map.get(c, :after),
               c.id

        {:fail, reason} = c.client.default

        assert String.starts_with?(reason, "batch unavailable: ") or
                 ChainTest.Build.refusal?(reason),
               "#{c.id}: #{reason} is no client refusal"
      end
    end

    # {name, key, value}: the case with `key` set to `value` (`:delete` removes it).
    for {name, key, value} <- [
          {"an unknown key", :expected, :pass},
          {"a missing key", :harness, :delete},
          {"a class that does not exist", :harness, %{"build/hit:jason" => :ok}},
          {"a harness key without a step", :harness, %{"hit:jason" => :fail}},
          {"a transform that is not one", :transform, {String, %{}}},
          {"a bad client expectation", :client, %{default: :maybe, deps: %{}}},
          {"a bad id", :id, "t 0"}
        ] do
      test "refuses #{name}", %{tmp_dir: tmp} do
        bad = change(@t0, unquote(key), unquote(Macro.escape(value)))
        assert {:error, why} = Case.load(write(tmp, [bad]))
        assert why =~ "T0" or why =~ "t 0"
      end
    end

    for {name, args} <- [
          {"no paths", %{paths: [], status: 500}},
          {"a status that is not one", %{paths: ["batch.json"], status: 99_000}},
          {"a path that is not a string", %{paths: [:batch], status: 500}},
          {"an unknown arg", %{paths: ["batch.json"], status: 500, extra: 1}}
        ] do
      test "refuses Status args with #{name}", %{tmp_dir: tmp} do
        bad = %{@status | transform: {ChainTest.Mirror.Status, unquote(Macro.escape(args))}}
        assert {:error, why} = Case.load(write(tmp, [bad]))
        assert why =~ "N5-manifest-500"
      end
    end

    test "refuses a case file that throws or exits", %{tmp_dir: tmp} do
      for {body, what} <- [{"throw(:nope)", "nope"}, {"exit(:gone)", "gone"}] do
        path = Path.join(tmp, "bad.exs")
        File.write!(path, body)
        assert {:error, why} = Case.load(path)
        assert why =~ what
      end
    end

    test "refuses a duplicate id", %{tmp_dir: tmp} do
      assert {:error, why} = Case.load(write(tmp, [@t0, @t0]))
      assert why =~ "duplicate"
    end

    test "refuses a file that is not a list of maps", %{tmp_dir: tmp} do
      assert {:error, _} = Case.load(write(tmp, %{}))
      assert {:error, _} = Case.load(Path.join(tmp, "absent.exs"))
    end
  end

  describe "judge/2" do
    test ":snapshot expects a hit only where the snapshot holds a build" do
      report = Synthetic.report([{"jason", "1.4.5", "hit", ""}, {"ash", "3.37.2", "miss", "x"}])

      verdict =
        Case.judge(@t0, %{
          rows: [row(:build, "hit:jason", :pass), row(:build, "hit:ash", :miss)],
          report: report,
          requests: served(["jason", "ash"]),
          snapshot: snap(%{"jason" => 1, "ash" => 0}),
          hits: [:jason, :ash]
        })

      assert %Result{step: :conformance, check: "T0", class: :pass} = verdict
    end

    test "a dep the snapshot holds a build of is judged even outside the expected hits" do
      report =
        Synthetic.report([{"jason", "1.4.5", "hit", ""}, {"decimal", "2.3.0", "miss", "x"}])

      input = %{
        rows: [row(:build, "hit:jason", :pass)],
        report: report,
        requests: served(["jason"]),
        snapshot: snap(%{"jason" => 1, "decimal" => 1, "telemetry" => 0}),
        hits: [:jason]
      }

      assert %Result{class: :fail, detail: detail} = Case.judge(@t0, input)
      assert detail =~ "client decimal: expected hit, got miss"
      refute detail =~ "telemetry"

      # Reported a hit, and served, it passes.
      report =
        Synthetic.report([{"jason", "1.4.5", "hit", ""}, {"decimal", "2.3.0", "hit", ""}])

      assert %Result{class: :pass} =
               Case.judge(@t0, %{
                 input
                 | report: report,
                   requests: served(["jason", "decimal"])
               })
    end

    test "a held dep the client treats as Nerves tooling is not judged" do
      report = Synthetic.report([{"jason", "1.4.5", "hit", ""}])

      input = %{
        rows: [row(:build, "hit:jason", :pass)],
        report: report,
        requests: served(["jason"]),
        snapshot: snap(%{"jason" => 1, "tablet" => 1}),
        hits: [:jason],
        tooling: ["tablet"]
      }

      assert %Result{class: :pass} = Case.judge(@t0, input)

      # Without it, a held dep with no report line is one the client skipped.
      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{input | tooling: []})

      assert detail =~ "client tablet: expected hit, got no report line"
    end

    test "a client verdict other than expected fails and names the dep" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "no manifest"}])

      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{
                 rows: [],
                 report: report,
                 requests: served(["jason", "ash"]),
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "jason"
    end

    test "a named row with its expected class passes, a failing unnamed row fails" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "manifest unavailable: Status 500"}])
      requests = [get("batch.json"), get("v2/manifests/jason.json", 500, true)]

      input = %{
        rows: [row(:build, "hit:jason", :fail), row(:compiled, "compiled_here", :pass)],
        report: report,
        requests: requests,
        snapshot: snap(%{"jason" => 1}),
        hits: [:jason]
      }

      assert %Result{class: :pass} = Case.judge(@status, input)

      broken = %{input | rows: input.rows ++ [row(:integrity, "integrity:ash", :disagreement)]}
      assert %Result{class: :fail, detail: detail} = Case.judge(@status, broken)
      assert detail =~ "integrity/integrity:ash"

      missing = %{input | rows: [row(:compiled, "compiled_here", :pass)]}
      assert %Result{class: :fail, detail: detail} = Case.judge(@status, missing)
      assert detail =~ "build/hit:jason"
    end

    test "a hit the snapshot holds no build for fails, even on an unexpected dep" do
      report =
        Synthetic.report([
          {"jason", "1.4.5", "hit", ""},
          {"nerves_pack", "0.7.2", "hit", "0.1 MB"}
        ])

      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{
                 rows: [row(:build, "hit:jason", :pass)],
                 report: report,
                 requests: served(["jason", "nerves_pack"]),
                 snapshot: snap(%{"jason" => 1, "nerves_pack" => 0}),
                 hits: [:jason]
               })

      assert detail =~ "nerves_pack"
      assert detail =~ "snapshot"

      # Not in the snapshot at all.
      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{
                 rows: [row(:build, "hit:jason", :pass)],
                 report:
                   Synthetic.report([
                     {"jason", "1.4.5", "hit", ""},
                     {"toolshed", "0.4.0", "hit", ""}
                   ]),
                 requests: served(["jason", "ash"]),
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "toolshed"
    end

    test ":snapshot with no build in the snapshot expects a miss; a hit fails" do
      report = Synthetic.report([{"ash", "3.37.2", "hit", ""}])

      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{
                 rows: [row(:build, "hit:ash", :pass)],
                 report: report,
                 requests: served(["jason", "ash"]),
                 snapshot: snap(%{"ash" => 0}),
                 hits: [:ash]
               })

      assert detail =~ "ash"
    end

    test "a hit where the case expects a miss or a refusal fails" do
      refusal = %{@status | client: %{default: :snapshot, deps: %{jason: {:miss, "batch stale"}}}}
      report = Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])
      requests = [get("batch.json"), get("v2/manifests/jason.json", 500, true)]

      input = %{
        rows: [row(:build, "hit:jason", :fail)],
        report: report,
        requests: requests,
        snapshot: snap(%{"jason" => 1}),
        hits: [:jason]
      }

      assert %Result{class: :fail, detail: d1} = Case.judge(@status, input)
      assert d1 =~ "jason"
      assert %Result{class: :fail, detail: d2} = Case.judge(refusal, input)
      assert d2 =~ "jason"
    end

    test "an expectation for a dep outside the expected hits is judged too" do
      c = %{@t0 | client: %{default: :snapshot, deps: %{plug_crypto: :miss}}}

      report =
        Synthetic.report([{"jason", "1.4.5", "hit", ""}, {"plug_crypto", "2.1.0", "hit", ""}])

      assert %Result{class: :fail, detail: detail} =
               Case.judge(c, %{
                 rows: [row(:build, "hit:jason", :pass)],
                 report: report,
                 requests: served(["jason", "plug_crypto"]),
                 snapshot: snap(%{"jason" => 1, "plug_crypto" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "plug_crypto"
    end

    test "an identity case without the client's use of the mirror is not exercised" do
      report = Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])

      input = %{
        rows: [row(:build, "hit:jason", :pass)],
        report: report,
        requests: [],
        snapshot: snap(%{"jason" => 1}),
        hits: [:jason]
      }

      assert %Result{class: :not_exercised, detail: detail} = Case.judge(@t0, input)
      assert detail =~ "batch.json"

      # The batch, but not the manifest of a reported hit.
      assert %Result{class: :not_exercised, detail: detail} =
               Case.judge(@t0, %{input | requests: [get("batch.json")]})

      assert detail =~ "v2/manifests/jason.json"

      assert %Result{class: :pass} = Case.judge(@t0, %{input | requests: served(["jason"])})
    end

    test "a hit whose manifest the mirror did not answer 200 is not from the mirror" do
      report = Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])

      input = %{
        rows: [row(:build, "hit:jason", :pass)],
        report: report,
        requests: [get("batch.json"), get("v2/manifests/jason.json", 404)],
        snapshot: snap(%{"jason" => 1}),
        hits: [:jason]
      }

      assert %Result{class: :not_exercised, detail: detail} = Case.judge(@t0, input)
      assert detail =~ "v2/manifests/jason.json"

      # A 200 for it later in the log is the client's use of the mirror.
      requests = input.requests ++ [get("v2/manifests/jason.json")]
      assert %Result{class: :pass} = Case.judge(@t0, %{input | requests: requests})
    end

    test "a hit on a manifest the case's own transform changed counts as served" do
      report = Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])

      assert %Result{detail: detail} =
               Case.judge(@status, %{
                 rows: [row(:build, "hit:jason", :fail)],
                 report: report,
                 requests: [get("batch.json"), get("v2/manifests/jason.json", 500, true)],
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })

      refute detail =~ "mirror:"
    end

    test "a transform case without the client's use of the mirror fails" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "manifest unavailable: Status 500"}])

      # The mutated manifest was served, but the batch never came from this mirror.
      assert %Result{class: :fail, detail: detail} =
               Case.judge(@status, %{
                 rows: [row(:build, "hit:jason", :fail)],
                 report: report,
                 requests: [get("v2/manifests/jason.json", 500, true)],
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "batch.json"
    end

    test "a rerun row is a difference: the snapshot never moves" do
      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{
                 rows: [row(:build, "hit:jason", :pass), row(:build, "sequence", :rerun)],
                 report: Synthetic.report([{"jason", "1.4.5", "hit", ""}]),
                 requests: served(["jason"]),
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "build/sequence"
    end

    test "a transform the mirror never applied leaves the case not exercised" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "manifest unavailable: Status 500"}])
      requests = [%{method: "GET", path: "batch.json", status: 200, mutated: false}]

      assert %Result{class: :not_exercised} =
               Case.judge(@status, %{
                 rows: [row(:build, "hit:jason", :fail)],
                 report: report,
                 requests: requests,
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })
    end
  end

  describe "optional keys" do
    @v2 %{
      id: "R3",
      description: "State N, mirror serves N-1.",
      transform: {ChainTest.Mirror.Identity, %{}},
      client: %{default: :snapshot, deps: %{}},
      harness: %{},
      setup: {ChainTest.TestSetup, %{state: "7"}},
      client_config: %{clock_offset_seconds: 3600, root: "/r.json", source: "http://127.0.0.1:1"},
      after: %{state_sequence: :unchanged, installed: :none, cache: :untouched}
    }

    test "a case with setup, client_config and after loads; the old cases stay valid",
         %{tmp_dir: tmp} do
      assert {:ok, [@t0, @v2]} = Case.load(write(tmp, [@t0, @v2]))

      for post <- [%{state_sequence: 9}, %{state_sequence: :absent}, %{state_sequence: :snapshot}] do
        assert {:ok, _} = Case.load(write(tmp, [%{@v2 | after: post}]))
      end

      assert {:ok, _} = Case.load(write(tmp, [%{@v2 | after: %{installed: :snapshot}}]))
      assert {:ok, _} = Case.load(write(tmp, [%{@v2 | client_config: %{}}]))

      assert {:ok, _} =
               Case.load(
                 write(tmp, [%{@v2 | client_config: %{clock_offset_seconds: {:age, 3600}}}])
               )

      assert {:ok, _} = Case.load(write(tmp, [%{@v2 | after: %{state_sequence: :previous}}]))
      assert {:ok, _} = Case.load(write(tmp, [%{@v2 | after: %{other_states: :unchanged}}]))
      assert {:ok, _} = Case.load(write(tmp, [%{@v2 | after: %{log: "treating it as 0"}}]))

      for env <- [
            %{"ELIXIR_PRECOMPILED_ROOT" => {:home, "attacker/root.json"}},
            %{"NERVES_PRECOMPILED_ROOT" => "/abs/root.json"}
          ] do
        assert {:ok, _} = Case.load(write(tmp, [Map.put(@v2, :client_env, env)]))
      end
    end

    for {name, key, value} <- [
          {"a setup that is not one", :setup, {String, %{}}},
          {"setup args the module refuses", :setup, {ChainTest.TestSetup, %{other: 1}}},
          {"setup args with the reserved :case", :setup, {ChainTest.TestSetup, %{case: 1}}},
          {"a setup needing an unknown batch", :setup, {ChainTest.TestSetup, %{needs: [:x]}}},
          {"an unknown client_config key", :client_config, %{home: "/h"}},
          {"a client_config value of the wrong type", :client_config,
           %{clock_offset_seconds: "1"}},
          {"a clock age that is not an integer", :client_config,
           %{clock_offset_seconds: {:age, 1.5}}},
          {"a client_config that is not a map", :client_config, [source: "x"]},
          {"a relative client_config root", :client_config, %{root: "priv/root.json"}},
          {"an unknown after key", :after, %{installed: :none, files: :none}},
          {"a bad state_sequence", :after, %{state_sequence: "7"}},
          {"a bad installed", :after, %{installed: :all}},
          {"a bad cache", :after, %{cache: :empty}},
          {"an empty after", :after, %{}},
          {"a bad other_states", :after, %{other_states: :gone}},
          {"an empty log", :after, %{log: ""}},
          {"a log that is not a string", :after, %{log: :warned}},
          {"an empty log list", :after, %{log: []}},
          {"a log list with an empty string", :after, %{log: ["a", ""]}},
          {"a client_env name the harness does not allow", :client_env,
           %{"ELIXIR_PRECOMPILED_HOME" => "/h"}},
          {"a client_env value outside the home", :client_env,
           %{"ELIXIR_PRECOMPILED_ROOT" => {:home, "../root.json"}}},
          {"a relative client_env path", :client_env,
           %{"ELIXIR_PRECOMPILED_ROOT" => "root.json"}},
          {"an empty client_env", :client_env, %{}}
        ] do
      test "refuses #{name}", %{tmp_dir: tmp} do
        bad = Map.put(@v2, unquote(key), unquote(Macro.escape(value)))
        assert {:error, why} = Case.load(write(tmp, [bad]))
        assert why =~ "R3"
        assert why =~ unquote(to_string(key))
      end
    end
  end

  describe "judge/2 post-conditions" do
    defp obs(states, cache \\ [], own \\ {:ok, "abc/state"}),
      do: %{states: states, cache: Map.new(cache, &{&1, {:file, "x"}}), own: own}

    defp judged(post, observed, snap_extra \\ %{}) do
      c = Map.put(@t0, :after, post)
      report = Synthetic.report([{"jason", "1.4.5", "hit", ""}])

      Case.judge(c, %{
        rows: [row(:build, "hit:jason", :pass)],
        report: report,
        requests: served(["jason"]),
        snapshot: Map.merge(snap(%{"jason" => 1, "ash" => 0}), Map.put(snap_extra, :sequence, 7)),
        hits: [:jason],
        observed: observed
      })
    end

    test "state_sequence: an integer or :snapshot is the own state file's number" do
      seen = %{before: obs(%{}), after: obs(%{"abc/state" => "7"}), installed: ["jason"]}
      assert %Result{class: :pass} = judged(%{state_sequence: 7}, seen)
      assert %Result{class: :pass} = judged(%{state_sequence: :snapshot}, seen)

      assert %Result{class: :fail, detail: detail} = judged(%{state_sequence: 8}, seen)
      assert detail =~ "state_sequence"

      other = %{seen | after: obs(%{"zzz/state" => "7"})}
      assert %Result{class: :fail, detail: detail} = judged(%{state_sequence: 7}, other)
      assert detail =~ "abc/state"
    end

    test "state_sequence: :unchanged means every state file in the home is as setup left it" do
      same = %{before: obs(%{"abc/state" => "9"}), after: obs(%{"abc/state" => "9"})}
      assert %Result{class: :pass} = judged(%{state_sequence: :unchanged}, same)

      for post <- [%{"abc/state" => "7"}, %{}, %{"abc/state" => "9", "zzz/state" => "7"}] do
        moved = %{same | after: obs(post)}
        assert %Result{class: :fail, detail: d} = judged(%{state_sequence: :unchanged}, moved)
        assert d =~ "state_sequence"
      end
    end

    test "state_sequence: :previous is the snapshot's previous batch's sequence" do
      seen = %{before: obs(%{}), after: obs(%{"abc/state" => "6"}), installed: ["jason"]}
      previous = %{previous: {:ok, %{sequence: 6}}}
      assert %Result{class: :pass} = judged(%{state_sequence: :previous}, seen, previous)

      assert %Result{class: :fail, detail: detail} =
               judged(
                 %{state_sequence: :previous},
                 %{seen | after: obs(%{"abc/state" => "7"})},
                 previous
               )

      assert detail =~ "hold 6"

      assert %Result{class: :fail, detail: detail} =
               judged(%{state_sequence: :previous}, seen, %{previous: {:missing, "pruned"}})

      assert detail =~ "pruned"
    end

    test "other_states: :unchanged allows the own state to move, no other" do
      before = obs(%{"zzz/state" => "9"})
      own_moved = %{before: before, after: obs(%{"zzz/state" => "9", "abc/state" => "6"})}
      assert %Result{class: :pass} = judged(%{other_states: :unchanged}, own_moved)

      for post <- [%{"zzz/state" => "6"}, %{}, %{"zzz/state" => "9", "yyy/state" => "1"}] do
        moved = %{before: before, after: obs(post)}
        assert %Result{class: :fail, detail: d} = judged(%{other_states: :unchanged}, moved)
        assert d =~ "other_states"
      end

      unnamed = %{own_moved | after: obs(%{"zzz/state" => "9"}, [], {:error, "no root"})}
      assert %Result{class: :fail, detail: d} = judged(%{other_states: :unchanged}, unnamed)
      assert d =~ "no root"
    end

    test "log: the build's output must contain the substring" do
      seen = %{
        before: obs(%{}),
        after: obs(%{}),
        installed: ["jason"],
        log: "a\nx is unreadable; treating it as 0\n"
      }

      assert %Result{class: :pass} = judged(%{log: "treating it as 0"}, seen)

      assert %Result{class: :fail, detail: detail} = judged(%{log: "never said"}, seen)
      assert detail =~ "after log"
      assert detail =~ "never said"

      assert %Result{class: :fail} = judged(%{log: "treating it as 0"}, Map.delete(seen, :log))

      # A list: every string must be in the output.
      assert %Result{class: :pass} = judged(%{log: ["x is", "as 0"]}, seen)

      assert %Result{class: :fail, detail: detail} =
               judged(%{log: ["precompiled: sequence state ", "as 0"]}, seen)

      assert detail =~ "precompiled: sequence state"
    end

    test "state_sequence: :absent means no own state file" do
      assert %Result{class: :pass} =
               judged(%{state_sequence: :absent}, %{
                 before: obs(%{}),
                 after: obs(%{"zzz/state" => "1"})
               })

      assert %Result{class: :fail} =
               judged(%{state_sequence: :absent}, %{
                 before: obs(%{}),
                 after: obs(%{"abc/state" => "1"})
               })
    end

    test "a state dir the harness cannot name fails" do
      seen = %{before: obs(%{}), after: obs(%{}, [], {:error, "no root"})}
      assert %Result{class: :fail, detail: detail} = judged(%{state_sequence: :absent}, seen)
      assert detail =~ "no root"
    end

    test "installed: :none and :snapshot" do
      none = %{before: obs(%{}), after: obs(%{}), installed: []}
      assert %Result{class: :pass} = judged(%{installed: :none}, none)

      some = %{none | installed: ["jason"]}
      assert %Result{class: :fail, detail: detail} = judged(%{installed: :none}, some)
      assert detail =~ "jason"

      # The snapshot holds a build of jason only.
      assert %Result{class: :pass} = judged(%{installed: :snapshot}, some)
      assert %Result{class: :fail} = judged(%{installed: :snapshot}, none)

      assert %Result{class: :fail} =
               judged(%{installed: :snapshot}, %{none | installed: ["jason", "ash"]})
    end

    test "cache: :untouched allows no entry setup did not write" do
      before = obs(%{}, ["files/a"])

      assert %Result{class: :pass} =
               judged(%{cache: :untouched}, %{before: before, after: before})

      grown = %{before: before, after: obs(%{}, ["files/a", "files/b"])}
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :untouched}, grown)
      assert detail =~ "files/b"
    end

    test "post-conditions nobody observed fail" do
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :untouched}, nil)
      assert detail =~ "after"
    end
  end

  describe "judge/2 transform errors" do
    test "a mirror log with a transform_error fails the case, naming it" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "manifest unavailable: Status 500"}])

      requests = [
        get("batch.json"),
        Map.put(
          get("v2/manifests/jason.json", 500, true),
          :transform_error,
          "transform returned :x"
        )
      ]

      for c <- [@status, @t0] do
        assert %Result{class: :fail, detail: detail} =
                 Case.judge(c, %{
                   rows: [row(:build, "hit:jason", :fail)],
                   report: report,
                   requests: requests,
                   snapshot: snap(%{"jason" => 1}),
                   hits: [:jason]
                 })

        assert detail =~ "transform returned :x"
        assert detail =~ "v2/manifests/jason.json"
      end
    end
  end

  describe "judge/2 with a second mirror" do
    @two %{@status | id: "N1", transform: {ChainTest.TestTransform, %{mirrors: 2}}}

    defp judge_two(c, report, requests, second) do
      Case.judge(c, %{
        rows: [row(:build, "hit:jason", :fail)],
        report: report,
        requests: requests,
        second_requests: second,
        snapshot: snap(%{"jason" => 1}),
        hits: [:jason],
        observed: %{before: obs(%{}), after: obs(%{}), installed: []}
      })
    end

    @miss Synthetic.report([{"jason", "1.4.5", "miss", "manifest unavailable: Status 500"}])

    test "a transform_error on the second mirror fails the case, naming it" do
      second = [Map.put(get("batch.json", 500, true), :transform_error, "transform returned :y")]
      requests = [get("batch.json", 302, true)]

      assert %Result{class: :fail, detail: detail} = judge_two(@two, @miss, requests, second)
      assert detail =~ "second mirror"
      assert detail =~ "transform returned :y"
    end

    test "after second_mirror: :requested or :untouched reads the second mirror's log" do
      requests = [get("batch.json", 302, true), get("v2/manifests/jason.json", 500, true)]
      asked = [get("batch.json")]

      requested = Map.put(@two, :after, %{second_mirror: :requested})
      untouched = Map.put(@two, :after, %{second_mirror: :untouched})

      assert %Result{class: :pass} = judge_two(requested, @miss, requests, asked)
      assert %Result{class: :fail, detail: d} = judge_two(requested, @miss, requests, [])
      assert d =~ "second_mirror"
      assert %Result{class: :pass} = judge_two(untouched, @miss, requests, [])
      assert %Result{class: :fail, detail: d} = judge_two(untouched, @miss, requests, asked)
      assert d =~ "batch.json"
    end

    test "second_mirror is refused at load on a one-mirror case", %{tmp_dir: tmp} do
      assert {:ok, _} =
               Case.load(write(tmp, [Map.put(@two, :after, %{second_mirror: :untouched})]))

      for bad <- [
            Map.put(@status, :after, %{second_mirror: :untouched}),
            Map.put(@two, :after, %{second_mirror: :maybe})
          ] do
        assert {:error, why} = Case.load(write(tmp, [bad]))
        assert why =~ "second_mirror"
      end
    end
  end
end
