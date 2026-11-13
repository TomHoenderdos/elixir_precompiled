# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Alpha.MixProject do
  use Mix.Project

  def project, do: [app: :alpha, version: "0.1.0", deps: [{:mid, path: "../mid"}]]
end
