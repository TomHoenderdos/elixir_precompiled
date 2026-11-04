# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.OlderBatch do
  @moduledoc """
  Serves one of the snapshot's older batches, real signed bytes, as
  `batch.json` (rollback, replay and freshness cases: T4, T5, R1-R4, R19).
  `batch` is `:previous` (`N-1`) or `:old` (issued over 25 hours before
  `N`); it `needs/1` that batch.

  `hits: true` (only with `:previous`) says the case expects the client to
  install from it. The mirror can serve only `N`'s manifests (the portal
  keeps no other manifest bytes), so the case then also needs
  `:previous_manifests`: `N-1` naming `N`'s manifest for every held dep.

  With `mirrors: 2` the second mirror serves the snapshot unchanged: a
  second source whose state the case can set up.

  `recheck: true` (only with `:previous`, not with `hits`) is R16's second
  build over a warm `_build` installed from `N`: it also needs
  `:previous_differs`, `N-1` naming another manifest, or none, for a held
  dep, so the warm `_build` holds a build `N-1` no longer vouches for.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Snapshot

  @impl true
  def valid_args?(%{batch: batch} = args) do
    batch in [:previous, :old] and
      Enum.all?(Map.keys(args), &(&1 in [:batch, :hits, :mirrors, :recheck])) and
      Map.get(args, :hits, false) in [true, false] and
      Map.get(args, :recheck, false) in [true, false] and
      not (batch == :old and Map.get(args, :hits, false)) and
      not (Map.get(args, :recheck, false) and (batch == :old or Map.get(args, :hits, false)))
  end

  def valid_args?(_args), do: false

  @impl true
  def needs(%{batch: :previous, hits: true}), do: [:previous, :previous_manifests]
  def needs(%{batch: :previous, recheck: true}), do: [:previous, :previous_differs]
  def needs(%{batch: batch}), do: [batch]

  @impl true
  def transform("batch.json", bytes, %{case: %{mirror: 2}}), do: {200, bytes}

  def transform("batch.json", _bytes, %{batch: batch, case: %{snapshot: snap}}) do
    case Snapshot.older(snap, batch) do
      {:ok, %{path: rel}} -> {200, File.read!(Path.join(snap.dir, rel))}
      {_kind, why} -> raise ArgumentError, "the snapshot has no #{batch} batch: #{why}"
    end
  end

  def transform(_path, bytes, _args), do: {200, bytes}
end
