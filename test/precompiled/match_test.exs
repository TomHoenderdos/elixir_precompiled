# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.MatchTest do
  use ExUnit.Case, async: true
  alias Precompiled.{Match, Reason}

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
          {"no dep_env recorded misses", [{"dep_env", nil}], [],
           {:miss, "build predates dep_env"}},
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

    test "a host project with no matching build has no trailing space in the reason" do
      other = %{
        "target" => "nerves_system_rpi4",
        "ebin" => [],
        "priv" => [],
        "build" => Map.put(@build, "system_version", "1.31.0")
      }

      assert {:miss, "not built for host"} =
               Match.select(doc([other]), ctx(system: {"host", ""}))
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
      self_lock = Map.put(@lock, :precompiled, put_elem(@ash, 1, :precompiled))
      assert Match.tooling?("precompiled")
      refute Match.candidate?(:precompiled, self_lock, [])
    end

    test "tooling named by Mix's dep data is never a candidate, even when the lock has no nerves list" do
      lock = Map.put(@lock, :nerves, {:git, "https://example.test/nerves.git", "abc", []})
      assert Match.candidate?(:tablet, lock, [], nil)
      refute Match.candidate?(:tablet, lock, [], [:tablet])
      # The lock's closure still counts when the lock has one.
      refute Match.candidate?(:tablet, @lock, [], [])
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

    # {:ok, <an atom this VM has never seen>} in the external term format,
    # built by hand so the test never creates the atom itself.
    defp unknown_atom_value() do
      name = "ep_never_an_atom_#{System.unique_integer([:positive])}"
      bin = <<131, 104, 2, 119, 2, "ok", 119, byte_size(name), name::binary>>
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      Base.url_encode64(bin, padding: false)
    end

    # No config in this VM can hold an atom it has never seen, so the
    # value differs from the project's, whatever the project sets.
    test "a recorded value naming an atom this VM has never seen differs" do
      ce = [%{"app" => "ash", "path" => ["mode"], "value" => unknown_atom_value()}]

      m =
        manifest(
          "nerves_system_rpi4",
          entry(%{"build" => Map.put(entry()["build"], "compile_env", ce)})
        )

      for config <- [fn _, _ -> :error end, fn "ash", ["mode"] -> {:ok, :fast} end] do
        assert {:miss, "compile_env differs: ash [:mode]"} =
                 Match.select(m, ctx(%{config: config}))

        assert {:miss, "compile_env differs: ash [:mode]"} = Match.compile_env_ok(ce, config)
      end
    end
  end

  describe "compile_env_ok/2 on a recorded value it will not decode" do
    @differs {:miss, "compile_env differs: ash [:mode]"}

    defp ce_bin(bin),
      do: [
        %{"app" => "ash", "path" => ["mode"], "value" => Base.url_encode64(bin, padding: false)}
      ]

    # Recorded as Application.fetch_env/2 would return it.
    defp ce_term(:error), do: ce_bin(:erlang.term_to_binary(:error))
    defp ce_term(value), do: ce_bin(:erlang.term_to_binary({:ok, value}))

    test "compressed ETF differs, and is never inflated" do
      huge = :erlang.term_to_binary(:binary.copy(<<0>>, 50_000_000), [:compressed])
      assert byte_size(huge) < 65_536

      {us, result} =
        :timer.tc(fn -> Match.compile_env_ok(ce_bin(huge), fn _, _ -> :error end) end)

      assert result == @differs
      assert us < 50_000

      # Even a value equal to the project's, once compressed, differs.
      value = :binary.copy("x", 1000)
      small = :erlang.term_to_binary({:ok, value}, [:compressed])
      assert <<131, 80, _::binary>> = small
      assert @differs = Match.compile_env_ok(ce_bin(small), fn _, _ -> {:ok, value} end)
    end

    test "a value over 64 KiB differs" do
      value = :binary.copy("a", 65_536)
      assert @differs = Match.compile_env_ok(ce_term(value), fn _, _ -> {:ok, value} end)
      fits = :binary.copy("a", 65_000)
      assert :ok = Match.compile_env_ok(ce_term(fits), fn _, _ -> {:ok, fits} end)
    end

    test "a value holding a fun, pid, port or reference differs" do
      for bad <- [
            &Enum.map/2,
            self(),
            hd(Port.list()),
            make_ref(),
            %{opts: %{fun: &Enum.map/2}}
          ] do
        assert @differs = Match.compile_env_ok(ce_term(bad), fn _, _ -> {:ok, bad} end),
               inspect(bad)
      end
    end

    test "invalid base64 is a miss, never a raise" do
      item = %{"app" => "ash", "path" => ["mode"], "value" => "!!"}
      assert {:miss, _} = Match.compile_env_ok([item], fn _, _ -> :error end)
    end

    test "plain values still match" do
      for term <- [:fast, "a string", [mode: :fast, retries: 3], %{a: %{b: [1, "c"]}}] do
        assert :ok = Match.compile_env_ok(ce_term(term), fn _, _ -> {:ok, term} end),
               inspect(term)
      end

      # A recorded :error is a key the build did not have set.
      assert :ok = Match.compile_env_ok(ce_term(:error), fn _, _ -> :error end)
    end
  end

  describe "compile_env_ok/2 on a value that is not base64" do
    test "is a malformed entry, never a raise" do
      for value <- ["!!", "a", nil, 1] do
        ce = [%{"app" => "ash", "path" => ["mode"], "value" => value}]

        assert {:miss, "malformed entry"} =
                 Match.compile_env_ok(ce, fn _, _ -> :error end),
               inspect(value)
      end
    end

    test "an item missing a field is a malformed entry, not skipped" do
      ok = Base.url_encode64(:erlang.term_to_binary(:error), padding: false)
      item = %{"app" => "ash", "path" => ["mode"], "value" => ok}
      assert :ok = Match.compile_env_ok([item], fn _, _ -> :error end)

      for key <- ["app", "path", "value"] do
        assert {:miss, "malformed entry"} =
                 Match.compile_env_ok([Map.delete(item, key)], fn _, _ -> :error end),
               key
      end
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

  describe "sticky selection" do
    test "files_hash ignores order and changes with any byte, path or mode" do
      a = %{"path" => "ebin/a.beam", "sha256" => String.duplicate("a", 64), "mode" => 33188}
      b = %{"path" => "ebin/b.beam", "sha256" => String.duplicate("b", 64), "mode" => 33188}
      h = Match.files_hash(%{"ebin" => [a, b], "priv" => []})
      assert h =~ ~r/\A[0-9a-f]{64}\z/
      assert h == Match.files_hash(%{"ebin" => [b, a]})
      refute h == Match.files_hash(%{"ebin" => [a, %{b | "mode" => 33261}]})
      refute h == Match.files_hash(%{"ebin" => [a, %{b | "sha256" => String.duplicate("c", 64)}]})
      refute h == Match.files_hash(%{"ebin" => [a, %{b | "path" => "ebin/c.beam"}]})
      refute h == Match.files_hash(%{"ebin" => [a], "priv" => [%{b | "path" => "priv/b.beam"}]})
      assert Match.files_hash(%{"ebin" => [%{"path" => 1}]}) == nil
    end

    test "a path that could fake a line boundary has no files_hash" do
      a = %{"path" => "ebin/a.beam", "sha256" => String.duplicate("a", 64), "mode" => 33188}
      assert Match.files_hash(%{"ebin" => [%{a | "path" => "ebin/a\nb"}]}) == nil
      assert Match.files_hash(%{"ebin" => [%{a | "path" => "ebin/a\0b"}]}) == nil
    end

    test "an installed build that still passes outranks a newer run" do
      old = entry(%{"build" => Map.put(entry()["build"], "run_id", "a")})

      new =
        entry(%{
          "build" => Map.put(entry()["build"], "run_id", "b"),
          "ebin" => [%{hd(entry()["ebin"]) | "sha256" => String.duplicate("c", 64)}]
        })

      assert {:ok, ^new, _} = Match.select(doc([old, new]), ctx())
      assert {:ok, ^old, _} = Match.select(doc([old, new]), ctx(prefer: Match.files_hash(old)))
    end

    test "a preferred build that no longer passes is never selected" do
      old =
        entry(%{
          "build" => entry()["build"] |> Map.put("run_id", "a") |> Map.put("otp", "28")
        })

      new = entry(%{"build" => Map.put(entry()["build"], "run_id", "b"), "ebin" => []})
      assert {:ok, ^new, _} = Match.select(doc([old, new]), ctx(prefer: Match.files_hash(old)))
      assert {:miss, _} = Match.select(doc([old]), ctx(prefer: Match.files_hash(old)))
    end
  end

  describe "compile-time inputs" do
    test "a dep reading Mix.target gets no pure_elixir build on a device target" do
      reads = %{target: true, env: []}

      assert {:miss,
              "reads Mix.target() at compile time; built for target host, project targets rpi4"} =
               Match.select(doc([pe(@build)]), ctx(reads: reads, mix_target: "rpi4"))

      assert {:ok, _, "pure_elixir"} =
               Match.select(doc([pe(@build)]), ctx(reads: reads, mix_target: "host"))
    end

    test "a system build is served only under its conventional or recorded target name" do
      reads = %{target: true, env: []}
      assert {:ok, _, _} = Match.select(manifest(), ctx(reads: reads, mix_target: "rpi4"))

      assert {:miss,
              "reads Mix.target() at compile time; built for target rpi4, project targets my_board"} =
               Match.select(manifest(), ctx(reads: reads, mix_target: "my_board"))

      recorded = entry(%{"build" => Map.put(entry()["build"], "mix_target", "my_board")})

      assert {:ok, _, _} =
               Match.select(
                 manifest("nerves_system_rpi4", recorded),
                 ctx(reads: reads, mix_target: "my_board")
               )
    end

    test "a module-level env read is a miss for every build; no scan is no rule" do
      assert {:miss, "reads FOO_URL at compile time, which no build records"} =
               Match.select(doc([pe(@build)]), ctx(reads: %{target: false, env: ["FOO_URL"]}))

      assert {:ok, _, _} = Match.select(doc([pe(@build)]), ctx(reads: nil))
      assert {:ok, _, _} = Match.select(doc([pe(@build)]), ctx(reads: %{target: false, env: []}))
    end

    test "sources that could not be scanned are a miss for every build" do
      assert {:miss, "source not scannable: lib/a.ex does not parse"} =
               Match.select(
                 doc([pe(@build)]),
                 ctx(reads: {:unscannable, "lib/a.ex does not parse"})
               )
    end
  end

  describe "build method (rule 9)" do
    for opt <- [:manager, :compile, :system_env] do
      test "a dependency declared with #{inspect(opt)} misses every build" do
        expect = {:miss, "project sets #{inspect(unquote(opt))} for this dependency"}

        assert ^expect =
                 Match.select(doc([pe(@build)]), ctx(overrides: [unquote(opt)], manager: "mix"))

        assert ^expect = Match.select(manifest(), ctx(overrides: [unquote(opt)]))
      end
    end

    test "deps that did not load miss every build, before any override" do
      expect = {:miss, "build method unknown (deps did not load: lock is broken)"}

      assert ^expect =
               Match.select(
                 doc([pe(@build)]),
                 ctx(build_method_unknown: "lock is broken", overrides: [:manager])
               )

      assert ^expect = Match.select(manifest(), ctx(build_method_unknown: "lock is broken"))
      assert {:ok, _, _} = Match.select(manifest(), ctx(build_method_unknown: nil))
    end

    test "the first override in the list names the miss" do
      assert {:miss, "project sets :compile for this dependency"} =
               Match.select(doc([pe(@build)]), ctx(overrides: [:compile, :system_env]))
    end

    test "a recorded manager other than the project's misses" do
      build = Map.put(@build, "manager", "rebar3")

      assert {:miss, "built with rebar3, project builds with make"} =
               Match.select(doc([pe(build)]), ctx(manager: "make"))
    end

    test "a recorded manager when the project's is unknown misses" do
      build = Map.put(@build, "manager", "rebar3")

      assert {:miss, "built with rebar3, project's manager for it is unknown"} =
               Match.select(doc([pe(build)]), ctx(manager: nil))

      assert {:miss, "built with rebar3, project's manager for it is unknown"} =
               Match.select(doc([pe(build)]), ctx())
    end

    test "a recorded manager equal to the project's hits" do
      build = Map.put(@build, "manager", "mix")
      assert {:ok, _, "pure_elixir"} = Match.select(doc([pe(build)]), ctx(manager: "mix"))
    end

    test "an entry without a manager is judged as before" do
      assert {:ok, _, "pure_elixir"} = Match.select(doc([pe(@build)]), ctx(manager: "make"))
      assert {:ok, _, "pure_elixir"} = Match.select(doc([pe(@build)]), ctx(manager: nil))
      assert {:ok, _, "pure_elixir"} = Match.select(doc([pe(@build)]), ctx(overrides: []))
      assert {:ok, _, _} = Match.select(manifest(), ctx(manager: "rebar3"))
    end

    test "a manager that is not a string is a malformed entry" do
      build = Map.put(@build, "manager", 3)

      assert {:miss, "malformed entry"} =
               Match.select(doc([pe(build)]), ctx(manager: "mix"))
    end

    test "a matching manager still answers to the other rules" do
      build = @build |> Map.put("manager", "mix") |> Map.put("otp", "28")

      assert {:miss, "built on OTP 28, running 29"} =
               Match.select(doc([pe(build)]), ctx(manager: "mix"))
    end
  end

  describe "across releases of the same system" do
    @tc "nerves_toolchain_aarch64_nerves_linux_gnu"
    @glibc for(n <- 17..41, do: "GLIBC_2.#{n}")
    @libs %{
      "libc.so.6" => @glibc,
      "libstdc++.so.6" => for(n <- 29..31, do: "GLIBCXX_3.4.#{n}")
    }
    @systems %{
      "nerves_system_rpi4" => %{
        "2.1.0" => %{
          "toolchain" => %{"package" => @tc, "version" => "15.3.1", "series" => "15.3"},
          "otp" => "28.1.0",
          "libs" => @libs
        },
        "2.2.0" => %{
          "toolchain" => %{"package" => @tc, "version" => "15.3.1", "series" => "15.3"},
          "otp" => "28.2.0",
          "libs" => @libs
        },
        "2.3.0" => %{
          "toolchain" => %{"package" => @tc, "version" => "15.4.0", "series" => "15.4"},
          "otp" => "28.2.0",
          "libs" => @libs
        },
        # As the portal publishes a release it knows only from Hex: its
        # toolchain requirement's series, no version, OTP or library table.
        "2.5.0" => %{
          "toolchain" => %{"package" => @tc, "version" => nil, "series" => "15.3"},
          "otp" => nil,
          "libs" => nil
        },
        "2.7.0" => %{
          "toolchain" => %{"package" => @tc, "version" => nil, "series" => "15.4"},
          "otp" => nil,
          "libs" => nil
        },
        "2.8.0" => %{
          "toolchain" => %{"package" => @tc, "version" => "15.3.1", "series" => "15.3"},
          "otp" => "28.2.0",
          "libs" => nil
        },
        "2.6.0" => %{
          "toolchain" => %{"package" => @tc, "version" => nil, "series" => nil},
          "otp" => "28.2.0",
          "libs" => @libs
        }
      }
    }

    defp xctx(project, over \\ []),
      do: ctx([system: {"nerves_system_rpi4", project}, otp: "28", systems: @systems] ++ over)

    # A build for another release; native ones need libc GLIBC_2.17.
    defp xbuild(version, over \\ %{}) do
      base = %{
        "otp" => "28",
        "system_version" => version,
        "run_id" => "r" <> version,
        "native" => true,
        "portable" => true,
        "otp_full" => "28.1.0",
        "toolchain" => %{"package" => @tc, "version" => "15.3.1"},
        "elf" => %{"needs" => %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_PRIVATE"]}}
      }

      entry(%{"build" => entry()["build"] |> Map.merge(base) |> Map.merge(over)})
    end

    defp beam_only(version), do: xbuild(version, %{"native" => false, "portable" => true})

    defp code_of({:miss, %Precompiled.Reason{code: code, args: args}}), do: {code, args}

    test "a beam-only build for another release hits" do
      assert {:ok, %{"build" => %{"system_version" => "2.1.0"}}, "nerves_system_rpi4"} =
               Match.select(doc([beam_only("2.1.0")]), xctx("2.2.0"))
    end

    test "a beam-only build of a dep that reads the system at compile time misses" do
      result =
        Match.select_reason(
          doc([beam_only("2.1.0")]),
          xctx("2.2.0", reads: %{target: false, env: [], system: true})
        )

      assert code_of(result) == {:system_bound_compile, []}
      assert {:miss, "reads the Nerves system at compile time"} = Reason.textual(result)
    end

    test "a native build hits on a release with the same series, OTP and libraries" do
      assert {:ok, %{"build" => %{"system_version" => "2.1.0"}}, _} =
               Match.select(doc([xbuild("2.1.0")]), xctx("2.2.0"))
    end

    test "a native build misses on a release with another toolchain series" do
      result = Match.select_reason(doc([xbuild("2.1.0")]), xctx("2.3.0"))

      assert code_of(result) ==
               {:system_version_abi, ["nerves_system_rpi4", "2.1.0", "15.3", "2.3.0", "15.4"]}
    end

    test "a release whose series is unknown misses on the series" do
      result = Match.select_reason(doc([xbuild("2.1.0")]), xctx("2.6.0"))

      assert code_of(result) ==
               {:system_version_abi, ["nerves_system_rpi4", "2.1.0", "15.3", "2.6.0", "?"]}
    end

    test "a native build on a newer OTP than the release misses" do
      build = xbuild("2.2.0", %{"otp_full" => "28.2.0"})
      result = Match.select_reason(doc([build]), xctx("2.1.0"))
      assert code_of(result) == {:toolchain_otp_minor, ["28.2.0", "28.1.0"]}
    end

    for {built, release, expect} <- [
          {"27.3.4.1", "27.3.4.3", :hit},
          {"27.3.4.3", "27.3.4.1", :miss},
          {"27.3.4", "27.3.4.1", :hit},
          {"28.10.0", "28.9.0", :miss},
          {"28.1", "29.0", :miss},
          {"junk", "28.2.0", :miss}
        ] do
      test "OTP #{built} built, release #{release}: #{expect}" do
        built = unquote(built)
        release = unquote(release)
        systems = put_in(@systems, ["nerves_system_rpi4", "2.2.0", "otp"], release)
        build = xbuild("2.1.0", %{"otp_full" => built})
        result = Match.select_reason(doc([build]), xctx("2.2.0", systems: systems))

        case unquote(expect) do
          :hit -> assert {:ok, _, _} = result
          :miss -> assert code_of(result) == {:toolchain_otp_minor, [built, release]}
        end
      end
    end

    test "an exact-release build of a dep that reads the system at compile time hits" do
      assert {:ok, %{"build" => %{"system_version" => "2.2.0"}}, _} =
               Match.select(
                 doc([xbuild("2.2.0")]),
                 xctx("2.2.0", reads: %{target: false, env: [], system: true})
               )
    end

    test "a native build with no recorded OTP release misses" do
      build = xbuild("2.1.0", %{"otp_full" => nil})
      result = Match.select_reason(doc([build]), xctx("2.2.0"))
      assert code_of(result) == {:toolchain_otp_minor, ["?", "28.2.0"]}
    end

    test "a needed library the release lacks misses" do
      build = xbuild("2.1.0", %{"elf" => %{"needs" => %{"libssl.so.3" => ["OPENSSL_3.0.0"]}}})
      result = Match.select_reason(doc([build]), xctx("2.2.0"))
      assert code_of(result) == {:needed_lib_missing, ["libssl.so.3"]}
    end

    test "a needed symbol version the release lacks misses" do
      build =
        xbuild("2.1.0", %{"elf" => %{"needs" => %{"libstdc++.so.6" => ["GLIBCXX_3.4.32"]}}})

      result = Match.select_reason(doc([build]), xctx("2.2.0"))
      assert code_of(result) == {:symbol_version_missing, ["libstdc++.so.6", "GLIBCXX_3.4.32"]}
    end

    test "a project release the portal has no row for misses as unknown" do
      unknown = Match.select_reason(doc([xbuild("2.1.0")]), xctx("2.4.0"))
      assert code_of(unknown) == {:system_unknown, ["nerves_system_rpi4", "2.4.0"]}
    end

    test "a release the portal knows only from Hex misses as unknown, not on OTP" do
      # Its series is the build's: OTP would be the first rule to fail.
      same = Match.select_reason(doc([xbuild("2.1.0")]), xctx("2.5.0"))
      assert code_of(same) == {:system_unknown, ["nerves_system_rpi4", "2.5.0"]}

      # Even a series the build does not share is not judged yet.
      other = Match.select_reason(doc([xbuild("2.1.0")]), xctx("2.7.0"))
      assert code_of(other) == {:system_unknown, ["nerves_system_rpi4", "2.7.0"]}

      # A beam-only build needs no row at all.
      assert {:ok, _, _} = Match.select(doc([beam_only("2.1.0")]), xctx("2.5.0"))
    end

    test "a release with OTP but no library table misses as unknown" do
      no_libs = Match.select_reason(doc([xbuild("2.1.0")]), xctx("2.8.0"))
      assert code_of(no_libs) == {:system_unknown, ["nerves_system_rpi4", "2.8.0"]}
    end

    test "an ebin-only build as the portal renders it hits on another release" do
      # The build fields of a target build with ebin files and an empty priv:
      # not native, portable, no elf, its toolchain and OTP recorded.
      build =
        entry(%{
          "build" =>
            entry()["build"]
            |> Map.merge(%{
              "otp" => "28",
              "system_version" => "2.1.0",
              "run_id" => "r-ebin-only",
              "native" => false,
              "portable" => true,
              "otp_full" => "28.1.0",
              "toolchain" => %{"package" => @tc, "version" => "15.3.1"}
            })
            |> Map.delete("elf")
        })

      assert {:ok, %{"build" => %{"system_version" => "2.1.0"}}, "nerves_system_rpi4"} =
               Match.select(doc([build]), xctx("2.3.0"))
    end

    test "a native build that is not portable misses as on another release" do
      build = xbuild("2.1.0", %{"portable" => false})

      assert Match.select(doc([build]), xctx("2.2.0")) ==
               {:miss, "built for nerves_system_rpi4 2.1.0, project has 2.2.0"}

      assert code_of(Match.select_reason(doc([build]), xctx("2.2.0"))) ==
               {:not_built_target, ["nerves_system_rpi4", "2.2.0"]}
    end

    test "a native build needing nothing hits given the series and OTP" do
      build = xbuild("2.1.0", %{"elf" => %{"needs" => %{}}})
      assert {:ok, _, _} = Match.select(doc([build]), xctx("2.2.0"))
    end

    test "a native build for another release without elf facts misses" do
      for elf <- [nil, "junk", []] do
        no_elf = xbuild("2.1.0", %{"elf" => elf})
        result = Match.select_reason(doc([no_elf]), xctx("2.2.0"))
        assert code_of(result) == {:build_predates, ["elf"]}
        assert {:miss, "build predates elf"} = Reason.textual(result)
      end
    end

    test "an exact-release native build without elf facts still hits" do
      no_elf = xbuild("2.2.0", %{"elf" => nil})
      assert {:ok, _, _} = Match.select(doc([no_elf]), xctx("2.2.0"))
    end

    test "the highest release below the project's wins, an exact one before it" do
      builds = [xbuild("2.0.0"), xbuild("2.3.0"), xbuild("2.1.0")]

      assert {:ok, %{"build" => %{"system_version" => "2.1.0"}}, _} =
               Match.select(doc(builds), xctx("2.2.0"))

      assert {:ok, %{"build" => %{"system_version" => "2.2.0"}}, _} =
               Match.select(doc(builds ++ [xbuild("2.2.0")]), xctx("2.2.0"))

      assert {:ok, %{"build" => %{"system_version" => "2.3.0"}}, _} =
               Match.select(doc([xbuild("2.4.0"), xbuild("2.3.0")]), xctx("2.2.0"))
    end

    test "an unparseable release orders last and does not crash" do
      builds = [beam_only("junk"), beam_only("2.3.0")]

      assert {:ok, %{"build" => %{"system_version" => "2.3.0"}}, _} =
               Match.select(doc(builds), xctx("2.2.0"))

      assert {:ok, %{"build" => %{"system_version" => "junk"}}, _} =
               Match.select(doc([beam_only("junk")]), xctx("2.2.0"))
    end

    test "without a systems table a native build for another release misses as before" do
      ctx = xctx("2.2.0", systems: nil)

      assert Match.select(doc([xbuild("2.1.0")]), ctx) ==
               {:miss, "built for nerves_system_rpi4 2.1.0, project has 2.2.0"}
    end

    test "the device rule still needs the exact release" do
      assert Match.target_ok("nerves_system_rpi4", "2.1.0", {"nerves_system_rpi4", "2.2.0"}) ==
               {:miss, "built for nerves_system_rpi4 2.1.0, project has 2.2.0"}
    end
  end

  describe "exposed rules (shared with the device)" do
    test "texts are the host's" do
      assert Match.target_ok("pure_elixir", nil, {"nerves_system_rpi4", "2.2.1"}) == :ok

      assert Match.target_ok("nerves_system_rpi4", "2.2.0", {"nerves_system_rpi4", "2.2.1"}) ==
               {:miss, "built for nerves_system_rpi4 2.2.0, project has 2.2.1"}

      assert Match.target_ok("nerves_system_rpi0_2", "2.2.1", {"nerves_system_rpi4", "2.2.1"}) ==
               {:miss, "not built for this system (nerves_system_rpi0_2)"}

      assert Match.elixir_ok("1.20.3", "1.20.2") ==
               {:miss, "built with Elixir 1.20.3, running 1.20.2"}

      assert Match.elixir_ok("1.20.3", "1.20.4") == :ok
      assert Match.otp_ok("29", "28") == {:miss, "built on OTP 29, running 28"}

      assert Match.dep_env_ok("dev", "prod") ==
               {:miss, "built with env dev, dependency compiles as prod"}

      assert Match.toolchain_present(%{}) == {:miss, "build predates toolchain"}
      assert Match.present(%{}, "package_checksum") == {:miss, "build predates package_checksum"}
      assert Match.parse3("1.20.3") == {1, 20, 3}
      assert Match.inverted("b") < Match.inverted("a")
    end
  end
end
