# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Env.MixProjectTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.Env.MixProject

  @ash {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "ASHOUTER"}
  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}
  @decimal {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", "DOUTER"}

  test "system_from_plan finds the v1 system package without nerves loaded" do
    plan = %{
      packages: [%{app: :nerves_system_rpi4, version: "1.31.0"}],
      actions: [{Nerves.BuildAction.NervesV1System, app: :nerves_system_rpi4}]
    }

    assert MixProject.system_from_plan(plan) == {"nerves_system_rpi4", "1.31.0"}
    assert MixProject.system_from_plan(%{packages: [], actions: []}) == nil
    assert MixProject.system_from_plan(nil) == nil
  end

  test "candidates_from keeps Hex deps Mix would compile now" do
    lock = %{ash: @ash, jason: @jason, decimal: @decimal}
    dep = fn app, status, scm -> %Mix.Dep{app: app, status: status, scm: scm} end

    assert MixProject.candidates_from([dep.(:ash, :compile, Hex.SCM)], lock) ==
             [%{name: :ash, version: "3.5.2", lock_entry: @ash, dep_env: "prod"}]

    assert MixProject.candidates_from([dep.(:jason, {:noappfile, {"a", "b"}}, Hex.SCM)], lock) ==
             [%{name: :jason, version: "1.4.5", lock_entry: @jason, dep_env: "prod"}]

    assert MixProject.candidates_from([dep.(:decimal, {:ok, "2.3.0"}, Hex.SCM)], lock) == []
    assert MixProject.candidates_from([dep.(:gitdep, :compile, Mix.SCM.Git)], lock) == []
    assert MixProject.candidates_from([dep.(:absent, :compile, Hex.SCM)], lock) == []
  end

  test "candidates_from reads the dep's own compile env from its opts" do
    lock = %{ash: @ash, jason: @jason}

    dep = fn app, opts ->
      %Mix.Dep{app: app, status: :compile, scm: Hex.SCM, opts: opts}
    end

    assert MixProject.candidates_from([dep.(:ash, env: :dev)], lock) ==
             [%{name: :ash, version: "3.5.2", lock_entry: @ash, dep_env: "dev"}]

    assert MixProject.candidates_from([dep.(:jason, [])], lock) ==
             [%{name: :jason, version: "1.4.5", lock_entry: @jason, dep_env: "prod"}]
  end
end
