# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Env.MixProject do
  @moduledoc false
  # Build time, inside a Mix project: the deps Mix is about to compile, the
  # project's lock (versions and checksums), each dep's children for the
  # current env (which optional deps are present), the build dir, and the
  # Nerves system from the build plan when the loaded nerves has one (the
  # Nerves fork).

  alias Precompiled.{Env, Fetch}

  # Mix.Dep.load_and_cache/0 and Mix.Dep.Lock.read/0 raise only when the
  # project itself is broken, in which case Mix is about to fail the same
  # way; no try here.
  @spec load() :: Env.t()
  def load() do
    lock = Mix.Dep.Lock.read()
    deps = Mix.Dep.load_and_cache()
    build_lib = Path.join(Mix.Project.build_path(), "lib")
    installed = installed_from(deps, build_lib)

    %Env{
      system: system(),
      candidates: candidates_from(deps, lock),
      lock: lock,
      build_lib: build_lib,
      deps_path: Mix.Project.deps_path(),
      installed: Enum.map(installed, &elem(&1, 0)),
      installed_envs: Map.new(installed),
      tooling: nerves_children_from(deps),
      mix_target: Atom.to_string(Mix.target()),
      build_methods: build_methods_from(deps),
      present_deps: present_deps_from(deps),
      non_hex_deps: non_hex_from(deps),
      inert_deps: inert_from(deps),
      dep_envs: dep_envs_from(deps),
      compiled_ok: compiled_ok_from(deps),
      dep_sources: dep_sources_from(deps),
      compile_order:
        Precompiled.CompileOrder.from_deps(
          deps,
          System.get_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT")
        )
    }
  end

  @doc false
  # Per Hex dep, the manager Mix resolved for it and the build options its
  # declaration sets. Mix pops `:system_env` out of the opts into the
  # dep's own field, so it is read from there.
  @spec build_methods_from([Mix.Dep.t()]) :: %{optional(atom()) => Env.build_method()}
  def build_methods_from(deps) do
    for %Mix.Dep{app: app, scm: Hex.SCM, opts: opts, manager: manager} = dep <- deps,
        into: %{} do
      opts = put_system_env(opts, Map.get(dep, :system_env, []))
      {app, %{manager: manager_name(manager), overrides: Env.overrides(opts)}}
    end
  end

  defp put_system_env(opts, []), do: opts
  defp put_system_env(opts, system_env), do: Keyword.put(opts, :system_env, system_env)

  defp manager_name(manager) when is_atom(manager) and manager != nil,
    do: Atom.to_string(manager)

  defp manager_name(_), do: nil

  @doc false
  # Each dep's children as Mix loaded them for the current env and target:
  # Mix.Dep.Converger keeps an optional child only when something in this
  # env brings it in, and drops a dep whose `only:`/`targets:` excludes it,
  # whereas mix.lock holds every env's deps. Plain data, as the device-side
  # modules must never see a %Mix.Dep{}.
  @spec present_deps_from([Mix.Dep.t()]) :: Env.present_deps()
  def present_deps_from(deps),
    do: Map.new(deps, &{&1.app, &1.deps |> Enum.map(fn child -> child.app end) |> Enum.sort()})

  @doc false
  # Where Mix loads each dep from (Env.dep_sources/0), for the closure
  # rule's source check (Match): a Hex dep as the lock entry Mix loaded it
  # with (Mix.Dep.Converger puts it in the dep's opts, whatever the SCM),
  # anything else as :path, :git or :other. A dep changed to `path:` or
  # `git:` with `override: true` still carries its old Hex entry there and
  # in mix.lock, which `mix deps.get` leaves in place; its SCM says what Mix
  # compiles. Plain data, as present_deps_from/1.
  @spec dep_sources_from([Mix.Dep.t()]) :: Env.dep_sources()
  def dep_sources_from(deps), do: Map.new(deps, &{&1.app, dep_source(&1)})

  defp dep_source(%Mix.Dep{scm: scm, opts: opts}) do
    cond do
      scm == Mix.SCM.Path or Keyword.has_key?(opts, :path) ->
        :path

      scm == Mix.SCM.Git or Keyword.has_key?(opts, :git) or Keyword.has_key?(opts, :github) ->
        :git

      scm == Hex.SCM ->
        hex_source(opts[:lock], opts[:hex])

      true ->
        :other
    end
  end

  # The entry must be a Hex entry of the package the dep names (`hex:`,
  # which Hex.SCM defaults to the app's name).
  defp hex_source({:hex, pkg, _, _, _, _, _, outer} = lock, hex)
       when is_atom(pkg) and is_binary(outer) and (is_binary(hex) or is_atom(hex)) do
    if Atom.to_string(pkg) == to_string(hex), do: lock, else: :other
  end

  defp hex_source(_lock, _hex), do: :other

  # 0.10.0: the deps that are no Hex deps, for a build's probe items (no
  # exact module list exists for one): every dep Mix does not load from Hex
  # with a Hex lock entry of the package it names (dep_source/1, 0.9.1's
  # B1): a path or git dep, and a closure dep switched to one with
  # `override: true`, which keeps its stale Hex lock entry. Not an
  # umbrella's own apps (`from_umbrella`), which Mix compiles after every
  # Hex dep.
  # An inert dep (inert_from/1) is no such dep: it has a module list.
  @spec non_hex_from([Mix.Dep.t()]) :: [atom()]
  def non_hex_from(deps) do
    inert = inert_from(deps)

    for %Mix.Dep{app: app, opts: opts} = dep <- deps,
        opts[:from_umbrella] != true,
        not Map.has_key?(inert, app),
        not match?({:hex, _, _, _, _, _, _, _}, dep_source(dep)),
        do: app
  end

  @doc false
  # 0.10.0 (fix round 2, proposal B): the path and git deps that compile and
  # evaluate nothing, each with its ebin dirs. Mix evaluates a dep's
  # mix.exs only when its manager is Mix, and infers the manager from the
  # files in its dir (mix.exs, rebar.config, rebar, Makefile): with none, no
  # code of it runs. With `compile: false` nothing compiles it, and with
  # `app: false` (or no .app in its ebin dirs) Mix loads no application of
  # it. What it can supply is then only the beams on disk in its build's or
  # its source's ebin dir, which Check reads as its module list. Exactly
  # that shape: any other path or git dep stays a non-Hex dep.
  @spec inert_from([Mix.Dep.t()]) :: %{optional(atom()) => [Path.t()]}
  def inert_from(deps) do
    for %Mix.Dep{app: app, manager: nil, opts: opts} = dep <- deps,
        dep_source(dep) in [:path, :git],
        opts[:compile] == false,
        is_binary(opts[:dest]) and is_binary(opts[:build]),
        dirs = [Path.join(opts[:build], "ebin"), Path.join(opts[:dest], "ebin")],
        opts[:app] == false or not Enum.any?(dirs, &File.exists?(Path.join(&1, "#{app}.app"))),
        into: %{},
        do: {app, dirs}
  end

  @doc false
  # 0.10.0: each Hex dep's own compile env, as candidates_from/2 reads it.
  @spec dep_envs_from([Mix.Dep.t()]) :: %{optional(atom()) => String.t()}
  def dep_envs_from(deps) do
    for %Mix.Dep{app: app, scm: Hex.SCM, opts: opts} <- deps,
        into: %{},
        do: {app, Atom.to_string(Keyword.get(opts, :env, :prod))}
  end

  @doc "The apps Mix loaded as compiled (`{:ok, _}`), which Phase B may place archives into."
  @spec compiled_ok_from([Mix.Dep.t()]) :: MapSet.t(atom())
  def compiled_ok_from(deps),
    do: for(%Mix.Dep{app: app, status: {:ok, _}} <- deps, into: MapSet.new(), do: app)

  @doc false
  # The closure of nerves' children as Mix loaded them: each Mix.Dep names
  # its own children in `deps`, whatever SCM nerves comes from.
  @spec nerves_children_from([Mix.Dep.t()]) :: [atom()] | nil
  def nerves_children_from(deps) do
    by_app = Map.new(deps, &{&1.app, &1})

    case by_app[:nerves] do
      nil ->
        nil

      nerves ->
        nerves.deps
        |> Enum.map(& &1.app)
        |> closure(by_app, MapSet.new([:nerves]))
        |> MapSet.delete(:nerves)
        |> Enum.sort()
    end
  end

  defp closure([], _by_app, seen), do: seen

  defp closure([app | rest], by_app, seen) do
    if MapSet.member?(seen, app) do
      closure(rest, by_app, seen)
    else
      children = for %Mix.Dep{deps: deps} <- [by_app[app]], d <- deps, do: d.app
      closure(children ++ rest, by_app, MapSet.put(seen, app))
    end
  end

  @doc false
  # Dependencies Mix counts as compiled and current (status {:ok, _}) whose
  # build dir holds the provenance file an install wrote: builds this
  # library placed, which the current batch must still vouch for. Paired
  # with each one's compile env, as candidates_from/2 reads it.
  @spec installed_from([Mix.Dep.t()], Path.t()) :: [{atom(), String.t()}]
  def installed_from(deps, build_lib) do
    for %Mix.Dep{app: app, status: {:ok, _}, scm: Hex.SCM, opts: opts} <- deps,
        File.regular?(Fetch.provenance_path(build_lib, app)),
        do: {app, Atom.to_string(Keyword.get(opts, :env, :prod))}
  end

  @doc false
  # Dependencies Mix would compile now: status :compile or no app file, Hex
  # SCM, and locked. Each dep's own :env option (defaulting to :prod, as Mix
  # itself does) names the env Mix compiles it with.
  @spec candidates_from([Mix.Dep.t()], map()) :: [Env.candidate()]
  def candidates_from(deps, lock) do
    pairs =
      for %Mix.Dep{app: app, status: status, scm: Hex.SCM, opts: opts} <- deps,
          match?(:compile, status) or match?({:noappfile, _}, status),
          do: {app, Atom.to_string(Keyword.get(opts, :env, :prod))}

    Env.hex_candidates(lock, Enum.map(pairs, &elem(&1, 0)), Map.new(pairs))
  end

  defp system(), do: system_from_module(Nerves)

  @doc false
  # Only the Nerves fork has build_plan/0; released nerves 1.x does not, so
  # there the system is nil and only pure_elixir builds match. When it is
  # there, it raises only when the project itself is broken; it already
  # ran, unguarded, one line earlier in the fork's nerves.init export_env/0.
  @spec system_from_module(module()) :: {String.t(), String.t()} | nil
  def system_from_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :build_plan, 0),
      do: system_from_plan(module.build_plan()),
      else: nil
  end

  @doc false
  # The v1 system package the plan builds against. Read as a plain map so
  # the struct need not exist here.
  @spec system_from_plan(term()) :: {String.t(), String.t()} | nil
  def system_from_plan(%{actions: actions, packages: packages}) do
    with {_, opts} <- Enum.find(actions, &match?({Nerves.BuildAction.NervesV1System, _}, &1)),
         %{app: app, version: version} <- Enum.find(packages, &(&1.app == opts[:app])) do
      {Atom.to_string(app), version}
    else
      _ -> nil
    end
  end

  def system_from_plan(_), do: nil
end
