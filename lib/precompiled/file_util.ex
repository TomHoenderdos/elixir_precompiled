# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.FileUtil do
  @moduledoc false
  # Writes that two runs sharing one home can make at the same time: every
  # writer has its own temp name, and the rename is the only shared step.
  # Neither function sets a mode: files and dirs get what the process
  # umask allows, as Mix's own writes do.

  @spec write_atomic(Path.t(), iodata()) :: :ok | {:error, term()}
  def write_atomic(path, data) do
    tmp = "#{path}.tmp-#{System.pid()}-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  @doc false
  # Sets a cache entry's access and modification times to now, so the
  # cache gc evicts by last use. Unlike File.touch/1 it never creates the
  # file: an entry another run evicted meanwhile stays gone. Any failure
  # (a read-only home) is ignored. It follows a link: Erlang has no
  # lutimes, so a swap to a link right after the caller's lstat (by
  # someone who can already write the cache) changes the link target's
  # times only, never its content.
  @spec mark_used(Path.t()) :: :ok
  def mark_used(path) do
    t = System.os_time(:second)
    u = :undefined
    info = {:file_info, u, u, u, t, t, u, u, u, u, u, u, u, u}
    _ = :file.write_file_info(String.to_charlist(path), info, [{:time, :posix}])
    :ok
  rescue
    _ -> :ok
  end

  @spec writable_dir?(Path.t()) :: boolean()
  def writable_dir?(dir) do
    probe = Path.join(dir, ".probe-#{System.pid()}-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(probe, "") do
      _ = File.rm(probe)
      true
    else
      _ -> false
    end
  end
end
