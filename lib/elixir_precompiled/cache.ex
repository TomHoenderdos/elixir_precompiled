# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Cache do
  @moduledoc false
  # The content-addressed cache under the home (files/, manifests/,
  # scan/v1/): bounded by size, least recently used first (a hit touches
  # its entry), and temp files of killed runs dropped after an hour. Trust
  # state (batch.json, batch.etag, the per-root state and roots) is never
  # touched: only regular files directly inside those cache dirs are.
  #
  # Nothing is followed: the home itself may be a link (a cache moved to
  # another disk), but a cache dir that is not a plain dir by lstat is
  # skipped, and an entry that is not a regular file by lstat (a link,
  # whatever it points at) is neither counted nor removed.
  #
  # Runs sharing the home may gc at the same time as they read. Every read
  # re-hashes what it reads (Fetch, and the scan cache's checksum key), so
  # an entry evicted under a reader costs that reader a download, never a
  # wrong build; a temp file younger than an hour is another run's write
  # in progress and is kept.

  @dirs [["files"], ["manifests"], ["scan", "v1"]]
  @tmp ~r/\.tmp-[0-9-]+\z/
  @day 86_400
  @tmp_age 3600

  @spec gc(Path.t(), non_neg_integer(), keyword()) :: %{
          removed: non_neg_integer(),
          bytes: non_neg_integer()
        }
  def gc(home, max_bytes, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    entries = for dir <- cache_dirs(home), entry <- entries(dir), do: entry

    {tmp, real} = Enum.split_with(entries, fn {path, _, _} -> path =~ @tmp end)
    stale = for {path, size, mtime} <- tmp, now - mtime > @tmp_age, do: {path, size}
    total = real |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    {evict, _left} =
      real
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.reduce({[], total}, fn {path, size, _}, {acc, left} ->
        if left > max_bytes, do: {[{path, size} | acc], left - size}, else: {acc, left}
      end)

    removed = for {path, size} <- stale ++ evict, remove_regular(path) == :ok, do: size
    %{removed: length(removed), bytes: Enum.sum(removed)}
  end

  @spec maybe_gc(map()) :: :ok
  def maybe_gc(%{home: home} = config) when is_binary(home) do
    marker = Path.join(home, "gc_at")
    now = System.os_time(:second)

    if due?(marker, now) do
      _ = gc(home, Map.get(config, :cache_max_bytes, 4096 * 1_048_576), now: now)
      _ = ElixirPrecompiled.FileUtil.write_atomic(marker, Integer.to_string(now))
    end

    :ok
  rescue
    _ -> :ok
  end

  def maybe_gc(_config), do: :ok

  # Due once a day; a marker from the future (a clock set back) or one that
  # is not a plain number makes it due now.
  defp due?(marker, now) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(marker),
         {:ok, s} <- File.read(marker),
         {at, _} <- Integer.parse(String.trim(s)) do
      now - at >= @day or at > now
    else
      _ -> true
    end
  end

  @doc false
  # The cache dirs, emptied: what `mix precompiled.clean --cache` removes.
  # A cache dir that is a link is left as it is (Fetch refuses one anyway);
  # inside a plain one, File.rm_rf/1 removes links as links.
  @spec clear(Path.t()) :: :ok
  def clear(home) do
    for top <- ["files", "manifests", "scan"],
        dir = Path.join(home, top),
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir)),
        do: File.rm_rf(dir)

    _ = remove_regular(Path.join(home, "gc_at"))
    :ok
  end

  # Each cache dir that is a plain dir all the way down from the home.
  defp cache_dirs(home) do
    for parts <- @dirs,
        dirs = Enum.scan(parts, home, &Path.join(&2, &1)),
        Enum.all?(dirs, &match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1))),
        do: List.last(dirs)
  end

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(dir, name),
            {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
              [File.lstat(path, time: :posix)],
            do: {path, size, mtime}

      {:error, _} ->
        []
    end
  end

  # File.rm/1 unlinks the name itself; checked once more by lstat so a dir
  # swapped in meanwhile is never touched.
  defp remove_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.rm(path)
      _ -> :skip
    end
  end
end
