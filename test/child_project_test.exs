# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ChildProjectTest do
  use ExUnit.Case, async: true
  alias Precompiled.ChildProject, as: C

  @moduletag :tmp_dir

  # A child VM started any other way writes the user's own ~/.hex.
  test "integration tests start child VMs only through ChildProject" do
    files = Path.wildcard("test/integration/**/*.exs")
    assert files != [], "no integration tests found from #{File.cwd!()}"

    for path <- files,
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

  test "a caller's env cannot override the private HEX_HOME", %{tmp_dir: dir} do
    out = C.cmd!(["sh", "-c", "echo home=$HEX_HOME"], dir, env: [{"HEX_HOME", "/elsewhere"}])
    assert out =~ "home=" <> Path.join(dir, "hex")
  end

  test "the seed is kept per package list", %{tmp_dir: dir} do
    marker = Path.join(dir, "hex/.seeded")
    echo = ["sh", "-c", "echo offline=$HEX_OFFLINE"]

    out = C.cmd!(echo, dir, packages: ["no_such_package-0.0.0"])
    assert out =~ "offline=\n"
    assert File.read!(marker) == "online no_such_package-0.0.0"

    # Another list seeds again instead of reusing the first answer.
    C.cmd!(echo, dir, packages: ["jason-1.4.5"])
    assert File.read!(marker) =~ ~r/^(offline|online) jason-1\.4\.5$/
  end
end
