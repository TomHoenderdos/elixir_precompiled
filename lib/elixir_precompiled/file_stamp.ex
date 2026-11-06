# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.FileStamp do
  @moduledoc false
  # A cached file (`<home>/files/<sha>`) whose bytes were hashed to its sha
  # is stamped with what the file system says about it: device, inode,
  # size, mtime and ctime, read from the open file. A later run that finds
  # the same stamp on the open file does not hash it again; any difference
  # at all is a full re-hash, and a mismatch on the hash is handled as it
  # always was (the file is fetched again).
  #
  # ctime is set by the kernel on every write, rename and time change and
  # cannot be set back from user space, so a rewrite that puts size and
  # mtime back still shows. Stamps are kept in seconds, so a file whose
  # ctime is the current second is not stamped: a change later in that same
  # second would carry the same ctime.
  #
  # Stamps live in one file in the home (`file_stamps`), read once per run
  # and written once, atomically, when the run changed them. They are only
  # read or written while the home itself is a real directory only its
  # owner can enter (mode 0700): a stamp vouches for bytes nobody else could
  # have changed. Losing the file, or two runs overwriting each other's,
  # only costs re-hashes.

  alias ElixirPrecompiled.FileUtil

  @type t :: {String.t(), integer(), integer(), integer(), integer(), integer(), integer()}

  @file_name "file_stamps"
  @format 1
  @max_bytes 67_108_864

  @spec new(File.Stat.t(), String.t()) :: t()
  def new(%File.Stat{} = stat, sha) when is_binary(sha) do
    {sha, stat.major_device, stat.minor_device, stat.inode, stat.size, stat.mtime, stat.ctime}
  end

  @spec match?(t() | nil, File.Stat.t(), String.t()) :: boolean()
  def match?(nil, _stat, _sha), do: false

  def match?(stamp, %File.Stat{} = stat, sha) when is_tuple(stamp) and is_binary(sha) do
    integers?(stat) and stamp == new(stat, sha)
  end

  def match?(_stamp, _stat, _sha), do: false

  # A stat without integer times (or inode) cannot be compared exactly.
  defp integers?(stat) do
    Enum.all?(
      [stat.major_device, stat.minor_device, stat.inode, stat.size, stat.mtime, stat.ctime],
      &is_integer/1
    )
  end

  @doc false
  # Whether a stat may be recorded now: taken in seconds, a ctime or mtime
  # that is not in the past yet could be shared with a change still to come.
  @spec settled?(File.Stat.t(), integer()) :: boolean()
  def settled?(%File.Stat{} = stat, now) do
    integers?(stat) and stat.ctime < now and stat.mtime < now
  end

  @doc """
  True only for a real directory (not a link) whose mode is exactly 0700:
  no group or other bits at all. Never on Windows, where modes say nothing.
  """
  @spec trusted_home?(Path.t() | nil) :: boolean()
  def trusted_home?(home) when is_binary(home) do
    not match?({:win32, _}, :os.type()) and
      match?(
        {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o777) == 0o700,
        File.lstat(home)
      )
  end

  def trusted_home?(_), do: false

  @doc false
  # The run's stamps: an ETS table loaded from the home's stamps file, or
  # nil when the home is not trusted (then nothing is skipped or recorded).
  # The table is public: the per-dep workers read and record into it.
  @spec open(Path.t() | nil) :: :ets.tid() | nil
  def open(home) do
    if trusted_home?(home) do
      table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
      :ets.insert(table, {:dirty, false})
      :ets.insert(table, Enum.map(load(home), fn {sha, stamp} -> {{:stamp, sha}, stamp} end))
      table
    end
  rescue
    _ -> nil
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
