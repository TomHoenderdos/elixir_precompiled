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

  test "request returns the etag, sends headers, and answers :not_modified on 304" do
    assert {:ok, "tagged", ~s("v1")} = HTTP.request(url("/etag"))
    assert :not_modified = HTTP.request(url("/etag"), headers: [{"if-none-match", ~s("v1")}])

    assert {:error, "Status 304 Not Modified"} =
             HTTP.get(url("/etag"), headers: [{"if-none-match", ~s("v1")}])
  end

  test "a run deadline in the past makes no request" do
    ElixirPrecompiled.Fixture.clear_requests()
    past = System.monotonic_time(:millisecond) - 1
    assert {:error, "run deadline passed"} = HTTP.get(url("/text"), deadline_at: past)
    assert ElixirPrecompiled.Fixture.requests() == []
  end

  test "a run deadline shorter than the request's own ends a stalled response" do
    t0 = System.monotonic_time(:millisecond)
    assert {:error, "no response within " <> _} = HTTP.get(url("/stall"), deadline_at: t0 + 300)
    assert System.monotonic_time(:millisecond) - t0 < 1_500
  end

  test "a redirect to an allowed content origin is followed, any other is refused" do
    cdn_port = ElixirPrecompiled.TestServer.port() + 2
    start_supervised!({ElixirPrecompiled.TestServer, port: cdn_port})
    cdn = "http://127.0.0.1:#{cdn_port}"

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect_cdn/text"), same_origin: true)

    ElixirPrecompiled.Fixture.clear_requests()

    assert {:error, "Status 404 Not Found"} =
             HTTP.get(url("/precompiled/redirect_cdn/nothing-here"),
               same_origin: true,
               allowed_origins: [cdn]
             )

    assert Enum.any?(ElixirPrecompiled.Fixture.requests(), &(&1.port == cdn_port))

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect_port/x"),
               same_origin: true,
               allowed_origins: [cdn]
             )
  end

  test "an allowed origin over plain http off loopback is never followed" do
    other = "http://127.0.0.2:#{ElixirPrecompiled.TestServer.port()}"

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect/root.json"),
               same_origin: true,
               allowed_origins: [other]
             )
  end

  test "NO_PROXY becomes httpc's no-proxy list" do
    assert HTTP.no_proxy_list(nil) == []
    assert HTTP.no_proxy_list("*") == :all

    assert HTTP.no_proxy_list("localhost, .corp.example:8080,10.0.0.1") ==
             [
               ~c"localhost",
               ~c"*.localhost",
               ~c"corp.example",
               ~c"*.corp.example",
               ~c"10.0.0.1",
               ~c"*.10.0.0.1"
             ]
  end

  test "lower-case proxy variables are honoured, and a NO_PROXY host gets no proxy or credentials" do
    proxy_port = ElixirPrecompiled.TestServer.port() + 3
    start_supervised!({ElixirPrecompiled.TestServer, port: proxy_port})
    keys = ~w(HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy)
    saved = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    System.put_env("http_proxy", "http://user:secret@127.0.0.1:#{proxy_port}")

    ElixirPrecompiled.Fixture.clear_requests()
    assert {:ok, "Basic " <> _} = HTTP.get(url("/proxy-auth"))
    assert [%{port: ^proxy_port}] = ElixirPrecompiled.Fixture.requests()

    System.put_env("no_proxy", "127.0.0.1")
    ElixirPrecompiled.Fixture.clear_requests()
    assert {:ok, ""} = HTTP.get(url("/proxy-auth"))
    refute Enum.any?(ElixirPrecompiled.Fixture.requests(), &(&1.port == proxy_port))
  end

  @tag :tmp_dir
  test "a CA bundle file replaces the OS store", %{tmp_dir: dir} do
    # OTP 25+ answers combined {:cert, der, decoded} records.
    {:ok, [cert | _]} = HTTP.cacerts()
    der = with {:cert, der, _} <- cert, do: der
    path = Path.join(dir, "ca.pem")
    File.write!(path, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    assert HTTP.pem_cacerts(path) == [der]

    System.put_env("ELIXIR_PRECOMPILED_CACERTS_PATH", path)
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_CACERTS_PATH") end)
    assert {:ok, [^der]} = HTTP.cacerts()
  end

  @tag :tmp_dir
  test "a CA file without certificates is an error line, not an empty store", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.pem")
    File.write!(path, "")
    System.put_env("ELIXIR_PRECOMPILED_CACERTS_PATH", path)
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_CACERTS_PATH") end)
    assert {:error, _} = HTTP.cacerts()
  end
end
