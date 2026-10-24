# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.EnvTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.Env

  @ash {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "ASHOUTER"}
  @git {:git, "https://example.test/x.git", "abc", []}

  test "hex_candidates keeps locked Hex entries in the given order" do
    lock = %{ash: @ash, gitdep: @git}

    assert Env.hex_candidates(lock, [:gitdep, :ash, :absent]) ==
             [%{name: :ash, version: "3.5.2", lock_entry: @ash, dep_env: "prod"}]
  end

  test "hex_candidates carries the given compile env, defaulting to prod" do
    lock = %{ash: @ash}

    assert Env.hex_candidates(lock, [:ash], %{ash: "dev"}) ==
             [%{name: :ash, version: "3.5.2", lock_entry: @ash, dep_env: "dev"}]

    assert Env.hex_candidates(lock, [:ash]) ==
             [%{name: :ash, version: "3.5.2", lock_entry: @ash, dep_env: "prod"}]
  end
end
