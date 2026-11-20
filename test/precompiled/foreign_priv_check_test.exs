# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ForeignPrivCheckTest do
  # 0.8.0 Phase B on a fake build lib against the local signed fixture: a
  # writer's archives go into kino's build priv only once kino is settled.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Precompiled.{Check, Env, Fetch}
  alias Precompiled.Fixture, as: F

  @moduletag :tmp_dir
  @kino {:hex, :kino, "0.19.1", "i", [:mix], [], "hexpm", "KOUTER"}
  @writer {:hex, :kino_vega_lite, "0.1.13", "i", [:mix],
           [{:kino, "~> 0.19", [hex: :kino, repo: "hexpm", optional: false]}], "hexpm", "WOUTER"}
  @twin {:hex, :kino_twin, "1.0.0", "i", [:mix],
         [{:kino, "~> 0.19", [hex: :kino, repo: "hexpm", optional: false]}], "hexpm", "TOUTER"}
  @h "uxwh53kfq2wszgf23hqwgkuiza"
  @archive "the writer's archive"

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
    lib = Path.join(dir, "_build/dev/lib")

    env = %Env{
      candidates: [
        %{name: :kino, version: "0.19.1", lock_entry: @kino},
        %{name: :kino_vega_lite, version: "0.1.13", lock_entry: @writer}
      ],
      lock: %{kino: @kino, kino_vega_lite: @writer},
      system: {"host", ""},
      build_lib: lib,
      deps_path: Path.join(dir, "deps"),
      compiled_ok: MapSet.new()
    }

    %{f: f, lib: lib, env: env, dir: dir}
  end

  defp configure(opts) do
    for {k, _} <- Application.get_all_env(:precompiled),
        do: Application.delete_env(:precompiled, k)

    Application.put_all_env([{:precompiled, opts}])
  end

  defp run(env, opts \\ []) do
    opts = Keyword.put_new(opts, :config_fun, fn _, _ -> :error end)

    out =
      capture_io(:stderr, fn ->
        stdio =
          capture_io(fn ->
            send(self(), {:report, Check.check(Precompiled.Config.load(), env, opts)})
          end)

        send(self(), {:stdio, stdio})
      end)

    assert_received {:stdio, stdio}
    assert_received {:report, report}
    {report, stdio <> out}
  end

  defp file(f, path, bytes),
    do: %{
      "path" => path,
      "sha256" => F.file(f, bytes),
      "size" => byte_size(bytes),
      "mode" => 33_188
    }

  defp build(deps, checksum, over),
    do:
      Map.merge(
        %{
          "elixir" => System.version(),
          "otp" => to_string(:erlang.system_info(:otp_release)),
          "system_version" => nil,
          "run_id" => "r",
          "image_digest" => "d",
          "deps" => deps,
          "compile_env" => [],
          "package_checksum" => checksum,
          "dep_env" => "prod"
        },
        over
      )

  defp kino_entry(f, beam \\ "kino beam") do
    app = "{application, kino, [{vsn, \"0.19.1\"}, {modules, ['Elixir.Kino.HTML']}]}.\n"

    %{
      "target" => "pure_elixir",
      "ebin" => [file(f, "ebin/Elixir.Kino.HTML.beam", beam), file(f, "ebin/kino.app", app)],
      "priv" => [file(f, "priv/assets/Kino_HTML/#{@h}.tar.gz", "kino's own archive")],
      "build" => build(%{}, "KOUTER", %{"foreign_priv_target" => "kino"})
    }
  end

  defp writer_entry(
         f,
         archive \\ @archive,
         app \\ "kino_vega_lite",
         vsn \\ "0.1.13",
         checksum \\ "WOUTER"
       ) do
    app_file =
      "{application, #{app}, [{vsn, \"#{vsn}\"}, {modules, ['Elixir.Kino.VegaLite']}]}.\n"

    %{
      "target" => "pure_elixir",
      "ebin" => [
        file(f, "ebin/Elixir.Kino.VegaLite.beam", "writer beam #{app}"),
        file(f, "ebin/#{app}.app", app_file)
      ],
      "priv" => [],
      "foreign_priv" => [
        Map.put(file(f, "priv/assets/Kino_VegaLite/#{@h}.tar.gz", archive), "app", "kino")
      ],
      "build" =>
        build(%{"kino" => %{"version" => "0.19.1", "checksum" => "KOUTER"}}, checksum, %{
          "foreign_priv_rule" => "kino_js_v1"
        })
    }
  end

  defp publish(f, kino, writer, seq \\ 1) do
    F.publish(
      f,
      %{
        "kino" => %{
          "versions" => %{
            "0.19.1" => %{"builds" => [], "foreign_priv" => %{"builds" => List.wrap(kino)}}
          }
        },
        "kino_vega_lite" => %{
          "versions" => %{
            "0.1.13" => %{"builds" => [], "foreign_priv" => %{"builds" => List.wrap(writer)}}
          }
        }
      },
      sequence: seq
    )
  end

  defp placed(lib), do: Path.join(lib, "kino/priv/assets/Kino_VegaLite/#{@h}.tar.gz")

  # A kino Mix built: its dir, ebin and .app, no provenance.
  defp mix_built_kino(lib, priv \\ :dir) do
    File.mkdir_p!(Path.join(lib, "kino/ebin"))

    File.write!(
      Path.join(lib, "kino/ebin/kino.app"),
      "{application, kino, [{vsn, \"0.19.1\"}, {modules, ['Elixir.Kino.HTML']}]}.\n"
    )

    if priv == :dir, do: File.mkdir_p!(Path.join(lib, "kino/priv/assets/Kino_HTML"))
  end

  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(
      &(String.contains?(&1, "/.precompiled") or String.ends_with?(&1, "report.json"))
    )
    |> Map.new(fn p ->
      {Path.relative_to(p, dir), if(File.regular?(p), do: File.read!(p), else: :dir)}
    end)
  end

  defp installed(env),
    do: %{
      env
      | candidates: [],
        installed: [:kino, :kino_vega_lite],
        installed_envs: %{kino: "prod", kino_vega_lite: "prod"}
    }

  test "kino placed in Phase A, then the writer's archive placed into it",
       %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, report}, out} = run(env)
    assert report.hits == 2, out
    assert out =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT\s+.*; 1 archive into kino/
    assert File.read!(placed(lib)) == @archive
    assert Bitwise.band(File.lstat!(placed(lib)).mode, 0o777) == 0o644
    assert Fetch.installed_as?(lib, :kino, kino_entry(f))

    [entry] = writer_entry(f)["foreign_priv"]
    doc = :json.decode(File.read!(Fetch.provenance_path(lib, :kino_vega_lite)))
    assert doc["foreign"] == [entry]
    refute Map.has_key?(:json.decode(File.read!(Fetch.provenance_path(lib, :kino))), "foreign")

    report_file = Path.join(lib, ".precompiled/report.json") |> File.read!() |> :json.decode()

    assert %{"status" => "hit", "reason_code" => "hit"} =
             Enum.find(report_file["lines"], &(&1["name"] == "kino_vega_lite"))
  end

  test "kino Mix-built and ok: the writer is placed into it", %{f: f, lib: lib, env: env} do
    publish(f, nil, writer_entry(f))
    mix_built_kino(lib)
    env = %{env | candidates: tl(env.candidates), compiled_ok: MapSet.new([:kino])}
    {{:ok, report}, out} = run(env)
    assert report.hits == 1, out
    assert File.read!(placed(lib)) == @archive
  end

  test "kino Mix-built but not loaded as compiled: target_compiles", %{f: f, lib: lib, env: env} do
    publish(f, nil, writer_entry(f))
    mix_built_kino(lib)

    for ok <- [MapSet.new(), nil] do
      env = %{env | candidates: tl(env.candidates), compiled_ok: ok}
      {{:ok, report}, out} = run(env)
      assert report.misses == 1, out

      assert out =~
               ~r/kino_vega_lite 0\.1\.13\s+MISS\s+writes into kino's priv; kino compiles from source in this run/

      refute File.exists?(placed(lib))
      refute File.exists?(Path.join(lib, "kino_vega_lite"))
    end
  end

  test "kino a candidate that missed: target_compiles, and an installed writer is removed",
       %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    assert File.dir?(Path.join(lib, "kino_vega_lite"))

    # The next run: both installed, kino no longer built.
    publish(f, nil, writer_entry(f), 2)
    {{:ok, report}, out} = run(installed(env))

    assert out =~
             ~r/precompiled: kino_vega_lite 0\.1\.13\s+MISS\s+writes into kino's priv; kino compiles from source in this run/

    assert report.misses == 2

    report_file = Path.join(lib, ".precompiled/report.json") |> File.read!() |> :json.decode()

    assert %{"reason_code" => "foreign_priv_target_compiles", "reason_args" => ["kino"]} =
             Enum.find(report_file["lines"], &(&1["name"] == "kino_vega_lite"))

    refute File.exists?(Path.join(lib, "kino_vega_lite"))
  end

  test "kino excepted this run: target_compiles", %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    configure(source: F.base_url(), root: f.root_path, except: [:kino])
    {{:ok, _report}, out} = run(%{installed(env) | compiled_ok: MapSet.new([:kino])})
    assert out =~ ~r/kino 0\.19\.1\s+MISS\s+excepted/
    assert out =~ "writes into kino's priv; kino compiles from source in this run"
    refute File.exists?(Path.join(lib, "kino_vega_lite"))
  end

  test "a kino priv link: target_linked; no kino: target_missing",
       %{f: f, lib: lib, env: env, dir: dir} do
    publish(f, nil, writer_entry(f))
    mix_built_kino(lib, :none)
    File.mkdir_p!(Path.join(dir, "deps/kino/priv"))
    File.ln_s!(Path.join(dir, "deps/kino/priv"), Path.join(lib, "kino/priv"))
    env = %{env | candidates: tl(env.candidates), compiled_ok: MapSet.new([:kino])}
    {_, out} = run(env)
    assert out =~ "writes into kino's priv, which links to its sources"
    assert File.ls!(Path.join(dir, "deps/kino/priv")) == []

    File.rm_rf!(Path.join(lib, "kino"))
    {_, out} = run(env)
    assert out =~ "writes into kino's priv; kino is not in this build"
  end

  test "a conflict: another dependency's module claims the directory",
       %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    File.mkdir_p!(Path.join(lib, "other/ebin"))

    File.write!(
      Path.join(lib, "other/ebin/other.app"),
      "{application, other, [{vsn, \"1\"}, {modules, ['Elixir.Kino.VegaLite']}]}.\n"
    )

    {_, out} = run(env)
    assert out =~ "writes kino's priv/assets/Kino_VegaLite, which other also claims"
    refute File.exists?(placed(lib))
  end

  test "a conflict: kino's own module claims the directory", %{f: f, lib: lib, env: env} do
    publish(f, nil, writer_entry(f))
    File.mkdir_p!(Path.join(lib, "kino/ebin"))

    File.write!(
      Path.join(lib, "kino/ebin/kino.app"),
      "{application, kino, [{vsn, \"0.19.1\"}, {modules, ['Elixir.Kino.VegaLite']}]}.\n"
    )

    env = %{env | candidates: tl(env.candidates), compiled_ok: MapSet.new([:kino])}
    {_, out} = run(env)
    assert out =~ "writes kino's priv/assets/Kino_VegaLite, which kino also claims"
    refute File.exists?(placed(lib))
  end

  # Spec 6: two writers claiming one <d> both miss.
  test "two writers this run claiming one directory both miss", %{f: f, lib: lib, env: env} do
    F.publish(f, %{
      "kino" => %{
        "versions" => %{
          "0.19.1" => %{"builds" => [], "foreign_priv" => %{"builds" => [kino_entry(f)]}}
        }
      },
      "kino_vega_lite" => %{
        "versions" => %{
          "0.1.13" => %{"builds" => [], "foreign_priv" => %{"builds" => [writer_entry(f)]}}
        }
      },
      "kino_twin" => %{
        "versions" => %{
          "1.0.0" => %{
            "builds" => [],
            "foreign_priv" => %{
              "builds" => [writer_entry(f, "twin", "kino_twin", "1.0.0", "TOUTER")]
            }
          }
        }
      }
    })

    env = %{
      env
      | candidates: env.candidates ++ [%{name: :kino_twin, version: "1.0.0", lock_entry: @twin}],
        lock: Map.put(env.lock, :kino_twin, @twin)
    }

    {{:ok, report}, out} = run(env)
    assert report.hits == 1, out
    assert out =~ "writes kino's priv/assets/Kino_VegaLite, which kino_twin also claims"
    assert out =~ "writes kino's priv/assets/Kino_VegaLite, which kino_vega_lite also claims"
    refute File.exists?(placed(lib))
  end

  # The rename into a priv/assets this user cannot write fails after the
  # target was found settled and the archive staged.
  @tag :non_root
  test "a failure mid-placement removes the writer and changes nothing outside A/<d>",
       %{f: f, lib: lib, env: env, dir: dir} do
    publish(f, nil, writer_entry(f))
    mix_built_kino(lib)
    assets = Path.join(lib, "kino/priv/assets")
    File.chmod!(assets, 0o555)
    on_exit(fn -> File.chmod(assets, 0o755) end)
    File.mkdir_p!(Path.join(dir, "deps"))
    env = %{env | candidates: tl(env.candidates), compiled_ok: MapSet.new([:kino])}
    before = {tree(lib), tree(Path.join(dir, "deps"))}
    {{:ok, report}, out} = run(env)
    assert report.fails == 1, out
    assert out =~ ~r/kino_vega_lite 0\.1\.13\s+FAIL\s+install failed/
    assert {tree(lib), tree(Path.join(dir, "deps"))} == before
  end

  test "a second run writes nothing", %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    stat = File.stat!(placed(lib), time: :posix)
    Process.sleep(1100)
    {_, out} = run(installed(env))
    refute out =~ "HIT"
    refute out =~ "MISS"
    assert File.stat!(placed(lib), time: :posix).mtime == stat.mtime
  end

  # Review Focus 2.
  test "archives Mix wiped are placed again on the next run", %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    writer_beam = Path.join(lib, "kino_vega_lite/ebin/Elixir.Kino.VegaLite.beam")
    beam_stat = File.stat!(writer_beam, time: :posix)
    File.rm_rf!(Path.join(lib, "kino/priv/assets/Kino_VegaLite"))
    Process.sleep(1100)
    {_, out} = run(installed(env))
    refute out =~ "MISS"
    assert File.read!(placed(lib)) == @archive
    assert File.stat!(writer_beam, time: :posix).mtime == beam_stat.mtime
  end

  # D2: kino replaced in Phase A keeps every writer archive.
  test "kino replaced keeps the writer's archive", %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    publish(f, kino_entry(f, "a newer kino beam"), writer_entry(f), 2)
    {_, out} = run(installed(env))
    assert out =~ ~r/precompiled: kino 0\.19\.1\s+HIT/
    refute out =~ "kino_vega_lite"
    assert File.read!(placed(lib)) == @archive
  end

  test "a writer whose archive changed is installed again", %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    publish(f, kino_entry(f), writer_entry(f, "a newer archive"), 2)
    {_, out} = run(installed(env))
    assert out =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT\s+.*; 1 archive into kino/
    assert File.read!(placed(lib)) == "a newer archive"
  end

  # Review Focus 5.
  test "a batch without the foreign object revokes the writer and kino, and Mix-built owners are marked",
       %{f: f, lib: lib, env: env} do
    publish(f, kino_entry(f), writer_entry(f))
    {{:ok, _}, _} = run(env)
    File.mkdir_p!(Path.join(lib, "proj/ebin"))
    File.mkdir_p!(Path.join(lib, "proj/.mix"))

    File.write!(
      Path.join(lib, "proj/ebin/proj.app"),
      "{application, proj, [{vsn, \"1\"}, {modules, ['Elixir.ProjWidget']}]}.\n"
    )

    File.write!(Path.join(lib, "proj/.mix/compile.elixir_scm"), "scm")
    File.mkdir_p!(Path.join(lib, "kino/priv/assets/ProjWidget"))

    F.publish(
      f,
      %{
        "kino" => %{"versions" => %{"0.19.1" => %{"builds" => []}}},
        "kino_vega_lite" => %{"versions" => %{"0.1.13" => %{"builds" => []}}}
      },
      sequence: 2
    )

    {{:ok, report}, _out} = run(installed(env))
    assert report.misses == 2
    refute File.exists?(Path.join(lib, "kino"))
    refute File.exists?(Path.join(lib, "kino_vega_lite"))
    refute File.exists?(Path.join(lib, "proj/.mix/compile.elixir_scm"))
  end
end
