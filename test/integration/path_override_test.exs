# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.PathOverrideTest do
  # The client review's B1, with real Mix: a developer changes a dependency
  # in a package's closure to a local fork (`path:` with `override: true`).
  # `mix deps.get` keeps the fork's old Hex entry in mix.lock, so the lock
  # alone still says Hex. Mix compiles the package against the fork; a build
  # the portal made against the Hex release is not that compile and must
  # miss, both when it is already installed and as a fresh candidate.
  # makeup's closure is nimble_parsec alone; both are in this checkout's
  # lock (ex_doc's), so the child resolves offline from the Hex cache.
  use ExUnit.Case, async: false
  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  @packages ["makeup-1.2.3", "nimble_parsec-1.4.2"]

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  # makeup's real beams, compiled here against Hex nimble_parsec, as the
  # portal's pure_elixir build with that closure.
  defp makeup_entry(f, lib, lock) do
    {:hex, :makeup, "1.2.3", _, _, _, _, outer} = lock.makeup
    {:hex, :nimble_parsec, vsn, _, _, _, _, np_outer} = lock.nimble_parsec

    f
    |> C.build_entry(lib, outer)
    |> put_in(["build", "deps"], %{"nimble_parsec" => %{"version" => vsn, "checksum" => np_outer}})
  end

  # The fork: nimble_parsec's own sources at the same version, plus a module
  # of its own, so it is not the Hex release.
  defp fork!(dir, from) do
    fork = Path.join(dir, "nimble_parsec_fork")
    File.cp_r!(from, fork)
    File.write!(Path.join(fork, "lib/fork.ex"), "defmodule NimbleParsec.Fork do\nend\n")
    fork
  end

  @miss ~r/precompiled: makeup 1\.2\.3\s+MISS\s+built against nimble_parsec 1\.4\.2 from Hex/

  test "a closure dep overridden by a path, its Hex lock entry kept, makes the build miss", %{
    tmp_dir: dir
  } do
    f = F.new(dir)
    proj = C.plain!(dir, f, deps: ~s([{:makeup, "1.2.3"}, #{C.own_dep()}]))
    mix = fn args, env -> C.mix!(proj, args, env, packages: @packages) end
    lib = &Path.join(proj, "_build/dev/lib/#{&1}")

    F.publish(f, %{}, sequence: 1)
    mix.(["deps.get"], [])
    mix.(["deps.compile"], [{"PRECOMPILED", "0"}])
    lock = Mix.Dep.Lock.read(Path.join(proj, "mix.lock"))
    entry = makeup_entry(f, lib.("makeup"), lock)
    File.rm_rf!(lib.("makeup"))

    F.publish(f, %{"makeup" => %{"versions" => %{"1.2.3" => %{"builds" => [entry]}}}},
      sequence: 2
    )

    # Against Hex nimble_parsec it is the build Mix would make.
    out = mix.(["compile"], [])
    assert out =~ ~r/precompiled: makeup 1\.2\.3\s+HIT/, out
    assert File.exists?(Path.join(lib.("makeup"), ".mix/precompiled.json"))

    fork = fork!(dir, Path.join(proj, "deps/nimble_parsec"))

    C.plain!(dir, f,
      deps:
        ~s([{:makeup, "1.2.3"}, {:nimble_parsec, path: #{inspect(fork)}, override: true}, ) <>
          C.own_dep() <> "]"
    )

    mix.(["deps.get"], [])
    # The stale entry: by the lock alone, nimble_parsec is still Hex 1.4.2.
    assert Mix.Dep.Lock.read(Path.join(proj, "mix.lock")).nimble_parsec == lock.nimble_parsec

    # The installed build is matched again and goes: Mix compiles makeup
    # against the fork in the same run.
    out = mix.(["compile"], [])
    assert out =~ @miss, out
    assert out =~ "==> makeup", out
    refute File.exists?(Path.join(lib.("makeup"), ".mix/precompiled.json")), out

    # A fresh candidate misses the same way.
    File.rm_rf!(lib.("makeup"))
    out = mix.(["compile"], [])
    assert out =~ @miss, out
    assert out =~ "==> makeup", out
    refute File.exists?(Path.join(lib.("makeup"), ".mix/precompiled.json")), out
  end

  # Mix.install/2's own resolution: the lockfile: option merges a lock with
  # Hex nimble_parsec into an install whose nimble_parsec is a path fork.
  @script """
  [source, root, fork, lockfile] = System.argv()
  Application.put_env(:precompiled, :source, source)
  Application.put_env(:precompiled, :root, root)

  {deps, opts} =
    if fork == "-",
      do: {[{:makeup, "1.2.3"}], []},
      else: {[{:makeup, "1.2.3"}, {:nimble_parsec, path: fork, override: true}], [lockfile: lockfile]}

  Precompiled.Host.install(deps, opts)
  IO.puts("fork_loaded=" <> to_string(Code.ensure_loaded?(NimbleParsec.Fork)))
  IO.puts("mix_dir=" <> Mix.install_project_dir())
  """

  test "under Mix.install/2, a lockfile: merge's stale Hex entry for a path dep misses", %{
    tmp_dir: dir
  } do
    f = F.new(dir)
    script = Path.join(dir, "install.exs")
    File.write!(script, @script)

    F.publish(f, %{}, sequence: 1)
    out = child!(dir, f, ["-", "-"], [{"PRECOMPILED", "0"}])
    hex_dir = line!(out, "mix_dir")
    lockfile = Path.join(hex_dir, "mix.lock")
    lock = Mix.Dep.Lock.read(lockfile)
    entry = makeup_entry(f, Path.join(hex_dir, "_build/dev/lib/makeup"), lock)

    F.publish(f, %{"makeup" => %{"versions" => %{"1.2.3" => %{"builds" => [entry]}}}},
      sequence: 2
    )

    fork = fork!(dir, Path.join(hex_dir, "deps/nimble_parsec"))
    out = child!(dir, f, [fork, lockfile])
    fork_dir = line!(out, "mix_dir")
    assert fork_dir != hex_dir
    assert line!(out, "fork_loaded") == "true", out
    # The merged lock still says Hex nimble_parsec 1.4.2.
    assert Mix.Dep.Lock.read(Path.join(fork_dir, "mix.lock")).nimble_parsec ==
             lock.nimble_parsec

    assert out =~ @miss, out
    # The fork itself is no candidate: Mix.install/2 loads it from its path.
    refute out =~ ~r/precompiled: nimble_parsec/, out
    # Mix.install/2 compiled makeup itself, against the fork.
    makeup = Path.join(fork_dir, "_build/dev/lib/makeup/.mix")
    assert File.exists?(Path.join(makeup, "compile.elixir")), out
    refute File.exists?(Path.join(makeup, "precompiled.json")), out
  end

  defp child!(dir, f, args, env \\ []) do
    argv =
      ["elixir", "-pa", C.own_ebin(), Path.join(dir, "install.exs"), F.base_url(), f.root_path] ++
        args

    env =
      [
        {"MIX_INSTALL_DIR", Path.join(dir, "installs")},
        {"PRECOMPILED_HOME", Path.join(dir, "home")},
        {"MIX_ENV", nil},
        {"MIX_TARGET", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_BUILD_ROOT", nil},
        {"MIX_DEPS_PATH", nil}
      ] ++ env

    C.cmd!(argv, dir, env: env, packages: @packages)
  end

  defp line!(out, key) do
    case Regex.run(~r/^#{key}=(.+)$/m, out, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("no #{key}= line in the child's output:\n" <> out)
    end
  end
end
