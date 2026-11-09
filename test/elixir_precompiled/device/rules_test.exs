# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Device.RulesTest do
  use ExUnit.Case, async: true
  import ElixirPrecompiled.DeviceFixture
  alias ElixirPrecompiled.Device.Rules

  describe "rule 1: target" do
    test "pure_elixir passes on any system, and on none" do
      assert {:ok, _} = Rules.check(build(), "recon", ctx())
      assert {:ok, _} = Rules.check(build(), "recon", ctx(env: env(system: nil)))
    end

    test "the device's system at exactly its version" do
      b = build(target: "nerves_system_rpi4", system_version: "2.2.1")
      assert {:ok, _} = Rules.check(b, "circuits_gpio", ctx())

      assert {:miss, "built for nerves_system_rpi4 2.2.0, project has 2.2.1", 0} =
               Rules.check(
                 %{b | "build" => %{b["build"] | "system_version" => "2.2.0"}},
                 "circuits_gpio",
                 ctx()
               )
    end

    test "a null system_version never passes" do
      b = build(target: "nerves_system_rpi4", system_version: nil)

      assert {:miss, "built for nerves_system_rpi4 (no system version)", 0} =
               Rules.check(b, "x", ctx())
    end

    test "a forked system gets pure_elixir only (Q4: no mapping)" do
      b = build(target: "nerves_system_rpi4", system_version: "2.2.1")
      ctx = ctx(env: env(system: {"nerves_system_rpi4_midi", "2.2.1"}))

      assert {:miss, "not built for this system (nerves_system_rpi4)", 0} =
               Rules.check(b, "x", ctx)
    end

    test "a device with no known system gets pure_elixir only" do
      b = build(target: "nerves_system_rpi4", system_version: "2.2.1")

      assert {:miss, "not built for this system (nerves_system_rpi4)", 0} =
               Rules.check(b, "x", ctx(env: env(system: nil)))

      host = build(target: "host", system_version: "")

      assert {:miss, "not built for this system (host)", 0} =
               Rules.check(host, "x", ctx(env: env(system: nil)))
    end

    test "a platform that is not the system's conventional name adds text only" do
      b = build(target: "nerves_system_rpi4", system_version: "2.2.1", declared: [])
      assert {:ok, %{warnings: []}} = Rules.check(b, "x", ctx(env: env(platform: "rpi4")))
      assert {:ok, %{warnings: [w]}} = Rules.check(b, "x", ctx(env: env(platform: "my_board")))
      assert w =~ "KV platform my_board"
    end
  end

  describe "rules 2 to 6" do
    test "toolchain, Elixir, OTP, dep_env, checksum, in that order" do
      assert {:miss, "build predates toolchain", 1} = Rules.check(build(elixir: nil), "x", ctx())

      assert {:miss, "built with Elixir 1.20.4, running 1.20.3", 2} =
               Rules.check(build(elixir: "1.20.4"), "x", ctx())

      assert {:miss, "built on OTP 28, running 29", 3} = Rules.check(build(otp: "28"), "x", ctx())

      assert {:miss, "built with env dev, dependency compiles as prod", 4} =
               Rules.check(put_in(build()["build"]["dep_env"], "dev"), "x", ctx())

      assert {:miss, "build predates package_checksum", 5} =
               Rules.check(build(checksum: nil), "x", ctx())
    end

    test "a missing dep_env is a miss, not a pass" do
      b = update_in(build()["build"], &Map.delete(&1, "dep_env"))
      assert {:miss, "build predates dep_env", 4} = Rules.check(b, "x", ctx())
    end

    test "a closure member pinned by another build's lock must have that checksum" do
      ctx = ctx(pin: %{version: "1.3.0", checksum: "other"})

      assert {:miss, "package checksum differs from the lock of the build that needs it", 5} =
               Rules.check(build(checksum: "pkgsum"), "telemetry", ctx)

      assert {:ok, _} =
               Rules.check(
                 build(checksum: "pkgsum"),
                 "telemetry",
                 ctx(pin: %{version: "1.3.0", checksum: "pkgsum"})
               )
    end
  end

  describe "rule 7: runtime dependencies" do
    @tel %{"telemetry" => %{"version" => "1.3.0", "checksum" => "tsum"}}

    test "a build-only dependency (elixir_make) is not checked" do
      b = build(deps: %{"elixir_make" => %{"version" => "0.9.0", "checksum" => "m"}})
      assert {:ok, %{needs: []}} = Rules.check(b, "circuits_gpio", ctx())
    end

    test "an absent runtime dependency joins the plan at the lock's version" do
      b = build(deps: @tel)
      ctx = ctx(app_spec: app_spec([:kernel, :stdlib, :elixir, :telemetry]))

      assert {:ok, %{needs: [%{app: :telemetry, version: "1.3.0", checksum: "tsum"}]}} =
               Rules.check(b, "x", ctx)
    end

    test "a present one at another version is refused" do
      b = build(deps: @tel)

      ctx =
        ctx(env: env(present: %{telemetry: "1.2.1"}), app_spec: app_spec([:kernel, :telemetry]))

      assert {:miss, "built against telemetry 1.3.0, device has 1.2.1", 6} =
               Rules.check(b, "x", ctx)
    end

    test "present at the same version passes: name and exact version only (Q1)" do
      b = build(deps: @tel)

      ctx =
        ctx(env: env(present: %{telemetry: "1.3.0"}), app_spec: app_spec([:kernel, :telemetry]))

      assert {:ok, %{needs: [], warnings: w}} = Rules.check(b, "x", ctx)
      refute Enum.any?(w, &(&1 =~ "telemetry"))
    end

    test "present but not loaded (in the release lib/ only) counts the same" do
      b = build(deps: @tel)
      e = env(present: %{})
      e = %{e | present: Map.put(e.present, :telemetry, %{vsn: "1.3.0", loaded?: false})}

      assert {:ok, %{needs: []}} =
               Rules.check(b, "x", ctx(env: e, app_spec: app_spec([:kernel, :telemetry])))
    end

    test "an app this tool already loaded in this VM counts as present at that version" do
      b = build(deps: @tel)
      spec = app_spec([:kernel, :telemetry])

      assert {:ok, %{needs: []}} =
               Rules.check(b, "x", ctx(active: %{telemetry: "1.3.0"}, app_spec: spec))

      assert {:miss, "built against telemetry 1.3.0, device has 1.2.0", 6} =
               Rules.check(b, "x", ctx(active: %{telemetry: "1.2.0"}, app_spec: spec))
    end

    test "a runtime app neither present nor in the lock (ssl left out of the firmware) is refused" do
      ctx = ctx(app_spec: app_spec([:kernel, :ssl]), env: env(present: %{}))

      assert {:miss, "needs ssl, which this firmware does not include", 6} =
               Rules.check(build(), "x", ctx)
    end

    test "optional_applications count only when present or locked" do
      spec = fn _ -> {:ok, [applications: [:kernel], optional_applications: [:jason]]} end
      assert {:ok, %{needs: []}} = Rules.check(build(), "x", ctx(app_spec: spec))

      locked = build(deps: %{"jason" => %{"version" => "1.4.4", "checksum" => "j"}})

      assert {:ok, %{needs: [%{app: :jason, version: "1.4.4"}]}} =
               Rules.check(locked, "x", ctx(app_spec: spec))
    end

    test "included_applications are part of the closure" do
      spec = app_spec([:kernel], included: [:ssl])

      assert {:miss, "needs ssl, which this firmware does not include", 6} =
               Rules.check(build(), "x", ctx(app_spec: spec))
    end

    test "an unreadable .app is the reason" do
      spec = fn _ -> {:fail, ".app does not match its hash"} end

      assert {:miss, ".app does not match its hash", 6} =
               Rules.check(build(), "x", ctx(app_spec: spec))
    end

    test "a build without a deps lock cannot be checked and is refused" do
      b = update_in(build()["build"], &Map.delete(&1, "deps"))
      assert {:miss, "build predates deps lock", 6} = Rules.check(b, "x", ctx())
    end

    test "a malformed deps entry or .app property list is refused" do
      bad = build(deps: %{"telemetry" => %{"version" => 1}})
      spec = app_spec([:kernel, :telemetry])
      assert {:miss, "malformed entry", _} = Rules.check(bad, "x", ctx(app_spec: spec))

      odd = fn _ -> {:ok, [applications: ["kernel"]]} end
      assert {:miss, "malformed entry", _} = Rules.check(build(), "x", ctx(app_spec: odd))
    end
  end

  describe "rule 8: declared dependencies rank, never refuse" do
    test "a build without an optional dep the device has carries it as uncovered" do
      declared = [
        %{"app" => "jason", "name" => "jason", "requirement" => "~> 1.0", "optional" => true}
      ]

      ctx = ctx(env: env(present: %{jason: "1.4.5"}))

      assert {:ok, %{uncovered: [:jason], warnings: [w]}} =
               Rules.check(build(declared: declared), "x", ctx)

      assert w == "built without jason (present here): its jason integration is off"
    end

    test "no declared field: rule 8 is skipped, and the line says so" do
      assert {:ok, %{warnings: ["build predates declared: optional integrations not checked"]}} =
               Rules.check(build(declared: nil), "x", ctx())
    end

    test "a malformed declared field is refused" do
      assert {:miss, "malformed entry", 7} = Rules.check(build(declared: "jason"), "x", ctx())
    end
  end

  describe "rule 9: compile_env" do
    test "items for present apps are compared now, items for the app itself later" do
      present_item = %{"app" => "logger", "path" => ["level"], "value" => enc({:ok, :info})}
      own_item = %{"app" => "x", "path" => ["mode"], "value" => enc(:error)}
      ctx = ctx(config: fn "logger", ["level"] -> {:ok, :info} end)

      assert {:ok, %{deferred_env: [^own_item]}} =
               Rules.check(build(compile_env: [present_item, own_item]), "x", ctx)

      bad = ctx(config: fn "logger", ["level"] -> {:ok, :debug} end)

      assert {:miss, "compile_env differs: logger [:level]", 8} =
               Rules.check(build(compile_env: [present_item]), "x", bad)
    end

    test "items for an app that is not loaded, or is still to be installed, wait" do
      tel = %{"app" => "telemetry", "path" => ["k"], "value" => enc(:error)}
      ghost = %{"app" => "no_such_app_anywhere", "path" => ["k"], "value" => enc(:error)}
      b = build(deps: @tel, compile_env: [tel, ghost])
      ctx = ctx(app_spec: app_spec([:kernel, :telemetry]), loaded: [{:kernel, ~c"", ~c"10.4"}])
      assert {:ok, %{deferred_env: [^tel, ^ghost]}} = Rules.check(b, "x", ctx)
    end

    test "a missing or malformed compile_env is refused" do
      b = update_in(build()["build"], &Map.delete(&1, "compile_env"))
      assert {:miss, "build predates compile_env", 8} = Rules.check(b, "x", ctx())

      own = %{"app" => "x", "path" => "mode", "value" => enc(:error)}
      assert {:miss, "malformed entry", 8} = Rules.check(build(compile_env: [own]), "x", ctx())
    end
  end

  describe "malformed entries" do
    test "never pass" do
      assert {:miss, "malformed entry", 0} = Rules.check("nope", "x", ctx())
      assert {:miss, _, _} = Rules.check(%{"target" => "pure_elixir", "build" => "x"}, "x", ctx())
      assert {:miss, _, _} = Rules.check(%{"target" => "pure_elixir"}, "x", ctx())
      assert {:miss, _, 5} = Rules.check(build(checksum: 42), "x", ctx())
    end
  end

  describe "select/4" do
    test "newest version with a passing build; exact; requirement" do
      m = manifest(%{"2.5.5" => [build()], "2.5.6" => [build()], "3.0.0" => [build(otp: "28")]})
      assert {:ok, "2.5.6", _, _} = Rules.select(m, "recon", nil, ctx())
      assert {:ok, "2.5.5", _, _} = Rules.select(m, "recon", "2.5.5", ctx())
      assert {:ok, "2.5.6", _, _} = Rules.select(m, "recon", "~> 2.5", ctx())
      assert {:miss, "built on OTP 28, running 29"} = Rules.select(m, "recon", "3.0.0", ctx())
      assert {:miss, "no version matches ~> 4.0"} = Rules.select(m, "recon", "~> 4.0", ctx())
    end

    test "nothing passes anywhere: the newest version's furthest reason" do
      m =
        manifest(%{
          "1.0.0" => [build(otp: "27")],
          "2.0.0" => [build(otp: "28"), build(elixir: "1.20.9")]
        })

      assert {:miss, "built on OTP 28, running 29"} = Rules.select(m, "x", nil, ctx())
    end

    test "an empty manifest, an unparsable requirement and an unparsable version" do
      assert {:miss, "no versions published"} = Rules.select(manifest(%{}), "x", nil, ctx())
      m = manifest(%{"1.0.0" => [build()], "garbage" => [build()]})
      assert {:miss, "no version matches >>> 1"} = Rules.select(m, "x", ">>> 1", ctx())
      assert {:ok, "1.0.0", _, _} = Rules.select(m, "x", nil, ctx())
    end

    test "device ranking: system build over pure_elixir (Q6), fewer closure installs first" do
      sys = build(target: "nerves_system_rpi4", system_version: "2.2.1", run_id: "s")
      pure = build(run_id: "p")
      m = manifest(%{"1.0.0" => [pure, sys]})
      assert {:ok, _, %{"target" => "nerves_system_rpi4"}, _} = Rules.select(m, "x", nil, ctx())

      needy =
        build(
          target: "nerves_system_rpi4",
          system_version: "2.2.1",
          deps: %{"telemetry" => %{"version" => "1.3.0", "checksum" => "t"}},
          run_id: "n"
        )

      spec = fn b ->
        {:ok,
         [
           applications:
             if(b["build"]["run_id"] == "n", do: [:kernel, :telemetry], else: [:kernel])
         ]}
      end

      m2 = manifest(%{"1.0.0" => [needy, pure]})

      assert {:ok, _, %{"build" => %{"run_id" => "p"}}, _} =
               Rules.select(m2, "x", nil, ctx(app_spec: spec))
    end

    test "the installed build ranks first among passing ones" do
      a = build(run_id: "a")

      b =
        build(
          run_id: "b",
          ebin: [
            %{
              "path" => "ebin/x.app",
              "sha256" => String.duplicate("b", 64),
              "size" => 1,
              "mode" => 420
            }
          ]
        )

      ctx = ctx(installed: %{x: ElixirPrecompiled.Match.files_hash(a)})

      assert {:ok, _, %{"build" => %{"run_id" => "a"}}, _} =
               Rules.select(manifest(%{"1.0.0" => [b, a]}), "x", nil, ctx)
    end
  end

  defp enc(term), do: Base.url_encode64(:erlang.term_to_binary(term), padding: false)
end
