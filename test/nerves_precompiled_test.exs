# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiledTest do
  use ExUnit.Case, async: false
  alias NervesPrecompiled.Env

  setup do
    for {k, _} <- Application.get_all_env(:nerves_precompiled),
        do: Application.delete_env(:nerves_precompiled, k)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:nerves_precompiled),
          do: Application.delete_env(:nerves_precompiled, k)
    end)

    %{env: %Env{candidates: [], lock: %{}, build_lib: "/nonexistent", deps_path: "/nonexistent"}}
  end

  test "disabled without a source", %{env: env} do
    assert NervesPrecompiled.run(env: env, host?: false) == :disabled
  end

  test "disabled on the host target even with a source", %{env: env} do
    Application.put_env(:nerves_precompiled, :source, "https://example.test/x")
    assert NervesPrecompiled.run(env: env, host?: true) == :disabled
  end

  test "with a source and a target, an empty env is nothing to do", %{env: env} do
    Application.put_env(:nerves_precompiled, :source, "https://example.test/x")
    assert NervesPrecompiled.run(env: env, host?: false) == :nothing_to_do
  end
end
