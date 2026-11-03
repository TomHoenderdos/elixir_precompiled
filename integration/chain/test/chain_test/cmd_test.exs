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

  @tag :tmp_dir
  test "a timeout kills the whole process group, grandchildren included", %{tmp_dir: tmp} do
    pids = Path.join(tmp, "pids")
    # The background sleep is a grandchild that is not exec'd into.
    script = ~S(sleep 30 & echo $! > "$PIDS"; echo $$ >> "$PIDS"; sleep 30)

    assert {124, _} = Cmd.run("sh", ["-c", script], timeout_ms: 500, env: [{"PIDS", pids}])

    [_ | _] = all = pids |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)
    assert length(all) == 2
    for pid <- all, do: assert(gone?(pid), "pid #{pid} survived the timeout")
  end

  @tag :tmp_dir
  test ":stdin_file feeds the file's bytes to stdin", %{tmp_dir: tmp} do
    input = Path.join(tmp, "in.bin")
    output = Path.join(tmp, "out.bin")
    bytes = :crypto.strong_rand_bytes(200_000)
    File.write!(input, bytes)

    assert {0, _} =
             Cmd.run("sh", ["-c", ~S(cat > "$OUT")], stdin_file: input, env: [{"OUT", output}])

    assert File.read!(output) == bytes
  end

  test "a missing :stdin_file fails without running the command" do
    assert {127, out} = Cmd.run("sh", ["-c", "echo ran"], stdin_file: "/nonexistent/fw")
    assert out =~ "/nonexistent/fw"
    refute out =~ "ran"
  end

  test "without :stdin_file a command runs as before" do
    assert {0, "x\n"} = Cmd.run("sh", ["-c", "echo x"])
  end

  # A killed process is gone once kill -0 fails; allow a moment for reaping.
  defp gone?(pid, tries \\ 20) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    cond do
      status != 0 -> true
      tries == 0 -> zombie?(pid)
      true -> Process.sleep(50) && gone?(pid, tries - 1)
    end
  end

  defp zombie?(pid) do
    {out, _} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)])
    String.starts_with?(String.trim(out), "Z")
  end

  test "a missing executable returns 127" do
    assert {127, out} = Cmd.run("chain-test-no-such-exe", [])
    assert out =~ "not found"
  end
end
