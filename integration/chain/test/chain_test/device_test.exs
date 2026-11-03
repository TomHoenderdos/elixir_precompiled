# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.DeviceTest do
  # FakeBin changes the global PATH.
  use ExUnit.Case, async: false

  alias ChainTest.{Device, FakeBin, Preflight, Result, Synthetic}

  @moduletag :tmp_dir

  @begin "-----BEGIN CHAIN PROBE-----"
  @finish "-----END CHAIN PROBE-----"
  @uuid "30be4482-7e87-555e-9718-3e4e4d5e961f"

  @files %{
    "jason" => %{"ebin/Elixir.Jason.beam" => "jason beam", "ebin/jason.app" => "{app}"},
    "exqlite" => %{
      "ebin/Elixir.Exqlite.beam" => "exqlite beam",
      "ebin/exqlite.app" => "{app}",
      "priv/sqlite3_nif.so" => "stripped nif"
    }
  }

  setup %{tmp_dir: tmp} do
    release = Path.join(tmp, "rel/chain_fixture")

    for {app, files} <- @files, {path, bytes} <- files do
      vsn = if app == "jason", do: "1.4.5", else: "0.42.0"
      full = Path.join([release, "lib", "#{app}-#{vsn}", path])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, bytes)
    end

    known_hosts = Path.join(tmp, "known_hosts")
    File.write!(known_hosts, "")
    %{release: release, known_hosts: known_hosts, tmp: tmp}
  end

  defp doc(overrides \\ %{}) do
    files =
      Map.new(@files, fn {app, files} ->
        {app,
         files
         |> Enum.map(fn {p, b} -> %{"path" => p, "sha256" => Synthetic.sha(b)} end)
         |> Enum.sort_by(& &1["path"])}
      end)

    Map.merge(
      %{
        "apps" => %{"jason" => "ok", "exqlite" => "ok"},
        "modules" => %{"loaded" => 42, "failed" => []},
        "smoke" => %{"exqlite" => "ok", "argon2" => "ok", "gpio" => "ok"},
        "files" => files,
        "firmware_uuid" => @uuid,
        "nerves_system" => "nerves_system_rpi4 2.0.1"
      },
      overrides
    )
  end

  defp block(doc), do: "#{@begin}\n#{JSON.encode!(doc)}\n#{@finish}\n"

  # A fake ssh printing `out` (CRLF line ends, as over a real channel).
  defp run_with(ctx, out, opts \\ []) do
    file = Path.join(ctx.tmp, "probe.out")
    File.write!(file, String.replace(out, "\n", "\r\n"))
    exit = Keyword.get(opts, :exit, 0)

    FakeBin.with_stubs(%{"ssh" => "cat '#{file}'; exit #{exit}"}, fn dir ->
      results =
        Device.run(%{
          device: "dev.local",
          known_hosts: ctx.known_hosts,
          apps: [:jason, :exqlite],
          release_dir: ctx.release,
          expected_uuid: Keyword.get(opts, :expected_uuid, @uuid),
          system: {"nerves_system_rpi4", "2.0.1"}
        })

      {results, FakeBin.argv(dir, "ssh")}
    end)
  end

  defp by_check(results), do: Map.new(results, &{&1.check, &1})

  @checks ~w(probe app:jason app:exqlite modules smoke:argon2 smoke:exqlite smoke:gpio
             files:jason files:exqlite firmware_uuid nerves_system)

  test "a clean probe passes every check", ctx do
    {results, argv} = run_with(ctx, block(doc()))

    assert Enum.map(results, & &1.check) == @checks
    assert Enum.all?(results, &match?(%Result{step: :device, class: :pass}, &1)), inspect(results)

    assert argv ==
             Preflight.ssh_opts(ctx.known_hosts) ++
               ["dev.local", ~s|ChainFixture.Probe.run(["jason", "exqlite"])|]
  end

  test "an IEx banner and log lines around the block are ignored", ctx do
    out =
      "Interactive Elixir (1.20.3) - press Ctrl+C to exit\n" <>
        "12:00:01.123 [info] something started\n" <>
        block(doc()) <>
        "12:00:02.000 [warning] a late log line\n:ok\n"

    {results, _} = run_with(ctx, out)
    assert Enum.all?(results, &(&1.class == :pass)), inspect(results)
  end

  test "two blocks fail the probe and exercise nothing else", ctx do
    {results, _} = run_with(ctx, block(doc()) <> block(doc()))
    r = by_check(results)

    assert r["probe"].class == :fail
    assert r["probe"].detail =~ "exactly one"
    assert Enum.all?(results -- [r["probe"]], &(&1.class == :not_exercised))
    assert Result.exit_code(results) == 1
  end

  test "no block fails the probe with the tail of the output", ctx do
    {results, _} =
      run_with(ctx, "** (UndefinedFunctionError) ChainFixture.Probe.run/1\n", exit: 1)

    r = by_check(results)

    assert r["probe"].class == :fail
    assert r["probe"].detail =~ "UndefinedFunctionError"
  end

  test "a BEGIN without an END fails", ctx do
    {results, _} = run_with(ctx, "#{@begin}\n#{JSON.encode!(doc())}\n")
    assert by_check(results)["probe"].class == :fail
  end

  test "garbage inside the block fails, it never passes", ctx do
    out = "#{@begin}\n12:00 [info] interleaved\n#{JSON.encode!(doc())}\n#{@finish}\n"
    {results, _} = run_with(ctx, out)
    assert by_check(results)["probe"].class == :fail
  end

  test "a device file hash different from the release image is a disagreement", ctx do
    files = doc()["files"]

    exqlite =
      Enum.map(files["exqlite"], fn
        %{"path" => "priv/sqlite3_nif.so"} = f -> %{f | "sha256" => Synthetic.sha("other")}
        f -> f
      end)

    {results, _} = run_with(ctx, block(doc(%{"files" => %{files | "exqlite" => exqlite}})))
    r = by_check(results)

    assert r["files:exqlite"].class == :disagreement
    assert r["files:exqlite"].detail =~ "priv/sqlite3_nif.so"
    assert r["files:jason"].class == :pass
    assert Result.exit_code(results) == 1
  end

  test "a file missing on the device or extra on it is a disagreement", ctx do
    files = doc()["files"]
    jason = tl(files["jason"]) ++ [%{"path" => "ebin/extra.beam", "sha256" => Synthetic.sha("x")}]

    {results, _} = run_with(ctx, block(doc(%{"files" => %{files | "jason" => jason}})))
    detail = by_check(results)["files:jason"].detail

    assert by_check(results)["files:jason"].class == :disagreement
    assert detail =~ "ebin/extra.beam"
    assert detail =~ "missing on the device"
  end

  test "a failed app start, module load or smoke call fails its check", ctx do
    overrides = %{
      "apps" => %{"jason" => "ok", "exqlite" => "error: {:bad, :nif}"},
      "modules" => %{
        "loaded" => 40,
        "failed" => ["Exqlite.Sqlite3NIF: {:error, :on_load_failure}"]
      },
      "smoke" => %{"exqlite" => "error: nif not loaded", "argon2" => "ok", "gpio" => "ok"}
    }

    {results, _} = run_with(ctx, block(doc(overrides)))
    r = by_check(results)

    assert r["app:exqlite"].class == :fail
    assert r["app:exqlite"].detail =~ ":bad"
    assert r["app:jason"].class == :pass
    assert r["modules"].class == :fail
    assert r["modules"].detail =~ "Sqlite3NIF"
    assert r["smoke:exqlite"].class == :fail
    assert r["smoke:argon2"].class == :pass
  end

  test "the device running another firmware uuid fails", ctx do
    {results, _} = run_with(ctx, block(doc(%{"firmware_uuid" => "other"})))
    detail = by_check(results)["firmware_uuid"].detail

    assert by_check(results)["firmware_uuid"].class == :fail
    assert detail =~ @uuid
    assert detail =~ "other"
  end

  test "another nerves system fails, an unknown one is not exercised", ctx do
    {results, _} = run_with(ctx, block(doc(%{"nerves_system" => "nerves_system_rpi4 1.9.0"})))
    assert by_check(results)["nerves_system"].class == :fail

    {results, _} = run_with(ctx, block(doc(%{"nerves_system" => "unknown"})))
    assert by_check(results)["nerves_system"].class == :not_exercised
  end

  test "an app name that is not a plain atom name is refused", ctx do
    assert_raise ArgumentError, fn ->
      Device.run(%{
        device: "dev.local",
        known_hosts: ctx.known_hosts,
        apps: [~s|jason"]); System.halt(0); (["|],
        release_dir: ctx.release
      })
    end
  end
end
