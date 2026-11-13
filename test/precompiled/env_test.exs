# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.EnvTest do
  use ExUnit.Case, async: true
  alias Precompiled.Env

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

  test "overrides names the build options a declaration sets, in rule order" do
    assert Env.overrides([]) == []
    assert Env.overrides(env: :dev, optional: true, override: true) == []
    assert Env.overrides(system_env: [], manager: nil) == []
    assert Env.overrides(system_env: %{}) == []
    assert Env.overrides(system_env: %{"A" => "1"}) == [:system_env]
    assert Env.overrides(compile: false) == [:compile]

    assert Env.overrides(system_env: [{"A", "1"}], compile: "make", manager: :make) ==
             [:manager, :compile, :system_env]

    assert Env.overrides(nil) == []
  end

  test "closure is a dep's transitive deps in the env's tree, sorted, or nil" do
    tree = %{ash: [:spark, :reactor], spark: [:decimal], reactor: [:spark], decimal: []}
    assert Env.closure(tree, :ash) == [:decimal, :reactor, :spark]
    assert Env.closure(tree, :decimal) == []
    assert Env.closure(tree, :absent) == nil
    assert Env.closure(nil, :ash) == nil
  end
end
