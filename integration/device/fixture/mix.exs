# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule DeviceFixture.MixProject do
  use Mix.Project

  @app :device_fixture
  @all_targets [:qemu_aarch64, :rpi4, :rpi0_2]

  def project do
    [
      app: @app,
      version: "0.1.0",
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [extra_applications: [:logger, :runtime_tools], mod: {DeviceFixture.Application, []}]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # No :mix anywhere: the release must not contain it (checked on the device).
  defp deps do
    [
      {:nerves, "~> 1.11", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.4"},
      {:elixir_precompiled, path: "../../..", targets: @all_targets},
      {:castore, "~> 1.0", targets: @all_targets},
      {:nerves_runtime, "~> 0.13", targets: @all_targets},
      {:nerves_pack, "~> 0.7", targets: @all_targets},
      {:nerves_system_qemu_aarch64, "0.5.1", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi4, "2.2.1", runtime: false, targets: :rpi4},
      {:nerves_system_rpi0_2, "2.2.1", runtime: false, targets: :rpi0_2}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
