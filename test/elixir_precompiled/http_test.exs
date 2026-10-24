# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.HTTPTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.HTTP

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  defp url(path), do: "http://127.0.0.1:#{ElixirPrecompiled.TestServer.port()}" <> path

  test "collects a body" do
    assert {:ok, "hello nerves"} = HTTP.get(url("/text"))
  end

  test "assembles a streamed body under the cap" do
    assert {:ok, body} = HTTP.get(url("/binary"), max_bytes: 2048)
    assert byte_size(body) == 1024
    assert body == :binary.copy(<<0xDE, 0xAD, 0xBE, 0xEF>>, 256)
  end

  test "refuses a body over the cap" do
    assert {:error, {:too_large, 10}} = HTTP.get(url("/binary"), max_bytes: 10)
    refute_receive {:http, _}, 200
  end

  test "refuses a content-length that doesn't parse as a non-negative integer" do
    assert :error = HTTP.content_length([{~c"content-length", ~c"abc"}])
    assert :error = HTTP.content_length([{~c"content-length", ~c"-1"}])
    assert :error = HTTP.content_length([{~c"content-length", ~c"12abc"}])
    assert {:ok, 0} = HTTP.content_length([])
    assert {:ok, 12} = HTTP.content_length([{~c"content-length", ~c"12"}])
  end

  test "gives up after a server accepts and then stalls" do
    assert {:error, "no data for 0.2 s"} = HTTP.get(url("/stall"), inactivity_ms: 200)
    refute_receive {:http, _}, 200
  end

  test "gives up when a response that keeps dripping passes the deadline" do
    assert {:error, "no response within 0.5 s"} = HTTP.get(url("/drip"), deadline_ms: 500)
    refute_receive {:http, _}, 200
  end

  test "caps a streamed body that has no content-length" do
    assert {:error, {:too_large, 1000}} = HTTP.get(url("/chunked"), max_bytes: 1000)
    refute_receive {:http, _}, 200
    assert {:ok, body} = HTTP.get(url("/chunked"), max_bytes: 8192)
    assert byte_size(body) == 4096
  end

  test "reports HTTP errors as a status line" do
    assert {:error, "Status 404 Not Found"} = HTTP.get(url("/nope"))
  end

  test "follows a same-origin redirect and refuses the others when asked" do
    assert {:ok, "hello nerves"} =
             HTTP.get(url("/precompiled/redirect_same/text"), same_origin: true)

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect/root.json"), same_origin: true)

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect_port/root.json"), same_origin: true)
  end

  test "a failed connection is an error, not a crash" do
    assert {:error, _} = HTTP.get("http://127.0.0.1:1/x")
  end

  test "the CA store is readable on this host, and its absence is an error line" do
    assert {:ok, [_ | _]} = HTTP.cacerts()

    assert HTTP.cacerts(fn -> raise "no store" end) ==
             {:error, "no CA certificate store on this system"}
  end
end
