# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainPathDep.MixProject do
  use Mix.Project

  # A path dependency of the chain fixture, not Nerves tooling: the client
  # must never install a precompiled build of it (P5), whatever a batch says.
  @version "0.1.0"

  def project do
    [app: :chain_path_dep, version: @version, elixir: "~> 1.18", deps: []]
  end

  def application, do: [extra_applications: []]
end
