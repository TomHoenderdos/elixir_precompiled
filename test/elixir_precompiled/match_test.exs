# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.MatchTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.Match

  @spark {:hex, :spark, "2.7.8", "inner", [:mix], [], "hexpm", "SPARKOUTER"}
  @ash {:hex, :ash, "3.5.2", "inner", [:mix],
        [{:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]}], "hexpm", "ASHOUTER"}
  @nerves {:hex, :nerves, "2.0.0-pre.4", "i", [:make, :mix],
           [{:tablet, "~> 0.3", [hex: :tablet, repo: "hexpm", optional: false]}], "hexpm", "NO"}
  @tablet {:hex, :tablet, "0.3.1", "i", [:mix], [], "hexpm", "TO"}
  @sys {:hex, :nerves_system_rpi4, "1.31.0", "i", [:mix], [], "hexpm", "SO"}
  @git {:git, "https://example/x.git", "abc", []}
  @lock %{
    spark: @spark,
    ash: @ash,
    nerves: @nerves,
    tablet: @tablet,
    nerves_system_rpi4: @sys,
    gitdep: @git
  }

  defp ctx(over \\ []) do
    Map.merge(
      %{
        name: "ash",
        version: "3.5.2",
        lock_entry: @ash,
        lock: @lock,
        system: {"nerves_system_rpi4", "1.31.0"},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end
      },
      Map.new(over)
    )
  end

  @build %{
    "elixir" => "1.20.3",
    "otp" => "29",
    "dep_env" => "prod",
    "system_version" => nil,
    "deps" => %{"spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"}},
    "compile_env" => [],
    "package_checksum" => "ASHOUTER"
  }

  defp doc(builds), do: %{"format" => 2, "versions" => %{"3.5.2" => %{"builds" => builds}}}
  defp pe(build), do: %{"target" => "pure_elixir", "ebin" => [], "priv" => [], "build" => build}

  defp entry(over \\ %{}) do
    Map.merge(
      %{
        "target" => "nerves_system_rpi4",
        "ebin" => [
          %{
            "path" => "ebin/Elixir.Ash.beam",
            "sha256" => String.duplicate("a", 64),
            "size" => 1,
            "mode" => 33188
          }
        ],
        "priv" => [],
        "build" => %{
          "elixir" => "1.20.3",
          "otp" => "29",
          "dep_env" => "prod",
          "system_version" => "1.31.0",
          "run_id" => "r",
          "image_digest" => "d",
          "deps" => %{"spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"}},
          "compile_env" => [],
          "package_checksum" => "ASHOUTER"
        }
      },
      over
    )
  end

  defp manifest(system \\ "nerves_system_rpi4", e \\ entry()),
    do: doc([Map.put(e, "target", system)])

  describe "the toolchain and env rules" do
    for {label, build_over, ctx_over, expect} <- [
          {"exact toolchain hits", [], [], :ok},
          {"older running patch misses", [], [elixir: "1.20.1"],
           {:miss, "built with Elixir 1.20.3, running 1.20.1"}},
          {"newer running patch hits", [], [elixir: "1.20.4"], :ok},
          {"other minor misses", [], [elixir: "1.21.0"],
           {:miss, "built with Elixir 1.20.3, running 1.21.0"}},
          {"older OTP misses", [], [otp: "28"], {:miss, "built on OTP 29, running 28"}},
          {"newer OTP misses", [{"otp", "27"}], [], {:miss, "built on OTP 27, running 29"}},
          {"env override misses", [], [dep_env: "dev"],
           {:miss, "built with env prod, dependency compiles as dev"}},
          {"no toolchain recorded misses", [{"elixir", nil}, {"otp", nil}], [],
           {:miss, "build predates toolchain"}},
          {"unparsable Elixir version misses", [{"elixir", "garbage"}], [],
           {:miss, "built with Elixir garbage, running 1.20.3"}},
          {"final build on a pre-release runtime misses", [{"elixir", "1.21.0"}],
           [elixir: "1.21.0-rc.0"], {:miss, "built with Elixir 1.21.0, running 1.21.0-rc.0"}},
          {"pre-release build on the final runtime hits", [{"elixir", "1.21.0-rc.0"}],
           [elixir: "1.21.0"], :ok},
          {"unparsable running version misses", [], [elixir: "garbage"],
           {:miss, "built with Elixir 1.20.3, running garbage"}}
        ] do
      test label do
        build =
          Enum.reduce(unquote(Macro.escape(build_over)), @build, fn {k, v}, b ->
            Map.put(b, k, v)
          end)

        result = Match.select(doc([pe(build)]), ctx(unquote(ctx_over)))

        case unquote(Macro.escape(expect)) do
          :ok -> assert {:ok, _, "pure_elixir"} = result
          miss -> assert ^miss = result
        end
      end
    end

    test "selection: exact patch first, then closest older patch, then pure before system, then newest run" do
      sys = %{
        "target" => "nerves_system_rpi4",
        "ebin" => [],
        "priv" => [],
        "build" => Map.merge(@build, %{"system_version" => "1.31.0", "run_id" => "s"})
      }

      older = pe(Map.merge(@build, %{"elixir" => "1.20.1", "run_id" => "o"}))
      exact = pe(Map.merge(@build, %{"run_id" => "e"}))

      assert {:ok, %{"build" => %{"run_id" => "e"}}, _} =
               Match.select(doc([sys, older, exact]), ctx())

      assert {:ok, %{"build" => %{"run_id" => "o"}}, _} =
               Match.select(doc([sys, older]), ctx(elixir: "1.20.2"))

      assert {:ok, %{"build" => %{"run_id" => "s"}}, "nerves_system_rpi4"} =
               Match.select(doc([sys]), ctx())
    end

    test "among otherwise equal builds the newest run wins" do
      a = pe(Map.put(@build, "run_id", "2026-10-01"))
      b = pe(Map.put(@build, "run_id", "2026-10-20"))
      c = pe(Map.put(@build, "run_id", "2026-10-20-x"))

      assert {:ok, %{"build" => %{"run_id" => "2026-10-20-x"}}, _} =
               Match.select(doc([a, c, b]), ctx())

      assert {:ok, %{"build" => %{"run_id" => "2026-10-20"}}, _} =
               Match.select(doc([b, a]), ctx())
    end

    test "the reported miss is the one that got furthest" do
      far = pe(Map.put(@build, "package_checksum", "OTHER"))
      near = pe(Map.put(@build, "otp", "27"))

      assert {:miss, "package checksum differs from mix.lock"} =
               Match.select(doc([near, far]), ctx())
    end

    test "a foreign-target miss ranks below every other miss" do
      foreign = %{
        "target" => "nerves_system_bbb",
        "ebin" => [],
        "priv" => [],
        "build" => Map.put(@build, "system_version", "1.0.0")
      }

      wrong_sys = %{
        "target" => "nerves_system_rpi4",
        "ebin" => [],
        "priv" => [],
        "build" => Map.put(@build, "system_version", "1.30.0")
      }

      assert {:miss, "built for nerves_system_rpi4 1.30.0, project has 1.31.0"} =
               Match.select(doc([foreign, wrong_sys]), ctx())
    end

    test "of two older-patch builds the closer patch wins" do
      p1 = pe(Map.merge(@build, %{"elixir" => "1.20.1", "run_id" => "p1"}))
      p2 = pe(Map.merge(@build, %{"elixir" => "1.20.2", "run_id" => "p2"}))

      assert {:ok, %{"build" => %{"run_id" => "p2"}}, _} = Match.select(doc([p1, p2]), ctx())
    end

    test "an exact-patch system build wins over an older-patch pure build" do
      older = pe(Map.merge(@build, %{"elixir" => "1.20.2", "run_id" => "o"}))

      sys = %{
        "target" => "nerves_system_rpi4",
        "ebin" => [],
        "priv" => [],
        "build" => Map.merge(@build, %{"system_version" => "1.31.0", "run_id" => "s"})
      }

      assert {:ok, %{"build" => %{"run_id" => "s"}}, "nerves_system_rpi4"} =
               Match.select(doc([older, sys]), ctx())
    end

    test "empty builds and unknown targets are misses" do
      assert {:miss, "not built for 3.5.2"} = Match.select(doc([]), ctx())

      other = %{
        "target" => "nerves_system_bbb",
        "ebin" => [],
        "priv" => [],
        "build" => Map.put(@build, "system_version", "1.0.0")
      }

      assert {:miss, "not built for nerves_system_rpi4 1.31.0"} =
               Match.select(doc([other]), ctx())
    end

    test "a malformed build is a miss, and a good one beside it still hits" do
      bad = %{"target" => "pure_elixir", "build" => ["not", "a", "map"]}
      assert {:miss, "malformed entry"} = Match.select(doc([bad]), ctx())
      assert {:ok, _, "pure_elixir"} = Match.select(doc([bad, pe(@build)]), ctx())
    end
  end

  describe "candidate?/3" do
    test "hex deps are candidates, tooling and nerves' children are not" do
      assert Match.candidate?(:ash, @lock, [])
      refute Match.candidate?(:nerves, @lock, [])
      refute Match.candidate?(:nerves_system_rpi4, @lock, [])
      refute Match.candidate?(:tablet, @lock, [])
      refute Match.candidate?(:gitdep, @lock, [])
      refute Match.candidate?(:ash, @lock, [:ash])
      refute Match.candidate?(:unknown, @lock, [])

      # The client never installs a portal build of itself.
      self_lock = Map.put(@lock, :elixir_precompiled, put_elem(@ash, 1, :elixir_precompiled))
      assert Match.tooling?("elixir_precompiled")
      refute Match.candidate?(:elixir_precompiled, self_lock, [])
    end
  end

  describe "select/2" do
    test "an exact match is selected" do
      assert {:ok, _entry, "nerves_system_rpi4"} = Match.select(manifest(), ctx())
    end

    test "pure_elixir matches any system" do
      assert {:ok, _, "pure_elixir"} =
               Match.select(
                 manifest(
                   "pure_elixir",
                   entry(%{"build" => Map.put(entry()["build"], "system_version", nil)})
                 ),
                 ctx()
               )
    end

    test "missing version or system is a miss" do
      assert {:miss, "not built for 3.5.2"} =
               Match.select(%{"format" => 2, "versions" => %{}}, ctx())

      assert {:miss, "not built for nerves_system_rpi4 1.31.0"} =
               Match.select(manifest("nerves_system_bbb"), ctx())
    end

    test "toolchain and system version must match exactly" do
      assert {:miss, "built with Elixir 1.19.1, running 1.20.3"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "elixir", "1.19.1")})
                 ),
                 ctx()
               )

      assert {:miss, "built on OTP 28, running 29"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "otp", "28")})
                 ),
                 ctx()
               )

      assert {:miss, "built for nerves_system_rpi4 1.30.0, project has 1.31.0"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "system_version", "1.30.0")})
                 ),
                 ctx()
               )
    end

    test "package checksum must match the lock" do
      assert {:miss, "package checksum differs from mix.lock"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "package_checksum", "OTHER")})
                 ),
                 ctx()
               )

      assert {:miss, "build predates package_checksum"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.delete(entry()["build"], "package_checksum")})
                 ),
                 ctx()
               )
    end

    test "deps lock is a subset check with exact version and checksum" do
      deps = %{"spark" => %{"version" => "2.7.2", "checksum" => "SPARKOUTER"}}

      assert {:miss, "built against spark 2.7.2, lock has 2.7.8"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "deps", deps)})
                 ),
                 ctx()
               )

      deps = %{"spark" => %{"version" => "2.7.8", "checksum" => "X"}}

      assert {:miss, "built against spark 2.7.8 with another checksum"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "deps", deps)})
                 ),
                 ctx()
               )

      deps = %{"sourceror" => %{"version" => "1.0.0", "checksum" => "S"}}

      assert {:miss, "built against sourceror 1.0.0, not in lock"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "deps", deps)})
                 ),
                 ctx()
               )

      assert {:miss, "build predates deps lock"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "deps", nil)})
                 ),
                 ctx()
               )
    end

    test "deps with a non-existing atom name does not create atoms" do
      name = "zz_never_an_atom_#{System.unique_integer([:positive])}"
      expected_msg = "built against #{name} 1.0.0, not in lock"

      deps = %{name => %{"version" => "1.0.0", "checksum" => "X"}}

      assert {:miss, ^expected_msg} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.put(entry()["build"], "deps", deps)})
                 ),
                 ctx()
               )

      # Verify the atom was not created
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "compile_env_from_app reads the .app into the manifest shape", %{} do
      dir = System.tmp_dir!() |> Path.join("match-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      app = Path.join(dir, "ash.app")
      File.write!(app, "{application, ash, [{compile_env, [{ash, [mode], {ok, fast}}]}]}.\n")

      assert [%{"app" => "ash", "path" => ["mode"], "value" => v}] =
               Match.compile_env_from_app(app)

      assert :erlang.binary_to_term(Base.url_decode64!(v, padding: false)) == {:ok, :fast}
      assert Match.compile_env_from_app(Path.join(dir, "none.app")) == nil
    end

    test "compile_env must equal the project's config" do
      value = fn term -> Base.url_encode64(:erlang.term_to_binary(term), padding: false) end
      ce = [%{"app" => "ash", "path" => ["mode"], "value" => value.({:ok, :fast})}]

      m =
        manifest(
          "nerves_system_rpi4",
          entry(%{"build" => Map.put(entry()["build"], "compile_env", ce)})
        )

      assert {:ok, _, _} = Match.select(m, ctx(%{config: fn "ash", ["mode"] -> {:ok, :fast} end}))

      assert {:miss, "compile_env differs: ash [:mode]"} =
               Match.select(m, ctx(%{config: fn "ash", ["mode"] -> :error end}))

      assert {:miss, "build predates compile_env"} =
               Match.select(
                 manifest(
                   "nerves_system_rpi4",
                   entry(%{"build" => Map.delete(entry()["build"], "compile_env")})
                 ),
                 ctx()
               )
    end
  end

  describe "deps the candidate declares" do
    @decimal {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", "DECOUTER"}
    @ash_opt {:hex, :ash, "3.5.2", "inner", [:mix],
              [
                {:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]},
                {:decimal, "~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}
              ], "hexpm", "ASHOUTER"}

    test "an optional dep in the client lock must be in the build's deps" do
      lock = Map.merge(@lock, %{ash: @ash_opt, decimal: @decimal})
      c = ctx(%{lock_entry: @ash_opt, lock: lock})

      assert {:miss, "built without decimal, lock has 2.3.0"} = Match.select(manifest(), c)

      with_decimal =
        entry()
        |> put_in(["build", "deps", "decimal"], %{"version" => "2.3.0", "checksum" => "DECOUTER"})

      assert {:ok, _, "nerves_system_rpi4"} =
               Match.select(manifest("nerves_system_rpi4", with_decimal), c)
    end

    test "an optional dep absent from the client lock is fine" do
      c = ctx(%{lock_entry: @ash_opt, lock: Map.put(@lock, :ash, @ash_opt)})
      assert {:ok, _, _} = Match.select(manifest(), c)
    end
  end

  describe "select/2 with both pure_elixir and a system entry" do
    defp stale(), do: entry(%{"build" => Map.delete(entry()["build"], "package_checksum")})

    defp pure(over \\ %{}),
      do: entry(%{"build" => Map.merge(entry()["build"], Map.put(over, "system_version", nil))})

    defp both(pe, sys), do: doc([Map.put(pe, "target", "pure_elixir"), sys])

    @wrong_env [%{"app" => "ash", "path" => ["mode"], "value" => "g3cEZmFzdA"}]

    test "a passing pure_elixir entry wins over a stale system entry" do
      assert {:ok, _, "pure_elixir"} = Match.select(both(pure(), stale()), ctx())
    end

    test "a pure_elixir entry that fails the key falls back to a passing system entry" do
      assert {:ok, _, "nerves_system_rpi4"} =
               Match.select(both(pure(%{"compile_env" => @wrong_env}), entry()), ctx())
    end

    test "when both fail, the reason of the build that got further is returned" do
      sys = entry(%{"build" => Map.put(entry()["build"], "otp", "28")})

      assert {:miss, "compile_env differs: ash [:mode]"} =
               Match.select(both(pure(%{"compile_env" => @wrong_env}), sys), ctx())
    end

    test "a fresh pure_elixir entry's reason wins over a stale system entry on a double miss" do
      assert {:miss, "compile_env differs: ash [:mode]"} =
               Match.select(both(pure(%{"compile_env" => @wrong_env}), stale()), ctx())
    end

    test "a stale pure_elixir entry that got further than a system entry gives its reason" do
      pe = pure(%{"package_checksum" => nil})
      sys = entry(%{"build" => Map.put(entry()["build"], "otp", "28")})

      assert {:miss, "build predates package_checksum"} = Match.select(both(pe, sys), ctx())
    end

    test "only a failing pure_elixir entry returns its reason" do
      m = doc([Map.put(pure(%{"compile_env" => @wrong_env}), "target", "pure_elixir")])
      assert {:miss, "compile_env differs: ash [:mode]"} = Match.select(m, ctx())
    end
  end
end
