# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.InstallTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.Install
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    old = System.get_env("MIX_INSTALL_DIR")
    System.put_env("MIX_INSTALL_DIR", dir)

    on_exit(fn ->
      if old,
        do: System.put_env("MIX_INSTALL_DIR", old),
        else: System.delete_env("MIX_INSTALL_DIR")
    end)

    %{config: %{source: "https://example.test/x", except: [], root_path: "/r", home: dir}}
  end

  test "normalize_deps matches Mix.install/2" do
    assert Install.normalize_deps([
             :jason,
             {:decimal, "~> 3.0"},
             {:x, path: "rel"},
             {:y, ">= 0", only: :dev}
           ]) ==
             [
               {:jason, ">= 0.0.0"},
               {:decimal, "~> 3.0"},
               {:x, path: Path.expand("rel")},
               {:y, ">= 0", only: :dev}
             ]
  end

  # Mix.install/2's own naming, which changed in Elixir 1.19: our install
  # must land in the dir Mix.install/2 then uses, or it compiles anyway.
  test "project_dir is the dir Mix.install/2 uses on this Elixir", %{tmp_dir: dir} do
    deps = [:jason]
    md5 = :erlang.md5(:erlang.term_to_binary({[{:jason, ">= 0.0.0"}], [], [], true}))
    {elixir, erts} = {System.version(), :erlang.system_info(:version)}

    expected =
      if Version.match?(elixir, ">= 1.19.0-0"),
        do: Path.join([dir, "ex-#{elixir}-erl-#{erts}", Base.url_encode64(md5, padding: false)]),
        else: Path.join([dir, "elixir-#{elixir}-erts-#{erts}", Base.encode16(md5, case: :lower)])

    assert Install.project_dir(deps, []) == expected

    # The id changes with the config and consolidation options, as in Mix.
    refute Install.project_dir(deps, consolidate_protocols: false) ==
             Install.project_dir(deps, [])

    refute Install.project_dir(deps, config: [a: 1]) == Install.project_dir(deps, [])
  end

  test "without Mix the error names extra_applications" do
    assert_raise RuntimeError, ~r/add :mix to extra_applications/, fn ->
      Install.ensure_mix!(false)
    end

    assert Install.ensure_mix!(true) == :ok
  end

  test "no config: plain Mix.install with one warning", %{tmp_dir: dir} do
    parent = self()

    installer = fn deps, opts ->
      send(parent, {:installed, deps, opts})
      :ok
    end

    out =
      capture_io(fn ->
        assert Install.run([:jason], [verbose: true], nil, installer: installer) == :ok
      end)

    assert out =~ "precompiled: no source configured"
    assert_received {:installed, [:jason], [verbose: true]}

    refute File.exists?(
             Path.join(dir, "ex-#{System.version()}-erl-#{:erlang.system_info(:version)}")
           )
  end

  test "the kill switch names itself in the warning" do
    installer = fn _deps, _opts -> :ok end
    System.put_env("PRECOMPILED", "0")

    try do
      out =
        capture_io(fn -> assert Install.run([:jason], [], nil, installer: installer) == :ok end)

      assert out =~ "precompiled: disabled by PRECOMPILED"
      refute out =~ "no source configured"
    after
      System.delete_env("PRECOMPILED")
    end
  end

  test "off: builds an earlier install placed go before Mix.install compiles", %{tmp_dir: _} do
    proj = Install.project_dir([:jason], [])
    lib = Path.join(proj, "_build/#{Mix.env()}/lib")

    File.mkdir_p!(proj)

    File.write!(
      Path.join(proj, "mix.lock"),
      ~s(%{"jason": {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "o"}}\n)
    )

    for f <- ["ebin/jason.app", ".mix/compile.elixir_scm", ".mix/precompiled.json"] do
      File.mkdir_p!(Path.dirname(Path.join([lib, "jason", f])))
      File.write!(Path.join([lib, "jason", f]), "x")
    end

    parent = self()

    installer = fn _deps, _opts ->
      send(parent, {:installed, File.exists?(Path.join(lib, "jason"))})
      :ok
    end

    out =
      capture_io(fn ->
        assert Install.run([:jason], [], nil, installer: installer, installed?: true) == :ok
      end)

    # A repeat call in one VM: its deps are loaded, nothing is undone.
    assert_received {:installed, true}
    refute out =~ "removed"

    out = capture_io(fn -> assert Install.run([:jason], [], nil, installer: installer) == :ok end)
    assert out =~ "precompiled: disabled; removed 1 installed build"
    assert_received {:installed, false}
  end

  test "a repeat install in the same VM defers to Mix without touching the project", %{
    config: config,
    tmp_dir: dir
  } do
    parent = self()

    installer = fn deps, opts ->
      send(parent, {:installed, deps, opts})
      :ok
    end

    assert Install.run([:jason], [], config, installer: installer, installed?: true) == :ok
    assert_received {:installed, [:jason], []}

    refute File.exists?(
             Path.join(dir, "ex-#{System.version()}-erl-#{:erlang.system_info(:version)}")
           )
  end

  test "a configured install resolves, checks and then installs", %{config: config} do
    parent = self()

    installer = fn deps, opts ->
      send(parent, {:installed, deps, opts})
      :ok
    end

    project = Mix.Project.get()

    capture_io(fn ->
      assert Install.run([], [], config, installer: installer, in_project?: false) == :ok
    end)

    assert_received {:installed, [], []}
    assert Mix.Project.get() == project
    assert File.dir?(Install.project_dir([], []))
  end

  test "inside a Mix project the configured install refuses before any work", %{config: config} do
    installer = fn _deps, _opts -> flunk("installer must not run") end

    assert_raise Mix.Error, ~r/cannot be used inside a Mix project/, fn ->
      Install.run([], [], config, installer: installer, in_project?: true)
    end

    refute File.exists?(Install.project_dir([], []))
  end

  test "MIX_INSTALL_FORCE survives a failed install", %{config: config, tmp_dir: dir} do
    # An install dir under a regular file cannot be created, so the forced
    # install fails before Mix.install/2 would run.
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "")
    System.put_env("MIX_INSTALL_DIR", blocker)
    System.put_env("MIX_INSTALL_FORCE", "1")
    on_exit(fn -> System.delete_env("MIX_INSTALL_FORCE") end)
    installer = fn _deps, _opts -> flunk("installer must not run") end

    assert_raise File.Error, fn ->
      Install.run([], [], config, installer: installer, in_project?: false)
    end

    assert System.get_env("MIX_INSTALL_FORCE") == "1"
  end

  test "a crashing precompiled step still runs Mix.install", %{config: config} do
    parent = self()

    installer = fn deps, opts ->
      send(parent, {:installed, deps, opts})
      :ok
    end

    out =
      capture_io(fn ->
        assert Install.run([], [], config,
                 installer: installer,
                 in_project?: false,
                 check: fn -> raise "boom" end
               ) == :ok
      end)

    assert out =~ "precompiled: internal error, compiling from source (boom)"
    assert_received {:installed, [], []}
  end

  test "a shutdown exit in the precompiled step is passed on", %{config: config} do
    installer = fn _deps, _opts -> flunk("Mix.install ran after a shutdown") end

    capture_io(fn ->
      assert catch_exit(
               Install.run([], [], config,
                 installer: installer,
                 in_project?: false,
                 check: fn -> exit({:shutdown, :stop}) end
               )
             ) == {:shutdown, :stop}
    end)
  end
end
