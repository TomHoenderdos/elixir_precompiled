# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule MiTop.MixProject do
  use Mix.Project

  def project,
    do: [app: :mi_top, version: "0.1.0", deps: [{:mi_link, path: "../mi_link"}]]
end
