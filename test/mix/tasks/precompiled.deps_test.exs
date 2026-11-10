# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.DepsTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Precompiled.Deps

  test "only tasks that never compile deps skip the install" do
    # mix format with plugins calls loadpaths, which compiles every dep:
    # installing first is the point (README, Phoenix).
    for task <- ~w(compile test run format release phx.server deps.loadpaths),
        do: refute(Deps.skip?(task))

    for task <- ~w(help clean precompiled.status precompiled.clean),
        do: assert(Deps.skip?(task))
  end

  test "the top-level task comes from the command line, not System.argv" do
    # `mix run script.exs help`: System.argv() is ["help"] in the script.
    assert Deps.top_level_task([~c"/usr/local/bin/mix", ~c"run", ~c"s.exs", ~c"help"]) == "run"
    assert Deps.top_level_task([~c"-pa", ~c"/x", ~c"-S", ~c"mix", ~c"compile"]) == "compile"
    assert Deps.top_level_task([~c"C:/elixir/bin/mix.bat", ~c"test"]) == "test"
    assert Deps.top_level_task([~c"/usr/local/bin/mix"]) == "run"
    assert Deps.top_level_task([~c"+iex", ~c"-S", ~c"mix"]) == "run"
    assert Deps.top_level_task([]) == "run"
  end

  @tag :tmp_dir
  test "the library is recompiled only when it is a dep and its app file is gone", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "ebin"))
    never = fn -> flunk("loaded deps although the app file is there") end
    File.write!(Path.join(dir, "ebin/precompiled.app"), "")
    assert Deps.ensure_compiled(String.to_charlist(dir), never) == :ok

    # On the code path by -pa, not a dep: nothing to purge or compile.
    File.rm!(Path.join(dir, "ebin/precompiled.app"))
    assert Deps.ensure_compiled(String.to_charlist(dir), fn -> [] end) == :not_a_dep
    assert Deps.ensure_compiled({:error, :bad_name}, never) == :ok
  end

  test "a raise while recompiling falls back to a source compile, not a failed build" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    assert Deps.install(fn -> raise "boom" end) == :ok
    assert_received {:mix_shell, :error, [msg]}
    assert msg =~ "precompiled: internal error, compiling from source (boom)"
  end
end
