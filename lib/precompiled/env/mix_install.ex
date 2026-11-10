# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Env.MixInstall do
  @moduledoc false
  # On a device, inside the project Mix.install/2 keeps under MIX_INSTALL_DIR:
  # every Hex entry of its lock that is not compiled there yet is a
  # candidate, and the system comes from the running Nerves system's
  # /usr/lib/os-release, or (a fallback, e.g. for a test or a firmware that
  # loads a bare app spec as a marker) a loaded nerves_system_* application.
  # Without either the system is nil and Check matches the pure_elixir
  # entries. A dep already compiled in the install project is no candidate;
  # the project dir persists across runs (Mix.install/2 finds it again and
  # only compiles what is missing), so a compiled dep this library placed
  # (it carries the provenance file) is rechecked against the current batch,
  # as in a Mix project's _build. Check removing one makes Mix.install/2
  # compile it from the sources deps.get already fetched.

  alias Precompiled.{Env, Fetch}

  @default_os_release_paths ["/usr/lib/os-release", "/etc/os-release"]

  # `methods`: how Mix builds each Hex dep there, as Install.build_methods/4
  # loads it from Mix. Without it rule 9 has nothing to go on, and every
  # candidate misses.
  @spec load(Path.t(), [term()], Env.build_methods()) :: Env.t()
  def load(project_dir, deps, methods \\ {:unknown, "not loaded"}) do
    lock = Mix.Dep.Lock.read(Path.join(project_dir, "mix.lock"))
    build_lib = Path.join([project_dir, "_build", Atom.to_string(Mix.env()), "lib"])

    envs = dep_envs(deps)
    system = system()

    {compiled, apps} =
      lock |> Map.keys() |> Enum.sort() |> Enum.split_with(&compiled?(build_lib, &1))

    installed = Enum.filter(compiled, &File.regular?(Fetch.provenance_path(build_lib, &1)))

    %Env{
      system: system,
      mix_target: mix_target(system),
      candidates: Env.hex_candidates(lock, apps, envs),
      lock: lock,
      build_lib: build_lib,
      deps_path: Path.join(project_dir, "deps"),
      installed: installed,
      installed_envs: Map.new(installed, &{&1, Map.get(envs, &1, "prod")}),
      build_methods: methods
    }
  end

  @doc false
  # Mix.install on a device compiles as :host, but a build for the device's
  # own system is the right one; its conventional target name stands in.
  @spec mix_target({String.t(), String.t()} | nil) :: String.t()
  def mix_target({"nerves_system_" <> name, _version}), do: name
  def mix_target(_), do: "host"

  # Mix.install/2 deps can carry env:; transitive deps compile as prod, as
  # Mix.Dep.Loader defaults them.
  defp dep_envs(deps) do
    Map.new(
      for d <- deps,
          {app, opts} <- [dep_opts(d)],
          app != nil,
          env = Keyword.get(opts, :env),
          env != nil,
          do: {app, Atom.to_string(env)}
    )
  end

  defp dep_opts({app, opts}) when is_atom(app) and is_list(opts), do: {app, opts}

  defp dep_opts({app, req, opts}) when is_atom(app) and is_binary(req) and is_list(opts),
    do: {app, opts}

  defp dep_opts(_other), do: {nil, []}

  # The evidence Mix itself takes for a compiled dep: its .app and the SCM
  # stamp Mix writes after compiling it.
  defp compiled?(build_lib, app) do
    dir = Path.join(build_lib, Atom.to_string(app))

    File.regular?(Path.join([dir, "ebin", "#{app}.app"])) and
      File.regular?(Path.join([dir, ".mix", "compile.elixir_scm"]))
  end

  @doc false
  @spec system([Path.t()], [{atom(), charlist(), charlist()}]) ::
          {String.t(), String.t()} | nil
  def system(
        os_release_paths \\ @default_os_release_paths,
        loaded \\ Application.loaded_applications()
      ) do
    case Precompiled.OsRelease.system(os_release_paths) do
      nil -> system_from_loaded(loaded)
      system -> system
    end
  end

  # The fallback: a loaded nerves_system_* application. On a release this
  # never matches, since Nerves systems are runtime: false dependencies and
  # are not part of it; a test or a firmware may still load a bare app spec
  # as a marker.
  defp system_from_loaded(loaded) do
    Enum.find_value(loaded, fn {app, _description, vsn} ->
      name = Atom.to_string(app)
      if String.starts_with?(name, "nerves_system_"), do: {name, List.to_string(vsn)}
    end)
  end
end
