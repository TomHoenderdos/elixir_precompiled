# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.OutputTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias ElixirPrecompiled.Output

  test "info, success and warning print on stdio; error on stderr" do
    assert capture_io(fn -> Output.info("a") end) =~ "a"
    assert capture_io(fn -> Output.success("b") end) =~ "b"
    assert capture_io(fn -> Output.warning("c") end) =~ "c"
    assert capture_io(:stderr, fn -> Output.error("d") end) =~ "d"
  end

  test "the IO fallback prints the same lines without Mix" do
    assert capture_io(fn -> Output.put(:info, "plain", false) end) =~ "plain"

    assert capture_io(:stderr, fn -> Output.put(:error, [:red, "red", :reset], false) end) =~
             "red"
  end
end
