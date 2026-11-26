# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Env.MixInstallTest do
  use ExUnit.Case, async: true
  alias Precompiled.Env.MixInstall
  @moduletag :tmp_dir

  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}
  @decimal {:hex, :decimal, "3.2.0", "i", [:mix], [], "hexpm", "DOUTER"}
  @git {:git, "https://example.test/x.git", "abc", []}

  test "load reads the install project's lock; git entries are not candidates", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal, gitdep: @git},
      file: Path.join(dir, "mix.lock")
    )

    env = MixInstall.load(dir, [])
    assert Enum.map(env.candidates, & &1.name) == [:decimal, :jason]
    assert env.lock.gitdep == @git
    assert env.build_lib == Path.join([dir, "_build", Atom.to_string(Mix.env()), "lib"])
    assert env.deps_path == Path.join(dir, "deps")
  end

  # 0.10.0: the install's deps that are no Hex deps, for a build's probe
  # items (no exact module list exists for one), and each Hex dep's env.
  test "load names the deps that are no Hex deps, and each dep's env", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))
    present = %{jason: [:decimal], decimal: [], mine: []}

    methods = %{
      jason: %{manager: "mix", overrides: []},
      decimal: %{manager: "mix", overrides: []}
    }

    deps = [{:jason, "1.4.5", env: :dev}, {:mine, path: "rel/mine"}]
    sources = %{jason: @jason, decimal: @decimal, mine: :path}
    env = MixInstall.load(dir, deps, methods, present, nil, nil, sources)

    assert env.non_hex_deps == [:mine]
    assert env.dep_envs == %{jason: "dev"}
    assert MixInstall.load(dir, []).non_hex_deps == nil
  end

  # 0.10.0 on 0.9.1: a dep counts as a Hex dep for a probe item only when
  # Mix loads it from Hex with its lock entry (B1); without the sources no
  # dep can be told.
  test "a dep Mix does not load from Hex as locked is no Hex dep for a probe", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))
    present = %{jason: [:decimal], decimal: []}

    methods = %{
      jason: %{manager: "mix", overrides: []},
      decimal: %{manager: "mix", overrides: []}
    }

    load = &MixInstall.load(dir, [], methods, present, nil, nil, &1)

    assert load.(%{jason: @jason, decimal: @decimal}).non_hex_deps == []

    for decimal <- [:path, :git, :other, put_elem(@decimal, 7, "OTHER")] do
      assert load.(%{jason: @jason, decimal: decimal}).non_hex_deps == [:decimal]
    end

    assert load.(%{jason: @jason}).non_hex_deps == [:decimal]
    assert load.(nil).non_hex_deps == nil
  end

  # S10 re-review R1: a lock entry from a repo other than hexpm is in no
  # module index, so it is no Hex dep for a probe, even loaded as locked.
  test "a dep from a repo other than hexpm is no Hex dep for a probe", %{tmp_dir: dir} do
    acme = put_elem(@decimal, 6, "hexpm:acme")
    Mix.Dep.Lock.write(%{jason: @jason, decimal: acme}, file: Path.join(dir, "mix.lock"))
    present = %{jason: [:decimal], decimal: []}

    methods = %{
      jason: %{manager: "mix", overrides: []},
      decimal: %{manager: "mix", overrides: []}
    }

    env = MixInstall.load(dir, [], methods, present, nil, nil, %{jason: @jason, decimal: acme})
    assert env.non_hex_deps == [:decimal]
  end

  test "load skips a dep the install project has already compiled", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))
    jason = Path.join([dir, "_build", Atom.to_string(Mix.env()), "lib", "jason"])
    File.mkdir_p!(Path.join(jason, "ebin"))
    File.mkdir_p!(Path.join(jason, ".mix"))
    File.write!(Path.join([jason, "ebin", "jason.app"]), "{application, jason, []}.")
    File.write!(Path.join([jason, ".mix", "compile.elixir_scm"]), "scm")

    assert Enum.map(MixInstall.load(dir, []).candidates, & &1.name) == [:decimal]
  end

  test "load names compiled deps carrying a provenance file as installed, with their env", %{
    tmp_dir: dir
  } do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))
    lib = Path.join([dir, "_build", Atom.to_string(Mix.env()), "lib"])

    for app <- ["jason", "decimal"] do
      File.mkdir_p!(Path.join([lib, app, "ebin"]))
      File.mkdir_p!(Path.join([lib, app, ".mix"]))
      File.write!(Path.join([lib, app, "ebin", "#{app}.app"]), "{application, #{app}, []}.")
      File.write!(Path.join([lib, app, ".mix", "compile.elixir_scm"]), "scm")
    end

    # Only jason was placed by this library; decimal is Mix's own build.
    File.write!(Path.join([lib, "jason", ".mix", "precompiled.json"]), "{}")

    env = MixInstall.load(dir, [{:jason, "1.4.5", env: :dev}])
    assert env.candidates == []
    assert env.installed == [:jason]
    assert env.installed_envs == %{jason: "dev"}
  end

  test "a provenance file in a dep Mix has not compiled is no install", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason}, file: Path.join(dir, "mix.lock"))
    jason = Path.join([dir, "_build", Atom.to_string(Mix.env()), "lib", "jason"])
    File.mkdir_p!(Path.join(jason, ".mix"))
    File.write!(Path.join([jason, ".mix", "precompiled.json"]), "{}")

    env = MixInstall.load(dir, [])
    assert Enum.map(env.candidates, & &1.name) == [:jason]
    assert env.installed == []
  end

  test "load without a lock has no candidates", %{tmp_dir: dir} do
    assert MixInstall.load(dir, []).candidates == []
  end

  test "load carries each dep's own compile env from the deps list given to Mix.install/2", %{
    tmp_dir: dir
  } do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))

    env = MixInstall.load(dir, [{:jason, "1.4.5"}, {:decimal, "3.2.0", env: :dev}])
    envs = Map.new(env.candidates, &{&1.name, &1.dep_env})
    assert envs == %{jason: "prod", decimal: "dev"}
  end

  test "a transitive lock entry absent from the deps list gets prod", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))

    env = MixInstall.load(dir, [{:jason, "1.4.5", env: :dev}])
    envs = Map.new(env.candidates, &{&1.name, &1.dep_env})
    assert envs == %{jason: "dev", decimal: "prod"}
  end

  test "load carries the build methods Mix loaded; without them rule 9 knows nothing", %{
    tmp_dir: dir
  } do
    Mix.Dep.Lock.write(%{jason: @jason}, file: Path.join(dir, "mix.lock"))
    loaded = %{jason: %{manager: "make", overrides: [:manager]}}

    assert MixInstall.load(dir, [], loaded).build_methods == loaded
    assert MixInstall.load(dir, [], {:unknown, "boom"}).build_methods == {:unknown, "boom"}
    assert {:unknown, _} = MixInstall.load(dir, []).build_methods
  end

  # 0.9.1: with the sources Mix loaded the install project's deps from, a
  # lock entry is a candidate only for a dep Mix loads from Hex with it.
  test "load takes as candidates only the Hex deps Mix loads there as locked", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))
    load = &MixInstall.load(dir, [], %{}, nil, nil, nil, &1)

    assert Enum.map(load.(%{jason: @jason, decimal: @decimal}).candidates, & &1.name) ==
             [:decimal, :jason]

    # decimal is a path fork whose Hex entry the lock kept; another
    # decimal entry, or none at all, is no candidate either.
    for decimal <- [:path, :git, :other, put_elem(@decimal, 7, "OTHER")] do
      env = load.(%{jason: @jason, decimal: decimal})
      assert Enum.map(env.candidates, & &1.name) == [:jason]
      assert env.dep_sources.decimal == decimal
    end

    assert Enum.map(load.(%{jason: @jason}).candidates, & &1.name) == [:jason]
    # Sources unknown (deps that did not load): the lock's entries, as before.
    assert Enum.map(MixInstall.load(dir, []).candidates, & &1.name) == [:decimal, :jason]
    assert MixInstall.load(dir, []).dep_sources == nil
  end

  test "system falls back to the loaded nerves_system_* application, or nil" do
    loaded = [{:kernel, ~c"ERTS", ~c"10.0"}, {:nerves_system_rpi4, ~c"rpi4", ~c"1.31.0"}]
    assert MixInstall.system([], loaded) == {"nerves_system_rpi4", "1.31.0"}
    assert MixInstall.system([], [{:kernel, ~c"ERTS", ~c"10.0"}]) == nil
  end

  @os_release """
  NAME=Nerves
  ID=nerves
  NERVES_SYSTEM_BR_VERSION=1.35.3
  NERVES_SYSTEM_NAME=nerves_system_rpi4
  NERVES_SYSTEM_VERSION=2.2.1
  NERVES_BUILDROOT_VERSION=2025.08
  """

  @quoted_os_release """
  NAME="Nerves"
  ID="nerves"
  NERVES_SYSTEM_BR_VERSION="1.35.3"
  NERVES_SYSTEM_NAME="nerves_system_rpi4"
  NERVES_SYSTEM_VERSION="2.2.1"
  NERVES_BUILDROOT_VERSION="2025.08"
  """

  test "system reads the Nerves system name and version from os-release", %{tmp_dir: dir} do
    path = Path.join(dir, "os-release")
    File.write!(path, @os_release)

    assert MixInstall.system([path], []) == {"nerves_system_rpi4", "2.2.1"}
  end

  test "system reads os-release with quoted values", %{tmp_dir: dir} do
    path = Path.join(dir, "os-release")
    File.write!(path, @quoted_os_release)

    assert MixInstall.system([path], []) == {"nerves_system_rpi4", "2.2.1"}
  end

  test "system falls back to the loaded list when os-release lacks the version", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "os-release")
    File.write!(path, "NAME=Nerves\nNERVES_SYSTEM_NAME=nerves_system_rpi4\n")
    loaded = [{:nerves_system_rpi4, ~c"rpi4", ~c"1.31.0"}]

    assert MixInstall.system([path], loaded) == {"nerves_system_rpi4", "1.31.0"}
  end

  test "system falls back to the loaded list when os-release names a non-Nerves system", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "os-release")

    File.write!(
      path,
      "NAME=Ubuntu\nNERVES_SYSTEM_NAME=not_a_nerves_system\nNERVES_SYSTEM_VERSION=1.0.0\n"
    )

    loaded = [{:nerves_system_rpi4, ~c"rpi4", ~c"1.31.0"}]

    assert MixInstall.system([path], loaded) == {"nerves_system_rpi4", "1.31.0"}
  end

  test "system is nil without an os-release file and without a loaded system app", %{
    tmp_dir: dir
  } do
    missing = Path.join(dir, "missing-os-release")
    loaded = [{:kernel, ~c"ERTS", ~c"10.0"}]

    assert MixInstall.system([missing], loaded) == nil
  end

  test "on a device the target is the system's conventional name" do
    assert MixInstall.mix_target({"nerves_system_rpi4", "1.31.0"}) == "rpi4"
    assert MixInstall.mix_target(nil) == "host"
  end
end
