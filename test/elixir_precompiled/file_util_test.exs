# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.FileUtilTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.FileUtil
  @moduletag :tmp_dir

  test "write_atomic writes through a unique temp file", %{tmp_dir: dir} do
    path = Path.join([dir, "sub", "state"])
    assert FileUtil.write_atomic(path, "7") == :ok
    assert File.read!(path) == "7"
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "concurrent writers to one path never fail each other", %{tmp_dir: dir} do
    path = Path.join(dir, "state")

    results =
      1..50
      |> Task.async_stream(&FileUtil.write_atomic(path, Integer.to_string(&1)),
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &(&1 == :ok))
    assert {n, ""} = Integer.parse(File.read!(path))
    assert n in 1..50
  end

  test "write_atomic reports an unwritable dir instead of raising", %{tmp_dir: dir} do
    blocker = Path.join(dir, "file")
    File.write!(blocker, "")
    assert {:error, _} = FileUtil.write_atomic(Path.join(blocker, "state"), "1")
  end

  test "writable_dir? creates the dir and leaves no probe behind", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    assert FileUtil.writable_dir?(home)
    assert File.ls!(home) == []
    blocker = Path.join(dir, "file")
    File.write!(blocker, "")
    refute FileUtil.writable_dir?(Path.join(blocker, "home"))
  end
end
