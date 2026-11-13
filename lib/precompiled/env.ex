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
          compile_order: compile_order() | nil
        }

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
            # items; nil when not read from a Mix project.
            compile_order: nil

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
