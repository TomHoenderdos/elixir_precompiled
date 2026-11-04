# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.LockTest do
  use ExUnit.Case, async: true

  alias ChainTest.Lock

  @moduletag :tmp_dir

  @lock """
  %{
    "jason": {:hex, :jason, "1.4.5", "inner", [:mix], [], "hexpm", "outer"},
    "nerves": {:git, "https://github.com/TomHoenderdos/nerves.git", "abc123", [branch: "feat/precompiled"]},
    "nerves_system_rpi4": {:hex, :nerves_system_rpi4, "2.0.1", "inner", [:mix], [], "hexpm", "outer"},
  }
  """

  defp write(tmp, text) do
    path = Path.join(tmp, "mix.lock")
    File.write!(path, text)
    path
  end

  test "reads a lock with string keys", %{tmp_dir: tmp} do
    assert {:ok, lock} = Lock.read(write(tmp, @lock))
    assert Map.keys(lock) |> Enum.sort() == ["jason", "nerves", "nerves_system_rpi4"]
    assert Lock.hex_version(lock, "jason") == "1.4.5"
    assert Lock.hex_version(lock, "nerves") == nil
    assert Lock.hex_version(lock, "absent") == nil
    assert Lock.git_ref(lock, "nerves") == "abc123"
    assert Lock.git_ref(lock, "jason") == nil
  end

  test "system names the target's system at its locked version", %{tmp_dir: tmp} do
    {:ok, lock} = Lock.read(write(tmp, @lock))
    assert Lock.system(lock, "rpi4") == {"nerves_system_rpi4", "2.0.1"}
    assert Lock.system(lock, "rpi0_2") == nil
  end

  test "a missing lock is an error, not a raise", %{tmp_dir: tmp} do
    assert {:error, "no such file or directory"} = Lock.read(Path.join(tmp, "mix.lock"))
  end

  test "a lock that is not valid Elixir is an error", %{tmp_dir: tmp} do
    assert {:error, _} = Lock.read(write(tmp, "%{\n  \"jason\": {:hex,\n"))
  end

  test "a lock that is not a map is an error", %{tmp_dir: tmp} do
    assert {:error, "not a map"} = Lock.read(write(tmp, "[1, 2]\n"))
  end
end
