# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule PrecompiledCacheTest do
  use ExUnit.Case, async: false
  import ElixirPrecompiled.DeviceFixture
  alias ElixirPrecompiled.{Device.Loader, Fixture}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!(ElixirPrecompiled.TestServer)
    f = Fixture.new(dir)

    host =
      env(
        system: nil,
        otp: System.otp_release(),
        elixir: System.version(),
        cpu: to_string(:erlang.system_info(:system_architecture))
      )

    opts = [
      source: Fixture.base_url(),
      root: f.root_path,
      dir: Path.join(dir, "store"),
      env: host,
      quiet: true
    ]

    build = publish_app(f, dir, :demo_cache, "1.0.0")
    Fixture.publish(f, %{"demo_cache" => manifest(%{"1.0.0" => [build]})})
    {:ok, [%{from_cache?: false}]} = Precompiled.install(:demo_cache, opts)
    # A reboot: the VM forgets the app, the files stay on /data.
    :ok = Loader.deactivate(:demo_cache, Path.join(opts[:dir], "demo_cache-1.0.0"), true)
    Fixture.clear_requests()
    on_exit(fn -> unload_all(opts) end)
    %{f: f, opts: opts, build: build}
  end

  defp unload_all(opts) do
    for %{loaded?: true, app: app} <- Precompiled.list(Keyword.take(opts, [:dir, :quiet])),
        do:
          Precompiled.uninstall(
            app,
            Keyword.take(opts, [:dir, :quiet]) ++ [force: true, cascade: true]
          )
  end

  test "after a reboot nothing is loaded; installing again loads from the cache with no file download",
       %{opts: opts} do
    assert :code.is_loaded(DemoCache) == false

    assert {:ok, [%{app: :demo_cache, from_cache?: true}]} =
             Precompiled.install(:demo_cache, opts)

    assert DemoCache.hello() == :hello
    refute Enum.any?(Fixture.requests(), &String.starts_with?(&1.path, "/precompiled/files/"))
    # The batch and manifest were still checked: the signed hashes came from them.
    assert Enum.any?(Fixture.requests(), &(&1.path == "/precompiled/batch.json"))
  end

  test "a changed cached file is downloaded again, never loaded", %{opts: opts} do
    [beam | _] = Path.wildcard(Path.join(opts[:dir], "demo_cache-1.0.0/ebin/*.beam"))
    File.write!(beam, "evil")
    assert {:ok, [%{from_cache?: false}]} = Precompiled.install(:demo_cache, opts)
    assert DemoCache.hello() == :hello
    assert Enum.any?(Fixture.requests(), &String.starts_with?(&1.path, "/precompiled/files/"))
  end

  test "a cached build the batch no longer names is not loaded", %{f: f, opts: opts} do
    Fixture.publish(f, %{}, sequence: 2)
    assert {:error, {:no_build, "demo_cache", _}} = Precompiled.install(:demo_cache, opts)
    assert :code.is_loaded(DemoCache) == false
  end

  test "LRU eviction makes room for a new install and keeps the loaded app", %{
    f: f,
    opts: opts,
    tmp_dir: dir,
    build: build
  } do
    {:ok, _} = Precompiled.install(:demo_cache, opts)
    other = publish_app(f, dir, :demo_old, "1.0.0")
    newer = publish_app(f, dir, :demo_new, "1.0.0")

    Fixture.publish(
      f,
      %{
        "demo_cache" => manifest(%{"1.0.0" => [build]}),
        "demo_old" => manifest(%{"1.0.0" => [other]}),
        "demo_new" => manifest(%{"1.0.0" => [newer]})
      },
      sequence: 3
    )

    {:ok, _} = Precompiled.install(:demo_old, opts ++ [start: false])
    :ok = Loader.deactivate(:demo_old, Path.join(opts[:dir], "demo_old-1.0.0"), true)
    used = ElixirPrecompiled.Device.Store.used_bytes(opts[:dir])
    plan = Enum.sum(for e <- newer["ebin"] ++ newer["priv"], do: e["size"])

    assert {:ok, [%{app: :demo_new}]} =
             Precompiled.install(:demo_new, opts ++ [max_bytes: used + 2 * plan - 1])

    apps = Precompiled.list(opts) |> Enum.map(& &1.app) |> Enum.sort()
    assert :demo_cache in apps
    refute :demo_old in apps
  end

  test "clean/1 removes the cache but not what is loaded", %{opts: opts} do
    {:ok, _} = Precompiled.install(:demo_cache, opts)
    assert {:ok, %{kept: [:demo_cache], removed: []}} = Precompiled.clean(opts)
    :ok = Loader.deactivate(:demo_cache, Path.join(opts[:dir], "demo_cache-1.0.0"), true)
    assert {:ok, %{removed: [:demo_cache]}} = Precompiled.clean(opts)
    assert Precompiled.list(opts) == []
  end
end
