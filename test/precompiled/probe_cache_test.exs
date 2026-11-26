# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ProbeCacheTest do
  # S10 re-review R2: the cross-run key is a hash of everything a dep's
  # match reads, so a change to any of it is another key and no stale list
  # is read: a dep's declaration (`system_env:`, `compile:`, `manager:`,
  # which rule 9 reads), the config of an app outside the lock, and the
  # global rebar3 config.
  use ExUnit.Case, async: false
  alias Precompiled.{Env, ProbeCache}

  @moduletag :tmp_dir

  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

  defp env(over \\ []) do
    struct!(
      %Env{
        candidates: [],
        build_lib: "/p/_build/dev/lib",
        deps_path: "/p/deps",
        lock: %{jason: @jason},
        present_deps: %{jason: []},
        build_methods: %{jason: %{manager: "mix", overrides: []}}
      },
      over
    )
  end

  defp key(env), do: ProbeCache.key(env, %{toolchain: {"1.20.3", "29"}}, %{sequence: 1})

  test "the same inputs give the same key" do
    assert key(env()) == key(env())
  end

  test "a dep's declared build overrides are another key" do
    for overrides <- [[:system_env], [:compile], [:manager]] do
      refute key(env()) ==
               key(env(build_methods: %{jason: %{manager: "mix", overrides: overrides}})),
             inspect(overrides)
    end
  end

  test "the config of an app outside the lock is another key" do
    before = key(env())
    Application.put_env(:precompiled_probe_cache_test_app, :flag, true)

    try do
      refute key(env()) == before
    after
      Application.delete_env(:precompiled_probe_cache_test_app, :flag)
    end
  end

  test "the global rebar3 config's bytes are another key", %{tmp_dir: dir} do
    old = System.get_env("REBAR_GLOBAL_CONFIG_DIR")
    System.put_env("REBAR_GLOBAL_CONFIG_DIR", dir)

    try do
      config = Path.join([dir, ".config", "rebar3", "rebar.config"])
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "{erl_opts, []}.\n")
      first = key(env())
      File.write!(config, "{erl_opts, [debug_info]}.\n")
      refute key(env()) == first
      File.write!(config <> ".script", "CONFIG.\n")
      refute key(env()) == first
    after
      if old,
        do: System.put_env("REBAR_GLOBAL_CONFIG_DIR", old),
        else: System.delete_env("REBAR_GLOBAL_CONFIG_DIR")
    end
  end

  test "the project's paths are part of the key" do
    refute key(env()) == key(env(deps_path: "/other/deps"))
  end
end
