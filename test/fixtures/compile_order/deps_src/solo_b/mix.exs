# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule SoloB.MixProject do
  use Mix.Project

  def project, do: [app: :solo_b, version: "0.1.0", deps: []]

  def application, do: [env: [k: 1]]
end
