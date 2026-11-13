# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.EnvDepsTest do
  # Against Mix's real dep loading: which optional deps of a dependency are
  # present in the current env. The fixture's parent declares opt optional,
  # and the project pulls opt in only for :test, so the lock (were it Hex)
  # would have opt in every env while Mix gives it to parent only in test.
  use ExUnit.Case, async: true

  alias Precompiled.Match

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @fixture Path.expand("../fixtures/env_deps", __DIR__)

  # The client's view and Mix's own, each read in the fixture's Mix VM, as
  # in a user's project. Mix prunes the code path to the project's deps
  # when it loads them, dropping a -pa entry, so the code adds it itself.
  defp views(tmp, mix_env) do
    ebin = Path.dirname(:code.which(Precompiled.Env.MixProject))

    # Mix's side walks each loaded dep's children itself, independently of
    # the client's Env.closure/2.
    code = """
    Code.prepend_path(#{inspect(ebin)})
    tree = Precompiled.Env.MixProject.load().present_deps
    client = Map.new([:parent, :top], &{&1, Precompiled.Env.closure(tree, &1)})
    by_app = Map.new(Mix.Dep.load_and_cache(), &{&1.app, &1})
    walk = fn walk, apps, seen ->
      Enum.reduce(apps, seen, fn app, seen ->
        if app in seen, do: seen, else: walk.(walk, Enum.map(by_app[app].deps, & &1.app), [app | seen])
      end)
    end
    mix = Map.new([:parent, :top], fn app ->
      {app, Enum.sort(walk.(walk, Enum.map(by_app[app].deps, & &1.app), []))}
    end)
    IO.puts("VIEWS " <> Base.encode64(:erlang.term_to_binary({client, mix})))
    """

    {out, status} =
      System.cmd(
        "elixir",
        ["-S", "mix", "run", "--no-compile", "--no-deps-check", "--no-start", "-e", code],
        cd: tmp,
        env: [{"MIX_ENV", mix_env}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    [encoded] = for "VIEWS " <> e <- String.split(out, "\n"), do: e
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  @opt {:hex, :opt, "0.1.0", "i", [:mix], [], "hexpm", "OPTOUTER"}
  @link {:hex, :link, "0.1.0", "i", [:mix],
         [{:opt, "~> 0.1", [hex: :opt, repo: "hexpm", optional: true]}], "hexpm", "LINKOUTER"}
  @parent {:hex, :parent, "0.1.0", "i", [:mix],
           [{:opt, "~> 0.1", [hex: :opt, repo: "hexpm", optional: true]}], "hexpm", "PARENTOUTER"}
  @top {:hex, :top, "0.1.0", "i", [:mix],
        [{:link, "~> 0.1", [hex: :link, repo: "hexpm", optional: false]}], "hexpm", "TOPOUTER"}
  @lock %{parent: @parent, top: @top, link: @link, opt: @opt}

  defp locked(app) do
    {:hex, _, v, _, _, _, _, c} = @lock[app]
    {Atom.to_string(app), %{"version" => v, "checksum" => c}}
  end

  # What Match decides for a package's build made with opt and the one
  # made without it, given the lock a phx_new-style project has in every
  # env (opt locked) and the package's closure in this env (nil: unknown).
  defp decide(app, env_closure) do
    {:hex, _, version, _, _, _, _, outer} = @lock[app]
    base = if app == :top, do: [:link], else: []

    ctx = %{
      name: Atom.to_string(app),
      version: version,
      lock_entry: @lock[app],
      lock: @lock,
      env_closure: env_closure,
      system: {"host", ""},
      elixir: "1.20.3",
      otp: "29",
      dep_env: "prod",
      config: fn _app, _path -> :error end
    }

    for {variant, deps} <- [with: [:opt | base], without: base], into: %{} do
      build = %{
        "elixir" => "1.20.3",
        "otp" => "29",
        "dep_env" => "prod",
        "system_version" => nil,
        "run_id" => "r",
        "deps" => Map.new(deps, &locked/1),
        "compile_env" => [],
        "package_checksum" => outer
      }

      manifest = %{
        "versions" => %{
          version => %{
            "builds" => [
              %{"target" => "pure_elixir", "ebin" => [], "priv" => [], "build" => build}
            ]
          }
        }
      }

      {variant, elem(Match.select(manifest, ctx), 0)}
    end
  end

  test "the client's env closures are Mix's in dev and in test", %{tmp_dir: tmp} do
    File.cp_r!(@fixture, tmp)

    {client, mix} = views(tmp, "dev")
    assert client == mix
    assert client == %{parent: [], top: [:link]}
    assert decide(:parent, client.parent) == %{with: :miss, without: :ok}
    # Two levels down: link's optional opt.
    assert decide(:top, client.top) == %{with: :miss, without: :ok}

    {client, mix} = views(tmp, "test")
    assert client == mix
    assert client == %{parent: [:opt], top: [:link, :opt]}
    assert decide(:parent, client.parent) == %{with: :ok, without: :miss}
    assert decide(:top, client.top) == %{with: :ok, without: :miss}

    # The lock alone, in either env: the direct optional dep wants the
    # build with opt; the one two levels down it cannot see.
    assert decide(:parent, nil) == %{with: :ok, without: :miss}
    assert decide(:top, nil) == %{with: :ok, without: :ok}
  end
end
