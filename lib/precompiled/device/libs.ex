# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Libs do
  @moduledoc false
  # A native build's needed libraries, checked against the device's own:
  # each needed soname is opened by name under the library roots
  # (following symlinks, as the dynamic loader does), read with the bounded
  # ELF reader, and must define every needed symbol version. This is the
  # authoritative check: the systems table describes the release's rootfs,
  # this describes the device that is running. Mix-free.
  #
  # A library that does not read as ELF (a linker script, a truncated or
  # oversized file, a directory, a dangling link) counts as missing. Reads
  # are memoised per resolved path, in the run's table when one is passed,
  # so a library many builds need is read once per run.

  alias Precompiled.Reason

  @roots ["/lib", "/usr/lib"]
  # Symlink hops followed to find the file a name resolves to (Linux's
  # own limit is 40).
  @max_hops 40

  @type opt ::
          {:read, (Path.t() -> term())}
          | {:memo, :ets.tid() | atom() | nil}

  @doc false
  @spec default_roots() :: [Path.t()]
  def default_roots(), do: @roots

  @doc false
  # `needs` is a build's `elf.needs`: soname => needed symbol versions.
  # Options: `:read` replaces Precompiled.Elf.read_file/1 (tests count
  # reads through it), `:memo` is an ets table that lives for the run.
  @spec check(term(), [Path.t()], [opt()]) :: :ok | {:miss, Reason.t()}
  def check(needs, roots \\ @roots, opts \\ []) do
    if well_formed?(needs) do
      read = Keyword.get(opts, :read, &Precompiled.Elf.read_file/1)

      with_memo(opts[:memo], fn memo ->
        needs
        |> Enum.sort()
        |> Enum.reduce_while(:ok, fn {soname, versions}, :ok ->
          case one(soname, versions, roots, read, memo) do
            :ok -> {:cont, :ok}
            miss -> {:halt, miss}
          end
        end)
      end)
    else
      {:miss, Reason.new(:malformed_entry, [], "malformed entry")}
    end
  end

  defp well_formed?(needs) when is_map(needs) do
    Enum.all?(needs, fn {soname, versions} ->
      is_binary(soname) and is_list(versions) and Enum.all?(versions, &is_binary/1)
    end)
  end

  defp well_formed?(_), do: false

  # A run's table, or a table for this call only.
  defp with_memo(nil, fun) do
    memo = :ets.new(__MODULE__, [:set, :private])

    try do
      fun.(memo)
    after
      :ets.delete(memo)
    end
  end

  defp with_memo(memo, fun), do: fun.(memo)

  defp one(soname, versions, roots, read, memo) do
    with {:ok, path} <- locate(soname, roots),
         {:ok, defines} <- defines(path, read, memo) do
      case Precompiled.Elf.satisfied?(versions, defines) do
        :ok -> :ok
        {:missing, v} -> {:miss, Reason.new(:symbol_version_missing, [soname, v])}
      end
    else
      :missing -> {:miss, Reason.new(:needed_lib_missing, [soname])}
    end
  end

  # The first root where the name is a readable regular file, after
  # following symlinks, resolved to that file's own path. A soname is a
  # plain file name: anything that could leave a root is never looked up.
  defp locate(soname, roots) do
    if plain_name?(soname) do
      Enum.find_value(roots, :missing, fn root ->
        path = Path.join(root, soname)

        case File.stat(path) do
          {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] ->
            {:ok, resolve(path, @max_hops)}

          _ ->
            nil
        end
      end)
    else
      :missing
    end
  end

  defp plain_name?(soname) do
    soname not in ["", ".", ".."] and Path.basename(soname) == soname and
      not String.contains?(soname, ["/", <<0>>])
  end

  defp resolve(path, 0), do: path

  defp resolve(path, hops) do
    case :file.read_link(path) do
      {:ok, target} -> resolve(Path.expand(to_string(target), Path.dirname(path)), hops - 1)
      _ -> path
    end
  end

  defp defines(path, read, memo) do
    case :ets.lookup(memo, {:lib, path}) do
      [{_, found}] ->
        found

      [] ->
        found = read_defines(path, read)
        :ets.insert(memo, {{:lib, path}, found})
        found
    end
  end

  # Anything but {:ok, info} with a list of definitions counts as missing.
  defp read_defines(path, read) do
    case read.(path) do
      {:ok, %{defines: defines}} when is_list(defines) -> {:ok, defines}
      _ -> :missing
    end
  rescue
    _ -> :missing
  end
end
