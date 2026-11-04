# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainPathDep do
  @moduledoc "The chain fixture's path dependency (P5-path): compiled here, never precompiled."

  @doc "Proves the dep was compiled into the project."
  @spec hello() :: :chain_path_dep
  def hello(), do: :chain_path_dep
end
