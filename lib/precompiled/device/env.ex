# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Env do
  @moduledoc false
  # What a running device is, read once per call: os-release for the Nerves
  # system, Nerves.Runtime.KV (when loaded) for the platform and
  # architecture, the VM for OTP, Elixir and CPU, and for the apps present
  # the loaded applications plus the release's lib/<app>-<vsn> directories
  # of apps that are shipped but not loaded, matched later by name and exact
  # version. Where both name an app the loaded version wins. No Mix, no Hex.

  @default_os_release ["/usr/lib/os-release", "/etc/os-release"]

  defstruct [:system, :platform, :arch, :otp, :elixir, :cpu, present: %{}, mounts: []]

  @type app_info :: %{vsn: String.t(), loaded?: boolean()}
  @type t :: %__MODULE__{
          system: {String.t(), String.t()} | nil,
          platform: String.t() | nil,
          arch: String.t() | nil,
          otp: String.t(),
          elixir: String.t(),
          cpu: String.t(),
          present: %{atom() => app_info()},
          mounts: [{mountpoint :: String.t(), options :: [String.t()]}]
        }

  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    kv = Keyword.get(opts, :kv, &nerves_kv/0).() || %{}
    os_release_paths = Keyword.get(opts, :os_release_paths, @default_os_release)
    loaded = Keyword.get_lazy(opts, :loaded, &Application.loaded_applications/0)
    lib_dir = Keyword.get_lazy(opts, :lib_dir, &release_lib_dir/0)

    %__MODULE__{
      system: Precompiled.OsRelease.system(os_release_paths),
      platform: kv["nerves_fw_platform"],
      arch: kv["nerves_fw_architecture"],
      otp: Keyword.get_lazy(opts, :otp, fn -> to_string(:erlang.system_info(:otp_release)) end),
      elixir: Keyword.get_lazy(opts, :elixir, &System.version/0),
      cpu:
        Keyword.get_lazy(opts, :cpu, fn ->
          to_string(:erlang.system_info(:system_architecture))
        end),
      present: present(loaded, lib_dir),
      mounts: mounts(Keyword.get(opts, :mounts_path, "/proc/mounts"))
    }
  end

  defp release_lib_dir(), do: Path.join(to_string(:code.root_dir()), "lib")

  # Nerves.Runtime is not a dependency of this library: called through
  # apply/3 only when it is loaded, so neither the compiler nor xref sees a
  # reference.
  defp nerves_kv() do
    if Code.ensure_loaded?(Nerves.Runtime.KV),
      do: apply(Nerves.Runtime.KV, :get_all_active, []),
      else: nil
  rescue
    # Catches everything: the KV store is optional context, and one that
    # raises or exits is the same as none.
    _ -> nil
  catch
    _, _ -> nil
  end

  defp present(loaded, lib_dir) do
    from_lib =
      for name <- ls(lib_dir),
          {:ok, app, vsn} <- [split_release(name)],
          into: %{},
          do: {app, %{vsn: vsn, loaded?: false}}

    Enum.reduce(loaded, from_lib, fn {app, _desc, vsn}, acc ->
      Map.put(acc, app, %{vsn: to_string(vsn), loaded?: true})
    end)
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end

  # "<app>-<vsn>": the version starts at the first "-" followed by a digit,
  # so a pre-release (foo-1.0.0-rc.1) keeps its whole version and a dashed
  # name (my-app-1.0.0) keeps its whole name. The version must parse, and
  # the app must already be an atom. Device.Store names its entries the
  # same way but parses them itself, without the atom rule: a cached app
  # need not be named in this VM yet.
  @doc false
  @spec split(String.t()) :: {:ok, atom(), String.t()} | :error
  def split(name) do
    case Regex.run(~r/\A(.+?)-(\d.*)\z/, name, capture: :all_but_first) do
      [app, vsn] -> app_vsn(app, vsn)
      _ -> :error
    end
  end

  @doc false
  # split/1 for a dir of the release's own lib dir: the firmware ships it,
  # so its app is present even when nothing has named the atom yet. The
  # atom is made only for a plain app name.
  @spec split_release(String.t()) :: {:ok, atom(), String.t()} | :error
  def split_release(name) do
    case Regex.run(~r/\A([a-z][a-z0-9_]*)-(\d.*)\z/, name, capture: :all_but_first) do
      [app, vsn] -> app_vsn(app, vsn, &{:ok, String.to_atom(&1)})
      _ -> split(name)
    end
  end

  defp app_vsn(app, vsn, to_atom \\ &existing/1) do
    with {:ok, _} <- Version.parse(pad(vsn)),
         {:ok, atom} <- to_atom.(app) do
      {:ok, atom, vsn}
    else
      _ -> :error
    end
  end

  # OTP app versions have two to four parts (kernel-10.4, ssl-11.7.8.1);
  # Version needs exactly three before any pre-release or build suffix.
  defp pad(vsn) do
    case Regex.run(~r/\A(\d+(?:\.\d+)*)(.*)\z/, vsn, capture: :all_but_first) do
      [core, rest] -> three(String.split(core, ".")) <> rest
      _ -> vsn
    end
  end

  defp three([a, b]), do: "#{a}.#{b}.0"
  defp three([a, b, c | _]), do: "#{a}.#{b}.#{c}"
  defp three(parts), do: Enum.join(parts, ".")

  defp existing(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp mounts(path) do
    case File.read(path) do
      {:ok, text} ->
        for line <- String.split(text, "\n"),
            [_dev, mountpoint, _type, options | _] <- [String.split(line, " ")],
            do: {mountpoint, String.split(options, ",")}

      _ ->
        []
    end
  end
end
