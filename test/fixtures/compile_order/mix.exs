# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule CompileOrderFixture.MixProject do
  use Mix.Project

  def project,
    do: [app: :compile_order_fixture, version: "0.1.0", deps: deps()]

  # A diamond (zeta and alpha over mid over base) and an independent solo_b,
  # named so that no alphabetical or declaration order is the compile order.
  defp deps do
    [
      {:zeta, path: "deps_src/zeta"},
      {:alpha, path: "deps_src/alpha"},
      {:solo_b, path: "deps_src/solo_b"}
    ]
  end
end
