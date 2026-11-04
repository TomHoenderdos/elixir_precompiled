# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.InstallTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Precompiled.Install

  test "only tasks that never compile deps skip the install" do
    # mix format with plugins calls loadpaths, which compiles every dep:
    # installing first is the point (README, Phoenix).
    for task <- ~w(compile test run format release phx.server deps.loadpaths),
        do: refute(Install.skip?(task))

    for task <- ~w(help clean precompiled.status precompiled.clean),
        do: assert(Install.skip?(task))
  end

  test "the top-level task comes from the command line, not System.argv" do
    # `mix run script.exs help`: System.argv() is ["help"] in the script.
    assert Install.top_level_task([~c"/usr/local/bin/mix", ~c"run", ~c"s.exs", ~c"help"]) == "run"
    assert Install.top_level_task([~c"-pa", ~c"/x", ~c"-S", ~c"mix", ~c"compile"]) == "compile"
    assert Install.top_level_task([~c"C:/elixir/bin/mix.bat", ~c"test"]) == "test"
    assert Install.top_level_task([~c"/usr/local/bin/mix"]) == "run"
    assert Install.top_level_task([~c"+iex", ~c"-S", ~c"mix"]) == "run"
    assert Install.top_level_task([]) == "run"
  end
end
