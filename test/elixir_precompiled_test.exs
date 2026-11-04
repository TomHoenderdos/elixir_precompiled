# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiledTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.Env

  setup do
    for {k, _} <- Application.get_all_env(:elixir_precompiled),
        do: Application.delete_env(:elixir_precompiled, k)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:elixir_precompiled),
          do: Application.delete_env(:elixir_precompiled, k)
    end)

    %{env: %Env{candidates: [], lock: %{}, build_lib: "/nonexistent", deps_path: "/nonexistent"}}
  end

  test "disabled without a source", %{env: env} do
    assert ElixirPrecompiled.run(env: env, host?: false) == :disabled
  end

  test "disabled on the host target even with a source", %{env: env} do
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")
    assert ElixirPrecompiled.run(env: env, host?: true) == :disabled
  end

  test "with a source and a target, an empty env is nothing to do", %{env: env} do
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")
    assert ElixirPrecompiled.run(env: env, host?: false) == :nothing_to_do
  end

  test "an internal error is one warning and :disabled, never a raise" do
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert ElixirPrecompiled.run(env: :not_an_env, host?: false) == :disabled
      end)

    assert out =~ "precompiled: internal error, compiling from source"
  end

  @tag :tmp_dir
  test "no HOME: run/1 falls back to a cache under _build", %{tmp_dir: dir} do
    saved = for v <- ~w(HOME XDG_CACHE_HOME ELIXIR_PRECOMPILED_HOME), do: {v, System.get_env(v)}

    on_exit(fn ->
      for {v, val} <- saved, do: if(val, do: System.put_env(v, val), else: System.delete_env(v))
    end)

    for {v, _} <- saved, do: System.delete_env(v)

    Application.put_env(:elixir_precompiled, :source, "http://127.0.0.1:1/x")
    assert ElixirPrecompiled.Config.load().home == nil

    lib = Path.join(dir, "_build/dev/lib")
    jason = {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

    env = %Env{
      candidates: [%{name: :jason, version: "1.4.5", lock_entry: jason, dep_env: "prod"}],
      lock: %{jason: jason},
      build_lib: lib,
      deps_path: Path.join(dir, "deps")
    }

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, %{fails: 1}} = ElixirPrecompiled.run(env: env, host?: false)
        end)
      end)

    assert out =~ "is not writable; using #{Path.join(lib, ".precompiled/home")}"
  end

  test "a shutdown exit is passed on, any other exit is one warning" do
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")

    exiting = fn reason ->
      %Env{
        candidates: Stream.map([:x], fn _ -> exit(reason) end),
        lock: %{},
        build_lib: "/nonexistent",
        deps_path: "/nonexistent"
      }
    end

    for reason <- [:normal, :shutdown, {:shutdown, :stop}] do
      assert catch_exit(ElixirPrecompiled.run(env: exiting.(reason), host?: false)) == reason
    end

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert ElixirPrecompiled.run(env: exiting.(:boom), host?: false) == :disabled
      end)

    assert out =~ "precompiled: internal error, compiling from source"
  end
end
