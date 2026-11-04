# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.CLI do
  @moduledoc """
  `mix chain_test --target rpi4|rpi0_2 --device HOST [--known-hosts PATH]
  [--target-config PATH] [--source URL] [--report-dir DIR]`.

  Defaults: `~/.config/chain_test/known_hosts`, `~/.config/chain_test/target.exs`,
  the production precompiled source, and a fresh
  `<tmp>/chain_test-<UTC timestamp>` report dir, never inside the repository.

  `main/1` returns the exit code; only `Mix.Tasks.ChainTest` halts.
  """

  alias ChainTest.{Preflight, Result, Run}

  @usage "usage: mix chain_test --target rpi4|rpi0_2 --device HOST " <>
           "[--known-hosts PATH] [--target-config PATH] [--source URL] [--report-dir DIR]"

  @switches [
    target: :string,
    device: :string,
    known_hosts: :string,
    target_config: :string,
    source: :string,
    report_dir: :string
  ]

  @default_source "https://compatibility.nerves-project.org/api/precompiled"
  @root Path.expand("../..", __DIR__)

  @type opts :: %{
          target: String.t(),
          device: String.t(),
          known_hosts: Path.t(),
          target_config: Path.t(),
          source: String.t(),
          report_dir: Path.t(),
          fixture_dir: Path.t()
        }

  @doc "The usage line."
  @spec usage() :: String.t()
  def usage(), do: @usage

  @doc "Parses and validates `argv`; raises `Mix.Error` with the usage line."
  @spec parse!([String.t()]) :: opts()
  def parse!(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [] do
      bad = rest ++ Enum.map(invalid, fn {k, _} -> k end)
      Mix.raise("unexpected arguments: #{Enum.join(bad, " ")}\n" <> @usage)
    end

    target = opts[:target] || Mix.raise("--target is required\n" <> @usage)
    device = opts[:device] || Mix.raise("--device is required\n" <> @usage)

    unless target in Preflight.targets() do
      Mix.raise("unsupported target #{target}; supported: rpi4, rpi0_2\n" <> @usage)
    end

    if String.starts_with?(device, "-") do
      Mix.raise("--device must be a host name, got #{device}\n" <> @usage)
    end

    %{
      target: target,
      device: device,
      known_hosts: Path.expand(opts[:known_hosts] || "~/.config/chain_test/known_hosts"),
      target_config: Path.expand(opts[:target_config] || "~/.config/chain_test/target.exs"),
      source: String.trim_trailing(opts[:source] || @default_source, "/"),
      report_dir: Path.expand(opts[:report_dir] || default_report_dir()),
      fixture_dir: Path.join(@root, "fixture")
    }
  end

  @doc "Runs the chain test (`ChainTest.Run`) and returns the exit code."
  @spec main([String.t()]) :: 0 | 1
  def main(argv), do: Run.main(argv)

  # Reports never go into the repository tree.
  defp default_report_dir() do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(System.tmp_dir!(), "chain_test-" <> stamp)
  end

  @doc "Prints one status line for a result."
  @spec print(Result.t()) :: :ok
  def print(%Result{} = r) do
    IO.puts("[#{r.class}] #{r.step}/#{r.check} (#{r.ms} ms) #{r.detail}")
  end
end
