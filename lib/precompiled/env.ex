# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Env do
  @moduledoc """
  What the two places the client runs answer differently: a Mix project at
  build time (`Precompiled.Env.MixProject`) and the project
  `Mix.install/2` keeps on a device (`Precompiled.Env.MixInstall`).
  Everything else in the client is shared.
  """

  @type candidate :: %{
          name: atom(),
          version: String.t(),
          lock_entry: tuple(),
          dep_env: String.t()
        }

  @type t :: %__MODULE__{
          system: {String.t(), String.t()} | nil,
          candidates: [candidate()],
          lock: map(),
          build_lib: Path.t(),
          deps_path: Path.t(),
          installed: [atom()],
          installed_envs: %{optional(atom()) => String.t()},
          tooling: [atom()] | nil,
          mix_target: String.t(),
          build_methods: build_methods(),
          compile_order: compile_order() | nil,
          present_deps: present_deps() | nil,
          config_unreadable: String.t() | nil,
          compiled_ok: MapSet.t(atom()) | nil,
          dep_sources: dep_sources() | nil,
          non_hex_deps: [atom()] | nil,
          inert_deps: %{optional(atom()) => [Path.t()]} | nil,
          dep_envs: %{optional(atom()) => String.t()},
          probe: map() | nil
        }

  @typedoc """
  Where Mix loads each dependency of this project from: for a Hex
  dependency (`Hex.SCM`, no `:path` or `:git` option), the lock entry Mix
  loaded it with, when that is a Hex entry of the package it names;
  otherwise `:path`, `:git` or `:other`. A dependency changed to `path:` or
  `git:` with `override: true` keeps its old Hex entry in `mix.lock`, so
  the lock alone cannot tell. Read only by this library.
  """
  @type dep_sources :: %{optional(atom()) => tuple() | :path | :git | :other}

  @typedoc """
  How Mix builds a dependency in this project: the manager it resolved
  (`"mix"`, `"rebar3"`, `"make"`, or nil when unknown) and the options
  among `:manager`, `:compile` and `:system_env` its declaration sets.
  """
  @type build_method :: %{manager: String.t() | nil, overrides: [atom()]}

  @typedoc """
  Every Hex dependency's `t:build_method/0`, or `{:unknown, why}` when Mix
  could not load the dependencies, in which case no build matches.
  """
  @type build_methods :: %{optional(atom()) => build_method()} | {:unknown, String.t()}

  @typedoc """
  The order `mix deps.compile` compiles this project's dependencies in, and
  what each one finds loaded when it compiles, or `{:ambiguous, why, deps}` when
  there is no single order (a partitioned compile). Read only by this
  library.
  """
  @type compile_order :: map() | {:ambiguous, String.t(), map()}

  @typedoc """
  Per dependency, its children as Mix loads them for the current env and
  target: an optional dependency nothing in this env brings in is not
  there, even when `mix.lock` has it (e.g. a project's `only: :test`
  dependency in dev). Read only by this library.
  """
  @type present_deps :: %{optional(atom()) => [atom()]}

  @overrides [:manager, :compile, :system_env]

  # `installed`: Hex deps Mix counts as compiled this run whose build dir
  # carries the provenance file an install writes, so `Check` can recheck
  # them against the current batch. `installed_envs` names each one's own
  # compile env, as `hex_candidates/3` takes it, for when one has to be
  # matched again.
  # `tooling`: deps nerves_bootstrap compiles with nerves (its dependency
  # closure as Mix loaded it), or nil when that is unknown and the lock's
  # closure is all there is. A git or path nerves has no list in the lock.
  # `build_methods`: per Hex dep, how Mix builds it here (rule 9); a dep
  # missing from it has no override and no known manager. {:unknown, why}
  # makes every candidate miss.
  @enforce_keys [:candidates, :lock, :build_lib, :deps_path]
  defstruct system: nil,
            candidates: [],
            lock: %{},
            build_lib: nil,
            deps_path: nil,
            installed: [],
            installed_envs: %{},
            tooling: nil,
            # The project's MIX_TARGET name, for deps that read Mix.target() at
            # compile time.
            mix_target: "host",
            build_methods: %{},
            # The deps.compile order (Precompiled.CompileOrder), for config_order
            # items, in the project or in Mix.install/2's install project; nil
            # when Mix's deps were not read.
            compile_order: nil,
            # Each dep's children in the current env (Mix.Dep.load_and_cache/0, in
            # the project or in Mix.install/2's install project), for the closure
            # rule (Env.closure/2); nil when Mix's deps were not read, and the lock
            # decides which declared deps are present.
            present_deps: nil,
            # Why the compile-time config the deps compile with could not be
            # read (Mix.install/2's config_path:), nil when it was: then no
            # compile-time config read can be checked.
            config_unreadable: nil,
            # The deps Mix loaded as compiled and current (status {:ok, _}),
            # in the project or in Mix.install/2's install project: a kino
            # among them that this run neither installs nor removes is one
            # Phase B may place a writer's archives into (0.8.0). nil when
            # Mix's deps were not read: then none is.
            compiled_ok: nil,
            # 0.9.1: where Mix loads each dep from (dep_sources/0), in the
            # project or in Mix.install/2's install project; nil when Mix's
            # deps were not read, and then no build that names a dependency
            # matches (Match's closure source rule).
            dep_sources: nil,
            # 0.9.0: this project's slots for a relocated build
            # (Precompiled.Relocate.user_slots/2), taken once per run by
            # Precompiled.Check; :unset until then.
            relocate: :unset,
            # 0.10.0: the deps Mix loads (in the project or in Mix.install/2's
            # install project) that are no Hex deps: path and git deps, a
            # closure dep switched to one, not an umbrella's own apps, which
            # Mix compiles after every Hex dep. A build's module probe misses
            # while there is one, as no exact module list exists for it
            # (Precompiled.ProbeInputs); nil when Mix's deps were not read.
            non_hex_deps: nil,
            # 0.10.0 (fix round 2, proposal B): the non-Hex deps that compile
            # and evaluate nothing: no manager (no mix.exs, rebar.config or
            # Makefile), `compile: false`, and `app: false` or no `.app` in
            # their ebin dirs (Phoenix's `heroicons`). Each with its ebin dirs
            # (its build's and its source's), whose beams on disk are its
            # whole module list. They are not in non_hex_deps. nil when
            # Mix's deps were not read, and under Mix.install/2, where such
            # a dep stays in non_hex_deps.
            inert_deps: nil,
            # 0.10.0: each Hex dep's own compile env, as Mix loads it (`env:`
            # in its declaration, else prod), for matching a dep outside a
            # probe build's closure to its own build.
            dep_envs: %{},
            # 0.10.0: the run's view of the project for probe items
            # (Precompiled.Check.probe_view/2), nil until Check takes it.
            probe: nil

  @doc """
  The locked Hex entries among `apps`, in the order given. `envs` names each
  app's own compile env (Mix compiles a dep as `:prod` unless the project
  overrides it, e.g. `{:foo, "~> 1.0", env: :dev}`); an app missing from it
  gets `"prod"`.
  """
  @spec hex_candidates(map(), [atom()], %{optional(atom()) => String.t()}) :: [candidate()]
  def hex_candidates(lock, apps, envs \\ %{}) do
    for app <- apps,
        entry = lock[app],
        match?({:hex, _, _, _, _, _, _, outer} when is_binary(outer), entry),
        do: %{
          name: app,
          version: elem(entry, 2),
          lock_entry: entry,
          dep_env: Map.get(envs, app, "prod")
        }
  end

  @doc """
  The transitive deps of `app` in `tree` (a `t:present_deps/0`), sorted,
  without `app` itself: what Mix has loaded when it compiles `app` in the
  current env. nil when the tree is unknown or does not have `app`.
  """
  @spec closure(present_deps() | nil, atom()) :: [atom()] | nil
  def closure(tree, app) when is_map(tree) and is_map_key(tree, app),
    do: tree |> walk(tree[app], MapSet.new()) |> MapSet.delete(app) |> Enum.sort()

  def closure(_tree, _app), do: nil

  defp walk(_tree, [], seen), do: seen

  defp walk(tree, [app | rest], seen) do
    if MapSet.member?(seen, app),
      do: walk(tree, rest, seen),
      else: walk(tree, Map.get(tree, app, []) ++ rest, MapSet.put(seen, app))
  end

  @doc """
  The options among `:manager`, `:compile` and `:system_env` that a
  dependency's declaration sets, in that order; an empty list or map
  sets nothing. Each makes Mix build the
  dependency another way than the portal did, so no build matches it.
  """
  @spec overrides(keyword()) :: [atom()]
  def overrides(opts) when is_list(opts),
    do: Enum.filter(@overrides, &set?(Keyword.get(opts, &1)))

  def overrides(_opts), do: []

  # An empty list or map (`system_env: %{}`) sets nothing; `compile: false`
  # does (Mix then skips compiling the dep).
  defp set?(nil), do: false
  defp set?(v) when is_list(v) or is_map(v), do: v != [] and v != %{}
  defp set?(_), do: true
end
