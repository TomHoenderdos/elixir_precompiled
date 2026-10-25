# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Env.MixInstall do
  @moduledoc false
  # On a device, inside the project Mix.install/2 keeps under MIX_INSTALL_DIR:
  # every Hex entry of its lock that is not compiled there yet is a
  # candidate, and the system comes from the running Nerves system's
  # /usr/lib/os-release, or (a fallback, e.g. for a test or a firmware that
  # loads a bare app spec as a marker) a loaded nerves_system_* application.
  # Without either the system is nil and Check matches the pure_elixir
  # entries. A dep already compiled in the install project is left to Mix,
  # so a second boot with a cached install needs no network and re-places
  # nothing.

  alias ElixirPrecompiled.Env

  @default_os_release_paths ["/usr/lib/os-release", "/etc/os-release"]

  @spec load(Path.t(), [term()]) :: Env.t()
  def load(project_dir, deps) do
    lock = Mix.Dep.Lock.read(Path.join(project_dir, "mix.lock"))
    build_lib = Path.join([project_dir, "_build", Atom.to_string(Mix.env()), "lib"])

    apps =
      lock
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&compiled?(build_lib, &1))

    %Env{
      system: system(),
      candidates: Env.hex_candidates(lock, apps, dep_envs(deps)),
      lock: lock,
      build_lib: build_lib,
      deps_path: Path.join(project_dir, "deps")
    }
  end

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
    case os_release_system(os_release_paths) do
      nil -> system_from_loaded(loaded)
      system -> system
    end
  end

  defp os_release_system(paths) do
    Enum.find_value(paths, &os_release_system_at/1)
  end

  defp os_release_system_at(path) do
    case File.read(path) do
      {:ok, contents} -> nerves_system_from_os_release(contents)
      {:error, _reason} -> nil
    end
  end

  defp nerves_system_from_os_release(contents) do
    kv = parse_os_release(contents)
    name = Map.get(kv, "NERVES_SYSTEM_NAME", "")
    version = Map.get(kv, "NERVES_SYSTEM_VERSION", "")

    if name != "" and version != "" and String.starts_with?(name, "nerves_system_") do
      {name, version}
    end
  end

  defp parse_os_release(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, &parse_os_release_line/2)
  end

  defp parse_os_release_line(line, acc) do
    line = String.trim(line)

    if line == "" or String.starts_with?(line, "#") do
      acc
    else
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), strip_quotes(String.trim(value)))
        _other -> acc
      end
    end
  end

  defp strip_quotes(value) do
    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
         byte_size(value) >= 2 do
      binary_part(value, 1, byte_size(value) - 2)
    else
      value
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
