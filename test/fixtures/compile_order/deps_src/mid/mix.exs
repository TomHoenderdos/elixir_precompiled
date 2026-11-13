# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mid.MixProject do
  use Mix.Project

  def project, do: [app: :mid, version: "0.1.0", deps: [{:base, path: "../base"}]]
end
