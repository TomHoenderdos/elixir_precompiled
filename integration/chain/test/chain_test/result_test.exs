# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.ResultTest do
  use ExUnit.Case, async: true

  alias ChainTest.Result

  defp results(classes),
    do: Enum.map(classes, &%Result{step: :test, check: "c", class: &1, detail: "", ms: 0})

  test "exit code is 0 for pass, miss and rerun" do
    assert Result.exit_code(results([:pass, :miss, :rerun])) == 0
    assert Result.exit_code([]) == 0
  end

  for class <- [:fail, :refused, :disagreement, :not_exercised] do
    test "exit code is 1 when any result is #{class}" do
      assert Result.exit_code(results([:pass, :miss, unquote(class), :rerun])) == 1
    end
  end

  test "the struct defaults" do
    assert %Result{detail: "", ms: 0} = %Result{step: :x, check: "y", class: :pass}
  end
end
