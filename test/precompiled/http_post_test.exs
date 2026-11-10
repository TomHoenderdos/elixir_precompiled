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
end
