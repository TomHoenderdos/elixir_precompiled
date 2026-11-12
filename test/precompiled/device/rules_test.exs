# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.RulesTest do
  use ExUnit.Case, async: true
  import Precompiled.DeviceFixture
  alias Precompiled.Device.Rules
  alias Precompiled.Match

  describe "build method (host rule 9)" do
    test "a recorded manager is not compared on a device" do
      for manager <- ["mix", "rebar3", "make"] do
        b = put_in(build(), ["build", "manager"], manager)
        assert {:ok, _} = Rules.check(b, "recon", ctx())
      end
    end
  end

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

      assert {:miss, "build has no system version", 0} = Rules.check(b, "x", ctx())
    end

    test "a missing system_version key gives the same clean message, not an empty interpolation" do
      b = build(target: "nerves_system_rpi4", system_version: "2.2.1")
      b = update_in(b["build"], &Map.delete(&1, "system_version"))

      assert {:miss, "build has no system version", 0} = Rules.check(b, "x", ctx())
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

    test "optional_applications count only when present or requested, never because locked" do
      spec = fn _ -> {:ok, [applications: [:kernel], optional_applications: [:jason]]} end
      assert {:ok, %{needs: [], skipped: []}} = Rules.check(build(), "x", ctx(app_spec: spec))

      locked = build(deps: %{"jason" => %{"version" => "1.4.4", "checksum" => "j"}})

      assert {:ok, %{needs: [], skipped: [:jason]}} =
               Rules.check(locked, "x", ctx(app_spec: spec))

      assert {:ok, %{needs: [%{app: :jason, version: "1.4.4"}], skipped: []}} =
               Rules.check(locked, "x", ctx(app_spec: spec, requested: [:jason]))
    end

    test "an app in both applications and optional_applications is optional" do
      # rustler_precompiled's .app: Mix lists an optional dep in both.
      spec = app_spec([:kernel, :rustler], optional: [:rustler])

      assert {:ok, %{needs: [], skipped: [:rustler]}} =
               Rules.check(build(), "x", ctx(app_spec: spec))
    end

    test "an optional app the device has is checked as a required one" do
      spec = app_spec([:kernel, :rustler], optional: [:rustler])
      locked = build(deps: %{"rustler" => %{"version" => "0.38.0", "checksum" => "r"}})

      assert {:ok, %{needs: [], skipped: []}} =
               Rules.check(
                 locked,
                 "x",
                 ctx(app_spec: spec, env: env(present: %{rustler: "0.38.0"}))
               )

      assert {:miss, "built against rustler 0.38.0, device has 0.37.0", 6} =
               Rules.check(
                 locked,
                 "x",
                 ctx(app_spec: spec, env: env(present: %{rustler: "0.37.0"}))
               )
    end

    test "a dep the build's declared marks optional is skipped too" do
      declared = [%{"app" => "decimal", "name" => "decimal", "optional" => true}]
      deps = %{"decimal" => %{"version" => "2.3.0", "checksum" => "d"}}
      spec = app_spec([:kernel, :decimal])

      assert {:ok, %{needs: [], skipped: [:decimal]}} =
               Rules.check(build(declared: declared, deps: deps), "x", ctx(app_spec: spec))
    end

    test "a compile_env item of a skipped optional app never refuses the build" do
      deps = %{"kino" => %{"version" => "0.19.1", "checksum" => "k"}}
      item = %{"app" => "kino", "path" => ["mode"], "value" => enc({:ok, :live})}
      b = build(deps: deps, compile_env: [item])
      spec = app_spec([:kernel, :kino], optional: [:kino])

      assert {:ok, %{needs: [], skipped: [:kino], deferred_env: []}} =
               Rules.check(b, "x", ctx(app_spec: spec))
    end

    test "a required app missing is still a miss, whatever is optional" do
      spec = app_spec([:kernel, :ssl, :jason], optional: [:jason])

      assert {:miss, "needs ssl, which this firmware does not include", 6} =
               Rules.check(build(), "x", ctx(app_spec: spec, env: env(present: %{})))
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

    test "a crashing app_spec callback refuses, keeping the rule index it happened in" do
      spec = fn _ -> raise "boom" end

      assert {:miss, "check raised", 6} = Rules.check(build(), "x", ctx(app_spec: spec))
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

    test "no declared field but a non-empty deps lock: rule 8 is skipped, and the line says so" do
      b = build(declared: nil, deps: @tel)

      assert {:ok, %{warnings: ["build predates declared: optional integrations not checked"]}} =
               Rules.check(b, "x", ctx())
    end

    test "no declared field and an empty deps lock: nothing to declare, no warning" do
      assert {:ok, %{warnings: []}} = Rules.check(build(declared: nil), "x", ctx())
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

    test "a compressed or fun-bearing recorded value refuses, even if equal" do
      value = :binary.copy("x", 1000)
      compressed = :erlang.term_to_binary({:ok, value}, [:compressed])
      assert <<131, 80, _::binary>> = compressed
      packed = Base.url_encode64(compressed, padding: false)

      for {enc_value, config_value} <- [
            {packed, value},
            {enc({:ok, &Enum.map/2}), &Enum.map/2}
          ] do
        item = %{"app" => "logger", "path" => ["level"], "value" => enc_value}
        ctx = ctx(config: fn "logger", ["level"] -> {:ok, config_value} end)

        assert {:miss, "compile_env differs: logger [:level]", 8} =
                 Rules.check(build(compile_env: [item]), "x", ctx)
      end
    end

    test "a key that is not set on a loaded app refuses against a recorded value" do
      item = %{"app" => "logger", "path" => ["nope"], "value" => enc({:ok, :info})}
      ctx = ctx(config: fn "logger", ["nope"] -> :error end)

      assert {:miss, "compile_env differs: logger [:nope]", 8} =
               Rules.check(build(compile_env: [item]), "x", ctx)
    end

    test "an app still to be installed waits; an app absent everywhere does not" do
      tel = %{"app" => "telemetry", "path" => ["k"], "value" => enc(:error)}
      ghost = %{"app" => "no_such_app_anywhere", "path" => ["k"], "value" => enc(:error)}
      b = build(deps: @tel, compile_env: [tel, ghost])
      ctx = ctx(app_spec: app_spec([:kernel, :telemetry]), loaded: [{:kernel, ~c"", ~c"10.4"}])

      # telemetry is being installed (it is in `needs`), so it still waits for
      # application:load/1; "no_such_app_anywhere" is not present, not loaded
      # and not planned, so there is nothing left to wait for and it is
      # checked right away, against the ctx().config default of :error.
      assert {:ok, %{deferred_env: [^tel]}} = Rules.check(b, "x", ctx)
    end

    test "an app absent everywhere is checked now, against :error, and can refuse" do
      ghost = %{"app" => "no_such_app_anywhere", "path" => ["k"], "value" => enc({:ok, :info})}

      assert {:miss, "compile_env differs: no_such_app_anywhere [:k]", 8} =
               Rules.check(build(compile_env: [ghost]), "x", ctx())
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

    test "a pre-release never beats a final release when no requirement names it" do
      m = manifest(%{"2.5.6" => [build()], "3.0.0-rc.0" => [build()]})
      assert {:ok, "2.5.6", _, _} = Rules.select(m, "recon", nil, ctx())
      assert {:ok, "2.5.6", _, _} = Rules.select(m, "recon", ">= 2.0.0", ctx())
    end

    test "a requirement that names a pre-release can still select it" do
      m = manifest(%{"2.5.6" => [build()], "3.0.0-rc.0" => [build()]})
      assert {:ok, "3.0.0-rc.0", _, _} = Rules.select(m, "recon", "3.0.0-rc.0", ctx())
      assert {:ok, "3.0.0-rc.0", _, _} = Rules.select(m, "recon", ">= 3.0.0-rc.0", ctx())
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

      ctx = ctx(installed: %{x: Precompiled.Match.files_hash(a)})

      assert {:ok, _, %{"build" => %{"run_id" => "a"}}, _} =
               Rules.select(manifest(%{"1.0.0" => [b, a]}), "x", nil, ctx)
    end
  end

  describe "rule 1 across releases (the batch's systems table in ctx.systems)" do
    @tc "nerves_toolchain_aarch64_nerves_linux_gnu"
    @systems %{
      "nerves_system_rpi4" => %{
        "2.2.1" => %{
          "toolchain" => %{"package" => @tc, "version" => "15.3.2", "series" => "15.3"},
          "otp" => "29.1",
          "libs" => %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_2.38"]}
        },
        "2.4.0" => %{
          "toolchain" => %{"package" => @tc, "version" => "15.4.0", "series" => "15.4"},
          "otp" => "29.1",
          "libs" => %{"libc.so.6" => ["GLIBC_2.17"]}
        }
      }
    }

    # A portable native build for `version` of the device's system.
    defp xbuild(version, over \\ %{}) do
      b = build(target: "nerves_system_rpi4", system_version: version, run_id: "r" <> version)

      update_in(
        b["build"],
        &Map.merge(
          &1,
          Map.merge(
            %{
              "native" => true,
              "portable" => true,
              "otp_full" => "29.0.2",
              "toolchain" => %{"package" => @tc, "version" => "15.3.1"},
              "elf" => %{"needs" => %{"libc.so.6" => ["GLIBC_2.17"]}}
            },
            over
          )
        )
      )
    end

    test "a native build for another release passes only through the table" do
      b = xbuild("2.2.0")

      assert {:miss, "built for nerves_system_rpi4 2.2.0, project has 2.2.1", 0} =
               Rules.check(b, "circuits_gpio", ctx())

      assert {:miss, "built for nerves_system_rpi4 2.2.0, project has 2.2.1", 0} =
               Rules.check(b, "circuits_gpio", ctx(systems: nil))

      assert {:ok, _} = Rules.check(b, "circuits_gpio", ctx(systems: @systems))
    end

    test "the table's toolchain series, OTP and libraries decide, as on the host" do
      ctx = ctx(systems: @systems)

      assert {:miss, "built for nerves_system_rpi4 2.2.0 (toolchain 15.4), " <> _, 0} =
               Rules.check(
                 xbuild("2.2.0", %{"toolchain" => %{"package" => @tc, "version" => "15.4.0"}}),
                 "x",
                 ctx
               )

      assert {:miss, "built on OTP 29.2, release has 29.1", 0} =
               Rules.check(xbuild("2.2.0", %{"otp_full" => "29.2"}), "x", ctx)

      assert {:miss, "libssl.so.3 missing on target", 0} =
               Rules.check(
                 xbuild("2.2.0", %{"elf" => %{"needs" => %{"libssl.so.3" => []}}}),
                 "x",
                 ctx
               )

      assert {:miss, "nerves_system_rpi4 2.2.1 not yet known to the portal", 0} =
               Rules.check(
                 xbuild("2.2.0"),
                 "x",
                 ctx(systems: %{"nerves_system_rpi4" => %{}})
               )
    end

    test "a native build for another release without elf facts misses" do
      no_elf = update_in(xbuild("2.2.0")["build"], &Map.delete(&1, "elf"))

      assert {:miss, "build predates elf", 0} =
               Rules.check(no_elf, "x", ctx(systems: @systems))

      assert {:miss, "build predates elf", 0} =
               Rules.check(xbuild("2.2.0", %{"elf" => nil}), "x", ctx(systems: @systems))

      assert {:ok, _} =
               Rules.check(
                 xbuild("2.2.0", %{"elf" => %{"needs" => %{}}}),
                 "x",
                 ctx(systems: @systems)
               )
    end

    test "an exact-release native build without elf facts passes" do
      no_elf = update_in(xbuild("2.2.1")["build"], &Map.delete(&1, "elf"))
      assert {:ok, _} = Rules.check(no_elf, "x", ctx(systems: @systems))
    end

    test "a native build that is not portable stays exact-release only" do
      b = xbuild("2.2.0", %{"portable" => false})

      assert {:miss, "built for nerves_system_rpi4 2.2.0, project has 2.2.1", 0} =
               Rules.check(b, "x", ctx(systems: @systems))
    end

    test "the exact release passes with or without a table" do
      b = xbuild("2.2.1", %{"elf" => %{"needs" => %{"libnothere.so.1" => []}}})
      assert {:ok, _} = Rules.check(b, "x", ctx())
      assert {:ok, _} = Rules.check(b, "x", ctx(systems: @systems))
    end

    test "selection takes the exact release, else the closest older, else the lowest newer" do
      ctx = ctx(systems: @systems)
      select = fn builds -> Rules.select(manifest(%{"1.0.0" => builds}), "x", nil, ctx) end

      assert {:ok, _, %{"build" => %{"system_version" => "2.2.1"}}, _} =
               select.([xbuild("2.2.0"), xbuild("2.2.1"), xbuild("2.3.0")])

      assert {:ok, _, %{"build" => %{"system_version" => "2.2.0"}}, _} =
               select.([xbuild("2.1.0"), xbuild("2.3.0"), xbuild("2.2.0")])

      assert {:ok, _, %{"build" => %{"system_version" => "2.3.0"}}, _} =
               select.([xbuild("2.5.0"), xbuild("2.3.0")])

      # An installed build is preferred only among the nearest release.
      installed = ctx(systems: @systems, installed: %{x: Match.files_hash(xbuild("2.1.0"))})

      assert {:ok, _, %{"build" => %{"system_version" => "2.2.0"}}, _} =
               Rules.select(
                 manifest(%{"1.0.0" => [xbuild("2.1.0"), xbuild("2.2.0")]}),
                 "x",
                 nil,
                 installed
               )
    end

    test "a release that is not semver is ordered last and never crashes selection" do
      ctx = ctx(systems: @systems)

      assert {:ok, _, %{"build" => %{"system_version" => "junk"}}, _} =
               Rules.select(manifest(%{"1.0.0" => [xbuild("junk")]}), "x", nil, ctx)

      assert {:ok, _, %{"build" => %{"system_version" => "2.3.0"}}, _} =
               Rules.select(
                 manifest(%{"1.0.0" => [xbuild("junk"), xbuild("2.3.0")]}),
                 "x",
                 nil,
                 ctx
               )
    end
  end

  defp enc(term), do: Base.url_encode64(:erlang.term_to_binary(term), padding: false)
end
