# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.CaseLayer1Test do
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

  @sha_a String.duplicate("a", 64)

  defp write(tmp, cases) do
    path = Path.join(tmp, "cases.exs")
    File.write!(path, inspect(cases, limit: :infinity, printable_limit: :infinity))
    path
  end

  defp snap(builds, extra \\ %{}) do
    Map.merge(
      %{
        sequence: 7,
        deps:
          Map.new(builds, fn {n, b} -> {n, %{builds: b, manifest: "v2/manifests/#{n}.json"}} end)
      },
      extra
    )
  end

  defp get(path, status \\ 200),
    do: %{method: "GET", path: path, status: status, mutated: false}

  defp served(deps), do: [get("batch.json")] ++ Enum.map(deps, &get("v2/manifests/#{&1}.json"))

  defp view(cache, outside \\ %{}),
    do: %{states: %{}, cache: cache, outside: outside, own: {:ok, "abc/state"}}

  defp judged(post, before, now, opts \\ []) do
    c = Map.put(@t0, :after, post)
    lines = Keyword.get(opts, :lines, [{"jason", "1.4.5", "hit", ""}])

    Case.judge(c, %{
      rows: [%Result{step: :build, check: "hit:jason", class: :pass}],
      report: Synthetic.report(lines),
      requests: served(["jason"]),
      snapshot: snap(%{"jason" => 1, "ash" => 0}),
      hits: [:jason],
      observed: %{
        before: before,
        after: now,
        installed: Keyword.get(opts, :installed, ["jason"])
      }
    })
  end

  describe "load/1 accepts the layer-1 keys" do
    test "cache :verified, outside :untouched, installed {:without, deps} and :recheck",
         %{tmp_dir: tmp} do
      for post <- [
            %{cache: :verified},
            %{outside: :untouched},
            %{installed: {:without, ["jason"]}},
            %{installed: :recheck}
          ] do
        assert {:ok, _} = Case.load(write(tmp, [Map.put(@t0, :after, post)])), inspect(post)
      end
    end

    test "refuses malformed layer-1 values", %{tmp_dir: tmp} do
      for post <- [
            %{cache: :fresh},
            %{outside: :changed},
            %{installed: {:without, []}},
            %{installed: {:without, [:jason]}},
            %{installed: {:without, "jason"}}
          ] do
        assert {:error, why} = Case.load(write(tmp, [Map.put(@t0, :after, post)])),
               inspect(post)

        assert why =~ "after"
      end
    end

    test "runs: 2 is accepted, other counts are not", %{tmp_dir: tmp} do
      assert {:ok, [c]} = Case.load(write(tmp, [Map.put(@t0, :runs, 2)]))
      assert Case.runs(c) == 2
      assert Case.runs(@t0) == 1

      for bad <- [0, 1, 3, :two] do
        assert {:error, why} = Case.load(write(tmp, [Map.put(@t0, :runs, bad)])), inspect(bad)
        assert why =~ "runs"
      end
    end

    test "the :recheck client expectation needs runs: 2", %{tmp_dir: tmp} do
      recheck = %{@t0 | client: %{default: :recheck, deps: %{}}}
      assert {:ok, _} = Case.load(write(tmp, [Map.put(recheck, :runs, 2)]))
      assert {:error, why} = Case.load(write(tmp, [recheck]))
      assert why =~ "recheck"
    end
  end

  describe "cache: :untouched compares content and links, not only names" do
    test "the same entries with the same fingerprints pass" do
      seen = view(%{"files" => :dir, "files/#{@sha_a}" => {:file, "x"}})
      assert %Result{class: :pass} = judged(%{cache: :untouched}, seen, seen)
    end

    test "changed bytes of a planted file fail, naming it" do
      before = view(%{"files" => :dir, "files/#{@sha_a}" => {:file, "x"}})
      now = view(%{"files" => :dir, "files/#{@sha_a}" => {:file, "y"}})
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :untouched}, before, now)
      assert detail =~ "files/#{@sha_a}"
      assert detail =~ "changed"
    end

    test "a re-pointed symlink fails, and so does a link turned file" do
      before = view(%{"files/#{@sha_a}" => {:link, "../outside/a"}})
      moved = view(%{"files/#{@sha_a}" => {:link, "../outside/b"}})
      filed = view(%{"files/#{@sha_a}" => {:file, "x"}})

      assert %Result{class: :fail, detail: d1} = judged(%{cache: :untouched}, before, moved)
      assert d1 =~ "outside/b"
      assert %Result{class: :fail} = judged(%{cache: :untouched}, before, filed)
    end

    test "a removed planted entry fails" do
      before = view(%{"files" => :dir, "files/#{@sha_a}" => {:file, "x"}})
      now = view(%{"files" => :dir})
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :untouched}, before, now)
      assert detail =~ "removed"
    end

    test "a new entry still fails" do
      before = view(%{})
      now = view(%{"files" => :dir})
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :untouched}, before, now)
      assert detail =~ "gained"
    end
  end

  describe "cache: :verified" do
    test "every cached file hashes to its name" do
      good = sha("good")
      seen = view(%{"files" => :dir, "files/#{good}" => {:file, good}})
      assert %Result{class: :pass} = judged(%{cache: :verified}, view(%{}), seen)
      assert %Result{class: :pass} = judged(%{cache: :verified}, view(%{}), view(%{}))
    end

    test "a cached file whose bytes do not hash to its name fails" do
      seen = view(%{"files" => :dir, "files/#{@sha_a}" => {:file, sha("other")}})
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :verified}, view(%{}), seen)
      assert detail =~ "files/#{@sha_a}"
    end

    test "a symlink, a stray name or a subdirectory in the cache fails" do
      for {rel, fp} <- [
            {"files/#{@sha_a}", {:link, "/tmp/x"}},
            {"files/#{@sha_a}.tmp-1", {:file, sha("x")}},
            {"files/sub", :dir}
          ] do
        seen = view(%{"files" => :dir, rel => fp})

        assert %Result{class: :fail, detail: detail} =
                 judged(%{cache: :verified}, view(%{}), seen),
               rel

        assert detail =~ rel
      end
    end

    test "the cache dir itself a symlink fails" do
      seen = view(%{"files" => {:link, "outside/cache"}})
      assert %Result{class: :fail, detail: detail} = judged(%{cache: :verified}, view(%{}), seen)
      assert detail =~ "symlink"
    end
  end

  describe "outside: :untouched" do
    test "the planted tree as setup left it passes" do
      tree = %{"outside" => :dir, "outside/a" => {:file, "x"}}

      assert %Result{class: :pass} =
               judged(%{outside: :untouched}, view(%{}, tree), view(%{}, tree))
    end

    test "a new, changed or removed entry fails" do
      tree = %{"outside" => :dir, "outside/a" => {:file, "x"}}

      for now <- [
            Map.put(tree, "outside/b", {:file, "y"}),
            Map.put(tree, "outside/a", {:file, "z"}),
            Map.delete(tree, "outside/a")
          ] do
        assert %Result{class: :fail, detail: detail} =
                 judged(%{outside: :untouched}, view(%{}, tree), view(%{}, now))

        assert detail =~ "after outside"
      end
    end

    test "setup that planted nothing outside fails rather than passing vacuously" do
      assert %Result{class: :fail, detail: detail} =
               judged(%{outside: :untouched}, view(%{}), view(%{}))

      assert detail =~ "planted nothing"
    end
  end

  describe "installed: {:without, deps}" do
    test "exactly the held deps but those" do
      c = fn installed ->
        judged(%{installed: {:without, ["ash"]}}, view(%{}), view(%{}), installed: installed)
      end

      # The snapshot holds a build of jason only; ash is held in this one.
      assert %Result{class: :pass} = c.(["jason"])
      assert %Result{class: :fail, detail: detail} = c.([])
      assert detail =~ "installed"
    end
  end

  describe "runs: 2 and :recheck" do
    defp info(v2), do: %{manifests: %{}, manifests_v2: v2}

    defp previous(v2),
      do: {:ok, %{sequence: 6, path: "batches/6.json", info: info(v2), manifests: %{}}}

    defp recheck_judge(lines, installed, rows \\ []) do
      c =
        @t0
        |> Map.merge(%{
          runs: 2,
          client: %{default: :recheck, deps: %{}},
          after: %{installed: :recheck}
        })

      s =
        snap(%{"jason" => 1, "ash" => 1, "plug" => 1}, %{
          info: info(%{"jason" => "s1", "ash" => "s2", "plug" => "s3"}),
          # jason another manifest, ash the same, plug none.
          previous: previous(%{"jason" => @sha_a, "ash" => "s2"})
        })

      Case.judge(c, %{
        rows: rows,
        report: Synthetic.report(lines),
        requests: served(["ash"]),
        snapshot: s,
        hits: [:jason, :ash, :plug],
        observed: %{before: view(%{}), after: view(%{}), installed: installed}
      })
    end

    test "a dep the previous batch names another manifest for fails its hash, one it does not name is revoked, the rest keep no line" do
      lines = [
        {"jason", "1.4.5", "fail", "manifest hash differs from batch"},
        {"plug", "1.0.0", "miss", "revoked: no longer in the current batch"}
      ]

      assert %Result{class: :pass} = recheck_judge(lines, ["ash"])
    end

    test "a kept dep that is reported, or a differing dep that is kept, fails" do
      lines = [
        {"jason", "1.4.5", "fail", "manifest hash differs from batch"},
        {"plug", "1.0.0", "miss", "revoked: no longer in the current batch"},
        {"ash", "3.0.0", "hit", ""}
      ]

      assert %Result{class: :fail, detail: d1} = recheck_judge(lines, ["ash"])
      assert d1 =~ "client ash"

      assert %Result{class: :fail, detail: d2} =
               recheck_judge(Enum.take(lines, 2), ["ash", "jason"])

      assert d2 =~ "after installed"
    end

    test "the warm build's hit rows are not judged on the second run" do
      lines = [
        {"jason", "1.4.5", "fail", "manifest hash differs from batch"},
        {"plug", "1.0.0", "miss", "revoked: no longer in the current batch"}
      ]

      rows = [%Result{step: :build, check: "hit:ash", class: :fail, detail: "not in report"}]
      assert %Result{class: :pass} = recheck_judge(lines, ["ash"], rows)
    end
  end

  describe "the repository's layer-1 manifest, file, network and cache cases" do
    setup do
      {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
      %{by: Map.new(cases, &{&1.id, &1})}
    end

    test "every brief row has its case", %{by: by} do
      for id <- ~w(M1 M2 M3 F1 F2-truncated F2-larger F2-endless N1 N1-manifest N1-batch N4
                   C1 C2-entry C2-dir R15-refused R15-unserved R16),
          do: assert(Map.has_key?(by, id), id)

      # M4 is T0 plus Integrity's selected-build check; N6 is Task 5's (TLS).
      refute Map.has_key?(by, "M4")
      refute Map.has_key?(by, "N6")
    end

    test "every case that leaves nothing installed also keeps the cache clean", %{by: by} do
      for {id, %{after: %{installed: :none} = post}} <- by,
          do: assert(post[:cache] in [:untouched, :verified], id)
    end

    test "N1 cases never let the client reach the second mirror, and pin the reason",
         %{by: by} do
      for id <- ~w(N1 N1-manifest N1-batch),
          do: assert(by[id].after.second_mirror == :untouched, id)

      assert by["N1"].after.log == "redirect to another host refused"
      assert by["N1-batch"].after.log == "redirect to another host refused"
    end

    test "N4 outlasts the client's 300 s deadline at the mirror, and is bounded", %{by: by} do
      {ChainTest.Mirror.Drip, args} = by["N4"].transform
      assert args.stream_max_ms > 300_000 and args.stream_max_ms <= 600_000
    end

    test "R16 builds twice and needs a previous batch that differs", %{by: by} do
      assert Case.runs(by["R16"]) == 2

      assert ChainTest.Mirror.Transform.needs(by["R16"].transform) == [
               :previous,
               :previous_differs
             ]
    end
  end

  describe ":older_manifest (M3)" do
    test "the dep served an older manifest fails its hash; its hit row is the client's line",
         %{tmp_dir: dir} do
      old = "old manifest"
      File.mkdir_p!(Path.join(dir, "older_manifests"))
      File.write!(Path.join(dir, "older_manifests/#{sha(old)}.json"), old)

      s =
        snap(%{"jason" => 1, "ash" => 1}, %{
          dir: dir,
          previous:
            {:ok,
             %{sequence: 6, manifests: %{"jason" => %{dir: "v2/manifests", sha256: sha(old)}}}}
        })

      c =
        Map.merge(@t0, %{
          client: %{default: :older_manifest, deps: %{}},
          after: %{installed: :older_manifest}
        })

      judge = fn lines, installed ->
        Case.judge(c, %{
          rows: [%Result{step: :build, check: "hit:jason", class: :fail, detail: "hash"}],
          report: Synthetic.report(lines),
          requests: served(["jason", "ash"]),
          snapshot: s,
          hits: [:jason, :ash],
          observed: %{before: view(%{}), after: view(%{}), installed: installed}
        })
      end

      good = [
        {"jason", "1.4.5", "fail", "manifest hash differs from batch"},
        {"ash", "3.0.0", "hit", ""}
      ]

      assert %Result{class: :pass} = judge.(good, ["ash"])

      assert %Result{class: :fail, detail: detail} =
               judge.([{"jason", "1.4.5", "hit", ""}, {"ash", "3.0.0", "hit", ""}], [
                 "ash",
                 "jason"
               ])

      assert detail =~ "client jason"
    end
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
