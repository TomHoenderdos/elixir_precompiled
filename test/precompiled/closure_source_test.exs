# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ClosureSourceTest do
  # The client review's B1 (0.9.1): a dependency changed to `path:` or
  # `git:` with `override: true` keeps its old Hex entry in mix.lock, so a
  # build made against the Hex release passed every rule that reads the
  # lock. Each dependency a match relies on must be one Mix loads here from
  # Hex, with the lock entry the rules compared: the package itself, each
  # dependency of the build, and each one of the env's closure.
  use ExUnit.Case, async: true
  alias Precompiled.{Env, Match, Reason}
  alias Precompiled.Env.MixProject

  @spark {:hex, :spark, "2.7.8", "inner", [:mix], [], "hexpm", "SPARKOUTER"}
  @ash {:hex, :ash, "3.5.2", "inner", [:mix],
        [{:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]}], "hexpm", "ASHOUTER"}
  @lock %{ash: @ash, spark: @spark}

  @build %{
    "elixir" => "1.20.3",
    "otp" => "29",
    "dep_env" => "prod",
    "system_version" => nil,
    "run_id" => "r",
    "deps" => %{"spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"}},
    "compile_env" => [],
    "package_checksum" => "ASHOUTER"
  }

  @manifest %{
    "versions" => %{
      "3.5.2" => %{
        "builds" => [%{"target" => "pure_elixir", "ebin" => [], "priv" => [], "build" => @build}]
      }
    }
  }

  defp ctx(over) do
    Map.merge(
      %{
        name: "ash",
        version: "3.5.2",
        lock_entry: @ash,
        lock: @lock,
        env_closure: [:spark],
        dep_sources: @lock,
        system: {"host", ""},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end
      },
      Map.new(over)
    )
  end

  defp dep(app, scm, opts),
    do: %Mix.Dep{app: app, scm: scm, opts: opts, manager: :mix, deps: [], status: :compile}

  defp select(over), do: Match.select_reason(@manifest, ctx(over))

  test "every dependency loaded from Hex as locked: the build matches" do
    assert {:ok, _, "pure_elixir"} = select([])
  end

  describe "each loaded dependency's source" do
    test "a Hex dependency is the lock entry Mix loaded it with" do
      ash = dep(:ash, Hex.SCM, hex: "ash", repo: "hexpm", lock: @ash)
      assert MixProject.dep_sources_from([ash]) == %{ash: @ash}
    end

    # Mix keeps the lock entry in the dep's opts whatever the SCM, and
    # `mix deps.get` leaves the old Hex entry for an overridden dep.
    test "a path or git override with its stale Hex entry is :path or :git" do
      path = dep(:spark, Mix.SCM.Path, lock: @spark, path: "../spark", dest: "/x/spark")
      git = dep(:spark, Mix.SCM.Git, lock: @spark, git: "https://example.test/spark.git")
      github = dep(:spark, Mix.SCM.Git, lock: @spark, github: "example/spark")

      assert MixProject.dep_sources_from([path]) == %{spark: :path}
      assert MixProject.dep_sources_from([git]) == %{spark: :git}
      assert MixProject.dep_sources_from([github]) == %{spark: :git}
    end

    test "a Hex dependency with a path or git option is not Hex" do
      assert MixProject.dep_sources_from([dep(:spark, Hex.SCM, lock: @spark, path: "../s")]) ==
               %{spark: :path}

      assert MixProject.dep_sources_from([dep(:spark, Hex.SCM, lock: @spark, git: "g")]) ==
               %{spark: :git}
    end

    test "a Hex dependency whose loaded entry is not its own package's is :other" do
      renamed = dep(:spark, Hex.SCM, hex: "spark_fork", repo: "hexpm", lock: @spark)
      unlocked = dep(:spark, Hex.SCM, hex: "spark", repo: "hexpm", lock: nil)
      git_locked = dep(:spark, Hex.SCM, hex: "spark", lock: {:git, "u", "abc", []})
      other_scm = dep(:spark, SomeOther.SCM, lock: @spark)

      for d <- [renamed, unlocked, git_locked, other_scm],
          do: assert(MixProject.dep_sources_from([d]) == %{spark: :other})
    end
  end

  describe "a dependency the match relies on that Mix does not load from Hex" do
    test "a closure dep overridden by a git dependency misses" do
      git = dep(:spark, Mix.SCM.Git, lock: @spark, git: "https://example.test/spark.git")
      ash = dep(:ash, Hex.SCM, hex: "ash", repo: "hexpm", lock: @ash)
      sources = MixProject.dep_sources_from([ash, git])

      assert {:miss, %Reason{code: :closure_source, args: ["spark", "2.7.8"]} = r} =
               select(dep_sources: sources)

      assert r.text ==
               "built against spark 2.7.8 from Hex, not the spark Mix loads here (a git dependency)"

      assert Reason.render(r.code, r.args) ==
               "built against spark 2.7.8 from Hex, not the spark Mix loads here"
    end

    test "a closure dep overridden by a path dependency misses" do
      assert {:miss, %Reason{code: :closure_source, args: ["spark", "2.7.8"]} = r} =
               select(dep_sources: %{@lock | spark: :path})

      assert r.text =~ "(a path dependency)"
    end

    test "the lock alone decides the closure (no env closure): the source still counts" do
      assert {:miss, %Reason{code: :closure_source, args: ["spark", "2.7.8"]}} =
               select(env_closure: nil, dep_sources: %{@lock | spark: :git})
    end

    test "a dep Mix does not load here, or loads with another lock entry, misses" do
      other = put_elem(@spark, 7, "OTHEROUTER")

      for sources <- [
            Map.delete(@lock, :spark),
            %{@lock | spark: other},
            %{@lock | spark: put_elem(@spark, 2, "2.7.9")},
            %{@lock | spark: :other}
          ] do
        assert {:miss, %Reason{code: :closure_source, args: ["spark", "2.7.8"]} = r} =
                 select(dep_sources: sources)

        assert r.text == "built against spark 2.7.8 from Hex, not the spark Mix loads here"
      end
    end

    test "the package itself not loaded from Hex misses" do
      assert {:miss, %Reason{code: :closure_source, args: ["ash", "3.5.2"]}} =
               select(dep_sources: %{@lock | ash: :path})
    end

    test "without the dependencies' sources nothing that names one matches" do
      assert {:miss, %Reason{code: :closure_source, args: ["ash", "3.5.2"]}} =
               select(dep_sources: nil)

      assert {:miss, %Reason{code: :closure_source}} =
               Match.select_reason(@manifest, Map.delete(ctx([]), :dep_sources))
    end

    # The rule is one of build_rules/3, which every list's rules take
    # (host-native ones too, after their triple).
    test "a build in any list takes the rule: world, foreign and relocated alike" do
      [build] = get_in(@manifest, ["versions", "3.5.2", "builds"])

      for version <- [
            %{"builds_with_inputs" => [build]},
            %{"builds_closure" => [build]},
            %{"foreign_priv" => %{"builds" => [build]}},
            %{"relocated" => %{"builds" => [build]}}
          ] do
        m = put_in(@manifest, ["versions", "3.5.2"], version)

        assert {:miss, %Reason{code: :closure_source}} =
                 Match.select_reason(m, ctx(dep_sources: %{@lock | spark: :path})),
               inspect(version)
      end
    end
  end

  test "a Check ctx carries the env's dependency sources" do
    env = %Env{
      candidates: [],
      lock: @lock,
      build_lib: "/b",
      deps_path: "/d",
      dep_sources: @lock,
      relocate: nil
    }

    candidate = %{name: :ash, version: "3.5.2", lock_entry: @ash}
    config = %{toolchain: {"1.20.3", "29"}}
    c = Precompiled.Check.ctx(candidate, env, config, fn _, _ -> :error end, nil)
    assert c.dep_sources == @lock
    assert c.env_closure == nil
  end
end
