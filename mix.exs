# SPDX-FileCopyrightText: None
#
# SPDX-License-Identifier: CC0-1.0
#
defmodule Precompiled.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/TomHoenderdos/elixir_precompiled"

  @otp_release :erlang.system_info(:otp_release) |> List.to_integer()
  if @otp_release < 27 do
    raise "precompiled requires OTP 27 or later. Current OTP version: #{@otp_release}"
  end

  def project do
    [
      app: :precompiled,
      name: "Precompiled",
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Install signed precompiled dependency builds instead of compiling them",
      package: package(),
      docs: docs(),
      dialyzer: [
        flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs],
        plt_add_apps: [:mix]
      ]
    ]
  end

  # crypto checks every signature and hash; the network stack is optional so
  # a firmware that only installs from a bundle can leave it out. A network
  # call without it returns {:error, {:missing_app, app}} (Precompiled).
  def application do
    [
      extra_applications: [
        :logger,
        :crypto,
        inets: :optional,
        ssl: :optional,
        public_key: :optional
      ]
    ]
  end

  def cli do
    [preferred_envs: %{credo: :dev, docs: :docs, "hex.build": :docs, "hex.publish": :docs}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:bandit, "~> 1.0", only: :test},
      {:plug, "~> 1.10", only: :test}
    ] ++ igniter()
  end

  # The installer task (mix igniter.install precompiled) needs
  # Igniter, whose own dependencies need Elixir 1.18; the library does not.
  # Optional and runtime: false, so a project that does not use Igniter
  # never fetches it.
  defp igniter() do
    if Version.match?(System.version(), ">= 1.18.0"),
      do: [{:igniter, "~> 0.6", optional: true, runtime: false}],
      else: []
  end

  defp docs do
    [
      main: "readme",
      # Internal modules the public docs name for context. They stay hidden,
      # so render these as plain code instead of warning about the link.
      skip_code_autolink_to: [
        "Precompiled.Check",
        "Precompiled.Env.MixProject",
        "Precompiled.Env.MixInstall",
        "Precompiled.Manifest",
        "Mix.Dep.ElixirSCM",
        "Mix.Hex.ensure_installed?/1"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/setup.md",
        "guides/nerves.md",
        "guides/device.md",
        "guides/configuration.md",
        "guides/matching.md",
        "guides/trust.md",
        "guides/troubleshooting.md",
        "guides/limitations.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        "Getting started": ["guides/setup.md", "guides/nerves.md", "guides/device.md"],
        Reference: ["guides/configuration.md", "guides/matching.md"],
        Explanation: ["guides/trust.md"],
        Troubleshooting: ["guides/troubleshooting.md", "guides/limitations.md"]
      ]
    ]
  end

  defp package do
    [
      files: [
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "guides",
        "lib",
        "LICENSE",
        "LICENSES/*",
        "mix.exs",
        "NOTICE",
        "priv",
        "README.md",
        "REUSE.toml"
      ],
      name: "precompiled",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
