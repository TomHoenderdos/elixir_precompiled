# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.Clean do
  @shortdoc "Removes precompiled installs (and with --cache, the download cache)"
  @moduledoc """
  Removes every dependency `elixir_precompiled` installed in the current
  `_build` (this `MIX_ENV` and `MIX_TARGET`), so the next `mix compile`
  compiles them from source (or installs them again, when the library is
  on). Only build dirs that carry the provenance file an install writes
  are removed; a dependency Mix compiled is never touched.

      mix precompiled.clean           # this build's installs
      mix precompiled.clean --cache   # also the downloaded files, manifests and scans

  Trust state (batch sequence, adopted roots) is never removed.
  """
  use Mix.Task
  alias ElixirPrecompiled.{Cache, Config, Status}

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [cache: :boolean])
    Mix.Project.get!()
    build_lib = Path.join(Mix.Project.build_path(), "lib")

    removed =
      for %{name: name} <- Status.installed(build_lib),
          result = Status.remove(build_lib, name),
          report(name, result) == :ok,
          do: name

    n = length(removed)

    Mix.shell().info(
      "precompiled: removed #{n} installed #{if n == 1, do: "build", else: "builds"}" <>
        if(removed == [], do: "", else: " (#{Enum.join(removed, ", ")})")
    )

    if opts[:cache] do
      # The configured home, and the fallback a run uses when that one
      # takes no writes.
      homes = Enum.filter([Config.home_dir(), Path.join(build_lib, ".precompiled/home")], & &1)

      for home <- homes, File.dir?(home) do
        :ok = Cache.clear(home)
        Mix.shell().info("precompiled: cleared the download cache in #{home}")
      end
    end

    :ok
  end

  defp report(_name, :ok), do: :ok

  defp report(name, {:error, why}) do
    Mix.shell().error("precompiled: could not remove #{name}: #{why}")
    :error
  end

  defp report(_name, :not_installed), do: :skip
end
