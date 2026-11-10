# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule DeviceQemu do
  @moduledoc """
  Boots the fixture firmware in qemu (`run_qemu.sh`) and talks to it over
  ssh on `localhost:10022`, where `nerves_ssh` evaluates each command as
  Elixir.

  One guest at a time: its qemu pid lives in a process registered under
  this module's name, and `stop!/0` kills it. The guest's console goes to
  `_qemu/qemu.log`.
  """

  @here Path.expand("../..", __DIR__)
  @client_root Path.expand("../../../..", __DIR__)
  @port "10022"
  @ssh_wait_ms if(match?({:unix, :darwin}, :os.type()), do: 120_000, else: 600_000)
  @clock_wait_ms 300_000

  @doc "Boots the guest and waits for ssh. `fresh: true` starts from a new disk image."
  @spec boot!(keyword()) :: :ok
  def boot!(opts \\ []) do
    offline? = Keyword.get(opts, :offline, false)
    if Keyword.get(opts, :fresh, false), do: File.rm(Path.join(@here, "_qemu/disk.img"))
    File.mkdir_p!(Path.join(@here, "_qemu"))
    stop!()

    args = if offline?, do: ["--offline"], else: []
    log = Path.join(@here, "_qemu/qemu.log")
    started = System.monotonic_time(:millisecond)

    parent = self()
    owner = spawn(fn -> own_qemu(parent, args, log, offline?) end)

    receive do
      {:qemu_started, ^owner} -> :ok
    after
      30_000 -> raise "qemu did not start"
    end

    wait_ssh!(@ssh_wait_ms)
    IO.puts("qemu: ssh up after #{System.monotonic_time(:millisecond) - started} ms")
    :ok
  end

  # The port's shell starts qemu in the background and prints its pid. A
  # second background job holds the port's stdin (as fd 3: an asynchronous
  # list's own stdin is /dev/null) and kills qemu when it ends, which is
  # when this VM exits, so no guest outlives the test run.
  defp own_qemu(parent, args, log, offline?) do
    script = Path.join(@here, "run_qemu.sh")

    cmd =
      ~s|log="$0"; script="$1"; shift; exec 3<&0; | <>
        ~s|"$script" "$@" >>"$log" 2>&1 3<&- & q=$!; echo "$q"; | <>
        ~s|(cat <&3 >/dev/null; kill "$q" 2>/dev/null) >/dev/null 2>&1 & wait "$q"|

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", cmd, log, script | args]
      ])

    receive do
      {^port, {:data, data}} ->
        Process.register(self(), __MODULE__)
        send(parent, {:qemu_started, self()})
        hold(port, %{pid: data |> String.trim() |> String.to_integer(), offline?: offline?})
    after
      30_000 -> :ok
    end
  end

  defp hold(port, state) do
    receive do
      {:get, from} ->
        send(from, {:qemu_state, state})
        hold(port, state)

      {:stop, from} ->
        # The port may have closed already, with its exit_status in flight.
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        send(from, {:qemu_stopped, self()})

      {^port, {:exit_status, _}} ->
        :ok

      {^port, _} ->
        hold(port, state)
    end
  end

  defp state() do
    with owner when is_pid(owner) <- Process.whereis(__MODULE__) do
      send(owner, {:get, self()})

      receive do
        {:qemu_state, state} -> state
      after
        5_000 -> nil
      end
    end
  end

  @doc "Kills the guest's qemu, if one runs, and waits for it to exit."
  @spec stop!() :: :ok
  def stop!() do
    case state() do
      nil ->
        :ok

      %{pid: pid} ->
        kill(pid)

        with owner when is_pid(owner) <- Process.whereis(__MODULE__) do
          send(owner, {:stop, self()})

          receive do
            {:qemu_stopped, ^owner} -> :ok
          after
            5_000 -> Process.exit(owner, :kill)
          end
        end

        :ok
    end
  end

  defp kill(pid) do
    System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)

    unless wait_until(fn -> not alive?(pid) end, 15_000) do
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
      wait_until(fn -> not alive?(pid) end, 15_000)
    end
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  @doc "Whether the running guest was booted without a network."
  @spec offline?() :: boolean()
  def offline?() do
    match?(%{offline?: true}, state())
  end

  @doc "Runs `expr` on the guest; returns `{output, exit_status}`."
  @spec ssh(String.t(), timeout()) :: {String.t(), non_neg_integer() | :timeout}
  def ssh(expr, timeout \\ 600_000) do
    task =
      Task.async(fn ->
        System.cmd("ssh", ssh_opts() ++ ["-p", @port, "localhost", expr], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {"ssh timed out after #{timeout} ms", :timeout}
    end
  end

  @doc "Runs `expr` on the guest and returns its output; fails on a non-zero exit."
  @spec dev!(String.t()) :: String.t()
  def dev!(expr) do
    case ssh(expr) do
      {out, 0} -> out
      {out, status} -> raise "ssh #{inspect(expr)} exited #{inspect(status)}:\n#{out}"
    end
  end

  @doc """
  Evaluates `expr` on the guest and returns its inspected value on one
  line, without the `precompiled:` lines or the echoed result around it.
  """
  @spec value!(String.t()) :: String.t()
  def value!(expr) do
    out =
      dev!(
        "IO.puts(\"\\nvalue: \" <> inspect((#{expr}), " <>
          "limit: :infinity, printable_limit: :infinity, width: :infinity)); :done"
      )

    case Regex.run(~r/^value: (.*)$/m, out) do
      [_, value] -> String.trim(value)
      nil -> raise "no value for #{inspect(expr)} in:\n#{out}"
    end
  end

  defp ssh_opts() do
    key = System.fetch_env!("DEVICE_TEST_KEY")

    ~w(-i #{key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
       -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=5)
  end

  defp wait_ssh!(ms) do
    unless wait_until(fn -> match?({_, 0}, ssh("1", 20_000)) end, ms),
      do: raise("no ssh on the guest after #{ms} ms; see _qemu/qemu.log")
  end

  @doc """
  Waits up to 5 minutes for `NervesTime.synchronized?/0` and for the
  guest to resolve the host of the library's default source: Erlang's
  resolver rereads `/etc/resolv.conf` only every few seconds, so right
  after DHCP a lookup can still fail with `nxdomain` on a synchronized
  clock.
  """
  @spec wait_online!() :: :ok
  def wait_online!() do
    probe =
      ~s|host = URI.parse(Precompiled.Device.Source.official()).host; | <>
        ~s|IO.inspect({NervesTime.synchronized?(), | <>
        ~s|match?({:ok, _}, :inet.gethostbyname(String.to_charlist(host)))})|

    synced? = fn -> match?({"{true, true}" <> _, 0}, ssh(probe, 20_000)) end

    unless wait_until(synced?, @clock_wait_ms),
      do: raise("the guest clock or DNS was not ready within #{@clock_wait_ms} ms")
  end

  @doc """
  Reboots the guest. With the same network mode as now it reboots in place
  (`Nerves.Runtime.reboot/0`); a change of `offline:` restarts qemu on the
  same disk image.
  """
  @spec reboot!(keyword()) :: :ok
  def reboot!(opts \\ []) do
    offline? = Keyword.get(opts, :offline, false)

    if offline? == offline?() do
      started = System.monotonic_time(:millisecond)
      ssh("Nerves.Runtime.reboot()", 20_000)

      unless wait_until(fn -> not match?({_, 0}, ssh("1", 10_000)) end, 120_000),
        do: raise("the guest did not go down after Nerves.Runtime.reboot/0")

      wait_ssh!(@ssh_wait_ms)
      IO.puts("qemu: rebooted in #{System.monotonic_time(:millisecond) - started} ms")
    else
      boot!(offline: offline?)
    end
  end

  @doc """
  Writes an offline bundle of `packages` for this firmware with
  `mix precompiled.bundle` from the client root, against the official source.
  Returns its directory.
  """
  @spec make_bundle!([String.t()]) :: Path.t()
  def make_bundle!(packages) do
    # A new directory every run: the task refuses one that is not empty.
    out = Path.join(@here, "_qemu/bundle")
    File.rm_rf!(out)

    args =
      ["precompiled.bundle" | packages] ++
        ~w(--out #{out} --system nerves_system_qemu_aarch64@0.5.1 --otp 29 --elixir 1.20.3)

    case System.cmd("mix", args,
           cd: @client_root,
           env: [{"MIX_ENV", "dev"}],
           stderr_to_stdout: true
         ) do
      {_, 0} -> out
      {output, status} -> raise "mix precompiled.bundle exited #{status}:\n#{output}"
    end
  end

  @doc """
  Copies a local directory to `remote` on the guest over nerves_ssh's sftp,
  with an `sftp -b` batch that makes every directory and puts every file
  by name: the guest's sftp server cannot canonicalize a path that does not
  exist yet (so no `put -r`), and it ends the channel without an exit
  status (so `scp` reports failure on a complete copy).
  """
  @spec copy_dir!(Path.t(), Path.t()) :: :ok
  def copy_dir!(local, remote) do
    entries = local |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.sort()
    {dirs, files} = Enum.split_with(entries, &File.dir?/1)
    to_remote = &Path.join(remote, Path.relative_to(&1, local))

    batch =
      ["-mkdir #{remote}"] ++
        Enum.map(dirs, &"mkdir #{to_remote.(&1)}") ++
        Enum.map(files, &"put #{&1} #{to_remote.(&1)}")

    path = Path.join(@here, "_qemu/sftp-batch")
    File.write!(path, Enum.join(batch, "\n") <> "\n")
    args = ssh_opts() ++ ["-P", @port, "-b", path, "localhost"]

    case System.cmd("sftp", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> raise "sftp exited #{status}:\n#{output}"
    end
  end

  @doc "Flips one byte of the first file under `dir/files/` on the guest."
  @spec tamper_one_file!(Path.t()) :: String.t()
  def tamper_one_file!(dir) do
    dev!("""
    [f | _] = Enum.sort(Path.wildcard("#{dir}/files/*"))
    <<b, rest::binary>> = File.read!(f)
    File.write!(f, <<Bitwise.bxor(b, 1), rest::binary>>)
    IO.puts("tampered " <> f)
    """)
  end

  defp wait_until(fun, ms) do
    poll(fun, System.monotonic_time(:millisecond) + ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(2_000)
        poll(fun, deadline)
    end
  end
end
