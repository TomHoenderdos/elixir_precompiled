# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.Env.MixInstall do
  @moduledoc false
  # On a device, inside the project Mix.install/2 keeps under MIX_INSTALL_DIR:
  # every Hex entry of its lock that is not compiled there yet is a
  # candidate, and the system is the running nerves_system_* application.
  # Without one (a host, the worker container) the system is nil and Check
  # matches the pure_elixir entries. A dep already compiled in the install
  # project is left to Mix, so a second boot with a cached install needs no
  # network and re-places nothing.

  alias NervesPrecompiled.Env

  @spec load(Path.t()) :: Env.t()
  def load(project_dir) do
    lock = Mix.Dep.Lock.read(Path.join(project_dir, "mix.lock"))
    build_lib = Path.join([project_dir, "_build", Atom.to_string(Mix.env()), "lib"])

    apps =
      lock
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&compiled?(build_lib, &1))

    %Env{
      system: system(Application.loaded_applications()),
      candidates: Env.hex_candidates(lock, apps),
      lock: lock,
      build_lib: build_lib,
      deps_path: Path.join(project_dir, "deps")
    }
  end

  # The evidence Mix itself takes for a compiled dep: its .app and the SCM
  # stamp Mix writes after compiling it.
  defp compiled?(build_lib, app) do
    dir = Path.join(build_lib, Atom.to_string(app))

    File.regular?(Path.join([dir, "ebin", "#{app}.app"])) and
      File.regular?(Path.join([dir, ".mix", "compile.elixir_scm"]))
  end

  @doc false
  @spec system([{atom(), charlist(), charlist()}]) :: {String.t(), String.t()} | nil
  def system(loaded) do
    Enum.find_value(loaded, fn {app, _description, vsn} ->
      name = Atom.to_string(app)
      if String.starts_with?(name, "nerves_system_"), do: {name, List.to_string(vsn)}
    end)
  end
end
