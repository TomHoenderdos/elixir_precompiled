# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.FileStamp do
  @moduledoc false
  # A cached file (`<home>/files/<sha>`) whose bytes were hashed to its sha
  # is stamped with what the file system said about the open file it was
  # read through: device, inode, size, mtime and ctime. A later run that
  # finds the same stamp on the open file does not hash it again; any
  # difference at all is a full re-hash, and a hash mismatch is handled as
  # it always was (the file is fetched again).
  #
  # Why a stamp cannot let a changed file pass:
  #
  # - Every change to a file through the file system (a write, a truncate,
  #   a chmod, utimes, a link or a rename) sets its ctime to the file
  #   system's current time, and no call sets ctime to a chosen value. A
  #   rewrite that puts size and mtime back still moves ctime.
  # - Times are compared in whole seconds (all Erlang reads). A change in
  #   the same second as the stamped state would keep ctime, so a file is
  #   only stamped when its ctime and mtime are older than the file
  #   system's own clock at the start of this run, read from a probe file
  #   written next to the cached files (open/1). Every later change then gets a ctime at
  #   or past that clock, so strictly newer than the stamp. Reading the
  #   clock off the file system, not the OS, also covers a file system
  #   whose clock lags (a network mount).
  # - A file replaced by a rename is another inode, created no earlier than
  #   now, so its ctime differs as well.
  # - The stat is the open file's own (fstat), taken before and after the
  #   bytes are read; the two must agree, or the file is not stamped. What
  #   is hashed, stamped and installed is what that one handle read.
  #
  # What a stamp does not see: a change below the file system (a failing
  # disk, someone editing the block device) and a clock set back past the
  # stamp by root. Both need more than write access to the cache. A
  # cached file is also marked used once a day, which changes its ctime,
  # so it is hashed again in full at least once a day it is used.
  #
  # Stamps live in one file in the home (`file_stamps`), read once per run
  # and written once, atomically, when the run changed them. They are only
  # read or written while the home is a real directory (not a link) that
  # only its owner can enter (mode 0700) and that this process owns: a
  # stamp vouches for bytes nobody else could have changed. Losing the
  # file, or two runs overwriting each other's, only costs re-hashes.
  # Never on Windows, where neither the modes nor ctime mean the same.

  alias Precompiled.FileUtil

  @type t :: {String.t(), integer(), integer(), integer(), integer(), integer(), integer()}

  @file_name "file_stamps"
  @format 1
  @max_bytes 67_108_864

  @spec new(File.Stat.t(), String.t()) :: t()
  def new(%File.Stat{} = stat, sha) when is_binary(sha) do
    {sha, stat.major_device, stat.minor_device, stat.inode, stat.size, stat.mtime, stat.ctime}
  end

  @spec match?(t() | nil, File.Stat.t(), String.t()) :: boolean()
  def match?(stamp, %File.Stat{} = stat, sha) when is_tuple(stamp) and is_binary(sha),
    do: integers?(stat) and stamp == new(stat, sha)

  def match?(_stamp, _stat, _sha), do: false

  # A stat without integer times (or inode) cannot be compared exactly.
  defp integers?(stat) do
    Enum.all?(
      [stat.major_device, stat.minor_device, stat.inode, stat.size, stat.mtime, stat.ctime],
      &is_integer/1
    )
  end

  @doc false
  # Whether a stat may be recorded in this run's table: its ctime and mtime
  # are older than the file system's clock when the table was opened.
  @spec settled?(:ets.tid() | nil, File.Stat.t()) :: boolean()
  def settled?(nil, _stat), do: false

  def settled?(table, %File.Stat{} = stat) do
    case :ets.lookup(table, :clock) do
      [{:clock, clock}] -> integers?(stat) and stat.ctime < clock and stat.mtime < clock
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  True only for a real directory (not a link) whose mode is exactly 0700:
  no group or other bits at all. Never on Windows.
  """
  @spec trusted_home?(Path.t() | nil) :: boolean()
  def trusted_home?(home) when is_binary(home), do: match?({:ok, _}, trusted_stat(home))
  def trusted_home?(_), do: false

  defp trusted_stat(home) do
    with false <- match?({:win32, _}, :os.type()),
         {:ok, %File.Stat{type: :directory, mode: mode} = stat}
         when Bitwise.band(mode, 0o777) == 0o700 <- File.lstat(home, time: :posix) do
      {:ok, stat}
    else
      _ -> :error
    end
  end

  @doc false
  # The run's stamps: an ETS table loaded from the home's stamps file, with
  # the file system's clock, or nil when the home is not trusted (then
  # nothing is skipped or recorded). The table is public: the per-dep
  # workers read and record into it.
  @spec open(Path.t() | nil) :: :ets.tid() | nil
  def open(home) when is_binary(home) do
    with {:ok, before} <- trusted_stat(home),
         files = Path.join(home, "files"),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(files),
         {:ok, probe} <- probe(files),
         true <- probe.uid == before.uid,
         stamps = load(home),
         {:ok, now} <- trusted_stat(home),
         true <- same_dir?(before, now) do
      table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
      :ets.insert(table, [{:dirty, false}, {:clock, probe.ctime}])
      :ets.insert(table, Enum.map(stamps, fn {sha, stamp} -> {{:stamp, sha}, stamp} end))
      table
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def open(_home), do: nil

  # The home was not swapped while the stamps were read.
  defp same_dir?(a, b),
    do: {a.major_device, a.minor_device, a.inode} == {b.major_device, b.minor_device, b.inode}

  # A file written where the cached files are, now: its ctime is that file
  # system's clock, its uid this process's. Removed at once. Named like a
  # temp file, so a run killed in between leaves one the sweep removes.
  defp probe(dir) do
    path = Path.join(dir, "stamp-probe.tmp-#{System.pid()}-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.write(path, ""),
           {:ok, %File.Stat{type: :regular, ctime: ctime, uid: uid} = stat}
           when is_integer(ctime) and is_integer(uid) <- File.lstat(path, time: :posix) do
        {:ok, stat}
      else
        _ -> :error
      end
    after
      _ = File.rm(path)
    end
  end

  @doc false
  @spec lookup(:ets.tid() | nil, String.t()) :: t() | nil
  def lookup(nil, _sha), do: nil

  def lookup(table, sha) do
    case :ets.lookup(table, {:stamp, sha}) do
      [{_, stamp}] -> stamp
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec put(:ets.tid() | nil, t()) :: :ok
  def put(nil, _stamp), do: :ok

  def put(table, stamp) do
    sha = elem(stamp, 0)

    if lookup(table, sha) != stamp do
      :ets.insert(table, {{:stamp, sha}, stamp})
      :ets.insert(table, {:dirty, true})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec drop(:ets.tid() | nil, String.t()) :: :ok
  def drop(nil, _sha), do: :ok

  def drop(table, sha) do
    if lookup(table, sha) != nil do
      :ets.delete(table, {:stamp, sha})
      :ets.insert(table, {:dirty, true})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Writes the stamps back when the run changed them, and frees the table.
  # A failed write costs the next run its re-hashes, nothing else. A table
  # already closed is left alone.
  @spec close(:ets.tid() | nil, Path.t() | nil) :: :ok
  def close(nil, _home), do: :ok

  def close(table, home) do
    if :ets.info(table, :id) != :undefined do
      try do
        if :ets.lookup(table, :dirty) == [{:dirty, true}] and trusted_home?(home),
          do: save(table, home)
      after
        :ets.delete(table)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp save(table, home) do
    stamps = for {{:stamp, sha}, stamp} <- :ets.tab2list(table), into: %{}, do: {sha, stamp}
    _ = FileUtil.write_atomic(path(home), :erlang.term_to_binary({@format, stamps}))
    :ok
  end

  @doc false
  # Every stamp goes: the cache gc evicted files, or the cache was cleared.
  @spec forget(Path.t() | nil) :: :ok
  def forget(home) when is_binary(home) do
    path = path(home)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> _ = File.rm(path)
      _ -> :ok
    end

    :ok
  end

  def forget(_), do: :ok

  defp path(home), do: Path.join(home, @file_name)

  # Only a regular file, within the cap, in the expected shape; anything
  # else is no stamps at all.
  defp load(home) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <-
           File.lstat(path(home)),
         {:ok, bin} <- File.read(path(home)),
         {@format, stamps} when is_map(stamps) <- :erlang.binary_to_term(bin, [:safe]) do
      Enum.filter(stamps, &valid?/1)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp valid?({sha, {sha, a, b, c, d, e, f}}) when is_binary(sha),
    do: Enum.all?([a, b, c, d, e, f], &is_integer/1)

  defp valid?(_), do: false
end
