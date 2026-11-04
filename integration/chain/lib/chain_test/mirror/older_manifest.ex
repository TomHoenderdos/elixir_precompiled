# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.OlderManifest do
  @moduledoc """
  M3: serves, under `N`'s manifest path for a dep, the real manifest an
  older batch (`N-1` or `old`) names for it and `N` does not
  (`ChainTest.Snapshot.older_manifests/1`). It `needs/1`
  `:older_manifest_bytes`, which a snapshot has only when it holds those
  bytes; the portal serves only the current batch's manifests, so today
  the case is not testable here.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Snapshot

  @impl true
  def valid_args?(args), do: args == %{}

  @impl true
  def needs(_args), do: [:older_manifest_bytes]

  @impl true
  def transform(path, bytes, %{case: %{snapshot: snap}}) do
    served =
      for {dep, rel} <- Snapshot.older_manifests(snap),
          snap.deps[dep][:manifest] == path,
          do: rel

    case served do
      [rel | _] -> {200, File.read!(Path.join(snap.dir, rel))}
      [] -> {200, bytes}
    end
  end
end
