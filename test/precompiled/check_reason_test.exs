# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CheckReasonTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.{Check, Env, Reason}
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
      for {k, _} <- Application.get_all_env(:precompiled),
          do: Application.delete_env(:precompiled, k)

      System.delete_env("PRECOMPILED_HOME")
    end)

    f = F.new(dir)
    Application.put_all_env(precompiled: [source: F.base_url(), root: f.root_path])
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
        mix_target: "rpi4",
        build_lib: lib,
        deps_path: Path.join(dir, "deps")
      }
    }
  end

  defp run(config, env) do
    capture_io(:stderr, fn ->
      capture_io(fn ->
        send(self(), {:report, Check.check(config, env, config_fun: fn _, _ -> :error end)})
      end)
    end)

    assert_received {:report, {:ok, report}}
    report
  end

  # JSON null decodes as nil, so a host's context compares with nil.
  defp report_json(lib) do
    bytes = lib |> Path.join(".precompiled/report.json") |> File.read!()
    {json, :ok, ""} = :json.decode(bytes, :ok, %{null: nil})
    json
  end

  test "lines carry codes, and report.json records codes, built_at and context", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{"ash" => %{"versions" => %{"3.4.0" => %{"builds" => []}}}})

    report = run(config, env)

    assert [
             %{name: "ash", reason: {:not_built_version, ["3.5.2"]}},
             %{name: "jason", reason: {:not_in_batch, []}}
           ] =
             report.lines

    json = report_json(lib)
    assert json["format"] == 1
    assert {:ok, _, 0} = DateTime.from_iso8601(json["built_at"])

    assert json["context"] == %{
             "elixir" => System.version(),
             "otp" => to_string(:erlang.system_info(:otp_release)),
             "target" => "rpi4",
             "system" => "nerves_system_rpi4",
             "system_version" => "1.31.0"
           }

    assert [
             %{
               "name" => "ash",
               "status" => "miss",
               "reason_code" => "not_built_version",
               "reason_args" => ["3.5.2"],
               "detail" => "not built for 3.5.2"
             },
             %{"name" => "jason", "reason_code" => "not_in_batch", "reason_args" => []}
           ] = json["lines"]
  end

  test "a host project records no system", %{f: f, config: config, env: env, lib: lib} do
    F.publish(f, %{})
    run(config, %{env | system: nil, mix_target: "host"})

    assert %{"system" => nil, "system_version" => nil, "target" => "host"} =
             report_json(lib)["context"]
  end

  test "an unavailable batch fails every candidate with fetch_failed", %{
    config: config,
    env: env,
    lib: lib
  } do
    F.withdraw_batch()
    run(config, env)

    assert Enum.all?(
             report_json(lib)["lines"],
             &(&1["status"] == "fail" and &1["reason_code"] == "fetch_failed")
           )
  end

  test "offline with a manifest that was never cached: a fetch_failed miss, no crash", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => []}}}})

    # Online, with only jason as a candidate: the batch is fetched and
    # cached, ash's manifest never is.
    run(config, %{env | candidates: tl(env.candidates)})

    System.put_env("PRECOMPILED_OFFLINE", "1")
    on_exit(fn -> System.delete_env("PRECOMPILED_OFFLINE") end)
    offline = Precompiled.Config.load()
    assert offline.offline

    run(offline, env)
    lines = report_json(lib)["lines"]

    assert %{
             "status" => "miss",
             "reason_code" => "fetch_failed",
             "detail" => "offline: manifest not cached"
           } =
             Enum.find(lines, &(&1["name"] == "ash"))

    refute Enum.any?(lines, &(&1["reason_code"] == "internal"))
  end

  test "an excepted install is coded excepted", %{f: f, config: config, env: env, lib: lib} do
    for dir <- ["ash/ebin", "ash/.mix"], do: File.mkdir_p!(Path.join(lib, dir))
    File.write!(Precompiled.Fetch.provenance_path(lib, :ash), ~s({"manifest_sha256":"x"}))
    F.publish(f, %{})

    run(%{config | except: [:ash]}, %{env | candidates: tl(env.candidates), installed: [:ash]})

    assert Enum.any?(
             report_json(lib)["lines"],
             &(&1["name"] == "ash" and &1["reason_code"] == "excepted")
           )
  end

  test "every code a line can carry is in the shared table", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{"builds" => []}}}})
    run(config, env)
    codes = Enum.map(Reason.codes(), &Atom.to_string/1)
    assert Enum.all?(report_json(lib)["lines"], &(&1["reason_code"] in codes))
  end
end
