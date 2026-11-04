# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Env.MixProject do
  @moduledoc false
  # Build time, inside a Mix project: the deps Mix is about to compile, the
  # project's lock and build dir, and the Nerves system from the build plan
  # when nerves is loaded.

  alias ElixirPrecompiled.{Env, Fetch}

  # nerves is not a dependency; its build plan is read only when the module
  # is there, so the compiler must not warn about the remote call.
  @compile {:no_warn_undefined, [Nerves]}

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
      mix_target: Atom.to_string(Mix.target())
    }
  end

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

  # Nerves.build_plan/0 raises only when the project itself is broken; it
  # already ran, unguarded, one line earlier in nerves.init's export_env/0.
  defp system() do
    if Code.ensure_loaded?(Nerves), do: system_from_plan(Nerves.build_plan()), else: nil
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
