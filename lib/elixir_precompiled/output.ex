# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Output do
  @moduledoc false
  # Lines for the person watching: Mix's shell when Mix is running (a build
  # host, or Mix.install/2 on a device), plain IO otherwise.

  @spec success(String.t()) :: :ok
  def success(msg), do: put(:info, [:green, msg, :reset])

  @spec info(String.t()) :: :ok
  def info(msg), do: put(:info, msg)

  @spec warning(String.t()) :: :ok
  def warning(msg), do: put(:info, [:yellow, msg, :reset])

  @spec error(String.t()) :: :ok
  def error(msg), do: put(:error, [:red, msg, :reset])

  @doc false
  @spec put(:info | :error, IO.chardata(), boolean()) :: :ok
  def put(level, msg, mix? \\ mix_running?())

  def put(:info, msg, true), do: Mix.shell().info(msg)
  def put(:error, msg, true), do: Mix.shell().error(msg)
  def put(:info, msg, false), do: IO.puts(IO.ANSI.format(msg))
  def put(:error, msg, false), do: IO.puts(:stderr, IO.ANSI.format(msg))

  defp mix_running?() do
    Code.ensure_loaded?(Mix) and
      Enum.any?(Application.started_applications(), &match?({:mix, _, _}, &1))
  end
end
