# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Integration.GitDepTest do
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

  # A package in a local bare git repo (file://), as a git dependency names
  # it: nothing of it ever reaches Hex.
  defp bare_repo!(dir) do
    src = Path.join(dir, "gitdep_src")
    File.mkdir_p!(Path.join(src, "lib"))

    File.write!(Path.join(src, "mix.exs"), """
    defmodule Gitdep.MixProject do
      use Mix.Project
      def project, do: [app: :gitdep, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(src, "lib/gitdep.ex"), "defmodule Gitdep do\n  def hi, do: :hi\nend\n")

    git = ["git", "-c", "user.email=test@example.invalid", "-c", "user.name=test"]
    run = &C.cmd!(git ++ &1, dir, cd: src, env: [], offline: false)
    run.(["init", "-q", "-b", "main"])
    run.(["add", "."])
    run.(["commit", "-q", "-m", "gitdep"])

    bare = Path.join(dir, "gitdep.git")
    C.cmd!(["git", "clone", "-q", "--bare", src, bare], dir, env: [], offline: false)
    "file://" <> bare
  end

  test "a git dependency is never installed precompiled, even when the source offers it", %{
    tmp_dir: dir
  } do
    f = F.new(dir)
    url = bare_repo!(dir)

    proj =
      C.plain!(dir, f,
        deps: ~s([{:jason, "1.4.5"}, {:gitdep, git: #{inspect(url)}}, #{C.own_dep()}])
      )

    F.publish(f, %{}, sequence: 1)
    C.mix!(proj, ["deps.get"])
    assert {:git, _, _, _} = Mix.Dep.Lock.read(Path.join(proj, "mix.lock"))[:gitdep]
    C.mix!(proj, ["deps.compile"], [{"ELIXIR_PRECOMPILED", "0"}])

    # Real beams of both, published as the portal's builds; the git dep's
    # manifest carries a well-formed checksum like any other.
    lib = &Path.join(proj, "_build/dev/lib/#{&1}")
    jason = C.jason_entry(f, lib.("jason"), proj)
    gitdep = C.build_entry(f, lib.("gitdep"), String.duplicate("ab", 32))
    File.rm_rf!(lib.("jason"))
    File.rm_rf!(lib.("gitdep"))

    F.publish(
      f,
      %{
        "jason" => %{"versions" => %{"1.4.5" => %{"builds" => [jason]}}},
        "gitdep" => %{"versions" => %{"0.1.0" => %{"builds" => [gitdep]}}}
      },
      sequence: 2
    )

    out = C.mix!(proj, ["compile"])
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    # jason is the one candidate: the git dep is not even asked about.
    assert out =~ "1 hit, 0 miss, 0 fail of 1 deps", out
    refute out =~ ~r/gitdep 0\.1\.0\s+HIT/, out
    assert out =~ "==> gitdep", out
    refute File.exists?(Path.join(lib.("gitdep"), ".mix/elixir_precompiled.json")), out
    refute Enum.any?(F.requests(), &(&1.path =~ "gitdep")), inspect(F.requests())
  end
end
