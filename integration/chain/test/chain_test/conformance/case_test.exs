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

  defp snap(builds), do: %{deps: Map.new(builds, fn {n, b} -> {n, %{builds: b}} end)}

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
          requests: [],
          snapshot: snap(%{"jason" => 1, "ash" => 0}),
          hits: [:jason, :ash]
        })

      assert %Result{step: :conformance, check: "T0", class: :pass} = verdict
    end

    test "a client verdict other than expected fails and names the dep" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "no manifest"}])

      assert %Result{class: :fail, detail: detail} =
               Case.judge(@t0, %{
                 rows: [],
                 report: report,
                 requests: [],
                 snapshot: snap(%{"jason" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "jason"
    end

    test "a named row with its expected class passes, a failing unnamed row fails" do
      report = Synthetic.report([{"jason", "1.4.5", "miss", "manifest unavailable: Status 500"}])
      requests = [%{method: "GET", path: "v2/manifests/jason.json", status: 500, mutated: true}]

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
                 requests: [],
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
                 requests: [],
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
                 requests: [],
                 snapshot: snap(%{"ash" => 0}),
                 hits: [:ash]
               })

      assert detail =~ "ash"
    end

    test "a hit where the case expects a miss or a refusal fails" do
      refusal = %{@status | client: %{default: :snapshot, deps: %{jason: {:miss, "batch stale"}}}}
      report = Synthetic.report([{"jason", "1.4.5", "hit", "0.3 MB"}])
      requests = [%{method: "GET", path: "v2/manifests/jason.json", status: 500, mutated: true}]

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
                 requests: [],
                 snapshot: snap(%{"jason" => 1, "plug_crypto" => 1}),
                 hits: [:jason]
               })

      assert detail =~ "plug_crypto"
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
end
