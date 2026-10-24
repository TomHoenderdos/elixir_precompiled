# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.HTTPTest do
  use ExUnit.Case, async: false
  alias NervesPrecompiled.HTTP

  setup_all do
    start_supervised!(NervesPrecompiled.TestServer)
    :ok
  end

  defp url(path), do: "http://127.0.0.1:#{NervesPrecompiled.TestServer.port()}" <> path

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

  test "the CA store is readable on this host" do
    assert {:ok, [_ | _]} = HTTP.cacerts()
  end
end
