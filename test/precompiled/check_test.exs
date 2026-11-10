# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CheckTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.{Check, Env, Match}
  alias Precompiled.Env.MixProject
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
      System.delete_env("PRECOMPILED_DEBUG")
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

  defp good_entry(f, dep, system_version, target \\ "nerves_system_rpi4") do
    beam = "beam #{dep}"
    vsn = if dep == "ash", do: "3.5.2", else: "1.4.5"
    app = "{application, #{dep}, [{vsn, \"#{vsn}\"}, {modules, ['Elixir.X']}]}.\n"

    %{
      "target" => target,
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
        "package_checksum" => elem(if(dep == "ash", do: @ash, else: @jason), 7),
        "dep_env" => "prod"
      }
    }
  end

  test "hits, misses and the summary line", %{f: f, config: config, env: env, lib: lib} do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}
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
    assert report_file["format"] == 1

    assert [%{"name" => "ash", "status" => "hit"}, %{"name" => "jason", "status" => "miss"}] =
             report_file["lines"]
  end

  test "a dep's build overrides and manager reach the rules (rule 9)", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    entry = put_in(good_entry(f, "ash", "1.31.0"), ["build", "manager"], "rebar3")

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [entry]}}}})
    env = %{env | candidates: [hd(env.candidates)]}

    out =
      run_capturing(config, %{env | build_methods: %{ash: %{manager: "mix", overrides: []}}})

    assert_received {:report, {:ok, %{hits: 0, misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+MISS\s+built with rebar3, project builds with mix/

    out =
      run_capturing(config, %{
        env
        | build_methods: %{ash: %{manager: "rebar3", overrides: [:system_env]}}
      })

    assert_received {:report, {:ok, %{hits: 0, misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+MISS\s+project sets :system_env for this dependency/

    run_capturing(config, %{env | build_methods: %{ash: %{manager: "rebar3", overrides: []}}})
    assert_received {:report, {:ok, %{hits: 1}}}
    assert File.exists?(Path.join(lib, "ash/.mix/compile.elixir_scm"))

    # Deps that did not load: every candidate misses, naming the cause.
    out = run_capturing(config, %{env | build_methods: {:unknown, "lock is broken"}})
    assert_received {:report, {:ok, %{hits: 0, misses: 1}}}

    assert out =~
             ~r/ash 3\.5\.2\s+MISS\s+build method unknown \(deps did not load: lock is broken\)/

    run_capturing(config, %{env | build_methods: %{ash: %{manager: "rebar3", overrides: []}}})
    assert_received {:report, {:ok, %{hits: 1}}}

    # Installed, then the project overrides how ash is built: removed.
    out =
      run_capturing(config, %{
        env
        | candidates: [],
          installed: [:ash],
          build_methods: %{ash: %{manager: "rebar3", overrides: [:compile]}}
      })

    assert_received {:report, {:ok, %{misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+MISS\s+project sets :compile for this dependency/
    refute File.exists?(Path.join(lib, "ash"))
  end

  test "a run with a verified batch keeps the cache under its bound, once a day", %{
    f: f,
    config: config,
    env: env
  } do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}
      }
    })

    old = Path.join(config.home, "files/" <> String.duplicate("0", 64))
    File.mkdir_p!(Path.dirname(old))
    File.write!(old, String.duplicate("x", 2_000_000))
    File.touch!(old, 1)

    _ = run_capturing(%{config | cache_max_bytes: 1_000_000}, env)
    assert_received {:report, {:ok, %{hits: 1}}}
    refute File.exists?(old)
    assert File.regular?(Path.join(config.home, "gc_at"))
    # What this run used was touched just now: it stays.
    assert [_ | _] = File.ls!(Path.join(config.home, "files"))
  end

  test "a format-1 manifest still hits", %{f: f, config: config, env: env, lib: lib} do
    e = Map.delete(good_entry(f, "ash", "1.31.0"), "target")
    e = update_in(e["build"], &Map.delete(&1, "dep_env"))

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}},
      format: 1
    )

    batch = F.get(:batch)["payload"] |> Base.url_decode64!(padding: false) |> :json.decode()
    refute Map.has_key?(batch, "manifests_v2")
    assert Map.has_key?(batch["manifests"], "ash")

    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{hits: 1}}}
    assert out =~ ~r/precompiled: ash 3\.5\.2\s+HIT/
    assert File.exists?(Path.join(lib, "ash/.mix/compile.elixir_scm"))
  end

  test "a batch with manifests_v2 fetches the v2 document", %{f: f, config: config, env: env} do
    F.publish(f, %{
      "ash" => %{"versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}}
    })

    # Nothing under /precompiled/manifests: a fetch there would be a MISS.
    assert F.get(:manifests) == %{}

    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{hits: 1}}}
    assert out =~ ~r/precompiled: ash 3\.5\.2\s+HIT/
  end

  test "manifests_v2 present but missing a package falls back to the format-1 document", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    e = Map.delete(good_entry(f, "ash", "1.31.0"), "target")
    e = update_in(e["build"], &Map.delete(&1, "dep_env"))

    F.publish(f, %{"other" => %{"versions" => %{}}}, format: 2)

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"nerves_system_rpi4" => e}}}},
      format: 1,
      merge: true
    )

    # ash is published only in format 1: a v2 fetch for it would 404 and MISS.
    refute Map.has_key?(F.get(:manifests_v2), "ash")
    assert Map.has_key?(F.get(:manifests), "ash")

    batch = F.get(:batch)["payload"] |> Base.url_decode64!(padding: false) |> :json.decode()
    assert batch["manifests_v2"] != %{}
    refute Map.has_key?(batch["manifests_v2"], "ash")
    assert Map.has_key?(batch["manifests"], "ash")

    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{hits: 1}}}
    assert out =~ ~r/precompiled: ash 3\.5\.2\s+HIT/
    assert File.exists?(Path.join(lib, "ash/.mix/compile.elixir_scm"))
  end

  test "a tampered manifest is a FAIL and installs nothing", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}
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

    app =
      "{application, ash, [{vsn, \"3.5.2\"}, {modules, ['Elixir.X']}, {compile_env, [{ash, [mode], {ok, fast}}]}]}.\n"

    e =
      update_in(e["ebin"], fn files ->
        Enum.map(files, fn
          %{"path" => "ebin/ash.app"} = x ->
            %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

          x ->
            x
        end)
      end)

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})
    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{fails: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+downloaded \.app: compile_env differs: ash \[:mode\]/
    refute File.exists?(Path.join(lib, "ash"))

    # The code carries the applications whose compile_env differs.
    report_file = Path.join(lib, ".precompiled/report.json") |> File.read!() |> :json.decode()

    assert %{"status" => "fail", "reason_code" => "compile_env_differs", "reason_args" => ["ash"]} =
             Enum.find(report_file["lines"], &(&1["name"] == "ash"))
  end

  test "a pure_elixir build of a dep that reads Mix.target is not served to a device", %{
    f: f,
    config: config,
    env: env,
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "deps/ash/lib"))

    File.write!(
      Path.join(dir, "deps/ash/lib/ash.ex"),
      "defmodule Ash do\n  @t Mix.target()\nend\n"
    )

    e = good_entry(f, "ash", nil, "pure_elixir")
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})

    out = run_capturing(config, %{env | candidates: [hd(env.candidates)], mix_target: "rpi4"})
    assert_received {:report, {:ok, %{misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+MISS\s+reads Mix\.target\(\) at compile time/

    # The same dep on host takes it.
    out = run_capturing(config, %{env | candidates: [hd(env.candidates)], mix_target: "host"})
    assert_received {:report, {:ok, %{hits: 1}}}, out

    # A nil target counts as host, not as a target named nil.
    out = run_capturing(config, %{env | candidates: [hd(env.candidates)], mix_target: nil})
    assert_received {:report, {:ok, %{hits: 1}}}, out
  end

  test "an invalid batch fails every candidate", %{f: f, config: config, env: env} do
    F.publish(f, %{}, expires: "2020-01-01T00:00:00Z")
    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
    assert out =~ ~r/FAIL\s+batch expired/
  end

  test "a batch issued 25 hours ago fails every candidate as stale", %{
    f: f,
    config: config,
    env: env
  } do
    F.publish(f, %{},
      issued: DateTime.add(DateTime.utc_now(), -25 * 3600, :second) |> DateTime.to_iso8601()
    )

    out = run_capturing(config, env)
    assert_received {:report, {:ok, report}}
    assert report.fails == 2 and report.hits == 0

    assert Enum.all?(report.lines, fn line ->
             line.status == :fail and String.starts_with?(line.detail, "batch stale")
           end)

    assert out =~ ~r/FAIL\s+batch stale/
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
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+manifest malformed/
    assert File.exists?(Path.join(lib, ".precompiled/report.json"))
  end

  test "already-compiled deps are left alone", %{f: f, config: config, env: env, lib: lib} do
    decimal = {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", "DOUTER"}
    File.mkdir_p!(Path.join(lib, "decimal/ebin"))
    File.write!(Path.join(lib, "decimal/ebin/keep.beam"), "keep")

    F.publish(f, %{
      "decimal" => %{
        "versions" => %{"2.3.0" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}
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
    refute File.exists?(System.get_env("PRECOMPILED_HOME"))
  end

  test "no candidates in DEBUG mode prints one line", %{config: config, env: env} do
    System.put_env("PRECOMPILED_DEBUG", "1")
    on_exit(fn -> System.delete_env("PRECOMPILED_DEBUG") end)

    out = run_capturing(config, %{env | candidates: []})
    assert_received {:report, :nothing_to_do}
    # Mix may print its own "==> precompiled" project header into the same
    # captured shell when another test ran a task first; only our lines count.
    lines = out |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "==> "))
    assert [_one] = lines
    assert out =~ "precompiled: no dependencies to check"
  end

  test "a dep Mix names as nerves' child is tooling, not fetched", %{config: config, env: env} do
    System.put_env("PRECOMPILED_DEBUG", "1")
    on_exit(fn -> System.delete_env("PRECOMPILED_DEBUG") end)
    env = %{env | candidates: [List.last(env.candidates)], tooling: [:jason]}

    out = run_capturing(config, env)
    assert_received {:report, :nothing_to_do}
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
        "versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}
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

    app =
      "{application, ash, [{vsn, \"3.5.2\"}, {modules, ['Elixir.X']}, {compile_env, [{ash, [mode], {ok, fast}}]}]}.\n"

    e =
      update_in(e["ebin"], fn files ->
        Enum.map(files, fn
          %{"path" => "ebin/ash.app"} = x ->
            %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

          x ->
            x
        end)
      end)

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})
    out = run_capturing(config, env, config_fun: fn _, _ -> throw(:boom) end)
    assert_received {:report, {:ok, %{fails: 1, misses: 1}}}
    assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+candidate crashed: :boom/
  end

  describe "installed builds are rechecked against the current batch" do
    # Installs ash (a HIT), then hands back an env for a later run in which
    # Mix already counts ash as compiled: no candidates, ash installed.
    defp install_ash(f, config, env) do
      F.publish(f, ash_packages(f, "1.31.0"), sequence: 1)
      run_capturing(config, %{env | candidates: [hd(env.candidates)]})
      assert_received {:report, {:ok, %{hits: 1}}}
      %{env | candidates: [], installed: [:ash]}
    end

    defp ash_packages(f, system_version) do
      %{
        "ash" => %{
          "versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", system_version)]}}
        }
      }
    end

    test "a new project on a warm cache downloads no manifest and no file", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      _ = install_ash(f, config, env)
      File.rm_rf!(lib)
      F.clear_requests()

      run_capturing(config, %{env | candidates: [hd(env.candidates)]})
      assert_received {:report, {:ok, %{hits: 1}}}
      assert [%{path: "/precompiled/batch.json"}] = F.requests()
    end

    test "by-sha manifest paths are asked for only when the signed batch names content", %{
      f: f,
      config: config,
      env: env
    } do
      env = %{env | candidates: [hd(env.candidates)]}
      cdn_port = Precompiled.TestServer.port() + 2
      start_supervised!({Precompiled.TestServer, port: cdn_port})
      cdn = "http://127.0.0.1:#{cdn_port}/precompiled"

      # The project's own :content: files from there, the manifest by name.
      F.publish(f, ash_packages(f, "1.31.0"), sequence: 1)
      F.clear_requests()
      run_capturing(Map.put(config, :content_override, [cdn]), env)
      assert_received {:report, {:ok, %{hits: 1}}}
      paths = Enum.map(F.requests(), & &1.path)
      assert "/precompiled/v2/manifests/ash.json" in paths
      refute Enum.any?(paths, &String.contains?(&1, "by-sha"))
      assert Enum.any?(F.requests(), &(&1.port == cdn_port and &1.path =~ "/files/"))

      # The batch names a (here unreachable) content origin: by-sha at the
      # source after it, which answers.
      File.rm_rf!(config.home |> Path.join("manifests"))
      File.rm_rf!(config.home |> Path.join("files"))

      F.publish(f, ash_packages(f, "1.31.0"),
        sequence: 2,
        batch_extra: %{"content" => ["https://127.0.0.1:1/precompiled"]}
      )

      F.clear_requests()
      run_capturing(config, env)
      assert_received {:report, {:ok, %{hits: 1}}}
      paths = Enum.map(F.requests(), & &1.path)
      assert Enum.any?(paths, &String.starts_with?(&1, "/precompiled/v2/manifests/by-sha/"))
      refute "/precompiled/v2/manifests/ash.json" in paths
    end

    test "a build the batch still names is left alone, silently", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      beam = Path.join(lib, "ash/ebin/Elixir.X.beam")
      before = File.stat!(beam, time: :posix)

      F.clear_requests()
      out = run_capturing(config, env)
      assert_received {:report, {:ok, report}}
      assert report.lines == []
      assert out == ""
      assert File.stat!(beam, time: :posix) == before
      assert File.exists?(Path.join(lib, "ash/.mix/precompiled.json"))
      # Matched again from the cached manifest: still one request.
      assert [%{path: "/precompiled/batch.json"}] = F.requests()
    end

    # The batch (and so the manifest sha) is unchanged in each of these;
    # what changed is the project, so the build is matched again.
    test "same batch, another OTP: the installed build is removed", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      out = run_capturing(config, env, toolchain: {System.version(), "0"})
      assert_received {:report, {:ok, %{misses: 1}}}
      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+built on OTP \d+, running 0/
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "same batch, an older Elixir: the installed build is removed", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      otp = to_string(:erlang.system_info(:otp_release))
      out = run_capturing(config, env, toolchain: {"1.0.0", otp})
      assert_received {:report, {:ok, %{misses: 1}}}
      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+built with Elixir .*, running 1\.0\.0/
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "same batch, a lock that now gives ash a dependency: removed", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      ash = {:hex, :ash, "3.5.2", "i", [:mix], [{:jason, "~> 1.4", []}], "hexpm", "ASHOUTER"}
      out = run_capturing(config, %{env | lock: %{env.lock | ash: ash}})
      assert_received {:report, {:ok, %{misses: 1}}}
      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+built without jason, lock has 1\.4\.5/
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "same batch, another compile_env: removed, by the manifest or by the .app", %{
      f: f,
      config: config,
      env: env,
      lib: lib,
      tmp_dir: dir
    } do
      env = %{env | candidates: [hd(env.candidates)]}
      fast = fn "ash", ["mode"] -> {:ok, :fast} end
      slow = fn "ash", ["mode"] -> {:ok, :slow} end

      for {honest?, sequence} <- [{true, 1}, {false, 2}] do
        F.publish(f, ash_with_compile_env(f, dir, honest?), sequence: sequence)
        run_capturing(config, env, config_fun: fast)
        assert_received {:report, {:ok, %{hits: 1}}}
        installed = %{env | candidates: [], installed: [:ash]}

        assert run_capturing(config, installed, config_fun: fast) == ""
        assert File.exists?(Path.join(lib, "ash"))

        out = run_capturing(config, installed, config_fun: slow)

        if honest?,
          do: assert(out =~ ~r/ash 3\.5\.2\s+MISS\s+compile_env differs: ash \[:mode\]/),
          else: assert(out =~ ~r/ash 3\.5\.2\s+FAIL\s+downloaded \.app: compile_env differs/)

        refute File.exists?(Path.join(lib, "ash"))
      end
    end

    test "same batch, a dep reading Mix.target and another project target: removed", %{
      f: f,
      config: config,
      env: env,
      lib: lib,
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "deps/ash/lib"))

      File.write!(
        Path.join(dir, "deps/ash/lib/ash.ex"),
        "defmodule Ash do\n  @t Mix.target()\nend\n"
      )

      e = good_entry(f, "ash", nil, "pure_elixir")
      F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})
      run_capturing(config, %{env | candidates: [hd(env.candidates)]})
      assert_received {:report, {:ok, %{hits: 1}}}
      installed = %{env | candidates: [], installed: [:ash]}
      assert run_capturing(config, installed) == ""

      out = run_capturing(config, %{installed | mix_target: "rpi4"})
      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+reads Mix\.target\(\) at compile time/
      refute File.exists?(Path.join(lib, "ash"))
    end

    # Under an unchanged manifest the disk is not re-hashed, but the kept
    # build's .app is still read: one that no longer names the locked
    # package fails the dep, which is removed for Mix to compile.
    test "same batch, an installed .app naming another version: FAIL, removed", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      app = Path.join(lib, "ash/ebin/ash.app")
      File.write!(app, String.replace(File.read!(app), "3.5.2", "9.9.9"))

      out = run_capturing(config, env)
      assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+downloaded \.app names ash 9\.9\.9/, out
      refute File.exists?(Path.join(lib, "ash"))
    end

    # A scan the deadline cut short says nothing against the installed
    # build, as a manifest the network could not deliver says nothing.
    test "same batch, the deadline cuts the source scan short: kept, with a note", %{
      f: f,
      config: config,
      env: env,
      lib: lib,
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "deps/ash/lib"))
      File.write!(Path.join(dir, "deps/ash/lib/ash.ex"), "defmodule Ash do\nend\n")
      env = install_ash(f, config, env)
      File.rm_rf!(Path.join(config.home, "scan"))

      out = run_capturing(Map.put(config, :deadline_ms, 0), env)
      assert out =~ ~r/ash 3\.5\.2\s+KEPT\s+source not scannable: run deadline passed/, out
      assert File.exists?(Path.join(lib, "ash/ebin/ash.app"))
    end

    # Kept without a recheck still reads the installed .app against today's
    # config: a kept build that no longer names the package is removed.
    test "same batch, offline, manifest not cached, the .app tampered: FAIL, removed", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      File.rm_rf!(Path.join(config.home, "manifests"))
      File.mkdir_p!(Path.join(config.home, "manifests"))
      app = Path.join(lib, "ash/ebin/ash.app")
      File.write!(app, String.replace(File.read!(app), "3.5.2", "9.9.9"))

      out = run_capturing(Map.put(config, :offline, true), env)
      assert out =~ ~r/ash 3\.5\.2\s+FAIL\s+downloaded \.app names ash 9\.9\.9/, out
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "same batch: the provenance file is not rewritten", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      prov = Path.join(lib, "ash/.mix/precompiled.json")
      inode = File.stat!(prov).inode
      assert run_capturing(config, env) == ""
      assert File.stat!(prov).inode == inode
    end

    test "same batch, offline, manifest no longer cached: kept, with a note", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      File.rm_rf!(Path.join(config.home, "manifests"))
      File.mkdir_p!(Path.join(config.home, "manifests"))
      F.clear_requests()

      out = run_capturing(Map.put(config, :offline, true), env)

      assert_received {:report,
                       {:ok,
                        %{lines: [%{name: "ash", status: :fail, reason: {:fetch_failed, []}}]}}}

      assert out =~
               ~r/ash 3\.5\.2\s+KEPT\s+offline: manifest not cached; installed build kept, not rechecked/

      report_file = Path.join(lib, ".precompiled/report.json") |> File.read!() |> :json.decode()

      assert [%{"name" => "ash", "status" => "fail", "reason_code" => "fetch_failed"}] =
               report_file["lines"]

      assert F.requests() == []
      assert File.exists?(Path.join(lib, "ash/ebin/Elixir.X.beam"))
    end

    # ash with a .app recording compile_env mode = fast; the manifest says
    # so too when honest, and records none otherwise.
    defp ash_with_compile_env(f, dir, honest?) do
      app =
        "{application, ash, [{vsn, \"3.5.2\"}, {modules, ['Elixir.X']}, " <>
          "{compile_env, [{ash, [mode], {ok, fast}}]}]}.\n"

      app_path = Path.join(dir, "ash.app")
      File.write!(app_path, app)
      e = good_entry(f, "ash", "1.31.0")

      e =
        update_in(e["ebin"], fn files ->
          Enum.map(files, fn
            %{"path" => "ebin/ash.app"} = x ->
              %{x | "sha256" => F.file(f, app), "size" => byte_size(app)}

            x ->
              x
          end)
        end)

      e =
        if honest?,
          do: put_in(e, ["build", "compile_env"], Match.compile_env_from_app(app_path)),
          else: e

      %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}}
    end

    test "a build the batch dropped is removed and reported as revoked", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 2)

      out = run_capturing(config, env)
      assert_received {:report, {:ok, report}}

      assert [%{name: "ash", status: :miss, detail: "revoked: no longer in the current batch"}] =
               report.lines

      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+revoked: no longer in the current batch/
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "a build whose manifest changed is matched again, never kept as the old bytes", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      # A different manifest (sha) for ash whose only build no longer matches.
      F.publish(f, ash_packages(f, "1.32.0"), sequence: 2)

      out = run_capturing(config, env)
      assert_received {:report, {:ok, report}}
      assert [%{name: "ash", status: :miss}] = report.lines
      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+built for nerves_system_rpi4 1\.32\.0/
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "a build whose manifest changed but still lists the same files is kept in place", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      beam = Path.join(lib, "ash/ebin/Elixir.X.beam")
      before = File.stat!(beam, time: :posix)
      packages = put_in(ash_packages(f, "1.31.0"), ["ash", "extra"], "changes the sha")
      F.publish(f, packages, sequence: 2)
      new_sha = F.get(:batch)["payload"] |> Base.url_decode64!(padding: false) |> :json.decode()

      assert run_capturing(config, env) == ""
      assert_received {:report, {:ok, %{lines: []}}}
      assert File.stat!(beam, time: :posix) == before

      assert %{"manifest_sha256" => sha, "batch_sequence" => 2, "files_sha256" => _} =
               Path.join(lib, "ash/.mix/precompiled.json")
               |> File.read!()
               |> :json.decode()

      assert sha == new_sha["manifests_v2"]["ash"]
    end

    test "a new portal run of the same inputs does not churn the installed bytes", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      publish_rerun(f)

      assert run_capturing(config, env) == ""
      assert File.read!(Path.join(lib, "ash/ebin/Elixir.X.beam")) == "beam ash"
    end

    test "an install from before files_sha256 is re-placed like before", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      prov = Path.join(lib, "ash/.mix/precompiled.json")

      File.write!(
        prov,
        prov |> File.read!() |> :json.decode() |> Map.delete("files_sha256") |> :json.encode()
      )

      F.publish(f, put_in(ash_packages(f, "1.31.0"), ["ash", "extra"], "x"), sequence: 2)

      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: [%{name: "ash", status: :hit}]}}}
    end

    # The provenance file only says which build to prefer; whether the
    # bytes on disk are that build is read from the disk itself.
    test "installed bytes changed on disk are never kept, whatever the provenance says", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      beam = Path.join(lib, "ash/ebin/Elixir.X.beam")
      publish_rerun(f)

      # Same size, other bytes.
      File.write!(beam, "beam asX")
      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: [%{name: "ash", status: :hit}]}}}
      assert File.read!(beam) == "beam ash"
    end

    test "an installed file swapped for a symlink to the same bytes is not kept", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      beam = Path.join(lib, "ash/ebin/Elixir.X.beam")
      publish_rerun(f)

      elsewhere = Path.join(lib, "elsewhere.beam")
      File.write!(elsewhere, "beam ash")
      File.rm!(beam)
      File.ln_s!(elsewhere, beam)

      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: [%{name: "ash", status: :hit}]}}}
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(beam)
    end

    test "an installed build with an extra file is not kept", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      extra = Path.join(lib, "ash/ebin/Elixir.Y.beam")
      publish_rerun(f)

      File.write!(extra, "planted")
      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: [%{name: "ash", status: :hit}]}}}
      refute File.exists?(extra)
    end

    test "an installed file with another mode is not kept", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      beam = Path.join(lib, "ash/ebin/Elixir.X.beam")
      publish_rerun(f)

      File.chmod!(beam, 0o755)
      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: [%{name: "ash", status: :hit}]}}}
      assert Bitwise.band(File.stat!(beam).mode, 0o777) == 0o644
    end

    test "a provenance file naming another build's files does not make it kept", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      rerun = publish_rerun(f)
      prov = Path.join(lib, "ash/.mix/precompiled.json")
      doc = prov |> File.read!() |> :json.decode()
      File.write!(prov, :json.encode(%{doc | "files_sha256" => Match.files_hash(rerun)}))

      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: [%{name: "ash", status: :hit}]}}}
      assert File.read!(Path.join(lib, "ash/ebin/Elixir.X.beam")) == "other bytes"
    end

    test "a kept build the next batch drops is removed as revoked", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      publish_rerun(f)
      assert run_capturing(config, env) == ""

      F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 3)
      run_capturing(config, env)

      assert_received {:report,
                       {:ok,
                        %{
                          lines: [
                            %{
                              name: "ash",
                              status: :miss,
                              detail: "revoked: no longer in the current batch"
                            }
                          ]
                        }}}

      refute File.exists?(Path.join(lib, "ash"))
    end

    # A second build of the same inputs from a newer portal run: its run id
    # "s" sorts newer than the installed "r", and its beam differs.
    defp publish_rerun(f) do
      installed = good_entry(f, "ash", "1.31.0")
      rerun = put_in(installed, ["build", "run_id"], "s")

      rerun =
        update_in(rerun["ebin"], fn [beam | rest] ->
          [%{beam | "sha256" => F.file(f, "other bytes"), "size" => 11} | rest]
        end)

      F.publish(
        f,
        %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [installed, rerun]}}}},
        sequence: 2
      )

      rerun
    end

    test "an unreadable provenance file counts as revoked", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      File.write!(Path.join(lib, "ash/.mix/precompiled.json"), "not json {")

      run_capturing(config, env)
      assert_received {:report, {:ok, report}}

      assert [%{name: "ash", status: :miss, detail: "revoked: provenance unreadable"}] =
               report.lines

      refute File.exists?(Path.join(lib, "ash"))
    end

    test "a run mixing a revoked install with a fresh candidate prints both, revoked first", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)

      F.publish(
        f,
        %{
          "jason" => %{
            "versions" => %{"1.4.5" => %{"builds" => [good_entry(f, "jason", "1.31.0")]}}
          }
        },
        sequence: 2
      )

      jason = %{name: :jason, version: "1.4.5", lock_entry: @jason}
      out = run_capturing(config, %{env | candidates: [jason]})
      assert_received {:report, {:ok, report}}

      assert [
               %{name: "ash", status: :miss, detail: "revoked: no longer in the current batch"},
               %{name: "jason", status: :hit}
             ] = report.lines

      assert out =~
               ~r/ash 3\.5\.2\s+MISS\s+revoked: no longer in the current batch.*\n.*jason 1\.4\.5\s+HIT/

      assert out =~ "precompiled: 1 hit, 1 miss, 0 fail of 2 deps"
      refute File.exists?(Path.join(lib, "ash"))
      assert File.exists?(Path.join(lib, "jason/.mix/precompiled.json"))
    end

    test "a run with nothing to say keeps the last report.json", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      report = Path.join(lib, ".precompiled/report.json")
      before = File.read!(report)
      assert before =~ ~s("hit")

      run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: []}}}
      assert File.read!(report) == before
    end

    test "a candidate that misses loses a provenance file left from an earlier install", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      install_ash(f, config, env)
      F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 2)

      # Mix wants to compile ash again (a new toolchain, say): it is a
      # candidate, and the build it compiles must not pass for an install.
      run_capturing(config, %{env | candidates: [hd(env.candidates)]})
      assert_received {:report, {:ok, %{misses: 1}}}
      refute File.exists?(Path.join(lib, "ash/.mix/precompiled.json"))
    end

    test "a refused batch marks only installed builds as kept", %{
      f: f,
      config: config,
      env: env
    } do
      env = install_ash(f, config, env)
      F.publish(f, %{}, sequence: 2, expires: "2020-01-01T00:00:00Z")

      jason = %{name: :jason, version: "1.4.5", lock_entry: @jason}
      out = run_capturing(config, %{env | candidates: [jason]})
      assert_received {:report, {:ok, report}}

      assert [%{name: "ash", detail: ash}, %{name: "jason", detail: jason}] =
               Enum.sort_by(report.lines, & &1.name)

      assert ash =~ ~r/^batch expired.* \(installed build kept\)$/
      assert jason =~ ~r/^batch expired/
      refute jason =~ "installed build kept"

      # The candidate keeps its FAIL line; the kept install folds into one
      # warning instead of a FAIL line of its own.
      assert out =~ ~r/jason 1\.4\.5\s+FAIL\s+batch expired/
      refute out =~ ~r/ash 3\.5\.2\s+FAIL/
      assert [_] = Regex.scan(~r/no fresh batch/, out)

      assert out =~
               ~r/precompiled: no fresh batch \(batch expired at [^)]+\); 1 installed build kept, not rechecked/

      assert out =~ "precompiled: 0 hit, 0 miss, 1 fail of 1 deps"
    end

    test "an unavailable batch with only installs prints one warning, no FAIL lines", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      jason_lib = Path.join(lib, "jason")
      File.cp_r!(Path.join(lib, "ash"), jason_lib)
      File.rename!(Path.join(jason_lib, "ebin/ash.app"), Path.join(jason_lib, "ebin/jason.app"))
      env = %{env | installed: [:ash, :jason]}

      # Nothing listens on port 1: the batch is unavailable, as offline.
      out = run_capturing(%{config | source: "http://127.0.0.1:1/precompiled"}, env)
      assert_received {:report, {:ok, report}}

      assert out ==
               "precompiled: no fresh batch (batch unavailable: cannot connect (econnrefused)); " <>
                 "2 installed builds kept, not rechecked\n"

      assert [
               %{name: "ash", status: :fail, detail: "batch unavailable: " <> _},
               %{name: "jason", status: :fail, detail: "batch unavailable: " <> _}
             ] = report.lines

      assert [_, _] =
               Path.join(lib, ".precompiled/report.json")
               |> File.read!()
               |> :json.decode()
               |> Map.fetch!("lines")
    end

    test "an installed build now in :except is removed without fetching a batch", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      # A refused batch: the removal must not depend on one, and with
      # nothing else to check no batch is fetched (no FAIL line).
      F.publish(f, %{}, sequence: 2, expires: "2020-01-01T00:00:00Z")

      out = run_capturing(%{config | except: [:ash]}, env)
      assert_received {:report, {:ok, report}}

      assert [%{name: "ash", status: :miss, detail: "excepted: compiled from source"}] =
               report.lines

      assert out =~ ~r/ash 3\.5\.2\s+MISS\s+excepted: compiled from source/
      refute File.exists?(Path.join(lib, "ash"))
    end

    test "a refused batch leaves installed builds in place", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)

      F.publish(f, %{},
        sequence: 2,
        issued: DateTime.add(DateTime.utc_now(), -25 * 3600, :second) |> DateTime.to_iso8601()
      )

      out = run_capturing(config, env)
      assert_received {:report, {:ok, report}}
      assert [%{name: "ash", status: :fail, detail: "batch stale" <> _ = detail}] = report.lines
      assert String.ends_with?(detail, " (installed build kept)")
      refute out =~ "FAIL"
      refute out =~ "deps,"

      assert out =~
               ~r/^precompiled: no fresh batch \(batch stale: .*\); 1 installed build kept, not rechecked\n$/

      assert File.exists?(Path.join(lib, "ash/ebin/Elixir.X.beam"))
      assert File.exists?(Path.join(lib, "ash/.mix/precompiled.json"))
    end

    test "a warm run asks for nothing but a conditional batch", %{f: f, config: config, env: env} do
      env = install_ash(f, config, env)
      F.clear_requests()

      assert run_capturing(config, env) == ""
      assert_received {:report, {:ok, %{lines: []}}}
      assert [%{path: "/precompiled/batch.json", if_none_match: "\"" <> _}] = F.requests()
    end

    test "a source without ETags still costs one batch request", %{
      f: f,
      config: config,
      env: env
    } do
      F.set_etags(false)
      env = install_ash(f, config, env)
      F.clear_requests()

      assert run_capturing(config, env) == ""
      assert [%{path: "/precompiled/batch.json", if_none_match: nil}] = F.requests()
    end

    test "a root rotated since the last check is fetched when the batch stops verifying", %{
      f: f,
      config: config,
      env: env
    } do
      env = install_ash(f, config, env)
      k2 = F.rotate_root(f, version: 2)
      F.publish(f, ash_packages(f, "1.31.0"), sequence: 2, signers: [k2])
      F.clear_requests()

      assert run_capturing(config, env) == ""

      assert Enum.map(F.requests(), & &1.path) == [
               "/precompiled/batch.json",
               "/precompiled/root.json",
               "/precompiled/batch.json"
             ]

      assert_received {:report, {:ok, %{fails: 0}}}
    end

    test "offline: a candidate the cached batch names compiles, nothing is fetched", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      jason = %{
        "versions" => %{"1.4.5" => %{"builds" => [good_entry(f, "jason", "1.31.0")]}}
      }

      F.publish(f, Map.put(ash_packages(f, "1.31.0"), "jason", jason))
      [ash, jason_dep] = env.candidates
      run_capturing(config, %{env | candidates: [ash]})
      assert_received {:report, {:ok, %{hits: 1}}}
      F.clear_requests()

      env = %{env | candidates: [jason_dep], installed: [:ash]}
      out = run_capturing(Map.put(config, :offline, true), env)
      assert_received {:report, {:ok, report}}

      assert [%{name: "jason", status: :miss, detail: "offline: manifest not cached"}] =
               report.lines

      assert out =~ ~r/jason 1\.4\.5\s+MISS\s+offline: manifest not cached/
      assert F.requests() == []
      refute File.exists?(Path.join(lib, "jason"))
    end

    test "an unreachable source: installs are rechecked against the cached batch", %{
      f: f,
      config: config,
      env: env
    } do
      env = install_ash(f, config, env)
      F.withdraw_batch()
      F.clear_requests()

      out = run_capturing(config, env)
      assert_received {:report, {:ok, %{lines: []}}}
      assert out =~ "source unreachable (Status 503"
      assert out =~ "using the cached batch (sequence 1)"
      assert [%{path: "/precompiled/batch.json"}] = F.requests()
    end

    test "a passed deadline uses the cached batch without a request", %{
      f: f,
      config: config,
      env: env
    } do
      env = install_ash(f, config, env)
      F.clear_requests()

      out = run_capturing(Map.put(config, :deadline_ms, 0), env)
      assert_received {:report, {:ok, %{lines: []}}}
      assert out =~ "source unreachable (run deadline passed)"
      assert F.requests() == []
    end

    test "a refused batch never falls back to the cached one", %{
      f: f,
      config: config,
      env: env
    } do
      env = install_ash(f, config, env)
      F.publish(f, ash_packages(f, "1.31.0"), sequence: 2, expires: "2020-01-01T00:00:00Z")

      out = run_capturing(config, env)
      assert_received {:report, {:ok, report}}
      assert [%{name: "ash", status: :fail, detail: "batch expired" <> _}] = report.lines
      refute out =~ "cached batch"
    end

    test "offline: installs are rechecked against the cached batch, no request", %{
      f: f,
      config: config,
      env: env
    } do
      env = install_ash(f, config, env)
      F.clear_requests()
      assert run_capturing(Map.put(config, :offline, true), env) == ""
      assert_received {:report, {:ok, %{lines: []}}}
      assert F.requests() == []
    end

    test "offline with no cached batch keeps installs and makes no request", %{
      config: config,
      env: env,
      lib: lib,
      f: f
    } do
      env = install_ash(f, config, env)
      [dir] = Path.wildcard(Path.join(config.home, "*/batch.json"))
      File.rm!(dir)
      F.clear_requests()

      out = run_capturing(Map.put(config, :offline, true), env)
      assert out =~ "batch unavailable: offline, no cached batch"
      assert F.requests() == []
      assert File.exists?(Path.join(lib, "ash/ebin/Elixir.X.beam"))
    end

    test "two concurrent runs on one home both get the batch", %{f: f, config: config, env: env} do
      env = install_ash(f, config, env)

      results =
        1..4
        |> Task.async_stream(fn _ ->
          Precompiled.Check.check(config, env, config_fun: fn _, _ -> :error end)
        end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, %{fails: 0}}, &1))
    end
  end

  test "a run whose deadline has passed makes no request and compiles", %{
    config: config,
    env: env
  } do
    F.clear_requests()
    out = run_capturing(Map.put(config, :deadline_ms, 0), env)
    assert_received {:report, {:ok, %{fails: 2}}}
    assert out =~ ~r/FAIL\s+batch unavailable/
    assert F.requests() == []
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
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})

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
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})

    out = run_capturing(config, env)
    assert_received {:report, {:ok, %{hits: 1}}}
    refute out =~ "stripped"
  end

  # The report under `.precompiled/` is a bookkeeping convenience that is
  # rewritten on every run with lines, refused batch or not; it alone is
  # left out of both snapshots below.
  defp home_snapshot(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      # When the root was last fetched says nothing about the batch: a
      # refused batch must leave no sequence, cached batch or ETag behind.
      |> Enum.reject(&(File.dir?(&1) or Path.basename(&1) == "root_checked"))
      |> Enum.map(&{Path.relative_to(&1, dir), File.read!(&1)})
      |> Enum.sort()
    else
      []
    end
  end

  defp dep_dirs(lib) do
    if File.dir?(lib) do
      top = lib |> File.ls!() |> Enum.reject(&(&1 == ".precompiled"))

      extra =
        case File.ls(Path.join(lib, ".precompiled")) do
          {:ok, names} -> for n <- names, n != "report.json", do: ".precompiled/" <> n
          {:error, _} -> []
        end

      Enum.sort(top ++ extra)
    else
      []
    end
  end

  defp assert_nothing_installed(config, lib, run) do
    home_before = home_snapshot(config.home)
    dirs_before = dep_dirs(lib)
    run.()
    assert home_snapshot(config.home) == home_before
    assert dep_dirs(lib) == dirs_before
  end

  describe "R14: a refused batch changes nothing on disk" do
    test "a stale batch", %{f: f, config: config, env: env, lib: lib} do
      F.publish(f, %{},
        issued: DateTime.add(DateTime.utc_now(), -25 * 3600, :second) |> DateTime.to_iso8601()
      )

      assert_nothing_installed(config, lib, fn ->
        out = run_capturing(config, env)
        assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
        assert out =~ ~r/FAIL\s+batch stale/
      end)
    end

    test "a future-dated batch (clock)", %{f: f, config: config, env: env, lib: lib} do
      F.publish(f, %{},
        issued: DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.to_iso8601()
      )

      assert_nothing_installed(config, lib, fn ->
        out = run_capturing(config, env)
        assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
        assert out =~ ~r/FAIL\s+clock/
      end)
    end

    test "a batch whose lifetime exceeds 30 days", %{f: f, config: config, env: env, lib: lib} do
      now = DateTime.utc_now()

      F.publish(f, %{},
        issued: DateTime.to_iso8601(now),
        expires: DateTime.add(now, 31 * 86_400, :second) |> DateTime.to_iso8601()
      )

      assert_nothing_installed(config, lib, fn ->
        out = run_capturing(config, env)
        assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
        assert out =~ ~r/FAIL\s+batch lifetime/
      end)
    end

    test "an expired batch", %{f: f, config: config, env: env, lib: lib} do
      F.publish(f, %{}, expires: "2020-01-01T00:00:00Z")

      assert_nothing_installed(config, lib, fn ->
        out = run_capturing(config, env)
        assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
        assert out =~ ~r/FAIL\s+batch expired/
      end)
    end

    test "a rollback batch, leaving the prior state file byte for byte", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      F.publish(f, %{}, sequence: 7)
      out = run_capturing(config, env)
      assert_received {:report, {:ok, %{fails: 0, misses: 2}}}
      refute out =~ "FAIL"

      F.publish(f, %{}, sequence: 6)

      assert_nothing_installed(config, lib, fn ->
        out = run_capturing(config, env)
        assert_received {:report, {:ok, %{fails: 2, hits: 0}}}
        assert out =~ ~r/FAIL\s+batch sequence 6 is older than 7/
      end)
    end
  end

  test "R15: files cached from an earlier install are not used once the batch stops naming it", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{
      "ash" => %{
        "versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}
      }
    })

    run_capturing(config, %{env | candidates: [hd(env.candidates)]})
    assert_received {:report, {:ok, %{hits: 1}}}
    cached_files = Path.join(config.home, "files") |> File.ls!() |> Enum.sort()
    assert cached_files != []

    # Mix wants to compile ash again (a new toolchain, say): it is a
    # candidate once more, with the earlier install's cached files still on
    # disk, while the current batch no longer names the package at all.
    File.rm_rf!(Path.join(lib, "ash"))
    F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 2)

    out = run_capturing(config, %{env | candidates: [hd(env.candidates)]})
    assert_received {:report, {:ok, %{misses: 1, hits: 0, fails: 0}}}
    assert out =~ ~r/ash 3\.5\.2\s+MISS\s+not in batch/
    refute File.exists?(Path.join(lib, "ash"))
    assert Path.join(config.home, "files") |> File.ls!() |> Enum.sort() == cached_files
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

      F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})
      out = run_capturing(config, env)
      assert_received {:report, {:ok, %{fails: 1}}}
      assert out =~ "FAIL  downloaded .app names #{unquote(label)}"
      refute File.exists?(Path.join(lib, "ash"))
    end
  end

  test "an unwritable home falls back to a cache under _build", %{
    f: f,
    config: config,
    env: env,
    lib: lib,
    tmp_dir: dir
  } do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "")

    F.publish(f, %{
      "ash" => %{"versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}}
    })

    out =
      run_capturing(%{config | home: Path.join(blocker, "home")}, %{
        env
        | candidates: [hd(env.candidates)]
      })

    assert_received {:report, {:ok, %{hits: 1}}}
    assert out =~ "is not writable; using #{Path.join(lib, ".precompiled/home")}"
    assert File.dir?(Path.join(lib, ".precompiled/home/files"))
  end

  test "a worker that dies outright is one FAIL, leaves nothing behind, and the rest install",
       %{f: f, config: config, env: env, lib: lib} do
    killer = %{
      "app" => "jason",
      "path" => ["k"],
      "value" => Base.url_encode64(:erlang.term_to_binary(1), padding: false)
    }

    jason = put_in(good_entry(f, "jason", "1.31.0"), ["build", "compile_env"], [killer])

    F.publish(f, %{
      "ash" => %{"versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}},
      "jason" => %{"versions" => %{"1.4.5" => %{"builds" => [jason]}}}
    })

    # What a half-finished install would leave: a staging dir and a build
    # dir that carries Mix's "already compiled" marker.
    staged = Precompiled.Fetch.staging_path(lib, :jason)
    File.mkdir_p!(staged)
    File.mkdir_p!(Path.join(lib, "jason/.mix"))
    File.write!(Path.join(lib, "jason/.mix/compile.elixir_scm"), "")

    config_fun = fn
      "jason", _ -> Process.exit(self(), :kill)
      _, _ -> :error
    end

    out = run_capturing(config, env, config_fun: config_fun)
    assert_received {:report, {:ok, %{hits: 1, fails: 1, lines: lines}}}
    assert [%{name: "ash", status: :hit}, %{name: "jason", status: :fail, detail: detail}] = lines
    assert detail =~ "candidate crashed: :killed"
    assert out =~ ~r/jason 1\.4\.5\s+FAIL/
    refute File.exists?(Path.join(lib, "jason"))
    refute File.exists?(staged)
    assert File.exists?(Path.join(lib, "ash/.mix/compile.elixir_scm"))
  end

  test "stripped?/2 never crashes on a long path to an unreadable beam", %{tmp_dir: dir} do
    long = Path.join([dir | List.duplicate(String.duplicate("d", 60), 5)])
    ebin = Path.join([long, "ash", "ebin"])
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "ash.app"), "{application, ash, [{modules, ['Elixir.X']}]}.\n")
    File.write!(Path.join(ebin, "Elixir.X.beam"), "not a beam")
    assert byte_size(Path.join(ebin, "Elixir.X.beam")) > 255
    assert Check.stripped?(Path.join(long, "ash"), "ash") == true
    File.rm!(Path.join(ebin, "Elixir.X.beam"))
    assert is_boolean(Check.stripped?(Path.join(long, "ash"), "ash"))
  end

  test "a run sweeps temp files killed runs left in the cache", %{f: f, config: config, env: env} do
    F.publish(f, %{
      "ash" => %{"versions" => %{"3.5.2" => %{"builds" => [good_entry(f, "ash", "1.31.0")]}}}
    })

    files = Path.join(config.home, "files")
    File.mkdir_p!(files)
    orphan = Path.join(files, String.duplicate("a", 64) <> ".tmp-1-2")
    File.write!(orphan, "x")
    File.touch!(orphan, System.os_time(:second) - 2 * 86_400)
    _ = run_capturing(config, env)
    assert_received {:report, {:ok, _}}
    refute File.exists?(orphan)
  end
end
