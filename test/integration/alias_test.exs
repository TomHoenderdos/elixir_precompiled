# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Integration.AliasTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.ChildProject, as: C
  alias ElixirPrecompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  test "plain project: the alias installs jason before Mix would compile it", %{tmp_dir: dir} do
    f = F.new(dir)
    proj = C.plain!(dir, f)
    C.publish_jason!(f, proj)

    out = C.mix!(proj, ["compile"])
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    refute out =~ "==> jason", out

    out = C.mix!(proj, ["run", "-e", ~s|IO.puts("encoded=" <> Jason.encode!(%{a: 1}))|])
    assert out =~ ~s(encoded={"a":1}), out

    # mix test runs in MIX_ENV=test: its own _build, the same alias.
    File.mkdir_p!(Path.join(proj, "test"))
    File.write!(Path.join(proj, "test/test_helper.exs"), "ExUnit.start()\n")
    out = C.mix!(proj, ["test"], [{"MIX_ENV", "test"}])
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
  end

  test "umbrella: the root alias serves every app", %{tmp_dir: dir} do
    f = F.new(dir)
    root = C.umbrella!(dir, f)
    C.publish_jason!(f, root)

    out = C.mix!(root, ["compile"])
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    refute out =~ "==> jason", out
  end

  # nerves_bootstrap prepends its own tasks to this alias; ours must still
  # run before Mix compiles the deps.
  test "a task prepended to the alias, as nerves_bootstrap does, runs first", %{tmp_dir: dir} do
    f = F.new(dir)

    prelude = """
    defmodule Mix.Tasks.Fake.Bootstrap do
      use Mix.Task
      def run(_), do: IO.puts("fake.bootstrap ran")
    end
    """

    proj =
      C.plain!(dir, f,
        prelude: prelude,
        aliases:
          ~s(["deps.loadpaths": ["fake.bootstrap", "deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"]])
      )

    C.publish_jason!(f, proj)
    out = C.mix!(proj, ["compile"])
    {boot, _} = :binary.match(out, "fake.bootstrap ran")
    {hit, _} = :binary.match(out, "precompiled: jason")
    assert boot < hit
    assert out =~ ~r/jason 1\.4\.5\s+HIT/, out
  end

  # Why the alias has three entries: without "deps.compile elixir_precompiled"
  # the task is not on the code path yet, and Mix's fallback for an unknown
  # task runs deps.loadpaths first, compiling every dep from source.
  test "the one-entry alias is too late: Mix compiles jason before the task exists", %{
    tmp_dir: dir
  } do
    f = F.new(dir)

    proj =
      C.plain!(dir, f, aliases: ~s(["deps.loadpaths": ["precompiled.install", "deps.loadpaths"]]))

    C.publish_jason!(f, proj)

    out = C.mix!(proj, ["compile"])
    assert out =~ "==> jason", out
    refute out =~ ~r/jason 1\.4\.5\s+HIT/, out
  end
end
