# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Parent.MixProject do
  use Mix.Project

  def project,
    do: [app: :parent, version: "0.1.0", deps: [{:opt, path: "../opt", optional: true}]]
end
