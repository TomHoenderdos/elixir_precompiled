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

  test "build_methods reads overrides a package's own mix.exs sets on its deps", %{
    tmp_dir: dir
  } do
    parent = Path.join(dir, "parent")
    File.mkdir_p!(parent)

    File.write!(Path.join(parent, "mix.exs"), """
    defmodule Parent.MixProject do
      use Mix.Project

      def project do
        [
          app: :parent,
          version: "0.1.0",
          deps: [
            {:jason, "~> 1.4", manager: :make},
            {:decimal, "~> 2.0", system_env: [{"DECIMAL_X", "1"}]},
            {:telemetry, "~> 1.0"}
          ]
        ]
      end
    end
    """)

    project = Path.join(dir, "install")
    File.mkdir_p!(project)

    Mix.Dep.Lock.write(
      %{
        jason: {:hex, :jason, "1.4.4", "i", [:mix], [], "hexpm", "JOUTER"},
        decimal: {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", "DOUTER"},
        telemetry: {:hex, :telemetry, "1.3.0", "i", [:rebar3], [], "hexpm", "TOUTER"}
      },
      file: Path.join(project, "mix.lock")
    )

    deps = [{:parent, path: parent}]
    methods = outside_project(fn -> Install.build_methods(project, deps) end)

    assert methods[:jason] == %{manager: "make", overrides: [:manager]}
    assert methods[:decimal] == %{manager: "mix", overrides: [:system_env]}
    assert methods[:telemetry] == %{manager: "rebar3", overrides: []}
    refute Map.has_key?(methods, :parent)
  end

  test "resolve/4 reads each dep's children as Mix loads them, or nil when they do not load", %{
    tmp_dir: dir
  } do
    dep = fn app, children ->
      %Mix.Dep{app: app, scm: Hex.SCM, opts: [], manager: :mix, deps: children}
    end

    here = dep.(:here, [])
    loaded = fn -> [dep.(:pkg, [here]), here] end
    project = Path.join(dir, "loaded")

    assert {methods, present} = quiet(fn -> Install.resolve(project, [], [], loaded) end)
    assert present == %{pkg: [:here], here: []}
    assert methods[:pkg] == %{manager: "mix", overrides: []}

    boom = fn -> raise "lock is broken" end
    other = Path.join(dir, "broken")

    assert quiet(fn -> Install.resolve(other, [], [], boom) end) ==
             {{:unknown, "lock is broken"}, nil}

    # A dep whose children are not the shape Mix gives: the tree is unknown
    # (lock-only matching), the build methods are still read.
    odd = fn -> [%{dep.(:pkg, []) | deps: :nope}] end
    third = Path.join(dir, "odd")
    assert {%{pkg: _}, nil} = quiet(fn -> Install.resolve(third, [], [], odd) end)
  end

  test "a child that is not an atom leaves the tree unknown", %{tmp_dir: dir} do
    pkg = %Mix.Dep{app: :pkg, scm: Hex.SCM, opts: [], manager: :mix, deps: [%{app: "here"}]}

    assert {%{pkg: _}, nil} =
             quiet(fn -> Install.resolve(Path.join(dir, "p"), [], [], fn -> [pkg] end) end)
  end

  # x lists z as optional and does not depend on y; y 2.0.0 requires z, y
  # 1.0.0 does not. The install project's lock has y 2.0.0; the lockfile:
  # option pins y 1.0.0, so Mix.install/2 compiles x without z. `load`
  # gives what Mix's converger would from the lock in the project's dir.
  @x {:hex, :x, "1.0.0", "i", [:mix], [{:z, "~> 1.0", [hex: :z, optional: true]}], "hexpm",
      "XOUTER"}
  @y2 {:hex, :y, "2.0.0", "i", [:mix], [{:z, "~> 1.0", [hex: :z]}], "hexpm", "Y2OUTER"}
  @y1 {:hex, :y, "1.0.0", "i", [:mix], [], "hexpm", "Y1OUTER"}
  @z {:hex, :z, "1.0.0", "i", [:mix], [], "hexpm", "ZOUTER"}

  defp lock_load() do
    fn ->
      dep = fn app, children ->
        %Mix.Dep{app: app, scm: Hex.SCM, opts: [], manager: :mix, deps: children}
      end

      z = dep.(:z, [])
      y_children = if elem(Mix.Dep.Lock.read()[:y], 2) == "2.0.0", do: [z], else: []
      x_children = if y_children == [], do: [], else: [z]
      [dep.(:x, x_children), dep.(:y, y_children) | Enum.uniq(y_children ++ x_children)]
    end
  end

  defp x_with_z(present) do
    build = %{
      "elixir" => "1.20.3",
      "otp" => "29",
      "dep_env" => "prod",
      "system_version" => nil,
      "run_id" => "r",
      "deps" => %{"z" => %{"version" => "1.0.0", "checksum" => "ZOUTER"}},
      "compile_env" => [],
      "package_checksum" => "XOUTER"
    }

    manifest = %{
      "versions" => %{
        "1.0.0" => %{
          "builds" => [%{"target" => "pure_elixir", "ebin" => [], "priv" => [], "build" => build}]
        }
      }
    }

    ctx = %{
      name: "x",
      version: "1.0.0",
      lock_entry: @x,
      lock: %{x: @x, y: @y1, z: @z},
      env_closure: Precompiled.Env.closure(present, :x),
      system: {"host", ""},
      elixir: "1.20.3",
      otp: "29",
      dep_env: "prod",
      config: fn _app, _path -> :error end
    }

    manifest |> Precompiled.Match.select(ctx) |> elem(0)
  end

  test "resolve merges the lockfile: option as Mix.install/2 does: a pinned sibling misses", %{
    tmp_dir: dir
  } do
    external = Path.join(dir, "pinned.lock")
    Mix.Dep.Lock.write(%{y: @y1}, file: external)

    project = Path.join(dir, "install")
    File.mkdir_p!(project)
    Mix.Dep.Lock.write(%{x: @x, y: @y2, z: @z}, file: Path.join(project, "mix.lock"))

    {_methods, present} =
      quiet(fn -> Install.resolve(project, [], [lockfile: external], lock_load()) end)

    # The lock Mix.install/2 compiles from, and the marker that makes it skip
    # a second merge, exactly as it writes them.
    assert Mix.Dep.Lock.read(Path.join(project, "mix.lock")) == %{x: @x, y: @y1, z: @z}

    assert File.read!(Path.join(project, "merge.lock.md5")) ==
             Base.encode64(:erlang.md5(File.read!(external)))

    assert present.x == []
    assert x_with_z(present) == :miss

    # Without the merge the tree would have z under x, and the build with z
    # would be taken although Mix.install/2 then compiles x without it.
    other = Path.join(dir, "unpinned")
    File.mkdir_p!(other)
    Mix.Dep.Lock.write(%{x: @x, y: @y2, z: @z}, file: Path.join(other, "mix.lock"))
    {_methods, unpinned} = quiet(fn -> Install.resolve(other, [], [], lock_load()) end)
    assert unpinned.x == [:z]
  end

  test "lockfile: as a path dep's name reads that dep's mix.lock", %{tmp_dir: dir} do
    src = Path.join(dir, "pinner")
    File.mkdir_p!(src)

    File.write!(Path.join(src, "mix.exs"), """
    defmodule Pinner.MixProject do
      use Mix.Project
      def project, do: [app: :pinner, version: "0.1.0", deps: []]
    end
    """)

    Mix.Dep.Lock.write(%{y: @y1}, file: Path.join(src, "mix.lock"))
    project = Path.join(dir, "install")
    File.mkdir_p!(project)
    Mix.Dep.Lock.write(%{x: @x, y: @y2, z: @z}, file: Path.join(project, "mix.lock"))
    deps = [{:pinner, path: src}]

    {_methods, present} =
      quiet(fn -> Install.resolve(project, deps, [lockfile: :pinner], lock_load()) end)

    assert present.x == []

    assert_raise Mix.Error, ~r/unknown dependency :nope given to :lockfile/, fn ->
      quiet(fn -> Install.resolve(project, deps, [lockfile: :nope], lock_load()) end)
    end
  end

  test "a configured install hands Check the tree Mix loaded", %{config: config} do
    parent = self()
    here = %Mix.Dep{app: :here, scm: Hex.SCM, opts: [], manager: :mix, deps: []}
    pkg = %{here | app: :pkg, deps: [here]}

    capture_io(fn ->
      assert Install.run([], [], config,
               installer: fn _, _ -> :ok end,
               in_project?: false,
               check: &send(parent, {:env, &1}),
               load: fn -> [pkg, here] end
             ) == :ok
    end)

    assert_received {:env, %Precompiled.Env{present_deps: %{pkg: [:here], here: []}}}
  end

  test "deps that do not load make build methods unknown, with the cause", %{tmp_dir: dir} do
    boom = fn -> raise "lock is broken" end
    assert Install.build_methods(dir, [], [], boom) == {:unknown, "lock is broken"}

    thrown = fn -> throw(:nope) end
    assert {:unknown, "** (throw) :nope"} = Install.build_methods(dir, [], [], thrown)
  end

  test "a configured install whose deps do not load warns once and checks with every candidate unknown",
       %{config: config} do
    parent = self()

    check = fn _env -> send(parent, :checked) end

    out =
      capture_io(fn ->
        assert Install.run([], [], config,
                 installer: fn _, _ -> :ok end,
                 in_project?: false,
                 check: check,
                 load: fn -> raise "lock is broken" end
               ) == :ok
      end)

    assert_received :checked

    assert out =~
             "precompiled: deps did not load (lock is broken); every dependency compiles from source"
  end

  defp quiet(fun) do
    parent = self()
    capture_io(fn -> send(parent, {:quiet, outside_project(fun)}) end)
    assert_received {:quiet, result}
    result
  end

  # Mix.install/2 runs with no project on the stack; this test suite runs
  # inside one, which would make the install project a child of it.
  defp outside_project(fun) do
    %{name: name, config: config, file: file} = Mix.ProjectStack.pop()

    try do
      fun.()
    after
      :ok = Mix.ProjectStack.push(name, config, file)
    end
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

  test "no usable config (a refused source): plain Mix.install with one warning", %{tmp_dir: dir} do
    parent = self()

    installer = fn deps, opts ->
      send(parent, {:installed, deps, opts})
      :ok
    end

    out =
      capture_io(fn ->
        assert Install.run([:jason], [verbose: true], nil, installer: installer) == :ok
      end)

    assert out =~ "precompiled: source refused"
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
      refute out =~ "source refused"
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
                 check: fn _env -> raise "boom" end
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
                 check: fn _env -> exit({:shutdown, :stop}) end
               )
             ) == {:shutdown, :stop}
    end)
  end
end
