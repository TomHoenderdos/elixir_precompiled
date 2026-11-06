# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.FileStampCacheTest do
  # How the stamps are used by an install from the file cache: recorded
  # once a cached file hashed to its sha, kept in the home, and taken at
  # their word only while they match the open file exactly.
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.{Config, Fetch, FileStamp}
  alias ElixirPrecompiled.Fixture, as: F

  @moduletag :tmp_dir
  @lock_entry {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "OUTER"}

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    f = F.new(dir)
    home = Path.join(dir, "home")
    File.mkdir_p!(Path.join(home, "files"))
    File.chmod!(home, 0o700)

    %{
      f: f,
      home: home,
      config: %{source: F.base_url(), except: [], root_path: f.root_path, home: home},
      build_lib: Path.join(dir, "_build/rpi4_dev/lib"),
      deps: Path.join(dir, "deps")
    }
  end

  defp file_entry(sha, size, path),
    do: %{"path" => path, "sha256" => sha, "size" => size, "mode" => 33188}

  defp entry(f, beam) do
    app = "{application, ash, [{modules, ['Elixir.Ash']}]}.\n"

    %{
      "ebin" => [
        file_entry(F.file(f, beam), byte_size(beam), "ebin/Elixir.Ash.beam"),
        file_entry(F.file(f, app), byte_size(app), "ebin/ash.app")
      ],
      "priv" => [],
      "build" => %{}
    }
  end

  defp install(config, entry, lib, deps),
    do: Fetch.install(config, :ash, entry, @lock_entry, lib, deps_path: deps)

  defp cached(home, bytes), do: Path.join([home, "files", F.sha(bytes)])

  defp installed(lib), do: File.read!(Path.join([lib, "ash", "ebin", "Elixir.Ash.beam"]))

  defp stat!(path), do: File.stat!(path, time: :posix)

  test "a cached file that hashed to its sha is stamped, and the stamp is kept", ctx do
    %{f: f, home: home, config: config, build_lib: lib, deps: deps} = ctx
    path = cached(home, "good")
    File.write!(path, "good")
    # A ctime in the current second is never stamped.
    Process.sleep(1_100)

    stamps = FileStamp.open(home)
    assert {:ok, _} = install(Map.put(config, :stamps, stamps), entry(f, "good"), lib, deps)
    assert FileStamp.match?(FileStamp.lookup(stamps, F.sha("good")), stat!(path), F.sha("good"))
    FileStamp.close(stamps, home)

    again = FileStamp.open(home)
    assert FileStamp.match?(FileStamp.lookup(again, F.sha("good")), stat!(path), F.sha("good"))
    FileStamp.close(again, home)
  end

  # White-box: a stamp is what spares the hash. One that matches the open
  # file is believed, so different bytes behind it are not looked at.
  test "a stamp that matches the open file spares the hash", ctx do
    %{f: f, home: home, config: config, build_lib: lib, deps: deps} = ctx
    path = cached(home, "good")
    File.write!(path, "baad")
    stamps = FileStamp.open(home)
    FileStamp.put(stamps, FileStamp.new(stat!(path), F.sha("good")))

    assert {:ok, _} = install(Map.put(config, :stamps, stamps), entry(f, "good"), lib, deps)
    assert installed(lib) == "baad"
    FileStamp.close(stamps, home)
  end

  test "a stamp that no longer matches means a full hash, and a fetch", ctx do
    %{f: f, home: home, config: config, build_lib: lib, deps: deps} = ctx
    path = cached(home, "good")
    File.write!(path, "baad")
    stamps = FileStamp.open(home)
    stat = stat!(path)
    FileStamp.put(stamps, FileStamp.new(%{stat | ctime: stat.ctime - 1}, F.sha("good")))

    assert {:ok, _} = install(Map.put(config, :stamps, stamps), entry(f, "good"), lib, deps)
    assert installed(lib) == "good"
    assert File.read!(path) == "good"
    FileStamp.close(stamps, home)
  end

  test "a home others can write to keeps no stamps", %{home: home} do
    File.chmod!(home, 0o770)
    assert FileStamp.open(home) == nil
    refute File.exists?(Path.join(home, "file_stamps"))
  end

  test "a stamps file that is not one is no stamps", %{home: home} do
    File.write!(Path.join(home, "file_stamps"), "not a term")
    stamps = FileStamp.open(home)
    assert FileStamp.lookup(stamps, F.sha("good")) == nil
    FileStamp.close(stamps, home)
  end

  test "the cache gc and clean drop the stamps", %{home: home} do
    stamps_file = Path.join(home, "file_stamps")
    File.write!(stamps_file, "x")
    File.write!(Path.join([home, "files", F.sha("old")]), "old")
    ElixirPrecompiled.Cache.gc(home, 0)
    refute File.exists?(stamps_file)

    File.write!(stamps_file, "x")
    ElixirPrecompiled.Cache.clear(home)
    refute File.exists?(stamps_file)
  end

  describe "a home a run creates" do
    test "is owner-only", %{tmp_dir: dir} do
      home = Path.join(dir, "new-home")
      assert {:ok, ^home} = Config.run_home(home, Path.join(dir, "lib"))
      assert FileStamp.trusted_home?(home)
    end

    test "an existing one keeps its mode", %{tmp_dir: dir} do
      home = Path.join(dir, "old-home")
      File.mkdir_p!(home)
      File.chmod!(home, 0o755)
      assert {:ok, ^home} = Config.run_home(home, Path.join(dir, "lib"))
      assert Bitwise.band(stat!(home).mode, 0o777) == 0o755
    end
  end
end
