# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.FileBytes do
  @moduledoc """
  Changes every file the mirror serves (`files/<sha256>`), real bytes
  otherwise:

    * `change: :flip_byte` - one byte changed, the size kept (F1).
    * `change: :truncate` - declares the file's size, sends one byte less
      and closes (F2).
    * `change: :larger` - one byte more than the manifest's size (F2).
    * `change: :endless` - no `content-length`, 64 KiB chunks until the
      client hangs up or the mirror's cap (F2).

  An empty file has no byte to change or leave out, so `:flip_byte` and
  `:truncate` serve it as it is; every build's `.app` is not empty.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Mirror.Transform

  @changes [:flip_byte, :truncate, :larger, :endless]
  @chunk :binary.copy(<<0>>, 65_536)

  @impl true
  def valid_args?(%{change: change} = args) when map_size(args) == 1, do: change in @changes
  def valid_args?(_args), do: false

  @impl true
  def transform(path, bytes, %{change: change}) do
    if Transform.file_path?(path), do: change(change, bytes), else: {200, bytes}
  end

  defp change(c, "") when c in [:flip_byte, :truncate], do: {200, ""}
  defp change(:flip_byte, bytes), do: {200, Transform.flip_byte(bytes)}
  defp change(:truncate, bytes), do: {:truncate, 200, bytes, byte_size(bytes) - 1}
  defp change(:larger, bytes), do: {200, bytes <> <<0>>}
  defp change(:endless, _bytes), do: {:endless, 200, @chunk, 0}
end
