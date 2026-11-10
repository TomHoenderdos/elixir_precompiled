# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainFixture.MixProject do
  use Mix.Project

  @app :chain_fixture
  @version "0.1.0"
  @all_targets [:rpi4, :rpi0_2]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      # The portal publishes release (stripped) BEAMs, without the debug info
      # protocol consolidation reads.
      consolidate_protocols: false,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto],
      mod: {ChainFixture.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # The precompiled test subjects are pinned exactly: a bump changes what the
  # portal must have built, so it goes together with expected.exs.
  defp deps do
    [
      nerves_dep(),
      {:precompiled, path: "../../..", runtime: false, override: true},
      {:nerves_runtime, "~> 0.13.12"},
      {:toolshed, "~> 0.5.0"},
      # A path dep that is not Nerves tooling: never precompiled (P5).
      {:chain_path_dep, path: "deps_local/chain_path_dep"},

      # Pure Elixir; on host too, so the probe's host test has an app to hash.
      {:jason, "1.4.5"},

      # Target-only test subjects and the deploy path (nerves_ssh).
      {:nerves_pack, "0.7.2", targets: @all_targets},
      {:exqlite, "0.42.0", targets: @all_targets},
      {:argon2_elixir, "4.1.3", targets: @all_targets},
      {:circuits_gpio, "2.3.0", targets: @all_targets},
      {:ash, "3.37.2", targets: @all_targets},
      # ash's optional plug: the portal builds ash with it, so a lock
      # without it never matches an ash build.
      {:plug, "1.20.3", targets: @all_targets},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi0_2, "~> 2.2", runtime: false, targets: :rpi0_2}
    ]
  end

  # nerves with the precompiled hook. CHAIN_NERVES_PATH points at a local
  # checkout instead of the branch.
  defp nerves_dep() do
    case System.get_env("CHAIN_NERVES_PATH") do
      nil ->
        {:nerves,
         github: "TomHoenderdos/nerves",
         branch: "feat/precompiled",
         runtime: false,
         override: true}

      path ->
        {:nerves, path: path, runtime: false, override: true}
    end
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.erts/0,
      steps: [&Nerves.init_release/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
