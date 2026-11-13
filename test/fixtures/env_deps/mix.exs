# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule EnvDepsFixture.MixProject do
  use Mix.Project

  def project,
    do: [app: :env_deps_fixture, version: "0.1.0", deps: deps()]

  # parent lists opt as an optional dep; the project pulls opt in only for
  # :test, as phx_new does lazy_html. Mix gives parent the child opt in
  # test and none in dev, though both envs share one lock.
  defp deps do
    [
      {:parent, path: "deps_src/parent"},
      {:opt, path: "deps_src/opt", only: :test}
    ]
  end
end
