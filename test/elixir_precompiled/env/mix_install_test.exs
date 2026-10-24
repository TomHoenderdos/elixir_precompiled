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

    env = MixInstall.load(dir)
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

    assert Enum.map(MixInstall.load(dir).candidates, & &1.name) == [:decimal]
  end

  test "load without a lock has no candidates", %{tmp_dir: dir} do
    assert MixInstall.load(dir).candidates == []
  end

  test "system is the loaded nerves_system_* application, or nil" do
    loaded = [{:kernel, ~c"ERTS", ~c"10.0"}, {:nerves_system_rpi4, ~c"rpi4", ~c"1.31.0"}]
    assert MixInstall.system(loaded) == {"nerves_system_rpi4", "1.31.0"}
    assert MixInstall.system([{:kernel, ~c"ERTS", ~c"10.0"}]) == nil
  end
end
