# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.ChildProjectTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.ChildProject, as: C

  @moduletag :tmp_dir

  # A child VM started any other way writes the user's own ~/.hex.
  test "integration tests start child VMs only through ChildProject" do
    for path <- Path.wildcard("test/integration/**/*.exs"),
        call <- ["System.cmd", "Port.open", ":os.cmd", "System.shell"] do
      refute File.read!(path) =~ call, "#{path} calls #{call}; use ChildProject.cmd!/3"
    end
  end

  test "every child gets a private HEX_HOME", %{tmp_dir: dir} do
    out = C.cmd!(["sh", "-c", "echo home=$HEX_HOME"], dir, env: [], offline: false)
    assert out =~ "home=" <> Path.join(dir, "hex")

    out = C.cmd!(["sh", "-c", "echo home=$HEX_HOME"], dir, env: [{"HEX_OFFLINE", nil}])
    assert out =~ "home=" <> Path.join(dir, "hex")
  end
end
