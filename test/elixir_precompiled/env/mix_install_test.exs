# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Env.MixInstallTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.Env.MixInstall
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

  test "load skips a dep the install project has already compiled", %{tmp_dir: dir} do
    Mix.Dep.Lock.write(%{jason: @jason, decimal: @decimal}, file: Path.join(dir, "mix.lock"))
    jason = Path.join([dir, "_build", Atom.to_string(Mix.env()), "lib", "jason"])
    File.mkdir_p!(Path.join(jason, "ebin"))
    File.mkdir_p!(Path.join(jason, ".mix"))
    File.write!(Path.join([jason, "ebin", "jason.app"]), "{application, jason, []}.")
    File.write!(Path.join([jason, ".mix", "compile.elixir_scm"]), "scm")

    assert Enum.map(MixInstall.load(dir, []).candidates, & &1.name) == [:decimal]
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
end
