# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.Deps do
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
            "deps.loadpaths": ["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"]
          ]
        ]
      end

  The first entry compiles this library so the task exists; without it
  Mix would compile every dependency first. In an umbrella the alias goes
  in the root `mix.exs`. Does nothing without
  `config :precompiled, source: ...` or `PRECOMPILED_SOURCE`.
  `mix igniter.install precompiled` writes the alias and the config
  (Elixir 1.18+, not in an umbrella).

  `mix do clean --deps + compile` installs twice: `clean` loads paths
  first, which runs the alias once before it deletes `_build`, and the
  compile after it installs again. The result is correct, just one install
  slower.
  """
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    # The alias ran "deps.compile precompiled" through Mix.Task.run,
    # which marks deps.compile as done; a later `mix deps.compile` in the
    # same VM must still work. And this task itself must run again when the
    # alias does: `mix clean` reenables deps.loadpaths and deletes _build,
    # so the compile after it in `mix do clean + compile` needs an install.
    Mix.Task.reenable("deps.compile")
    Mix.Task.reenable("precompiled.deps")

    if not skip?(top_level_task()) do
      install(&ensure_compiled/0)
    end

    :ok
  end

  @doc false
  # run/1 never raises, but if this library's own modules cannot load, its
  # error path cannot either, and recompiling them can raise too: whatever
  # goes wrong here, the build goes on and Mix compiles the deps.
  @spec install((-> term())) :: :ok
  def install(ensure_compiled) do
    _ = ensure_compiled.()
    _ = Precompiled.Host.run(allow_host: true)
    :ok
  rescue
    e ->
      Mix.shell().error(
        "precompiled: internal error, compiling from source (#{Exception.message(e)})"
      )

      :ok
  end

  @doc false
  # `mix do clean + compile`: clean's own loadpaths ran this alias, which
  # compiled this library, then clean deleted _build. Mix compiles a
  # project at most once per VM, so the alias's "deps.compile
  # precompiled" is now a no-op, the modules not loaded yet are gone
  # and deps.loadpaths would stop on the missing app file. Reenable the
  # library's compile tasks and compile it again; only when it is a dep of
  # this project (on the code path by -pa, it is not Mix's to compile).
  @spec ensure_compiled(term(), (-> [Mix.Dep.t()])) :: :ok | :not_a_dep | :recompiled
  def ensure_compiled(
        lib_dir \\ :code.lib_dir(:precompiled),
        load_deps \\ &reload_deps/0
      ) do
    with dir when is_list(dir) or is_binary(dir) <- lib_dir,
         false <- File.regular?(Path.join(dir, "ebin/precompiled.app")) do
      case Enum.filter(load_deps.(), &(&1.app == :precompiled)) do
        [dep] -> recompile(dep)
        _ -> :not_a_dep
      end
    else
      _ -> :ok
    end
  end

  defp reload_deps() do
    Mix.Dep.clear_cached()
    Mix.Dep.load_and_cache()
  end

  defp recompile(dep) do
    Mix.Dep.in_dependency(dep, fn _ ->
      tasks = ["compile", "compile.all" | Enum.map(compilers(), &"compile.#{&1}")]
      Enum.each(tasks, &Mix.Task.reenable/1)
    end)

    # Unload the old copies, so the compile does not warn about each one
    # it redefines; this module keeps running, so it stays.
    for mod <- Application.spec(:precompiled, :modules) || [], mod != __MODULE__ do
      :code.purge(mod)
      :code.delete(mod)
    end

    Mix.Task.reenable("deps.compile")
    Mix.Task.run("deps.compile", ["precompiled"])
    Mix.Task.reenable("deps.compile")
    :recompiled
  end

  defp compilers(), do: Mix.Project.config()[:compilers] || Mix.compilers()

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
