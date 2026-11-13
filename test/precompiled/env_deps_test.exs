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

    code = """
    Code.prepend_path(#{inspect(ebin)})
    client = Precompiled.Env.MixProject.load().present_deps
    mix = Map.new(Mix.Dep.load_and_cache(), &{&1.app, Enum.sort(Enum.map(&1.deps, fn d -> d.app end))})
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
  @parent {:hex, :parent, "0.1.0", "i", [:mix],
           [{:opt, "~> 0.1", [hex: :opt, repo: "hexpm", optional: true]}], "hexpm", "PARENTOUTER"}

  # What Match decides for parent's build made with opt and the one made
  # without it, given the lock a phx_new-style project has in every env.
  defp decide(present_deps) do
    ctx = %{
      name: "parent",
      version: "0.1.0",
      lock_entry: @parent,
      lock: %{parent: @parent, opt: @opt},
      present_deps: present_deps,
      system: {"host", ""},
      elixir: "1.20.3",
      otp: "29",
      dep_env: "prod",
      config: fn _app, _path -> :error end
    }

    for {variant, deps} <- [
          with: %{"opt" => %{"version" => "0.1.0", "checksum" => "OPTOUTER"}},
          without: %{}
        ],
        into: %{} do
      build = %{
        "elixir" => "1.20.3",
        "otp" => "29",
        "dep_env" => "prod",
        "system_version" => nil,
        "run_id" => "r",
        "deps" => deps,
        "compile_env" => [],
        "package_checksum" => "PARENTOUTER"
      }

      manifest = %{
        "versions" => %{
          "0.1.0" => %{
            "builds" => [
              %{"target" => "pure_elixir", "ebin" => [], "priv" => [], "build" => build}
            ]
          }
        }
      }

      {variant, elem(Match.select(manifest, ctx), 0)}
    end
  end

  test "the client's present deps are Mix's children in dev and in test", %{tmp_dir: tmp} do
    File.cp_r!(@fixture, tmp)

    {client, mix} = views(tmp, "dev")
    assert client == mix
    assert client[:parent] == []
    refute Map.has_key?(client, :opt)
    assert decide(client[:parent]) == %{with: :miss, without: :ok}

    {client, mix} = views(tmp, "test")
    assert client == mix
    assert client[:parent] == [:opt]
    assert decide(client[:parent]) == %{with: :ok, without: :miss}

    # The lock alone, in either env, wants the build with opt.
    assert decide(nil) == %{with: :ok, without: :miss}
  end
end
