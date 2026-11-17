# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.DeterministicMatchTest do
  # Builds compiled with ERL_COMPILER_OPTIONS=deterministic: listed under a
  # version's `deterministic` object, taken only by a project whose own
  # ERL_COMPILER_OPTIONS is exactly `[deterministic]`, which takes nothing else.
  use ExUnit.Case, async: true
  alias Precompiled.{Manifest, Match}

  @moduletag :tmp_dir

  @ash {:hex, :ash, "3.5.2", "inner", [:mix], [], "hexpm", "ASHOUTER"}

  @build %{
    "elixir" => "1.20.3",
    "otp" => "29",
    "dep_env" => "prod",
    "system_version" => nil,
    "deps" => %{},
    "compile_env" => [],
    "package_checksum" => "ASHOUTER",
    "run_id" => "r1"
  }

  @sibling Map.put(@build, "erl_compiler_options", ["deterministic"])

  defp pe(build, sha),
    do: %{
      "target" => "pure_elixir",
      "ebin" => [%{"path" => "ebin/ash.beam", "sha256" => sha}],
      "priv" => [],
      "build" => build
    }

  defp doc(version),
    do: %{"format" => 2, "versions" => %{"3.5.2" => version}}

  defp both(),
    do:
      doc(%{
        "builds" => [pe(@build, "plain")],
        "deterministic" => %{"builds" => [pe(@sibling, "det")]}
      })

  defp ctx(dir, value, over \\ []) do
    env = %{"HOME" => dir, "ERL_COMPILER_OPTIONS" => value}

    Map.merge(
      %{
        name: "ash",
        version: "3.5.2",
        lock_entry: @ash,
        lock: %{ash: @ash},
        system: {"host", ""},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end,
        prefer: nil,
        manager: "mix",
        machine_env: &Map.get(env, &1),
        # A VM whose Elixir has not read the variable yet: the env decides.
        elixir_compiler_options: fn -> :undefined end
      },
      Map.new(over)
    )
  end

  defp sha({:ok, %{"ebin" => [%{"sha256" => sha}]}, _target}), do: sha

  # Elixir 1.18+ reads ERL_COMPILER_OPTIONS once per VM, on its first
  # compile (mix.exs itself), and compiles every later module with what it
  # read. A project that sets the variable later (in `project/0` or
  # config/config.exs) compiles its Elixir deps without it, while rebar3
  # and compile.erlang see it: no build is that compile.
  test "a variable set or cleared after Elixir read it misses, sibling or plain",
       %{tmp_dir: dir} do
    for {value, cached} <- [{"deterministic", []}, {nil, [:deterministic]}] do
      ctx = ctx(dir, value, elixir_compiler_options: fn -> cached end)

      assert {:miss, %{code: :erl_compiler_options, args: ["ERL_COMPILER_OPTIONS"], text: text}} =
               Match.select_reason(both(), ctx),
             inspect(value)

      assert text =~ "after this VM's first Elixir compile"
    end

    assert both()
           |> Match.select(
             ctx(dir, "deterministic", elixir_compiler_options: fn -> [:deterministic] end)
           )
           |> sha() == "det"

    assert both() |> Match.select(ctx(dir, nil, elixir_compiler_options: fn -> [] end)) |> sha() ==
             "plain"
  end

  test "a deterministic project takes the sibling, in either spelling", %{tmp_dir: dir} do
    for value <- ["deterministic", "[deterministic]"] do
      assert both() |> Match.select(ctx(dir, value)) |> sha() == "det"
    end
  end

  test "a project without the option takes the plain build and never a sibling",
       %{tmp_dir: dir} do
    assert both() |> Match.select(ctx(dir, nil)) |> sha() == "plain"

    misplaced = doc(%{"builds" => [pe(@sibling, "det")]})

    assert {:miss, %{code: :erl_compiler_options, text: text}} =
             Match.select_reason(misplaced, ctx(dir, nil))

    assert text == "built with ERL_COMPILER_OPTIONS=deterministic, this project is not"
  end

  test "a deterministic project never takes a build made without the option", %{tmp_dir: dir} do
    plain_listed = doc(%{"builds" => [], "deterministic" => %{"builds" => [pe(@build, "plain")]}})

    assert {:miss, %{code: :erl_compiler_options, text: text}} =
             Match.select_reason(plain_listed, ctx(dir, "deterministic"))

    assert text == "ERL_COMPILER_OPTIONS is deterministic, this build was made without it"
  end

  test "no sibling of a built version is its own reason; an unbuilt version stays one",
       %{tmp_dir: dir} do
    built = doc(%{"builds" => [pe(@build, "plain")]})

    assert {:miss, %{code: :deterministic_not_built, args: ["3.5.2"], text: text}} =
             Match.select_reason(built, ctx(dir, "deterministic"))

    assert text == "no ERL_COMPILER_OPTIONS=deterministic build of 3.5.2 yet"

    assert {:miss, %{code: :not_built_version}} =
             Match.select_reason(doc(%{"builds" => []}), ctx(dir, "deterministic"))
  end

  test "any other value misses as before, siblings or not", %{tmp_dir: dir} do
    for value <- ["[deterministic,debug_info]", "deterministic.", "[no_line_info]"] do
      assert {:miss, %{code: :erl_compiler_options, args: ["ERL_COMPILER_OPTIONS"]}} =
               Match.select_reason(both(), ctx(dir, value)),
             value
    end
  end

  test "a sibling under builds_closure is read only with the env's closure", %{tmp_dir: dir} do
    closure =
      doc(%{
        "builds" => [],
        "deterministic" => %{"builds" => [], "builds_closure" => [pe(@sibling, "det")]}
      })

    assert {:miss, %{code: :deterministic_not_built}} =
             Match.select_reason(
               put_in(closure, ["versions", "3.5.2", "builds"], [pe(@build, "p")]),
               ctx(dir, "deterministic")
             )

    assert closure |> Match.select(ctx(dir, "deterministic", env_closure: [])) |> sha() == "det"
  end

  describe "manifest normalization" do
    test "keeps a well-formed deterministic object and drops a malformed one" do
      assert {:ok, %{"versions" => %{"3.5.2" => %{"deterministic" => %{"builds" => [_]}}}}} =
               Manifest.normalize(both())

      for bad <- [[], "x", %{}, %{"builds" => "x"}, %{"builds" => [], "builds_with_inputs" => 1}] do
        assert {:ok, %{"versions" => %{"3.5.2" => version}}} =
                 Manifest.normalize(doc(%{"builds" => [], "deterministic" => bad}))

        refute Map.has_key?(version, "deterministic"), inspect(bad)
      end

      assert {:ok, %{"versions" => %{"3.5.2" => %{"deterministic" => lists}}}} =
               Manifest.normalize(
                 doc(%{
                   "builds" => [],
                   "deterministic" => %{"builds" => [], "builds_closure" => 1}
                 })
               )

      assert lists == %{"builds" => []}
    end
  end
end
