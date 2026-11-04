# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.ChainConformance do
  @shortdoc "Runs the precompiled client against a loopback mirror, one case at a time"
  @moduledoc """
  Runs the conformance cases (`ChainTest.Conformance`).

      mix chain_conformance [--target rpi4|rpi0_2] [--cases PATH] [--only ID,ID]
                            [--source URL] [--snapshot-dir DIR] [--report-dir DIR]

  Defaults: `rpi4`, `conformance/cases.exs`, every case, the production
  portal (contacted once, for the snapshot), fresh dirs under the system tmp
  dir. Needs no device. Exits non-zero when a case fails or is not exercised.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: argv |> ChainTest.Conformance.main() |> System.halt()
end
