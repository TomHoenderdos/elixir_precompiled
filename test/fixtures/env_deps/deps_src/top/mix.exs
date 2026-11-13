# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Top.MixProject do
  use Mix.Project

  def project,
    do: [app: :top, version: "0.1.0", deps: [{:link, path: "../link"}]]
end
