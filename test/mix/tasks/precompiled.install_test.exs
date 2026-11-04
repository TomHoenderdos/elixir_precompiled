# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.InstallTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Precompiled.Install

  test "only tasks that never compile deps skip the install" do
    # mix format with plugins calls loadpaths, which compiles every dep:
    # installing first is the point (README, Phoenix).
    for task <- ~w(compile test run format release phx.server deps.loadpaths),
        do: refute(Install.skip?(task))

    for task <- ~w(help precompiled.status precompiled.clean), do: assert(Install.skip?(task))
  end
end
