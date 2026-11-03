# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.HTTPTest do
  use ExUnit.Case, async: true

  alias ChainTest.HTTP

  # A loopback server answering each of `responses` (raw HTTP) to one
  # connection in turn; reports every request line it got to the test.
  defp responder(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    test = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        for resp <- responses do
          {:ok, sock} = :gen_tcp.accept(listen)
          {:ok, req} = :gen_tcp.recv(sock, 0, 5_000)
          send(test, {ref, req})
          :gen_tcp.send(sock, resp)
          :gen_tcp.close(sock)
        end

        receive do: (:stop -> :ok)
      end)

    :gen_tcp.controlling_process(listen, pid)
    on_exit(fn -> send(pid, :stop) end)
    {port, ref}
  end

  defp reply(status, headers, body) do
    hs = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    "HTTP/1.1 #{status} X\r\n#{hs}content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n#{body}"
  end

  test "200 returns the body" do
    {port, _} = responder([reply(200, [], "hello")])
    assert HTTP.get("http://127.0.0.1:#{port}/x", 2_000) == {:ok, "hello"}
  end

  test "a 302 to another port is an error, never the redirect target's body" do
    {target, target_ref} = responder([reply(200, [], "redirected body")])

    {port, _} =
      responder([reply(302, [{"location", "http://127.0.0.1:#{target}/elsewhere"}], "")])

    assert {:error, why} = HTTP.get("http://127.0.0.1:#{port}/batch.json", 2_000)
    assert why =~ "302"
    refute_receive {^target_ref, _}, 200
  end

  test "plain http to a non-loopback host is refused before any request" do
    assert {:error, why} = HTTP.get("http://example.com/api/precompiled/root.json", 2_000)
    assert why =~ "plain http"
    assert {:error, _} = HTTP.get("HTTP://Example.com/x", 2_000)
    assert {:error, _} = HTTP.get("ftp://example.com/x", 2_000)
  end

  test "plain http to loopback is allowed, whatever the case" do
    {port, _} = responder([reply(200, [], "a"), reply(200, [], "b"), reply(200, [], "c")])
    assert {:ok, "a"} = HTTP.get("http://127.0.0.1:#{port}/x", 2_000)
    assert {:ok, "b"} = HTTP.get("HTTP://LOCALHOST:#{port}/x", 2_000)
    assert HTTP.loopback_allowed?("http://[::1]:#{port}/x")
    assert {:ok, "c"} = HTTP.get("http://localhost:#{port}/x", 2_000)
  end

  test "https gets peer verification against the OS CA store" do
    assert [ssl: ssl] = HTTP.ssl_opts("HTTPS://example.com/x")
    assert ssl[:verify] == :verify_peer
    assert ssl[:cacerts] != []
  end
end
