# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.CaseLayer2Test do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Case
  alias ChainTest.{Result, Synthetic}

  @moduletag :tmp_dir

  @t0 %{
    id: "T0",
    description: "Passthrough.",
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

  @t2 %{
    id: "T2",
    description: "Signed outside the batch role.",
    transform: {ChainTest.Mirror.TestBatch, %{signers: [:outside]}},
    client: %{default: {:fail, "batch signature invalid"}, deps: %{}},
    harness: %{},
    client_config: %{root: {:test_root, :v1}}
  }

  defp write(tmp, cases) do
    path = Path.join(tmp, "cases.exs")
    File.write!(path, inspect(cases, limit: :infinity, printable_limit: :infinity))
    path
  end

  defp snap(),
    do: %{sequence: 7, deps: %{"jason" => %{builds: 1, manifest: "v2/manifests/jason.json"}}}

  defp get(path), do: %{method: "GET", path: path, status: 200, mutated: false}

  defp view(roots \\ %{}),
    do: %{states: %{}, cache: %{}, outside: %{}, own: {:ok, "abc/state"}, root_versions: roots}

  defp judged(c, opts) do
    Case.judge(c, %{
      rows: [%Result{step: :build, check: "hit:jason", class: :pass}],
      report: Synthetic.report([{"jason", "1.4.5", "hit", ""}]),
      requests: [get("batch.json"), get("v2/manifests/jason.json")],
      snapshot: snap(),
      hits: [:jason],
      isolation: Keyword.get(opts, :isolation, []),
      observed: %{
        before: Keyword.get(opts, :before, view()),
        after: Keyword.get(opts, :after, view()),
        installed: ["jason"]
      }
    })
  end

  describe "load/1" do
    test "a test root by name, with its control case", %{tmp_dir: tmp} do
      t2_root = %{@t2 | id: "T3-pair", client_config: %{root: {:test_root, :threshold_2}}}
      assert {:ok, loaded} = Case.load(write(tmp, [@t0, @l2_t0, @t2, t2_root]))
      assert Enum.map(loaded, &Case.layer2?/1) == [false, true, true, true]
      assert Enum.map(loaded, &Case.control?/1) == [false, true, false, false]
    end

    test "an unknown test root is refused", %{tmp_dir: tmp} do
      bad = %{@t2 | client_config: %{root: {:test_root, :v9}}}
      assert {:error, why} = Case.load(write(tmp, [@l2_t0, bad]))
      assert why =~ "client_config"
    end

    test "a layer-2 case needs the L2-T0 control in the file", %{tmp_dir: tmp} do
      assert {:error, why} = Case.load(write(tmp, [@t0, @t2]))
      assert why =~ "L2-T0"

      # The control itself must be the unchanged copy under the test root v1.
      for bad <- [
            %{@l2_t0 | transform: {ChainTest.Mirror.TestBatch, %{signers: [:batch]}}},
            %{@l2_t0 | client_config: %{root: {:test_root, :threshold_2}}},
            Map.delete(@l2_t0, :client_config)
          ] do
        assert {:error, why} = Case.load(write(tmp, [bad, @t2])), inspect(bad)
        assert why =~ "L2-T0"
      end
    end

    test "a test-root-only transform or setup without a test root is refused", %{tmp_dir: tmp} do
      for bad <- [
            Map.delete(@t2, :client_config),
            %{@t2 | client_config: %{root: "/elsewhere/root.json"}},
            Map.merge(@t0, %{setup: {ChainTest.Conformance.Setup.AdoptedRoot, %{}}}),
            %{@t0 | transform: {ChainTest.Mirror.Forge, %{forge: :dotdot}}}
          ] do
        assert {:error, why} = Case.load(write(tmp, [@l2_t0, bad])), inspect(bad)
        assert why =~ "test root"
      end
    end

    test "runs: 2 is not for a layer-2 case", %{tmp_dir: tmp} do
      assert {:error, why} = Case.load(write(tmp, [@l2_t0, Map.put(@t2, :runs, 2)]))
      assert why =~ "runs: 2"
    end

    test "after root_version", %{tmp_dir: tmp} do
      for good <- [:absent, 2],
          do:
            assert(
              {:ok, _} =
                Case.load(write(tmp, [@l2_t0, Map.put(@t2, :after, %{root_version: good})]))
            )

      assert {:error, _} =
               Case.load(write(tmp, [@l2_t0, Map.put(@t2, :after, %{root_version: :kept})]))
    end
  end

  describe "judge/2" do
    test "root_version: an integer the case's own state dir holds, or none" do
      c = Map.put(@t0, :after, %{root_version: 2})
      assert %Result{class: :pass} = judged(c, after: view(%{"abc/root_version" => "2"}))

      assert %Result{class: :fail, detail: d} =
               judged(c, after: view(%{"abc/root_version" => "1"}))

      assert d =~ "root_version"
      assert %Result{class: :fail} = judged(c, after: view())

      absent = Map.put(@t0, :after, %{root_version: :absent})
      assert %Result{class: :pass} = judged(absent, after: view(%{"other/root_version" => "3"}))

      assert %Result{class: :fail, detail: d} =
               judged(absent, after: view(%{"abc/root_version" => "2"}))

      assert d =~ "root_version"
    end

    test "an isolation problem fails the case, naming it" do
      assert %Result{class: :pass} = judged(@t0, [])

      assert %Result{class: :fail, detail: d} =
               judged(@t0, isolation: ["the home holds a state dir for the test root"])

      assert d =~ "test root"
    end
  end

  describe "the repository's layer-2 cases" do
    setup do
      {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
      %{cases: cases, by: Map.new(cases, &{&1.id, &1})}
    end

    test "every brief row has its case, under a test root", %{by: by} do
      ids =
        ~w(L2-T0 T2 T3-duplicated T7 T8 R9 R10 R11 R17 R18 T5-expired P1-dotdot P1-absolute
           P1-outside P2-setuid P2-0777 P3-escape P3-app P4-checksum P4-deps P5 P6-name
           P6-version P8-duplicate P8-case P8-unicode P9)

      for id <- ids do
        assert Map.has_key?(by, id), id
        assert Case.layer2?(by[id]), id
      end

      # P7 is known, not testable: the client trusts the signed target claim.
      refute Enum.any?(Map.keys(by), &String.starts_with?(&1, "P7"))
      assert by["T3-duplicated"].client_config.root == {:test_root, :threshold_2}
    end

    test "no real-root case names a test root, and every layer-2 case does", %{cases: cases} do
      for c <- cases, not Case.layer2?(c) do
        refute match?(%{client_config: %{root: {:test_root, _}}}, c), c.id
      end
    end

    test "the reasons the client gives, and the post-conditions of a refusal", %{by: by} do
      for {id, reason} <- [
            {"T2", "batch signature invalid"},
            {"T3-duplicated", "batch signature invalid"},
            {"T7", "batch signature invalid"},
            {"T8", "batch lifetime"},
            {"R9", "clock: batch issued at"},
            {"R11", "batch stale"},
            {"T5-expired", "batch expired at"}
          ] do
        assert by[id].client.default == {:fail, reason}, id
        assert %{state_sequence: :unchanged, installed: :none, cache: :untouched} = by[id].after
      end

      assert by["T7"].after.root_version == :absent
      assert by["R17"].after.root_version == 2
      assert by["R18"].after.root_version == :absent
      assert by["R11"].client_config.clock_offset_seconds == {:age, 25 * 3600}
      assert by["T5-expired"].client_config.clock_offset_seconds == {:age, 2 * 3600}
    end
  end
end
