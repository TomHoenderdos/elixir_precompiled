# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.CheckTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias NervesPrecompiled.{Check, Env}
  alias NervesPrecompiled.Env.MixProject
  alias NervesPrecompiled.Fixture, as: F
  @moduletag :tmp_dir

  @ash {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "ASHOUTER"}
  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

  setup_all do
    start_supervised!(NervesPrecompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      configure([])
      System.delete_env("NERVES_PRECOMPILED_HOME")
      System.delete_env("NERVES_PRECOMPILED_DEBUG")
    end)

    f = F.new(dir)
    configure(source: F.base_url(), root: f.root_path)
    System.put_env("NERVES_PRECOMPILED_HOME", Path.join(dir, "home"))
    lib = Path.join(dir, "_build/rpi4_dev/lib")

    %{
      f: f,
      lib: lib,
      config: NervesPrecompiled.Config.load(),
      env: %Env{
        candidates: [
          %{name: :ash, version: "3.5.2", lock_entry: @ash},
          %{name: :jason, version: "1.4.5", lock_entry: @jason}
        ],
        lock: %{ash: @ash, jason: @jason},
        system: {"nerves_system_rpi4", "1.31.0"},
        build_lib: lib,
        deps_path: Path.join(dir, "deps")
      }
    }
  end

  defp configure(opts) do
    for {k, _} <- Application.get_all_env(:nerves_precompiled),
        do: Application.delete_env(:nerves_precompiled, k)

    Application.put_all_env([{:nerves_precompiled, opts}])
  end

  # `Output.error/1` (used for FAIL lines) writes to stderr, which a plain
  # `capture_io/1` never sees. Capture both and concatenate.
  defp run_capturing(config, env, opts \\ []) do
    opts = Keyword.put_new(opts, :config_fun, fn _, _ -> :error end)

    stderr =
      capture_io(:stderr, fn ->
        stdio = capture_io(fn -> send(self(), {:report, Check.check(config, env, opts)}) end)
        send(self(), {:stdio, stdio})
      end)

    receive do
      {:stdio, stdio} -> stdio <> stderr
    end
  end

  defp good_entry(f, dep, system_version) do
    beam = "beam #{dep}"
    vsn = if dep == "ash", do: "3.5.2", else: "1.4.5"
    app = "{application, #{dep}, [{vsn, \"#{vsn}\"}]}.\n"

    %{
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
        "system_version" => system_version,
        "run_id" => "r",
        "image_digest" => "d",
        "deps" => %{},
        "compile_env" => [],
        "package_checksum" => elem(if(dep == "ash", do: @ash, else: @jason), 7)
      }
    }
  end

  test "hits, misses and the summary line", %{f: f, config: config, env: env, lib: lib} do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"nerves_system_rpi4" => good_entry(f, "ash", "1.31.0")}}
      }
    })

    out = run_capturing(config, env)
    assert_received {:report, {:ok, report}}
    assert report.hits == 1 and report.misses == 1 and report.fails == 0
    assert out =~ ~r/precompiled: ash 3\.5\.2\s+HIT\s+0\.0 MB/
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+MISS\s+not in batch/
    assert out =~ "precompiled: 1 hit, 1 miss, 0 fail of 2 deps"
    assert File.exists?(Path.join(lib, "ash/.mix/compile.elixir_scm"))
    report_file = Path.join(lib, ".precompiled/report.json") |> File.read!() |> :json.decode()

    assert [%{"name" => "ash", "status" => "hit"}, %{"name" => "jason", "status" => "miss"}] =
             report_file["lines"]
  end

  test "a tampered manifest is a FAIL and installs nothing", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"nerves_system_rpi4" => good_entry(f, "ash", "1.31.0")}}
      }
    })

    F.tamper_manifest(f, "ash")
    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{fails: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+manifest hash differs from batch/
    refute File.exists?(Path.join(lib, "ash"))
  end

  test "a downloaded .app whose compile_env differs is a FAIL", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    e = good_entry(f, "ash", "1.31.0")
    app = "{application, ash, [{vsn, \"3.5.2\"}, {compile_env, [{ash, [mode], {ok, fast}}]}]}.\n"

    e =
      update_in(e["ebin"], fn files ->
        Enum.map(files, fn
          %{"path" => "ebin/ash.app"} = x ->
            %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

          x ->
            x
        end)
      end)

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}})
    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{fails: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+downloaded \.app: compile_env differs: ash \[:mode\]/
    refute File.exists?(Path.join(lib, "ash"))
  end

  test "an invalid batch fails every candidate", %{f: f, config: config, env: env} do
    F.publish(f, %{}, expires: "2020-01-01T00:00:00Z")
    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
    assert out =~ ~r/FAIL\s+batch expired/
  end

  test "a malformed manifest fails its candidate without crashing the run", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{"ash" => %{"versions" => ["oops"]}})
    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{fails: 1, misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+candidate crashed: /
    assert File.exists?(Path.join(lib, ".precompiled/report.json"))
  end

  test "already-compiled deps are left alone", %{f: f, config: config, env: env, lib: lib} do
    decimal = {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", "DOUTER"}
    File.mkdir_p!(Path.join(lib, "decimal/ebin"))
    File.write!(Path.join(lib, "decimal/ebin/keep.beam"), "keep")

    F.publish(f, %{
      "decimal" => %{
        "versions" => %{"2.3.0" => %{"nerves_system_rpi4" => good_entry(f, "ash", "1.31.0")}}
      }
    })

    deps =
      MixProject.candidates_from(
        [%Mix.Dep{app: :decimal, status: {:ok, "2.3.0"}, scm: Hex.SCM}],
        %{decimal: decimal}
      )

    assert deps == []
    assert run_capturing(config, %{env | candidates: deps, lock: %{decimal: decimal}}) == ""
    assert_received {:report, :nothing_to_do}
    assert File.read!(Path.join(lib, "decimal/ebin/keep.beam")) == "keep"
  end

  test "no candidates: no network, no output, no report", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{}, sequence: 3)
    env = %{env | candidates: []}

    assert run_capturing(config, env) == ""
    assert_received {:report, :nothing_to_do}
    refute File.exists?(Path.join(lib, ".precompiled/report.json"))
    # The batch fetch would have stored the sequence under the home dir.
    refute File.exists?(System.get_env("NERVES_PRECOMPILED_HOME"))
  end

  test "no candidates in DEBUG mode prints one line", %{config: config, env: env} do
    System.put_env("NERVES_PRECOMPILED_DEBUG", "1")
    on_exit(fn -> System.delete_env("NERVES_PRECOMPILED_DEBUG") end)

    out = run_capturing(config, %{env | candidates: []})
    assert_received {:report, :nothing_to_do}
    assert [_one] = String.split(out, "\n", trim: true)
    assert out =~ "precompiled: no dependencies to check"
  end

  test "an unwritable build_lib degrades report.json to one warning, run still completes", %{
    f: f,
    config: config,
    env: env,
    tmp_dir: dir
  } do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"nerves_system_rpi4" => good_entry(f, "ash", "1.31.0")}}
      }
    })

    blocker = Path.join(dir, "_build_file")
    File.write!(blocker, "a file where _build/<t>/lib should be")

    out = run_capturing(config, %{env | build_lib: blocker})
    assert_received {:report, {:ok, report}}
    # build_lib is a plain file, so ash's install (an otherwise-HIT
    # candidate) fails to stage into it, and jason stays a MISS as usual.
    # What this test exercises is that write_report's own failure to create
    # "<blocker>/.precompiled" only warns instead of raising.
    assert report.hits == 0 and report.misses == 1 and report.fails == 1
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+install failed: /
    assert out =~ ~r/jason 1\.4\.5\s+MISS\s+not in batch/
    warnings = out |> String.split("\n") |> Enum.filter(&(&1 =~ "could not write report.json"))
    assert length(warnings) == 1
  end

  test "a throw inside a candidate is that candidate's FAIL", %{f: f, config: config, env: env} do
    e = good_entry(f, "ash", "1.31.0")
    app = "{application, ash, [{vsn, \"3.5.2\"}, {compile_env, [{ash, [mode], {ok, fast}}]}]}.\n"

    e =
      update_in(e["ebin"], fn files ->
        Enum.map(files, fn
          %{"path" => "ebin/ash.app"} = x ->
            %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

          x ->
            x
        end)
      end)

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}})
    out = run_capturing(config, env, config_fun: fn _, _ -> throw(:boom) end)
    assert_received {:report, {:ok, %{fails: 1, misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+candidate crashed: :boom/
  end

  defp with_beam(f, entry, beam) do
    app = "{application, ash, [{vsn, \"3.5.2\"}, {modules, ['Elixir.X']}]}.\n"

    update_in(entry["ebin"], fn files ->
      Enum.map(files, fn
        %{"path" => "ebin/ash.app"} = x ->
          %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

        %{"path" => "ebin/Elixir.X.beam"} = x ->
          %{x | "sha256" => F.file(f, beam), "size" => byte_size(beam)}
      end)
    end)
  end

  test "HITs whose beams carry no debug_info are counted once", %{f: f, config: config, env: env} do
    e = with_beam(f, good_entry(f, "ash", "1.31.0"), "beam bytes")
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}})

    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{hits: 1}}}

    assert out =~
             "precompiled: 1 hits carry stripped beams; protocols they define are not " <>
               "consolidated and Dialyzer has no types for them"
  end

  test "HITs with debug_info print no stripped line", %{f: f, config: config, env: env} do
    {:module, _, beam, _} =
      defmodule WithDbgi do
        @moduledoc false
        @spec x() :: :x
        def x(), do: :x
      end

    e = with_beam(f, good_entry(f, "ash", "1.31.0"), beam)
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}})

    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{hits: 1}}}
    refute out =~ "stripped"
  end

  for {app, label} <- [
        {"{application, other, [{vsn, \"3.5.2\"}]}.\n", "other 3.5.2"},
        {"{application, ash, [{vsn, \"9.9.9\"}]}.\n", "ash 9.9.9"},
        {"{application, ash, []}.\n", "ash nil"}
      ] do
    test "a downloaded .app naming #{label} is a FAIL", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      app = unquote(app)

      e =
        update_in(good_entry(f, "ash", "1.31.0")["ebin"], fn files ->
          Enum.map(files, fn
            %{"path" => "ebin/ash.app"} = x ->
              %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

            x ->
              x
          end)
        end)

      F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}})
      out = run_capturing(config, env)
      assert_received {:report, {:ok, %{fails: 1}}}
      assert out =~ "FAIL  downloaded .app names #{unquote(label)}"
      refute File.exists?(Path.join(lib, "ash"))
    end
  end
end
