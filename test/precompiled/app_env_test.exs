# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.AppEnvTest do
  # The project's config is loaded into the running VM before any dependency
  # compiles, :elixir, :logger and :kernel included. Whatever it sets there
  # is compared where a build recorded it and is otherwise none of this
  # library's business. Changes global app env: never async.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.{Check, CompileEnv, Env}
  alias Precompiled.Fixture, as: F
  @moduletag :tmp_dir

  @ash {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "ASHOUTER"}
  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      configure([])
      System.delete_env("PRECOMPILED_HOME")
    end)

    f = F.new(dir)
    configure(source: F.base_url(), root: f.root_path)
    System.put_env("PRECOMPILED_HOME", Path.join(dir, "home"))
    lib = Path.join(dir, "_build/rpi4_dev/lib")

    %{
      f: f,
      lib: lib,
      config: Precompiled.Config.load(),
      env: %Env{
        candidates: [
          %{name: :ash, version: "3.5.2", lock_entry: @ash},
          %{name: :jason, version: "1.4.5", lock_entry: @jason}
        ],
        lock: %{ash: @ash, jason: @jason},
        dep_sources: %{ash: @ash, jason: @jason},
        system: {"nerves_system_rpi4", "1.31.0"},
        build_lib: lib,
        deps_path: Path.join(dir, "deps")
      }
    }
  end

  defp configure(opts) do
    for {k, _} <- Application.get_all_env(:precompiled),
        do: Application.delete_env(:precompiled, k)

    Application.put_all_env([{:precompiled, opts}])
  end

  # Sets {app, key} for this test only, as a project's config would.
  defp put_app_env(app, key, value) do
    old = Application.fetch_env(app, key)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)

    Application.put_env(app, key, value)
  end

  defp run(config, env, opts \\ []) do
    opts = Keyword.put_new(opts, :config_fun, &CompileEnv.lookup/2)
    parent = self()

    capture_io(:stderr, fn ->
      capture_io(fn -> send(parent, {:report, Check.check(config, env, opts)}) end)
    end)

    assert_received {:report, {:ok, report}}
    report
  end

  defp entry(f, dep, compile_env) do
    beam = "beam #{dep}"
    vsn = if dep == "ash", do: "3.5.2", else: "1.4.5"
    app = "{application, #{dep}, [{vsn, \"#{vsn}\"}, {modules, ['Elixir.X']}]}.\n"

    %{
      "target" => "nerves_system_rpi4",
      "ebin" => [
        %{
          "path" => "ebin/Elixir.X.beam",
          "sha256" => F.file(f, beam),
          "size" => byte_size(beam),
          "mode" => 33188
        },
        %{
          "path" => "ebin/#{dep}.app",
          "sha256" => F.file(f, app),
          "size" => byte_size(app),
          "mode" => 33188
        }
      ],
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "system_version" => "1.31.0",
        "run_id" => "r",
        "image_digest" => "d",
        "deps" => %{},
        "compile_env" => compile_env,
        "package_checksum" => elem(if(dep == "ash", do: @ash, else: @jason), 7),
        "dep_env" => "prod"
      }
    }
  end

  defp ash_only(f, compile_env \\ []),
    do: %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [entry(f, "ash", compile_env)]}}}}

  defp recorded(app, path, value),
    do: %{
      "app" => app,
      "path" => path,
      "value" => Base.url_encode64(:erlang.term_to_binary(value), padding: false)
    }

  defp statuses(report), do: Enum.map(report.lines, &{&1.name, &1.status})

  describe "config :elixir, :time_zone_database naming a module not loaded yet" do
    # What ex_nvr's config does: Tzdata is a dependency, compiled after
    # this library runs, so the module does not exist yet.
    setup %{f: f} do
      F.publish(f, ash_only(f))
      put_app_env(:elixir, :time_zone_database, NotCompiledYet.TimeZoneDatabase)
      :ok
    end

    test "the batch verifies and every dependency is checked", %{config: config, env: env} do
      report = run(config, env)
      assert statuses(report) == [{"ash", :hit}, {"jason", :miss}]
      assert report.fails == 0
      refute Enum.any?(report.lines, &(&1.detail =~ ~r/malformed|crashed/))
    end

    test "the hourly root check is stamped, not silently skipped", %{
      config: config,
      env: env,
      tmp_dir: dir
    } do
      run(config, env)
      assert [_] = Path.wildcard(Path.join([dir, "home", "*", "root_checked"]))
    end
  end

  describe "a build that recorded :elixir, :time_zone_database" do
    setup %{f: f} do
      item = recorded("elixir", ["time_zone_database"], {:ok, NotCompiledYet.TimeZoneDatabase})
      F.publish(f, ash_only(f, [item]))
      :ok
    end

    test "is a HIT where the project sets the same module", %{config: config, env: env} do
      put_app_env(:elixir, :time_zone_database, NotCompiledYet.TimeZoneDatabase)
      assert [{"ash", :hit} | _] = statuses(run(config, env))
    end

    test "is a MISS naming the key where the project sets another", %{config: config, env: env} do
      put_app_env(:elixir, :time_zone_database, SomeOther.TimeZoneDatabase)
      report = run(config, env)
      assert [%{name: "ash", status: :miss, detail: detail} | _] = report.lines
      assert detail =~ "compile_env differs: elixir [:time_zone_database]"
      assert report.fails == 0
    end
  end

  # Shapes real projects put in these apps' env: modules, MFA tuples,
  # nested keywords, Erlang handler specs, IP tuples. None of them is
  # anything a build recorded here, so none changes a verdict.
  @shapes [
    {:elixir, :ansi_enabled, true},
    {:elixir, :dbg_callback, {NotCompiledYet.Dbg, :dbg, []}},
    {:logger, :backends, [RingLogger, :console]},
    {:logger, :console, [format: "$time $metadata[$level] $message\n", metadata: [:request_id]]},
    {:logger, :compile_time_purge_matching, [[level_lower_than: :info]]},
    {:logger, :handle_sasl_reports, true},
    {:kernel, :inet_dist_use_interface, {127, 0, 0, 1}},
    {:kernel, :shell_history, :enabled},
    {:kernel, :logger,
     [
       {:handler, :ring, NotCompiledYet.Handler,
        %{config: %{max_size: 1024}, formatter: {:logger_formatter, %{}}}}
     ]}
  ]

  test "other :elixir, :logger and :kernel config shapes leave every verdict as it was", %{
    f: f,
    config: config,
    env: env
  } do
    F.publish(f, ash_only(f))
    for {app, key, value} <- @shapes, do: put_app_env(app, key, value)
    report = run(config, env)
    assert statuses(report) == [{"ash", :hit}, {"jason", :miss}]
    assert report.fails == 0
  end

  describe "a crash while checking the batch" do
    # A client bug, simulated: a clock offset no config could carry makes
    # the batch's time checks raise.
    defp crashing(config), do: Map.put(config, :clock_offset_seconds, :not_a_number)

    test "is every candidate's MISS with an honest reason, never a FAIL", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      F.publish(f, ash_only(f))
      report = run(crashing(config), env)
      assert statuses(report) == [{"ash", :miss}, {"jason", :miss}]
      assert report.fails == 0

      for line <- report.lines do
        assert line.reason == {:internal, []}
        assert line.detail =~ "trust check crashed: "
        refute line.detail =~ "malformed"
      end

      refute File.exists?(Path.join(lib, "ash"))
    end

    test "removes an installed build, so Mix compiles it, and says why", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      F.publish(f, ash_only(f))
      assert [{"ash", :hit} | _] = statuses(run(config, env))
      installed = %{env | candidates: [], installed: [:ash]}

      report = run(crashing(config), installed)

      assert [%{name: "ash", status: :miss, reason: {:internal, []}, detail: detail}] =
               report.lines

      assert detail =~ "trust check crashed: "
      refute File.exists?(Path.join(lib, "ash"))
    end
  end
end
