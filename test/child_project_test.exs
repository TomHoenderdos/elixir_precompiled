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

defmodule Precompiled.ChildProjectLockTest do
  # Changes the VM's env: never async.
  use ExUnit.Case, async: false
  alias Precompiled.ChildProject, as: C

  @moduletag :tmp_dir

  # Mix has no OS build lock before 1.18.
  if Version.match?(System.version(), ">= 1.18.0") do
    # A Mix build lock nobody releases, as Mix's own can be (ci.yml): this
    # VM holds the child's for the child's whole run. Waiting on it, the
    # child would time out; without the lock it compiles.
    @tag timeout: 120_000
    test "a child never waits on a Mix build lock", %{tmp_dir: dir} do
      proj = Path.join(dir, "proj")
      File.mkdir_p!(proj)

      File.write!(Path.join(proj, "mix.exs"), """
      defmodule LockProj.MixProject do
        use Mix.Project
        def project, do: [app: :lock_proj, version: "0.1.0", deps: []]
      end
      """)

      out = holding_build_lock(Path.join(proj, "_build/dev"), fn -> compile(proj) end)
      refute out =~ "Waiting for lock", out
    end

    # Mix locks a build dir by its path, the child's here. CI turns the
    # lock off for this VM, whose env a child inherits: it is on for the
    # whole call, so only the harness can turn it off for the child.
    defp holding_build_lock(build_path, fun) do
      saved = System.get_env("MIX_OS_CONCURRENCY_LOCK")
      System.delete_env("MIX_OS_CONCURRENCY_LOCK")

      try do
        Mix.Project.with_build_lock([deps_build_path: build_path], fun)
      after
        if saved, do: System.put_env("MIX_OS_CONCURRENCY_LOCK", saved)
      end
    end

    defp compile(proj), do: C.mix!(proj, ["compile"], [], timeout: 30)
  end
end
