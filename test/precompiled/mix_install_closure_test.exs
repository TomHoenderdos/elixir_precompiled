# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.MixInstallClosureTest do
  # Against a real Mix.install/2 in a fresh VM: the dependency tree the
  # client reads for the install project before Mix.install/2 runs is the
  # one Mix.install/2 itself loads and compiles. The fixture's mi_pkg and
  # mi_link (under mi_top) list mi_here and mi_gone as optional; the install
  # brings mi_here in, and mi_gone only for :test, so in dev Mix gives
  # neither parent mi_gone.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @fixture Path.expand("../fixtures/mix_install", __DIR__)

  defp deps(),
    do: [
      {:mi_pkg, path: Path.join(@fixture, "mi_pkg")},
      {:mi_top, path: Path.join(@fixture, "mi_top")},
      {:mi_here, path: Path.join(@fixture, "mi_here")},
      {:mi_gone, path: Path.join(@fixture, "mi_gone"), only: :test}
    ]

  # The client's side is what Install.run/4 hands Check: resolve/4 in the
  # install project, then Env.MixInstall.load/4. Mix's side walks the deps
  # Mix.install/2 loaded in its own install project, independently of
  # Env.closure/2.
  defp views(tmp) do
    ebin = Path.dirname(:code.which(Precompiled.Install))

    script = """
    Mix.start()
    deps = #{inspect(deps())}
    dir = Precompiled.Install.project_dir(deps, [])
    {methods, present} = Precompiled.Install.resolve(dir, deps, [])
    env = Precompiled.Env.MixInstall.load(dir, deps, methods, present)
    apps = [:mi_pkg, :mi_top, :mi_link, :mi_here]
    client = Map.new(apps, &{&1, Precompiled.Env.closure(env.present_deps, &1)})

    Mix.install(deps)
    ^dir = Mix.install_project_dir()

    by_app = Mix.in_install_project(fn -> Map.new(Mix.Dep.cached(), &{&1.app, &1}) end)
    walk = fn walk, apps, seen ->
      Enum.reduce(apps, seen, fn app, seen ->
        if app in seen, do: seen, else: walk.(walk, Enum.map(by_app[app].deps, & &1.app), [app | seen])
      end)
    end
    mix = Map.new(apps, fn app ->
      {app, Enum.sort(walk.(walk, Enum.map(by_app[app].deps, & &1.app), []))}
    end)
    compiled = dir |> Path.join("_build/dev/lib") |> File.ls!() |> Enum.sort()
    IO.puts("VIEWS " <> Base.encode64(:erlang.term_to_binary({client, mix, Map.keys(by_app), compiled})))
    """

    path = Path.join(tmp, "install.exs")
    File.write!(path, script)

    {out, status} =
      System.cmd("elixir", ["-pa", ebin, path],
        cd: tmp,
        env: [{"MIX_INSTALL_DIR", Path.join(tmp, "installs")}, {"MIX_ENV", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    [encoded] = for "VIEWS " <> e <- String.split(out, "\n"), do: e
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  test "the closure read before Mix.install/2 is the one it compiles", %{tmp_dir: tmp} do
    {client, mix, loaded, compiled} = views(tmp)

    assert client == mix

    # The optional dep the install brings in is in both parents' closures,
    # at any depth; the one it has only for :test is in neither.
    assert client.mi_pkg == [:mi_here]
    assert client.mi_top == [:mi_here, :mi_link]
    assert client.mi_link == [:mi_here]
    assert client.mi_here == []

    # And Mix.install/2 loaded and compiled exactly that: no mi_gone.
    assert Enum.sort(loaded) == [:mi_here, :mi_link, :mi_pkg, :mi_top]
    refute "mi_gone" in compiled
    assert "mi_here" in compiled
  end
end
