# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.ManifestBytes do
  @moduledoc """
  Changes every manifest the mirror serves (`manifests/*.json` and
  `v2/manifests/*.json`), real bytes otherwise unchanged:

    * `change: :flip_byte` - one byte of it changed (M1): the bytes no
      longer hash to what the batch names.
    * `change: :swap` - another dep's manifest served in its place (M2):
      the snapshot's stored manifests in name order, each served as the
      next one's. Fewer than two stored manifests raise, so the case fails
      naming it rather than passing on an unchanged response.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Mirror.Transform

  @impl true
  def valid_args?(%{change: change} = args) when map_size(args) == 1,
    do: change in [:flip_byte, :swap]

  def valid_args?(_args), do: false

  @impl true
  def transform(path, bytes, %{change: change} = args) do
    if Transform.manifest_path?(path), do: change(change, path, bytes, args), else: {200, bytes}
  end

  defp change(:flip_byte, _path, bytes, _args), do: {200, Transform.flip_byte(bytes)}

  defp change(:swap, path, bytes, %{case: %{snapshot: snap}}) do
    paths =
      for {_name, %{manifest: rel}} <- Enum.sort(snap.deps),
          is_binary(rel),
          File.regular?(Path.join(snap.dir, rel)),
          do: rel

    with [_, _ | _] <- paths,
         i when is_integer(i) <- Enum.find_index(paths, &(&1 == path)),
         other = File.read!(Path.join(snap.dir, Enum.at(paths, rem(i + 1, length(paths))))),
         true <- other != bytes do
      {200, other}
    else
      _ ->
        raise ArgumentError,
              "cannot serve another dep's manifest as #{path}: the snapshot stores " <>
                "#{length(paths)} distinct manifest(s) to swap"
    end
  end
end
