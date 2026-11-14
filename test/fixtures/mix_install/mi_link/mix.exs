# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule MiLink.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mi_link,
      version: "0.1.0",
      deps: [
        {:mi_here, path: "../mi_here", optional: true},
        {:mi_gone, path: "../mi_gone", optional: true}
      ]
    ]
end
