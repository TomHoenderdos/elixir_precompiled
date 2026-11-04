# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Setup.PlantRoot do
  @moduledoc """
  Writes an attacker's root (`ChainTest.AttackerRoot`, a fresh key of its
  own) at `path`, relative to the case home, for a case that points
  something other than the project config at it (T9: an environment
  variable naming a root path).
  """
  @behaviour ChainTest.Conformance.Setup

  alias ChainTest.AttackerRoot

  @impl true
  def valid_args?(%{path: path} = args) when map_size(args) == 1, do: inside?(path)
  def valid_args?(_args), do: false

  @doc false
  # A non-empty relative path that stays under the directory it is joined to.
  @spec inside?(term()) :: boolean()
  def inside?(path) when is_binary(path) and path != "" do
    Path.type(path) == :relative and ".." not in Path.split(path)
  end

  def inside?(_path), do: false

  @impl true
  def setup(home, _snap, %{path: rel}) do
    path = Path.join(home, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, AttackerRoot.envelope(1))
  end
end
