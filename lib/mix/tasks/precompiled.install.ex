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
  @spec run([String.t()]) :: :ok
  def run(_args) do
    # The alias ran "deps.compile elixir_precompiled" through Mix.Task.run,
    # which marks deps.compile as done; a later `mix deps.compile` in the
    # same VM must still work. And this task itself must run again when the
    # alias does: `mix clean` reenables deps.loadpaths and deletes _build,
    # so the compile after it in `mix do clean + compile` needs an install.
    Mix.Task.reenable("deps.compile")
    Mix.Task.reenable("precompiled.install")

    if not skip?(top_level_task()) do
      ensure_compiled()
      install()
    end

    :ok
  end

  # `mix do clean + compile`: clean's own loadpaths ran this alias, which
  # compiled this library, then clean deleted _build. Mix compiles a
  # project at most once per VM, so the alias's "deps.compile
  # elixir_precompiled" is now a no-op, the modules not loaded yet are gone
  # and deps.loadpaths would stop on the missing app file. Reenable the
  # library's compile tasks and compile it again.
  defp ensure_compiled() do
    with dir when is_list(dir) <- :code.lib_dir(:elixir_precompiled),
         false <- File.regular?(Path.join(dir, "ebin/elixir_precompiled.app")) do
      Mix.Dep.clear_cached()

      for %Mix.Dep{app: :elixir_precompiled} = dep <- Mix.Dep.load_and_cache() do
        Mix.Dep.in_dependency(dep, fn _ ->
          tasks = ["compile", "compile.all" | Enum.map(compilers(), &"compile.#{&1}")]
          Enum.each(tasks, &Mix.Task.reenable/1)
        end)
      end

      # Unload the old copies, so the compile does not warn about each one
      # it redefines; this module keeps running, so it stays.
      for mod <- Application.spec(:elixir_precompiled, :modules) || [], mod != __MODULE__ do
        :code.purge(mod)
        :code.delete(mod)
      end

      Mix.Task.reenable("deps.compile")
      Mix.Task.run("deps.compile", ["elixir_precompiled"])
      Mix.Task.reenable("deps.compile")
    end
  end

  defp compilers(), do: Mix.Project.config()[:compilers] || Mix.compilers()

  # run/1 never raises, but if this library's own modules cannot load,
  # its error path cannot either: the build must still go on.
  defp install() do
    _ = ElixirPrecompiled.run(allow_host: true)
  rescue
    e ->
      Mix.shell().error(
        "precompiled: internal error, compiling from source (#{Exception.message(e)})"
      )
  end

  @doc false
  # Tasks that load paths without compiling deps (help), that delete the
  # build (clean), or that inspect or undo installs; everything else may
  # compile deps right after this.
  @spec skip?(String.t()) :: boolean()
  def skip?(task), do: task in ["help", "clean"] or String.starts_with?(task, "precompiled.")

  @doc false
  # The task named on the command line. System.argv/0 is not it: `mix run
  # script.exs help` rewrites it to the script's own arguments. The VM's
  # plain arguments keep the command line, after the `mix` launcher's path
  # or `-S mix`; `mix` alone runs `run`.
  @spec top_level_task([charlist()]) :: String.t()
  def top_level_task(plain \\ :init.get_plain_arguments()) do
    plain
    |> Enum.map(&List.to_string/1)
    |> Enum.drop_while(&(Path.rootname(Path.basename(&1)) != "mix"))
    |> case do
      [_mix, task | _] -> task
      _ -> "run"
    end
  end
end
