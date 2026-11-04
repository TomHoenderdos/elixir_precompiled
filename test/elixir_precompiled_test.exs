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

  test "allow_host: true runs on the host target; host? still wins", %{env: env} do
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")
    assert Mix.target() == :host
    assert ElixirPrecompiled.run(env: env) == :disabled
    assert ElixirPrecompiled.run(env: env, allow_host: true) == :nothing_to_do
    assert ElixirPrecompiled.run(env: env, allow_host: true, host?: true) == :disabled
    assert ElixirPrecompiled.run(env: env, allow_host: false, host?: false) == :nothing_to_do
  end

  test "without :env, a second run in one VM returns the first result while it holds", %{env: env} do
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")
    key = {ElixirPrecompiled, :ran, Mix.Project.build_path()}
    saved = :persistent_term.get(key, :none)

    on_exit(fn ->
      if saved == :none, do: :persistent_term.erase(key), else: :persistent_term.put(key, saved)
    end)

    # The first call loads this project's own deps: all compiled, nothing to do.
    :persistent_term.erase(key)
    assert ElixirPrecompiled.run(allow_host: true) == :nothing_to_do
    assert {:nothing_to_do, {dirs, []}} = :persistent_term.get(key)
    assert "elixir_precompiled" in dirs

    :persistent_term.put(key, {:first_result, {dirs, []}})
    assert ElixirPrecompiled.run(allow_host: true) == :first_result

    # The build lib no longer looks as the first run left it (mix clean,
    # an installed dep gone): run again.
    :persistent_term.put(key, {:first_result, {["gone" | dirs], []}})
    assert ElixirPrecompiled.run(allow_host: true) == :nothing_to_do
    :persistent_term.put(key, {:first_result, {dirs, [false]}})
    assert ElixirPrecompiled.run(allow_host: true) == :nothing_to_do

    # An explicit :env is never memoised.
    assert ElixirPrecompiled.run(env: env, allow_host: true) == :nothing_to_do
  end

  @tag :tmp_dir
  test "the memo proof changes when an installed dep's ebin or provenance goes", %{
    tmp_dir: lib
  } do
    result = {:ok, %{lines: [%{status: :hit, name: "jason"}, %{status: :miss, name: "x"}]}}
    File.mkdir_p!(Path.join(lib, "jason/ebin"))
    File.mkdir_p!(Path.join(lib, "jason/.mix"))
    File.write!(Path.join(lib, "jason/ebin/jason.app"), "")
    File.write!(ElixirPrecompiled.Fetch.provenance_path(lib, "jason"), "{}")
    proof = ElixirPrecompiled.memo_proof(result, lib)
    assert proof == {["jason"], [true]}

    File.rm_rf!(Path.join(lib, "jason/ebin"))
    refute ElixirPrecompiled.memo_proof(result, lib) == proof

    File.mkdir_p!(Path.join(lib, "jason/ebin"))
    File.write!(Path.join(lib, "jason/ebin/jason.app"), "")
    assert ElixirPrecompiled.memo_proof(result, lib) == proof
    File.rm!(ElixirPrecompiled.Fetch.provenance_path(lib, "jason"))
    refute ElixirPrecompiled.memo_proof(result, lib) == proof
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

  @tag :tmp_dir
  test "turned off, installed builds are removed so Mix compiles them", %{tmp_dir: dir} do
    lib = Path.join(dir, "_build/dev/lib")
    File.mkdir_p!(Path.join(lib, "ash/.mix"))
    File.write!(Path.join(lib, "ash/.mix/elixir_precompiled.json"), "{}")
    ash = {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "AO"}

    env = %Env{
      candidates: [],
      lock: %{ash: ash},
      build_lib: lib,
      deps_path: dir,
      installed: [:ash]
    }

    System.put_env("ELIXIR_PRECOMPILED", "0")
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED") end)

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert ElixirPrecompiled.run(env: env, host?: false) == :disabled
      end)

    assert out =~ "precompiled: disabled; removed 1 installed build, Mix compiles it from source"
    refute File.exists?(Path.join(lib, "ash"))
  end

  @tag :tmp_dir
  test "turned off, only dirs with the provenance file go, and links are never followed", %{
    tmp_dir: dir
  } do
    lib = Path.join(dir, "_build/dev/lib")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(Path.join(outside, ".mix"))
    File.write!(Path.join(outside, ".mix/elixir_precompiled.json"), "{}")
    File.write!(Path.join(outside, "keep"), "x")
    # Mix's own build of a dep: no provenance file.
    File.mkdir_p!(Path.join(lib, "decimal/ebin"))
    # A dep dir that is a link to somewhere else, provenance and all.
    File.ln_s!(outside, Path.join(lib, "linked"))
    # An install holding a link out of _build (priv, as Mix makes them).
    File.mkdir_p!(Path.join(lib, "jason/.mix"))
    File.write!(Path.join(lib, "jason/.mix/elixir_precompiled.json"), "{}")
    File.ln_s!(outside, Path.join(lib, "jason/priv"))

    env = %Env{
      candidates: [],
      lock: %{},
      build_lib: lib,
      deps_path: dir,
      installed: [:decimal, :linked, :jason]
    }

    System.put_env("ELIXIR_PRECOMPILED", "0")
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED") end)

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert ElixirPrecompiled.run(env: env, host?: false) == :disabled
      end)

    assert out =~ "removed 1 installed build"
    assert File.ls!(lib) |> Enum.sort() == ["decimal", "linked"]
    assert File.read!(Path.join(outside, "keep")) == "x"
    assert File.regular?(Path.join(outside, ".mix/elixir_precompiled.json"))
  end

  @tag :tmp_dir
  test "the host target leaves installs alone", %{tmp_dir: dir} do
    lib = Path.join(dir, "_build/dev/lib")
    File.mkdir_p!(Path.join(lib, "ash/.mix"))
    File.write!(Path.join(lib, "ash/.mix/elixir_precompiled.json"), "{}")
    Application.put_env(:elixir_precompiled, :source, "https://example.test/x")

    env = %Env{
      candidates: [],
      lock: %{},
      build_lib: lib,
      deps_path: dir,
      installed: [:ash]
    }

    assert ElixirPrecompiled.run(env: env, host?: true) == :disabled
    assert File.exists?(Path.join(lib, "ash"))
  end
end
