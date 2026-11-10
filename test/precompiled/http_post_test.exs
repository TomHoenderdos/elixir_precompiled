# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HTTPPostTest do
  use ExUnit.Case, async: false
  alias Precompiled.Fixture, as: F
  alias Precompiled.HTTP

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup do
    F.clear_reports()
    :ok
  end

  defp url(path), do: "http://127.0.0.1:#{Precompiled.TestServer.port()}/precompiled" <> path

  test "posts JSON and answers the status and body" do
    assert {:ok, 201, body} = HTTP.post(url("/reports"), ~s({"a":1}))
    assert body =~ "5b2c6f0e"
    assert [%{body: ~s({"a":1}), content_type: "application/json"}] = F.report_posts()
  end

  test "any final status comes back to the caller" do
    F.set_report_response({429, ~s({"error":"slow down"})})
    assert {:ok, 429, _} = HTTP.post(url("/reports"), "{}")
  end

  test "plain http is refused off loopback, before connecting" do
    assert {:error, "plain http is only allowed on loopback"} =
             HTTP.post("http://example.com/x", "{}")

    assert {:error, "plain http is only allowed on loopback"} =
             HTTP.post("ftp://127.0.0.1/x", "{}")
  end

  test "a redirect is never followed" do
    assert {:error, :redirect} = HTTP.post(url("/redirect_report/reports"), "{}")
    assert F.report_posts() == []
  end

  test "a response over the cap is refused" do
    F.set_report_response({201, String.duplicate("x", 20_000)})
    assert {:error, {:too_large, 16_384}} = HTTP.post(url("/reports"), "{}")
  end

  test "a slow server ends at the deadline" do
    started = System.monotonic_time(:millisecond)
    assert {:error, _} = HTTP.post(url("/slow/reports"), "{}", deadline_ms: 300)
    assert System.monotonic_time(:millisecond) - started < 1_900
  end

  test "offline makes no request" do
    assert {:error, "offline"} = HTTP.post(url("/reports"), "{}", offline: true)
    assert F.report_posts() == []
  end

  test "an unknown option is refused before any request" do
    assert_raise ArgumentError, fn -> HTTP.post(url("/reports"), "{}", headers: []) end
    assert F.report_posts() == []
  end

  # The server sends 64 chunks of 64 KiB, 20 ms apart: about 1.3 s and 4 MiB
  # in full. The client must stop at the cap and close the connection, so the
  # server's writes start failing long before the last chunk.
  test "a streamed 200 over the cap stops the transfer early" do
    assert_stops_early("/huge/200/reports")
  end

  test "a 201 over the cap stops the transfer early where httpc can cap it" do
    if HTTP.capped_buffer?() do
      assert_stops_early("/huge/201/reports")
    else
      assert {:error, {:too_large, 16_384}} = HTTP.post(url("/huge/201/reports"), "{}")
    end
  end

  defp assert_stops_early(path) do
    started = System.monotonic_time(:millisecond)
    assert {:error, {:too_large, 16_384}} = HTTP.post(url(path), "{}", deadline_ms: 5_000)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert %{sent: sent, of: 64} = await_huge()
    assert sent < 64
  end

  defp await_huge(tries \\ 100) do
    case F.report_posts() do
      [%{sent: _} = post] ->
        post

      _ when tries > 0 ->
        Process.sleep(20)
        await_huge(tries - 1)

      other ->
        flunk("the server never finished sending: #{inspect(other)}")
    end
  end
end
