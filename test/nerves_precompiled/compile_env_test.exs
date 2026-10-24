# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.CompileEnvTest do
  use ExUnit.Case, async: false
  alias NervesPrecompiled.CompileEnv

  test "lookup follows compile_env semantics" do
    Application.put_env(:precompiled_test_app, :mode, fast: true)
    on_exit(fn -> Application.delete_env(:precompiled_test_app, :mode) end)
    assert CompileEnv.lookup("precompiled_test_app", ["mode"]) == {:ok, [fast: true]}
    assert CompileEnv.lookup("precompiled_test_app", ["mode", "fast"]) == {:ok, true}
    assert CompileEnv.lookup("precompiled_test_app", ["mode", "slow"]) == :error
    assert CompileEnv.lookup("precompiled_test_app", ["nothing"]) == :error
  end

  test "lookup never creates an atom from untrusted input" do
    never = "never_an_atom_#{System.unique_integer([:positive])}"
    assert CompileEnv.lookup(never, ["mode"]) == :error
  end
end
