# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.ArchiveTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "the archive carries the root of trust", %{tmp_dir: dir} do
    ez = Path.join(dir, "elixir_precompiled.ez")

    {out, 0} =
      System.cmd("mix", ["archive.build", "-o", ez],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert out =~ "Generated archive"
    {:ok, files} = :zip.list_dir(String.to_charlist(ez))
    names = for {:zip_file, name, _, _, _, _} <- files, do: to_string(name)
    assert Enum.any?(names, &String.ends_with?(&1, "priv/precompiled/root.json"))
    assert Enum.any?(names, &String.ends_with?(&1, "ebin/Elixir.ElixirPrecompiled.beam"))
  end
end
