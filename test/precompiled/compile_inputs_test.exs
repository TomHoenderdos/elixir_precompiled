# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CompileInputsTest do
  use ExUnit.Case, async: false

  alias Precompiled.CompileInputs

  @name "PRECOMPILED_TEST_COMPILE_INPUT"

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  setup do
    on_exit(fn -> System.delete_env(@name) end)
  end

  # The end-to-end shape of `GITHUB_ACTIONS=true mix deps.loadpaths`: the
  # host check reads the running VM's environment.
  test "the host check reads the real environment" do
    items = [%{"kind" => "env", "name" => @name, "value" => rec(:error), "set_by" => "host"}]
    assert :ok = CompileInputs.host(items, &System.get_env/1)

    System.put_env(@name, "true")

    assert {:miss, %{code: :env_differs, args: [@name]}} =
             CompileInputs.host(items, &System.get_env/1)
  end

  test "no field is no rule" do
    assert :ok = CompileInputs.host(nil, fn _ -> raise "never called" end)
    assert :ok = CompileInputs.device(nil)
  end
end
