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

  describe "nerves_children/2" do
    @closure_lock """
    %{
      "nerves": {:git, "https://example.invalid/nerves.git", "abc123", [branch: "x"]},
      "interactive_cmd": {:hex, :interactive_cmd, "0.1.4", "i", [:mix], [], "hexpm", "o"},
      "tablet": {:hex, :tablet, "0.3.3", "i", [:mix], [{:dep_of_tablet, "~> 1.0", [hex: :dep_of_tablet, repo: "hexpm", optional: false]}], "hexpm", "o"},
      "dep_of_tablet": {:hex, :dep_of_tablet, "1.0.0", "i", [:mix], [], "hexpm", "o"},
      "jason": {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "o"},
    }
    """

    defp nerves_app(build_lib, apps) do
      ebin = Path.join([build_lib, "nerves", "ebin"])
      File.mkdir_p!(ebin)

      app =
        {:application, :nerves, [optional_applications: [], applications: apps, vsn: ~c"2.0.0"]}

      File.write!(Path.join(ebin, "nerves.app"), :io_lib.format("~p.~n", [app]))
    end

    test "a git nerves's children come from its compiled .app, then the lock", %{tmp_dir: tmp} do
      {:ok, lock} = Lock.read(write(tmp, @closure_lock))
      build_lib = Path.join(tmp, "lib")
      nerves_app(build_lib, [:kernel, :stdlib, :elixir, :logger, :interactive_cmd, :tablet])

      assert Lock.nerves_children(lock, build_lib) == [
               "dep_of_tablet",
               "interactive_cmd",
               "tablet"
             ]
    end

    test "a Hex nerves's children come from the lock alone", %{tmp_dir: tmp} do
      text =
        String.replace(
          @closure_lock,
          ~s("nerves": {:git, "https://example.invalid/nerves.git", "abc123", [branch: "x"]}),
          ~s("nerves": {:hex, :nerves, "1.0.0", "i", [:mix], [{:tablet, "~> 0.3", [hex: :tablet, repo: "hexpm", optional: false]}], "hexpm", "o"})
        )

      {:ok, lock} = Lock.read(write(tmp, text))
      assert Lock.nerves_children(lock, Path.join(tmp, "none")) == ["dep_of_tablet", "tablet"]
    end

    test "no nerves, or no compiled nerves.app for a git one, has no children", %{tmp_dir: tmp} do
      {:ok, lock} = Lock.read(write(tmp, @closure_lock))
      assert Lock.nerves_children(lock, Path.join(tmp, "none")) == []
      assert Lock.nerves_children(Map.delete(lock, "nerves"), tmp) == []
    end
  end
end
