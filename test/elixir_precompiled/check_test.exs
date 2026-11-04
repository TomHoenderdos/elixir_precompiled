# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.CheckTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias ElixirPrecompiled.{Check, Env}
  alias ElixirPrecompiled.Env.MixProject
  alias ElixirPrecompiled.Fixture, as: F
  @moduletag :tmp_dir

  @ash {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "ASHOUTER"}
  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      configure([])
      System.delete_env("ELIXIR_PRECOMPILED_HOME")
      System.delete_env("ELIXIR_PRECOMPILED_DEBUG")
    end)

    f = F.new(dir)
    configure(source: F.base_url(), root: f.root_path)
    System.put_env("ELIXIR_PRECOMPILED_HOME", Path.join(dir, "home"))
    lib = Path.join(dir, "_build/rpi4_dev/lib")

    %{
      f: f,
      lib: lib,
      config: ElixirPrecompiled.Config.load(),
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
    for {k, _} <- Application.get_all_env(:elixir_precompiled),
        do: Application.delete_env(:elixir_precompiled, k)

    Application.put_all_env([{:elixir_precompiled, opts}])
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
    app = "{application, #{dep}, [{vsn, \"#{vsn}\"}]}.\n"

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

    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => [e]}}}})
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
    refute File.exists?(System.get_env("ELIXIR_PRECOMPILED_HOME"))
  end

  test "no candidates in DEBUG mode prints one line", %{config: config, env: env} do
    System.put_env("ELIXIR_PRECOMPILED_DEBUG", "1")
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_DEBUG") end)

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

    test "a build the batch still names is left alone, silently", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      beam = Path.join(lib, "ash/ebin/Elixir.X.beam")
      before = File.stat!(beam, time: :posix)

      out = run_capturing(config, env)
      assert_received {:report, {:ok, report}}
      assert report.lines == []
      assert out == ""
      assert File.stat!(beam, time: :posix) == before
      assert File.exists?(Path.join(lib, "ash/.mix/elixir_precompiled.json"))
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

    test "a build whose manifest changed and still matches is re-installed", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      packages = put_in(ash_packages(f, "1.31.0"), ["ash", "extra"], "changes the sha")
      F.publish(f, packages, sequence: 2)
      new_sha = F.get(:batch)["payload"] |> Base.url_decode64!(padding: false) |> :json.decode()

      run_capturing(config, env)
      assert_received {:report, {:ok, %{hits: 1, lines: [%{name: "ash", status: :hit}]}}}

      assert Path.join(lib, "ash/.mix/elixir_precompiled.json")
             |> File.read!()
             |> :json.decode()
             |> Map.take(["manifest_sha256", "batch_sequence"]) ==
               %{"manifest_sha256" => new_sha["manifests_v2"]["ash"], "batch_sequence" => 2}
    end

    test "an unreadable provenance file counts as revoked", %{
      f: f,
      config: config,
      env: env,
      lib: lib
    } do
      env = install_ash(f, config, env)
      File.write!(Path.join(lib, "ash/.mix/elixir_precompiled.json"), "not json {")

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
      assert File.exists?(Path.join(lib, "jason/.mix/elixir_precompiled.json"))
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
      refute File.exists?(Path.join(lib, "ash/.mix/elixir_precompiled.json"))
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
               "precompiled: no fresh batch (batch unavailable); " <>
                 "2 installed builds kept, not rechecked\n"

      assert [
               %{name: "ash", status: :fail, detail: "batch unavailable (installed build kept)"},
               %{name: "jason", status: :fail, detail: "batch unavailable (installed build kept)"}
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
      assert File.exists?(Path.join(lib, "ash/.mix/elixir_precompiled.json"))
    end
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
      |> Enum.reject(&File.dir?/1)
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

  test "an unwritable home falls back to _build and still reads the old cache", %{
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
end
