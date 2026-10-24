# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.Env.MixInstall do
  @moduledoc false
  # On a device, inside the project Mix.install/2 keeps under MIX_INSTALL_DIR:
  # nothing is compiled yet, so every Hex entry of its lock is a candidate,
  # and the system is the running nerves_system_* application. Without one
  # (a host, the worker container) the system is nil and Check matches the
  # pure_elixir entries.

  alias NervesPrecompiled.Env

  @spec load(Path.t()) :: Env.t()
  def load(project_dir) do
    lock = Mix.Dep.Lock.read(Path.join(project_dir, "mix.lock"))

    %Env{
      system: system(Application.loaded_applications()),
      candidates: Env.hex_candidates(lock, lock |> Map.keys() |> Enum.sort()),
      lock: lock,
      build_lib: Path.join([project_dir, "_build", Atom.to_string(Mix.env()), "lib"]),
      deps_path: Path.join(project_dir, "deps")
    }
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
