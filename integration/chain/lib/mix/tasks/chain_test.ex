# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.ChainTest do
  @shortdoc "Runs the precompiled chain test against one device"
  @moduledoc """
  Runs the precompiled chain test for one target on one device.

      mix chain_test --target rpi4|rpi0_2 --device HOST [--known-hosts PATH]
                     [--source URL] [--report-dir DIR]

  Defaults: `--known-hosts ~/.config/chain_test/known_hosts`, the production
  precompiled source, `--report-dir integration/chain/reports`. Exits non-zero
  on any fail, refused, disagreement or not exercised result.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    argv |> ChainTest.CLI.main() |> System.halt()
  end
end
