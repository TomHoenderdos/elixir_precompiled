# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.Status do
  @shortdoc "Lists the dependencies installed precompiled in this build"
  @moduledoc """
  Lists every dependency in the current `_build` (this `MIX_ENV` and
  `MIX_TARGET`) that `precompiled` installed, with the batch and
  manifest it came from, and where the cache lives.

      mix precompiled.status
  """
  use Mix.Task
  alias Precompiled.{Config, Status}

  @impl Mix.Task
  def run(_args) do
    Mix.Project.get!()
    build_lib = Path.join(Mix.Project.build_path(), "lib")
    installed = Status.installed(build_lib)
    Enum.each(installed, &Mix.shell().info(Status.format(&1)))

    config = Config.load()

    # The cache a run in this project would use, by the run's own rule.
    cache =
      case Config.run_home(Config.configured_home(), build_lib) do
        {:ok, home} -> home
        {:fallback, home} -> "#{home} (#{inspect(Config.configured_home())} is not writable)"
      end

    Mix.shell().info(
      "precompiled: #{length(installed)} installed in #{build_lib}; " <>
        "source #{if config, do: config.source, else: "off"}; " <>
        "cache #{cache}" <>
        if(Config.offline?(), do: "; offline", else: "")
    )
  end
end
