# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Cmd do
  @moduledoc """
  The one place the harness runs external commands.

  stdout and stderr are merged. Every command runs as the leader of its own
  process group, started through a small perl wrapper (`setpgrp`, then
  `exec`; perl is on macOS and Linux, which have no common `setsid`). A
  command that outlives `:timeout_ms` has its whole group killed, so the
  grandchildren ssh, mix or fwup fork die with it, and is reported as exit
  status 124 (as `timeout(1)` does), with the output collected so far and a
  `[timeout]` marker.
  """

  # ARGV: stdin file ("" for none), exe, args. The group id is the pid, which
  # the exec keeps. Where the runtime already made the child a session leader,
  # setpgrp fails with EPERM but the child already leads its own group.
  @wrapper ~S"""
  my $in = shift @ARGV;
  if ($in ne "") { open(STDIN, "<", $in) or do { print "stdin $in: $!\n"; exit 127 } }
  setpgrp(0, 0) or getpgrp() == $$ or do { print "setpgrp: $!\n"; exit 126 };
  exec { $ARGV[0] } @ARGV or do { print "exec $ARGV[0]: $!\n"; exit 127 };
  """

  @default_timeout_ms 60_000

  @doc """
  Runs `exe` with `args`. Options:

    * `:timeout_ms` - default #{@default_timeout_ms}.
    * `:env` - `[{name, value}]`; a `nil` value unsets the variable.
    * `:cd` - the working directory.
    * `:stdin_file` - a file whose bytes become the command's stdin (a
      missing file returns `{127, message}` without running the command).

  An `exe` that is not found returns `{127, message}`.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {integer(), String.t()}
  def run(exe, args, opts \\ []) do
    case resolve(exe) do
      nil ->
        {127, "#{exe}: command not found"}

      path ->
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

        stdin = opts[:stdin_file] || ""
        wrapper_args = ["-e", @wrapper, stdin, path | args]

        port_opts =
          [:binary, :exit_status, :stderr_to_stdout, :hide, args: wrapper_args]
          |> put_env(opts[:env])
          |> put_cd(opts[:cd])

        port = Port.open({:spawn_executable, perl()}, port_opts)
        deadline = System.monotonic_time(:millisecond) + timeout
        collect(port, deadline, [])
    end
  end

  @doc "The last five non-empty lines of `out`, joined with ` / `, for a result's detail."
  @spec tail(String.t()) :: String.t()
  def tail(out) do
    out
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.take(-5)
    |> Enum.join(" / ")
  end

  # The system perl first, so a stub dir on PATH cannot replace the wrapper.
  defp perl() do
    if File.regular?("/usr/bin/perl"),
      do: "/usr/bin/perl",
      else: System.find_executable("perl") || raise("ChainTest.Cmd needs perl")
  end

  defp resolve(exe) do
    if String.contains?(exe, "/"),
      do: if(File.regular?(exe), do: exe),
      else: System.find_executable(exe)
  end

  defp put_env(opts, nil), do: opts

  defp put_env(opts, env) do
    pairs =
      Enum.map(env, fn
        {k, nil} -> {to_charlist(k), false}
        {k, v} -> {to_charlist(k), to_charlist(v)}
      end)

    [{:env, pairs} | opts]
  end

  defp put_cd(opts, nil), do: opts
  defp put_cd(opts, dir), do: [{:cd, to_charlist(dir)} | opts]

  defp collect(port, deadline, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, deadline, [acc | data])
      {^port, {:exit_status, status}} -> {status, IO.iodata_to_binary(acc)}
    after
      left -> kill(port, acc)
    end
  end

  defp kill(port, acc) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> kill_group(pid)
      nil -> :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port, acc)
  end

  # The command leads its own group (pgid == pid); a negative pid kills the
  # group. The pid itself as well, in case it died before setpgrp ran.
  defp kill_group(pid) do
    pid = Integer.to_string(pid)
    System.cmd("kill", ["-KILL", "--", "-" <> pid], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
  end

  defp drain(port, acc) do
    receive do
      {^port, {:data, data}} -> drain(port, [acc | data])
      {^port, {:exit_status, _}} -> drain(port, acc)
    after
      0 -> {124, IO.iodata_to_binary(acc) <> "\n[timeout]"}
    end
  end
end
