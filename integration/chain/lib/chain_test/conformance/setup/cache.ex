# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Setup.Cache do
  @moduledoc """
  Fills the client's file cache (`files/<sha256>` under the home) before the
  build, from the snapshot's real files: every file of every build the
  snapshot holds. `plant` is one of:

    * `:all_files` - each file with its own bytes (R15: a cache the client
      must not install from without a batch that vouches for it).
    * `:corrupt_files` - each non-empty file with one byte changed, the
      size kept, so only the hash tells (C1).
    * `:link_entries` - each entry a symlink, by absolute path, to a file
      with the right bytes under `ChainTest.Conformance.Setup.outside_dir/0`
      (C2).
    * `:link_dir` - `files` itself a symlink, by absolute path, to an empty
      directory under `outside_dir/0` (C2).

  With `:all_files`, `deps` (a non-empty list of dep names) plants only
  those deps' files (C0: one expected hit's files, already in the cache).

  A snapshot without a file to plant is an error: the case would prove
  nothing.
  """
  @behaviour ChainTest.Conformance.Setup

  alias ChainTest.Conformance.Setup
  alias ChainTest.Mirror.Transform

  @plants [:all_files, :corrupt_files, :link_entries, :link_dir]

  @impl true
  def valid_args?(%{plant: plant} = args) when map_size(args) == 1, do: plant in @plants

  def valid_args?(%{plant: :all_files, deps: [_ | _] = deps} = args) when map_size(args) == 2,
    do: Enum.all?(deps, &(is_binary(&1) and &1 != ""))

  def valid_args?(_args), do: false

  @impl true
  def setup(home, snap, %{plant: plant} = args) do
    case shas(snap, Map.get(args, :deps)) do
      [] -> {:error, "the snapshot holds no file of any build to plant in the cache"}
      shas -> plant(plant, home, snap, shas)
    end
  end

  defp shas(snap, only) do
    for {name, %{builds: n} = dep} <- Map.get(snap, :deps, %{}),
        is_integer(n) and n > 0,
        only == nil or name in only,
        sha <- Map.get(dep, :file_shas, []),
        uniq: true,
        do: sha
  end

  defp plant(:link_dir, home, _snap, _shas) do
    target = Path.join([home, Setup.outside_dir(), "cache"])
    File.mkdir_p!(target)
    File.ln_s!(target, Path.join(home, "files"))
  end

  defp plant(plant, home, snap, shas) do
    cache = Path.join(home, "files")
    outside = Path.join(home, Setup.outside_dir())
    File.mkdir_p!(cache)

    for sha <- shas,
        bytes = File.read!(Path.join([snap.dir, "files", sha])),
        not (plant == :corrupt_files and bytes == "") do
      entry = Path.join(cache, sha)

      case plant do
        :all_files ->
          File.write!(entry, bytes)

        :corrupt_files ->
          File.write!(entry, Transform.flip_byte(bytes))

        :link_entries ->
          File.mkdir_p!(outside)
          File.write!(Path.join(outside, sha), bytes)
          File.ln_s!(Path.join(outside, sha), entry)
      end
    end

    :ok
  end
end
