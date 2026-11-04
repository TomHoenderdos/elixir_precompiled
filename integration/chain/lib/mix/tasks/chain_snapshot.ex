# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.ChainSnapshot do
  @shortdoc "Downloads and verifies a snapshot of the precompiled portal"
  @moduledoc """
  Takes a snapshot (`ChainTest.Snapshot`) of the fixture's precompiled
  builds for one target and prints its directory.

      mix chain_snapshot [--target rpi4|rpi0_2] [--source URL] [--dir DIR]

  Defaults: `rpi4`, the production portal, a fresh dir under the system tmp
  dir (never inside the repository). The snapshot is good for 24 hours.
  Exits 1 when it cannot be taken.
  """
  use Mix.Task

  @requirements ["app.start"]

  @usage "usage: mix chain_snapshot [--target rpi4|rpi0_2] [--source URL] [--dir DIR]"

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv, strict: [target: :string, source: :string, dir: :string])

    if rest != [] or invalid != [], do: Mix.raise(@usage)

    target = opts[:target] || "rpi4"

    unless target in ChainTest.Preflight.targets() do
      Mix.raise("unsupported target #{target}; supported: rpi4, rpi0_2\n" <> @usage)
    end

    input = %{
      source: opts[:source] || ChainTest.CLI.default_source(),
      fixture_dir: Path.join(ChainTest.CLI.root(), "fixture"),
      target: target,
      dir: opts[:dir] && Path.expand(opts[:dir])
    }

    case ChainTest.Snapshot.take(input) do
      {:ok, snap} ->
        hits = Enum.count(snap.deps, fn {_, d} -> d.builds > 0 end)
        IO.puts("snapshot: #{snap.dir} (batch #{snap.sequence}, #{hits} deps with builds)")

      {:error, why} ->
        IO.puts(:stderr, "snapshot failed: #{why}")
        System.halt(1)
    end
  end
end
