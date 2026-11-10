# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HTTPTest do
  use ExUnit.Case, async: false
  alias Precompiled.HTTP

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  defp url(path), do: "http://127.0.0.1:#{Precompiled.TestServer.port()}" <> path

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

    assert :not_modified = HTTP.request(url("/etag"), headers: [{"If-None-Match", ~s("v1")}])
  end

  test "a 304 to a request that was not conditional is an error" do
    assert {:error, "Status 304 Not Modified"} = HTTP.request(url("/always-304"))
  end

  test "a run deadline in the past makes no request" do
    Precompiled.Fixture.clear_requests()
    past = System.monotonic_time(:millisecond) - 1
    assert {:error, "run deadline passed"} = HTTP.get(url("/text"), deadline_at: past)
    assert Precompiled.Fixture.requests() == []
  end

  test "a run deadline shorter than the request's own ends a stalled response" do
    t0 = System.monotonic_time(:millisecond)
    assert {:error, "no response within " <> _} = HTTP.get(url("/stall"), deadline_at: t0 + 300)
    assert System.monotonic_time(:millisecond) - t0 < 1_500
  end

  test "a redirect to an allowed content origin is followed, any other is refused" do
    cdn_port = Precompiled.TestServer.port() + 2
    start_supervised!({Precompiled.TestServer, port: cdn_port})
    cdn = "http://127.0.0.1:#{cdn_port}"

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect_cdn/text"), same_origin: true)

    Precompiled.Fixture.clear_requests()

    assert {:error, "Status 404 Not Found"} =
             HTTP.get(url("/precompiled/redirect_cdn/nothing-here"),
               same_origin: true,
               allowed_origins: [cdn]
             )

    assert Enum.any?(Precompiled.Fixture.requests(), &(&1.port == cdn_port))

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect_port/x"),
               same_origin: true,
               allowed_origins: [cdn]
             )

    # The CDN itself redirecting onwards to an origin nobody allowed.
    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect_cdn/redirect/x"),
               same_origin: true,
               allowed_origins: [cdn]
             )

    # Scheme and host compare case-insensitively.
    Precompiled.Fixture.clear_requests()

    assert {:error, "Status 404 Not Found"} =
             HTTP.get(url("/precompiled/redirect_cdn_upper/nothing-here"),
               same_origin: true,
               allowed_origins: ["HTTP://localhost:#{cdn_port}"]
             )

    assert Enum.any?(Precompiled.Fixture.requests(), &(&1.port == cdn_port))
  end

  test "an allowed origin over plain http off loopback is never followed" do
    other = "http://127.0.0.2:#{Precompiled.TestServer.port()}"

    assert {:error, :cross_origin_redirect} =
             HTTP.get(url("/precompiled/redirect/root.json"),
               same_origin: true,
               allowed_origins: [other]
             )
  end

  test "NO_PROXY becomes httpc's no-proxy list" do
    assert HTTP.no_proxy_list(nil) == []
    assert HTTP.no_proxy_list("*") == :all
    assert HTTP.no_proxy_list("example.org, *") == :all

    assert HTTP.no_proxy_list("Localhost, .Corp.Example:8080,10.0.0.1") ==
             [~c"localhost", ~c"*.localhost", ~c"corp.example", ~c"*.corp.example", ~c"10.0.0.1"]
  end

  test "NO_PROXY keeps IPv6 literals whole and drops CIDR ranges" do
    assert HTTP.no_proxy_list("localhost,127.0.0.1,::1,[::1]:8080") ==
             [~c"localhost", ~c"*.localhost", ~c"127.0.0.1", ~c"::1"]

    assert HTTP.no_proxy_list("[FE80::1],fd00::2:3,10.0.0.0/8,fd00::/8") ==
             [~c"fe80::1", ~c"fd00::2:3"]
  end

  # Proxy settings are read once per VM; each case resets that decision.
  defp with_proxy_env(env) do
    proxy_port = Precompiled.TestServer.port() + 3
    start_supervised!({Precompiled.TestServer, port: proxy_port})
    keys = ~w(HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy)
    saved = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      HTTP.reset_proxy_config()
    end)

    for {k, v} <- env, do: System.put_env(k, String.replace(v, "PROXY_PORT", "#{proxy_port}"))
    HTTP.reset_proxy_config()
    Precompiled.Fixture.clear_requests()
    proxy_port
  end

  defp proxied?(proxy_port),
    do: Enum.any?(Precompiled.Fixture.requests(), &(&1.port == proxy_port))

  test "a lower-case proxy variable is honoured, with URI-decoded credentials" do
    proxy_port = with_proxy_env([{"http_proxy", "http://us%40er:p%3Ass@127.0.0.1:PROXY_PORT"}])
    assert {:ok, "Basic " <> b64} = HTTP.get(url("/proxy-auth"))
    assert Base.decode64!(b64) == "us@er:p:ss"
    assert proxied?(proxy_port)
  end

  test "a NO_PROXY host gets no proxy and no credentials" do
    proxy_port =
      with_proxy_env([
        {"http_proxy", "http://user:secret@127.0.0.1:PROXY_PORT"},
        {"no_proxy", "127.0.0.1"}
      ])

    assert {:ok, ""} = HTTP.get(url("/proxy-auth"))
    refute proxied?(proxy_port)
  end

  # NO_PROXY entries are lower-cased, and httpc compares hosts as given:
  # the request's host is lower-cased too, so case cannot route a NO_PROXY
  # host through the proxy with its credentials.
  test "a NO_PROXY host in another case still gets no proxy" do
    proxy_port =
      with_proxy_env([
        {"http_proxy", "http://user:secret@127.0.0.1:PROXY_PORT"},
        {"no_proxy", "localhost"}
      ])

    upper = String.replace(url("/proxy-auth"), "127.0.0.1", "LocalHost")
    assert {:ok, ""} = HTTP.get(upper)
    refute proxied?(proxy_port)
  end

  test "NO_PROXY=* sends nothing through a configured proxy" do
    proxy_port =
      with_proxy_env([
        {"HTTP_PROXY", "http://user:secret@127.0.0.1:PROXY_PORT"},
        {"NO_PROXY", "*"}
      ])

    assert {:ok, ""} = HTTP.get(url("/proxy-auth"))
    refute proxied?(proxy_port)
  end

  test "upper-case NO_PROXY takes precedence over no_proxy" do
    proxy_port =
      with_proxy_env([
        {"HTTP_PROXY", "http://user:secret@127.0.0.1:PROXY_PORT"},
        {"NO_PROXY", "other.example"},
        {"no_proxy", "127.0.0.1"}
      ])

    assert {:ok, "Basic " <> _} = HTTP.get(url("/proxy-auth"))
    assert proxied?(proxy_port)
  end

  test "the proxy decision holds for the run, even when the environment changes" do
    proxy_port = with_proxy_env([{"http_proxy", "http://127.0.0.1:PROXY_PORT"}])
    assert {:ok, _} = HTTP.get(url("/proxy-auth"))
    System.put_env("no_proxy", "127.0.0.1")
    Precompiled.Fixture.clear_requests()
    assert {:ok, _} = HTTP.get(url("/proxy-auth"))
    assert proxied?(proxy_port)
  end

  @tag :tmp_dir
  test "a CA bundle file replaces the OS store", %{tmp_dir: dir} do
    der = test_der()
    path = Path.join(dir, "ca.pem")
    File.write!(path, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    assert HTTP.pem_cacerts(path) == [der]

    System.put_env("PRECOMPILED_CACERTS_PATH", path)
    on_exit(fn -> System.delete_env("PRECOMPILED_CACERTS_PATH") end)
    assert {:ok, [^der]} = HTTP.cacerts()
  end

  @tag :tmp_dir
  test "a CA file without certificates is an error line, not an empty store", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.pem")
    File.write!(path, "")
    System.put_env("PRECOMPILED_CACERTS_PATH", path)
    on_exit(fn -> System.delete_env("PRECOMPILED_CACERTS_PATH") end)
    assert {:error, _} = HTTP.cacerts()
  end

  # A CAStore stand-in: file_path/0 names whatever the test put in the
  # process dictionary.
  defmodule FakeCAStore do
    @moduledoc false
    @spec file_path() :: Path.t() | nil
    def file_path(), do: Process.get(:fake_ca_path)
  end

  # A certificate made here, so no test depends on this machine's own
  # CA store (a CI runner or a container may have none).
  defp test_der() do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"precompiled test CA", [])
    der
  end

  defp write_pem(dir, name, der) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    path
  end

  @tag :tmp_dir
  test "cacerts: the explicit path wins; an empty OS store falls through to CAStore, then fails",
       %{tmp_dir: dir} do
    assert {:error, "no CA certificates"} = HTTP.cacerts(fn -> [] end)

    der = test_der()
    pem = write_pem(dir, "ca.pem", der)
    assert {:ok, [^der]} = HTTP.cacerts_for(cacerts_path: pem)

    # The explicit path wins over the environment's file.
    File.write!(Path.join(dir, "empty.pem"), "")
    System.put_env("PRECOMPILED_CACERTS_PATH", Path.join(dir, "empty.pem"))
    on_exit(fn -> System.delete_env("PRECOMPILED_CACERTS_PATH") end)
    assert {:ok, [^der]} = HTTP.cacerts_for(cacerts_path: pem)
    assert {:error, "CA certificate file " <> _} = HTTP.cacerts_for([])

    # A path that is named but unusable is an error, never a quiet fallback.
    assert {:error, "CA certificate file " <> _} =
             HTTP.cacerts_for(cacerts_path: Path.join(dir, "missing.pem"))
  end

  @tag :tmp_dir
  test "the store order: the OS store, then CAStore when loaded, then an error", %{tmp_dir: dir} do
    der = test_der()
    Process.put(:fake_ca_path, write_pem(dir, "castore.pem", der))

    assert HTTP.store_cacerts(fn -> [:os] end, FakeCAStore) == [:os]
    assert HTTP.store_cacerts(fn -> [] end, FakeCAStore) == [der]
    assert HTTP.store_cacerts(fn -> raise "no store" end, FakeCAStore) == [der]

    assert HTTP.store_cacerts(fn -> [] end, Precompiled.NoSuchCAStore) ==
             {:error, "no CA certificates"}

    assert HTTP.store_cacerts(fn -> raise "no store" end, Precompiled.NoSuchCAStore) ==
             {:error, "no CA certificates"}

    Process.put(:fake_ca_path, Path.join(dir, "missing.pem"))
    assert {:error, "CA certificate file " <> _} = HTTP.store_cacerts(fn -> [] end, FakeCAStore)
  end

  @tag :tmp_dir
  test "request takes :cacerts_path", %{tmp_dir: dir} do
    pem = write_pem(dir, "ca.pem", test_der())
    assert {:ok, "hello nerves"} = HTTP.get(url("/text"), cacerts_path: pem)

    assert {:error, "CA certificate file " <> _} =
             HTTP.get(url("/text"), cacerts_path: Path.join(dir, "missing.pem"))
  end
end
