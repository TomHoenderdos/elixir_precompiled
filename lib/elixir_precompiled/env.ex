# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Env do
  @moduledoc """
  What the two places the client runs answer differently: a Mix project at
  build time (`ElixirPrecompiled.Env.MixProject`) and the project
  `Mix.install/2` keeps on a device (`ElixirPrecompiled.Env.MixInstall`).
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
          deps_path: Path.t()
        }

  @enforce_keys [:candidates, :lock, :build_lib, :deps_path]
  defstruct system: nil, candidates: [], lock: %{}, build_lib: nil, deps_path: nil

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
end
