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

    # Status.sweep/1 handles every outcome of Status.remove/2, the stale
    # provenance of a dep Mix rebuilt since its install included.
    %{removed: removed, failed: failed} = Status.sweep(build_lib)

    for {name, why} <- failed,
        do: Mix.shell().error("precompiled: could not remove #{name}: #{why}")

    n = length(removed)

    Mix.shell().info(
      "precompiled: removed #{n} installed #{if n == 1, do: "build", else: "builds"}" <>
        if(removed == [], do: "", else: " (#{Enum.join(removed, ", ")})")
    )

    if opts[:cache] do
      # The home a run in this project uses (by the run's own rule), and
      # the fallback under this _build, which an earlier run may have used.
      {_, home} = Config.run_home(Config.configured_home(), build_lib)
      homes = Enum.uniq([home, Config.fallback_home(build_lib)])

      for home <- homes, File.dir?(home) do
        :ok = Cache.clear(home)
        Mix.shell().info("precompiled: cleared the download cache in #{home}")
      end
    end

    :ok
  end
end
