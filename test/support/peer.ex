# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.TestPeer do
  @moduledoc false
  # A peer VM shaped like a release on a device: embedded code loading (no
  # autoload), and on its code path only kernel, stdlib, compiler, crypto,
  # Elixir, Logger and this library. Mix is never on it, so any Mix call
  # from the device layer fails there as it would on a device.

  @spec start_embedded() :: {pid(), node()}
  def start_embedded() do
    # A release ships consolidated protocols: this VM's go first, so they
    # are the ones loaded below.
    dirs =
      consolidated() ++
        Enum.map([:compile, :crypto, Kernel, Logger, Precompiled.Device.Loader], &ebin/1)

    pa = Enum.flat_map(dirs, &[~c"-pa", String.to_charlist(&1)])

    {peer, node} =
      case :peer.start_link(%{connection: :standard_io, args: [~c"-mode", ~c"embedded" | pa]}) do
        {:ok, peer} -> {peer, :nonode@nohost}
        {:ok, peer, node} -> {peer, node}
      end

    # Embedded mode loads only what the boot script names, so everything
    # the library may reach is loaded here up front, as a release would.
    # crypto's on_load refuses to run in embedded mode before its app is.
    :ok = :peer.call(peer, :application, :load, [:crypto])

    # Ahead of Elixir's own ebin whatever order -pa gave them.
    for dir <- consolidated(),
        do: true = :peer.call(peer, :code, :add_patha, [String.to_charlist(dir)])

    for dir <- dirs do
      :ok = :peer.call(peer, :code, :ensure_modules_loaded, [modules(dir)])
    end

    {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
    {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:logger])
    {peer, node}
  end

  defp consolidated() do
    if Protocol.consolidated?(Inspect), do: [ebin(Inspect)], else: []
  end

  defp ebin(mod), do: mod |> :code.which() |> to_string() |> Path.dirname()

  defp modules(dir) do
    for beam <- Path.wildcard(Path.join(dir, "*.beam")) do
      {:ok, {mod, []}} = :beam_lib.chunks(String.to_charlist(beam), [])
      mod
    end
  end
end
