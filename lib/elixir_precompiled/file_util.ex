# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.FileUtil do
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
