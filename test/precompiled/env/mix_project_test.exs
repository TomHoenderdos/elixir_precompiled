# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Env.MixProjectTest do
  use ExUnit.Case, async: true
  alias Precompiled.Env.MixProject

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

  defmodule NervesWithoutPlan do
    # Released nerves 1.x: the module is there, build_plan/0 is not.
    @spec version() :: String.t()
    def version(), do: "1.11.0"
  end

  defmodule NervesWithPlan do
    @spec build_plan() :: map()
    def build_plan() do
      %{
        packages: [%{app: :nerves_system_rpi4, version: "1.31.0"}],
        actions: [{Nerves.BuildAction.NervesV1System, app: :nerves_system_rpi4}]
      }
    end
  end

  test "system_from_module reads no system from a nerves without build_plan/0" do
    assert MixProject.system_from_module(NervesWithoutPlan) == nil
    assert MixProject.system_from_module(NoSuchNervesModule) == nil
    assert MixProject.system_from_module(NervesWithPlan) == {"nerves_system_rpi4", "1.31.0"}
  end

  # Mix drops an optional child no other dep brings in for the current env:
  # in dev the project's `only: :test` decimal is gone, so ash has none.
  test "present_deps_from takes each dep's children for the current env" do
    dep = fn app, children -> %Mix.Dep{app: app, deps: Enum.map(children, &%Mix.Dep{app: &1})} end

    dev = [dep.(:spark, []), dep.(:ash, [:spark])]
    test_env = [dep.(:spark, []), dep.(:decimal, []), dep.(:ash, [:spark, :decimal])]

    assert MixProject.present_deps_from(dev) == %{spark: [], ash: [:spark]}

    assert MixProject.present_deps_from(test_env) ==
             %{spark: [], decimal: [], ash: [:decimal, :spark]}
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

  @tag :tmp_dir
  test "installed_from keeps compiled Hex deps that carry a provenance file", %{tmp_dir: lib} do
    for app <- ~w(ash jason gitdep stale) do
      File.mkdir_p!(Path.join([lib, app, ".mix"]))
      File.write!(Path.join([lib, app, ".mix/precompiled.json"]), "{}")
    end

    dep = fn app, status, scm, opts ->
      %Mix.Dep{app: app, status: status, scm: scm, opts: opts}
    end

    deps = [
      dep.(:ash, {:ok, "3.5.2"}, Hex.SCM, []),
      dep.(:jason, {:ok, "1.4.5"}, Hex.SCM, env: :dev),
      # compiled by Mix, never installed by this library
      dep.(:decimal, {:ok, "2.3.0"}, Hex.SCM, []),
      dep.(:gitdep, {:ok, "1.0.0"}, Mix.SCM.Git, []),
      # Mix compiles this one now: a candidate, not an installed build
      dep.(:stale, :compile, Hex.SCM, [])
    ]

    assert MixProject.installed_from(deps, lib) == [{:ash, "prod"}, {:jason, "dev"}]
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

  test "build_methods_from reads each Hex dep's manager and build overrides" do
    dep = fn app, manager, opts, system_env ->
      %Mix.Dep{
        app: app,
        scm: Hex.SCM,
        status: :compile,
        manager: manager,
        opts: opts,
        system_env: system_env
      }
    end

    deps = [
      dep.(:ash, :mix, [hex: :ash, dest: "deps/ash"], []),
      dep.(:jiffy, :make, [manager: :make], []),
      dep.(:eleveldb, :rebar3, [compile: "make all"], []),
      dep.(:exla, :mix, [], [{"XLA_TARGET", "cuda"}]),
      dep.(:both, :mix, [compile: "x", manager: :mix], []),
      dep.(:unknown, nil, [], []),
      %Mix.Dep{app: :gitdep, scm: Mix.SCM.Git, manager: :mix, opts: [manager: :make]}
    ]

    assert MixProject.build_methods_from(deps) == %{
             ash: %{manager: "mix", overrides: []},
             jiffy: %{manager: "make", overrides: [:manager]},
             eleveldb: %{manager: "rebar3", overrides: [:compile]},
             exla: %{manager: "mix", overrides: [:system_env]},
             both: %{manager: "mix", overrides: [:manager, :compile]},
             unknown: %{manager: nil, overrides: []}
           }
  end

  test "nerves_children_from reads a git nerves' children from Mix's deps" do
    child = fn app, deps -> %Mix.Dep{app: app, scm: Hex.SCM, deps: deps} end
    castore = child.(:castore, [])
    jason = child.(:jason, [])
    tablet = child.(:tablet, [jason])

    nerves = %Mix.Dep{
      app: :nerves,
      scm: Mix.SCM.Git,
      deps: [%Mix.Dep{app: :tablet}, %Mix.Dep{app: :castore}]
    }

    assert MixProject.nerves_children_from([nerves, tablet, castore, jason, child.(:ash, [])]) ==
             [:castore, :jason, :tablet]

    assert MixProject.nerves_children_from([child.(:ash, [])]) == nil
  end
end
