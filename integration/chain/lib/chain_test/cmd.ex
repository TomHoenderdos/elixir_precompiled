# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Cmd do
  @moduledoc """
  The one place the harness runs external commands.

  stdout and stderr are merged. A command that outlives `:timeout_ms` is
  killed and reported as exit status 124 (as `timeout(1)` does), with the
  output collected so far and a `[timeout]` marker.
  """

  @default_timeout_ms 60_000

  @doc """
  Runs `exe` with `args`. Options:

    * `:timeout_ms` - default #{@default_timeout_ms}.
    * `:env` - `[{name, value}]`; a `nil` value unsets the variable.
    * `:cd` - the working directory.

  An `exe` that is not found returns `{127, message}`.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {integer(), String.t()}
  def run(exe, args, opts \\ []) do
    case resolve(exe) do
      nil ->
        {127, "#{exe}: command not found"}

      path ->
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

        port_opts =
          [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
          |> put_env(opts[:env])
          |> put_cd(opts[:cd])

        port = Port.open({:spawn_executable, path}, port_opts)
        deadline = System.monotonic_time(:millisecond) + timeout
        collect(port, deadline, [])
    end
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
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port, acc)
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
