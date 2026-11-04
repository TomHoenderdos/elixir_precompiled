# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.Install do
  @shortdoc "Installs matching precompiled builds before Mix compiles the dependencies"

  @moduledoc """
  Installs signed precompiled builds of the dependencies Mix is about to
  compile, and rechecks the ones installed earlier. Not meant to be run by
  hand: add it to the project's `deps.loadpaths` alias, which every
  `mix compile`, `test`, `run` and `release` passes through before Mix
  compiles the dependencies:

      def project do
        [
          ...,
          aliases: [
            "deps.loadpaths": ["deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"]
          ]
        ]
      end

  The first entry compiles this library so the task exists; without it
  Mix would compile every dependency first. In an umbrella the alias goes
  in the root `mix.exs`. Does nothing without
  `config :elixir_precompiled, source: ...`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # The alias ran "deps.compile elixir_precompiled" through Mix.Task.run,
    # which marks deps.compile as done; a later `mix deps.compile` in the
    # same VM must still work.
    Mix.Task.reenable("deps.compile")

    if not skip?(top_level_task()) do
      _ = ElixirPrecompiled.run(allow_host: true)
    end

    :ok
  end

  @doc false
  # Tasks that load paths without compiling deps (help) or that inspect or
  # undo installs; everything else may compile deps right after this.
  @spec skip?(String.t()) :: boolean()
  def skip?(task), do: task == "help" or String.starts_with?(task, "precompiled.")

  defp top_level_task() do
    case System.argv() do
      [task | _] -> task
      [] -> "run"
    end
  end
end
