# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.PreflightTest do
  # FakeBin changes the global PATH.
  use ExUnit.Case, async: false

  alias ChainTest.{FakeBin, Preflight, Result}

  @moduletag :tmp_dir

  defp cfg(tmp_dir, overrides \\ %{}) do
    known_hosts = Path.join(tmp_dir, "known_hosts")
    File.write!(known_hosts, "")

    Map.merge(
      %{
        target: "rpi4",
        device: "device.invalid",
        known_hosts: known_hosts,
        source: "http://127.0.0.1:1/api/precompiled",
        fixture_dir: tmp_dir
      },
      overrides
    )
  end

  describe "ssh" do
    test "a device that answers ok passes", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"ssh" => "echo ok"}, fn dir ->
        assert %Result{step: :preflight, check: "ssh", class: :pass} = Preflight.ssh(cfg(tmp))

        argv = FakeBin.argv(dir, "ssh")
        assert "BatchMode=yes" in argv
        assert "StrictHostKeyChecking=yes" in argv
        assert "UserKnownHostsFile=#{Path.join(tmp, "known_hosts")}" in argv
        refute Enum.any?(argv, &(&1 =~ "accept-new"))
        assert List.last(argv) == "IO.puts(:ok)"
        assert "device.invalid" in argv
      end)
    end

    test "IEx noise around ok still passes", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"ssh" => "echo 'Interactive Elixir'; echo ok; echo ':ok'"}, fn _ ->
        assert %Result{class: :pass} = Preflight.ssh(cfg(tmp))
      end)
    end

    test "a changed host key fails with a clear host key message", %{tmp_dir: tmp} do
      stub = """
      echo '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@' >&2
      echo '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @' >&2
      echo 'Host key verification failed.' >&2
      exit 255
      """

      FakeBin.with_stubs(%{"ssh" => stub}, fn _ ->
        assert %Result{class: :fail, detail: detail} = Preflight.ssh(cfg(tmp))
        assert detail =~ "host key"
        assert detail =~ "host key changed"
        assert detail =~ Path.join(tmp, "known_hosts")
      end)
    end

    test "a device that hangs fails at the timeout", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"ssh" => "exec sleep 30"}, fn _ ->
        {us, result} = :timer.tc(fn -> Preflight.ssh(cfg(tmp, %{timeout_ms: 500})) end)

        assert %Result{class: :fail, detail: detail} = result
        assert detail =~ "timeout"
        assert us < 5_000_000
      end)
    end

    test "the default timeout is 15 s" do
      assert Preflight.timeout_ms() == 15_000
    end

    test "a missing known_hosts file fails without calling ssh", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"ssh" => "echo ok"}, fn dir ->
        missing = Path.join(tmp, "nope")

        assert %Result{class: :fail, detail: detail} =
                 Preflight.ssh(cfg(tmp, %{known_hosts: missing}))

        assert detail =~ missing
        assert FakeBin.argv(dir, "ssh") == nil
      end)
    end

    test "a device that answers something else fails", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"ssh" => "echo 'not ok'"}, fn _ ->
        assert %Result{class: :fail} = Preflight.ssh(cfg(tmp))
      end)
    end
  end

  describe "portal" do
    test "200 on root.json passes and requests <source>/root.json", %{tmp_dir: tmp} do
      {port, seen} = http_stub(200)
      source = "http://127.0.0.1:#{port}/api/precompiled"

      assert %Result{check: "portal", class: :pass} =
               Preflight.portal(cfg(tmp, %{source: source}))

      assert_receive {^seen, "GET /api/precompiled/root.json " <> _}, 1_000
    end

    test "500 fails with the status", %{tmp_dir: tmp} do
      {port, _} = http_stub(500)
      source = "http://127.0.0.1:#{port}/api/precompiled"

      assert %Result{class: :fail, detail: detail} = Preflight.portal(cfg(tmp, %{source: source}))
      assert detail =~ "500"
    end

    test "a refused connection fails", %{tmp_dir: tmp} do
      {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(l)
      :gen_tcp.close(l)
      source = "http://127.0.0.1:#{port}/api/precompiled"

      assert %Result{class: :fail} = Preflight.portal(cfg(tmp, %{source: source}))
    end
  end

  describe "toolchain" do
    @mix_ok "echo '* hex-2.2.1'; echo '* nerves_bootstrap-1.13.1'; echo 'Archives installed at: /x'"

    test "nerves_bootstrap listed and fwup on PATH passes", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"mix" => @mix_ok, "fwup" => "exit 0"}, fn dir ->
        assert %Result{check: "toolchain", class: :pass} = Preflight.toolchain(cfg(tmp))
        assert FakeBin.argv(dir, "mix") == ["archive"]
      end)
    end

    test "no nerves_bootstrap archive fails", %{tmp_dir: tmp} do
      FakeBin.with_stubs(%{"mix" => "echo '* hex-2.2.1'", "fwup" => "exit 0"}, fn _ ->
        assert %Result{class: :fail, detail: detail} = Preflight.toolchain(cfg(tmp))
        assert detail =~ "nerves_bootstrap"
      end)
    end

    test "fwup missing from PATH fails", %{tmp_dir: tmp} do
      FakeBin.with_stubs(
        %{"mix" => @mix_ok},
        fn _ ->
          assert %Result{class: :fail, detail: detail} = Preflight.toolchain(cfg(tmp))
          assert detail =~ "fwup"
        end,
        path: :only
      )
    end
  end

  describe "fixture_lock" do
    test "a lock naming every expected dep passes", %{tmp_dir: tmp} do
      write_lock(tmp, Preflight.expected_deps("rpi4"))
      assert %Result{check: "fixture_lock", class: :pass} = Preflight.fixture_lock(cfg(tmp))
    end

    test "the expected deps include the target's system" do
      assert "nerves_system_rpi4" in Preflight.expected_deps("rpi4")
      assert "nerves_system_rpi0_2" in Preflight.expected_deps("rpi0_2")
      refute "nerves_system_rpi4" in Preflight.expected_deps("rpi0_2")

      for dep <- ~w(exqlite argon2_elixir circuits_gpio jason ash nerves_pack nerves_ssh) do
        assert dep in Preflight.expected_deps("rpi4")
      end
    end

    test "a lock missing a dep fails and names it", %{tmp_dir: tmp} do
      write_lock(tmp, Preflight.expected_deps("rpi4") -- ["exqlite"])
      assert %Result{class: :fail, detail: detail} = Preflight.fixture_lock(cfg(tmp))
      assert detail =~ "exqlite"
    end

    test "a lock for the other target fails", %{tmp_dir: tmp} do
      write_lock(tmp, Preflight.expected_deps("rpi0_2"))
      assert %Result{class: :fail, detail: detail} = Preflight.fixture_lock(cfg(tmp))
      assert detail =~ "nerves_system_rpi4"
    end

    test "no lock fails", %{tmp_dir: tmp} do
      assert %Result{class: :fail, detail: detail} = Preflight.fixture_lock(cfg(tmp))
      assert detail =~ "mix.lock"
    end
  end

  test "run/1 returns the four checks in order", %{tmp_dir: tmp} do
    write_lock(tmp, Preflight.expected_deps("rpi4"))
    {port, _} = http_stub(200)
    source = "http://127.0.0.1:#{port}/api/precompiled"

    FakeBin.with_stubs(%{"ssh" => "echo ok", "mix" => @mix_ok, "fwup" => "exit 0"}, fn _ ->
      results = Preflight.run(cfg(tmp, %{source: source}))
      assert Enum.map(results, & &1.check) == ~w(ssh portal toolchain fixture_lock)
      assert Enum.all?(results, &(&1.class == :pass and &1.step == :preflight))
      assert Enum.all?(results, &(is_integer(&1.ms) and &1.ms >= 0))
    end)
  end

  describe "target_config" do
    test "an existing operator file passes, a missing one fails naming it", %{tmp_dir: tmp} do
      file = Path.join(tmp, "target.exs")
      File.write!(file, "import Config\n")

      assert %Result{check: "target_config", class: :pass} =
               Preflight.target_config(cfg(tmp, %{target_config: file}))

      missing = Path.join(tmp, "nope.exs")

      assert %Result{class: :fail, detail: detail} =
               Preflight.target_config(cfg(tmp, %{target_config: missing}))

      assert detail =~ missing
    end

    test "run/1 adds the check when a target config is given", %{tmp_dir: tmp} do
      write_lock(tmp, Preflight.expected_deps("rpi4"))
      {port, _} = http_stub(200)
      source = "http://127.0.0.1:#{port}/api/precompiled"
      file = Path.join(tmp, "target.exs")
      File.write!(file, "import Config\n")

      FakeBin.with_stubs(%{"ssh" => "echo ok", "mix" => @mix_ok, "fwup" => "exit 0"}, fn _ ->
        results = Preflight.run(cfg(tmp, %{source: source, target_config: file}))

        assert Enum.map(results, & &1.check) ==
                 ~w(ssh portal toolchain fixture_lock target_config)
      end)
    end
  end

  defp write_lock(dir, deps) do
    body =
      Enum.map_join(deps, "", fn dep ->
        ~s|  "#{dep}": {:hex, :#{dep}, "1.0.0", "00", [:mix], [], "hexpm", "00"},\n|
      end)

    File.write!(Path.join(dir, "mix.lock"), "%{\n" <> body <> "}\n")
  end

  # A one-shot HTTP server on loopback answering every request with `status`.
  defp http_stub(status) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    test = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, req} = :gen_tcp.recv(sock, 0, 5_000)
        send(test, {ref, req})
        reason = if status == 200, do: "OK", else: "Error"
        body = "{}"

        :gen_tcp.send(
          sock,
          "HTTP/1.1 #{status} #{reason}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )

        :gen_tcp.close(sock)
        receive do: (:stop -> :ok)
      end)

    :gen_tcp.controlling_process(listen, pid)
    on_exit(fn -> send(pid, :stop) end)
    {port, ref}
  end
end
