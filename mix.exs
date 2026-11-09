# SPDX-FileCopyrightText: None
#
# SPDX-License-Identifier: CC0-1.0
#
defmodule ElixirPrecompiled.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/TomHoenderdos/elixir_precompiled"

  @otp_release :erlang.system_info(:otp_release) |> List.to_integer()
  if @otp_release < 27 do
    raise "elixir_precompiled requires OTP 27 or later. Current OTP version: #{@otp_release}"
  end

  def project do
    [
      app: :elixir_precompiled,
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
    [preferred_envs: %{credo: :dev, docs: :docs, "hex.build": :docs}]
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

  # The installer task (mix igniter.install elixir_precompiled) needs
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
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: [
        "CHANGELOG.md",
        "lib",
        "LICENSE",
        "LICENSES/*",
        "mix.exs",
        "NOTICE",
        "priv",
        "README.md",
        "REUSE.toml"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
