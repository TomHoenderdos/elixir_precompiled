# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HexPackageTest do
  # A dep declared `{:eini, "~> 2.2", hex: :eini_beam}` locks as
  # `eini: {:hex, :eini_beam, ...}`: Mix installs, compiles and loads the
  # app eini, from the Hex package eini_beam. The Hex package eini is
  # another one. The portal builds, and the batch names, Hex packages.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.{Check, Env, Match}
  alias Precompiled.Fixture, as: F
  @moduletag :tmp_dir

  @beam_outer String.duplicate("b", 64)
  @eini_outer String.duplicate("e", 64)
  @lock_entry {:hex, :eini_beam, "2.2.5", "i", [:rebar3], [], "hexpm", @beam_outer}

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
        candidates: [%{name: :eini, version: "2.2.5", lock_entry: @lock_entry}],
        lock: %{eini: @lock_entry},
        dep_sources: %{eini: @lock_entry},
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

  defp run(config, env) do
    parent = self()
    opts = [config_fun: fn _, _ -> :error end]

    capture_io(:stderr, fn ->
      capture_io(fn -> send(parent, {:report, Check.check(config, env, opts)}) end)
    end)

    assert_received {:report, {:ok, report}}
    report
  end

  # A build of the app eini (both packages' OTP app is called eini), from
  # the package whose outer checksum is `outer`, with `beam` as its code.
  defp build(f, beam, outer) do
    app = "{application, eini, [{vsn, \"2.2.5\"}, {modules, ['eini']}]}.\n"

    %{
      "target" => "nerves_system_rpi4",
      "ebin" => [
        %{"path" => "ebin/eini.beam", "sha256" => F.file(f, beam), "size" => byte_size(beam)},
        %{"path" => "ebin/eini.app", "sha256" => F.file(f, app), "size" => byte_size(app)}
      ],
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "system_version" => "1.31.0",
        "run_id" => "r",
        "image_digest" => "d",
        "deps" => %{},
        "compile_env" => [],
        "package_checksum" => outer,
        "dep_env" => "prod"
      }
    }
    |> update_in(["ebin"], fn files -> Enum.map(files, &Map.put(&1, "mode", 33188)) end)
  end

  defp package(builds), do: %{"versions" => %{"2.2.5" => %{"builds" => builds}}}

  defp installed_beam(lib), do: File.read(Path.join(lib, "eini/ebin/eini.beam"))

  test "the manifest is the Hex package's; the build installs as the app", %{
    f: f,
    config: config,
    env: env,
    lib: lib
  } do
    F.publish(f, %{
      "eini_beam" => package([build(f, "eini_beam's code", @beam_outer)]),
      "eini" => package([build(f, "the other package's code", @eini_outer)])
    })

    report = run(config, env)
    assert [%{name: "eini", status: :hit}] = report.lines
    assert installed_beam(lib) == {:ok, "eini_beam's code"}

    # The next run rechecks the install against the same manifest.
    report = run(config, %{env | candidates: [], installed: [:eini]})
    assert Enum.all?(report.lines, &(&1.status != :fail))
    assert installed_beam(lib) == {:ok, "eini_beam's code"}
  end

  test "another package under the app's name is never installed, even one passing every rule",
       %{f: f, config: config, env: env, lib: lib} do
    # What the lookup by app name would install: the package eini's build,
    # its checksum the lock's (a portal recording the wrong one, say).
    # Looked up by the Hex package, eini_beam is simply not in the batch.
    F.publish(f, %{"eini" => package([build(f, "the other package's code", @beam_outer)])})

    report = run(config, env)
    assert [%{name: "eini", status: :miss, reason: {:not_in_batch, []}}] = report.lines
    assert installed_beam(lib) == {:error, :enoent}
  end

  test "the package checksum alone refuses another package's build of the same app", %{f: f} do
    # The guard the lookup by app name had: the lock's outer checksum is
    # eini_beam's tarball, which no build of eini can record.
    other = build(f, "x", @eini_outer)

    {:ok, manifest} =
      [other] |> package() |> Map.put("format", 2) |> Precompiled.Manifest.normalize()

    ctx = %{
      name: "eini",
      version: "2.2.5",
      lock_entry: @lock_entry,
      lock: %{eini: @lock_entry},
      dep_sources: %{eini: @lock_entry},
      env_closure: nil,
      system: {"nerves_system_rpi4", "1.31.0"},
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      dep_env: "prod",
      config: fn _, _ -> :error end
    }

    assert {:miss, %{code: :checksum_differs}} = Match.select_reason(manifest, ctx)

    # And it is the only rule that does: with the lock's checksum, the
    # same build of the other package is selected.
    {:ok, manifest} =
      [put_in(other, ["build", "package_checksum"], @beam_outer)]
      |> package()
      |> Map.put("format", 2)
      |> Precompiled.Manifest.normalize()

    assert {:ok, _entry, _} = Match.select_reason(manifest, ctx)
  end
end
