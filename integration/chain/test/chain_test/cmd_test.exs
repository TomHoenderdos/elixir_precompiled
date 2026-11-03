# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.CmdTest do
  use ExUnit.Case, async: true

  alias ChainTest.Cmd

  test "returns the exit status and merged output" do
    assert {3, out} = Cmd.run("sh", ["-c", "echo out; echo err >&2; exit 3"])
    assert out =~ "out"
    assert out =~ "err"
  end

  test "passes env and cd" do
    dir = System.tmp_dir!() |> Path.expand()

    assert {0, out} =
             Cmd.run("sh", ["-c", "echo $CHAIN_X; pwd -P"], env: [{"CHAIN_X", "hello"}], cd: dir)

    assert out =~ "hello"
    assert out =~ Path.basename(dir)
  end

  test "a timeout returns 124 with the output so far" do
    {us, result} =
      :timer.tc(fn -> Cmd.run("sh", ["-c", "echo started; exec sleep 30"], timeout_ms: 300) end)

    assert {124, out} = result
    assert out =~ "started"
    assert String.ends_with?(out, "\n[timeout]")
    assert us < 5_000_000
  end

  test "a missing executable returns 127" do
    assert {127, out} = Cmd.run("chain-test-no-such-exe", [])
    assert out =~ "not found"
  end
end
