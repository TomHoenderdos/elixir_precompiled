# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.MirrorTest do
  use ExUnit.Case, async: true

  alias ChainTest.{HTTP, Mirror}
  alias ChainTest.Mirror.{Identity, Status, Transform}

  @moduletag :tmp_dir

  @sha String.duplicate("ab", 32)
  @layout %{
    "root.json" => ~s({"root":1}),
    "batch.json" => ~s({"batch":7}),
    "batches/7.json" => ~s({"batch":7}),
    "manifests/jason.json" => ~s({"v":1}),
    "v2/manifests/jason.json" => ~s({"v":2}),
    ("files/" <> @sha) => "file bytes"
  }

  setup %{tmp_dir: tmp} do
    dir = Path.join(tmp, "snapshot")

    for {rel, bytes} <- @layout do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    # A file outside every route, which no request may reach, and one
    # outside the snapshot directory altogether.
    File.write!(Path.join(dir, "secret.txt"), "secret")
    File.write!(Path.join(tmp, "outside.txt"), "outside secret")
    %{dir: dir, tmp: tmp}
  end

  defp start!(dir, opts \\ []) do
    {:ok, mirror} = Mirror.start(dir, opts)
    on_exit(fn -> Mirror.stop(mirror) end)
    mirror
  end

  # Polls `fun` until it is true, for at most 5 s.
  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(10) || eventually(fun, deadline)
    end
  end

  # One raw request line; returns the status code the mirror answers.
  defp raw(mirror, request_line) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
    :ok = :gen_tcp.send(sock, request_line <> "\r\nhost: 127.0.0.1\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
    [_, code | _] = String.split(response, " ", parts: 3)
    String.to_integer(code)
  end

  # Sends `bytes` as they are; returns the whole response, read until the
  # mirror closes the connection.
  defp raw_bytes(mirror, bytes) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
    :gen_tcp.send(sock, bytes)
    response = recv_all(sock, "")
    :gen_tcp.close(sock)
    response
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, _} -> acc
    end
  end

  defp code(response) do
    [_, code | _] = String.split(response, " ", parts: 3)
    String.to_integer(code)
  end

  test "serves every route of the portal layout unchanged", %{dir: dir} do
    mirror = start!(dir)
    assert mirror.url == "http://127.0.0.1:#{mirror.port}"

    for {rel, bytes} <- @layout do
      assert {:ok, ^bytes} = HTTP.get(mirror.url <> "/" <> rel, 5_000)
    end

    assert length(Mirror.requests(mirror)) == map_size(@layout)
    refute Enum.any?(Mirror.requests(mirror), & &1.mutated)
  end

  test "anything outside the layout is 404 and never reads a file", %{dir: dir} do
    mirror = start!(dir)

    for path <- [
          "/secret.txt",
          "/files/../secret.txt",
          "/files/%2e%2e/secret.txt",
          "//root.json",
          "/root.json?x=1",
          "/manifests/Jason.json",
          "/files/" <> String.duplicate("a", 63)
        ] do
      assert raw(mirror, "GET #{path} HTTP/1.1") == 404, path
    end

    assert Enum.all?(Mirror.requests(mirror), &(&1.status == 404 and not &1.mutated))
  end

  test "no request escapes the snapshot directory", %{dir: dir, tmp: tmp} do
    mirror = start!(dir)

    for target <- [
          "/../outside.txt",
          "/files/../../outside.txt",
          "/manifests/../../outside.txt",
          "/%2e%2e/outside.txt",
          "/files/%2e%2e%2f%2e%2e%2foutside.txt",
          "/files/%2E%2E/%2E%2E/outside.txt",
          "/files/..%2f..%2foutside.txt",
          "/" <> Path.join(tmp, "outside.txt"),
          Path.join(tmp, "outside.txt"),
          "/root.json%00",
          "/root.json%00/../outside.txt",
          "/root.json\0",
          "/files/" <> @sha <> "\0../outside.txt",
          "http://127.0.0.1/root.json",
          "file:///etc/passwd",
          "*",
          "/manifests/jason.json/../../outside.txt",
          "/files\\..\\..\\outside.txt"
        ] do
      response = raw_bytes(mirror, "GET #{target} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
      assert code(response) in [400, 404], inspect(target)
      refute response =~ "secret", inspect(target)
    end

    assert Enum.all?(Mirror.requests(mirror), &(&1.status in [400, 404] and not &1.mutated))
  end

  test "a symlink in the snapshot pointing outside it is not followed", %{dir: dir, tmp: tmp} do
    File.rm!(Path.join(dir, "root.json"))
    :ok = File.ln_s(Path.join(tmp, "outside.txt"), Path.join(dir, "root.json"))
    mirror = start!(dir)

    assert raw(mirror, "GET /root.json HTTP/1.1") == 404
  end

  test "a method other than GET is 405, a malformed request 400", %{dir: dir} do
    mirror = start!(dir)
    assert raw(mirror, "POST /root.json HTTP/1.1") == 405
    assert raw(mirror, "this is not http") == 400
    assert {:ok, _} = HTTP.get(mirror.url <> "/root.json", 5_000)
  end

  test "an overlong request line, header line or header count is refused", %{dir: dir} do
    mirror = start!(dir)

    long_path = "/files/" <> String.duplicate("a", 2_000)
    assert code(raw_bytes(mirror, "GET #{long_path} HTTP/1.1\r\n\r\n")) == 414

    huge_line = "/" <> String.duplicate("a", 20_000)
    assert code(raw_bytes(mirror, "GET #{huge_line} HTTP/1.1\r\n\r\n")) == 400

    long_header = "x-big: " <> String.duplicate("b", 20_000) <> "\r\n"
    assert code(raw_bytes(mirror, "GET /root.json HTTP/1.1\r\n" <> long_header <> "\r\n")) == 400

    many = Enum.map_join(1..200, "", &"x-h#{&1}: v\r\n")
    assert code(raw_bytes(mirror, "GET /root.json HTTP/1.1\r\n" <> many <> "\r\n")) == 400

    assert {:ok, _} = HTTP.get(mirror.url <> "/root.json", 5_000)
  end

  test "a client that sends nothing, or trickles headers, is cut off", %{dir: dir} do
    mirror = start!(dir, request_timeout_ms: 300)

    {:ok, idle} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
    started = System.monotonic_time(:millisecond)
    response = recv_all(idle, "")
    assert code(response) == 408
    assert System.monotonic_time(:millisecond) - started < 2_000

    # A header every 100 ms never finishes inside 300 ms in total.
    {:ok, slow} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
    :ok = :gen_tcp.send(slow, "GET /root.json HTTP/1.1\r\n")

    trickle =
      Task.async(fn ->
        for i <- 1..20 do
          Process.sleep(100)
          :gen_tcp.send(slow, "x-h#{i}: v\r\n")
        end
      end)

    started = System.monotonic_time(:millisecond)
    assert code(recv_all(slow, "")) == 408
    assert System.monotonic_time(:millisecond) - started < 2_000
    Task.shutdown(trickle, :brutal_kill)

    assert {:ok, _} = HTTP.get(mirror.url <> "/root.json", 5_000)
  end

  test "connections past the cap are answered 503 at once", %{dir: dir} do
    mirror = start!(dir, max_connections: 2, request_timeout_ms: 2_000)

    held =
      for _ <- 1..2 do
        {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
        s
      end

    # The acceptor takes connections in order, so both are held by the
    # time it takes the third.
    assert code(raw_bytes(mirror, "GET /root.json HTTP/1.1\r\n\r\n")) == 503

    # Their handlers end once they see the close; until the acceptor has
    # reaped them a new connection may still be one past the cap.
    Enum.each(held, &:gen_tcp.close/1)
    assert eventually(fn -> match?({:ok, _}, HTTP.get(mirror.url <> "/root.json", 5_000)) end)
  end

  test "a client that hangs up mid-request does not take the mirror down", %{dir: dir} do
    mirror = start!(dir)

    for partial <- ["", "GET /root.json HTTP/1.1\r\n", "GET /ro"] do
      {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
      :gen_tcp.send(s, partial)
      :gen_tcp.close(s)
    end

    # A client that asks and leaves before the answer.
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
    :gen_tcp.send(s, "GET /files/#{@sha} HTTP/1.1\r\n\r\n")
    :gen_tcp.close(s)

    # The last one is logged once its handler has read the whole head.
    assert eventually(fn ->
             Enum.any?(Mirror.requests(mirror), &(&1.path == "files/#{@sha}"))
           end)

    assert Process.alive?(mirror.pid)
    assert {:ok, _} = HTTP.get(mirror.url <> "/root.json", 5_000)
  end

  test "listens on 127.0.0.1 only", %{dir: dir} do
    mirror = start!(dir)

    {:ok, addrs} = :inet.getifaddrs()

    others =
      for {_name, opts} <- addrs,
          {:addr, {a, _, _, _} = ip} <- opts,
          a != 127,
          do: ip

    for ip <- others do
      # Refused, or no route from that interface at all: never connected.
      assert {:error, reason} = :gen_tcp.connect(ip, mirror.port, [], 2_000)
      assert reason in [:econnrefused, :eaddrnotavail, :ehostunreach, :enetunreach], inspect(ip)
    end

    assert {:ok, {{127, 0, 0, 1}, port}} = Mirror.sockname(mirror)
    assert port == mirror.port
  end

  test "stop/1 closes the port", %{dir: dir} do
    {:ok, mirror} = Mirror.start(dir)
    assert :ok = Mirror.stop(mirror)
    refute Process.alive?(mirror.pid)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [], 2_000)
  end

  test "the transform answers per request, and mutated responses are logged", %{dir: dir} do
    t = fn
      "v2/manifests/jason.json", _bytes -> {500, ""}
      _path, bytes -> {200, bytes}
    end

    mirror = start!(dir, transform: t)

    assert {:error, reason} = HTTP.get(mirror.url <> "/v2/manifests/jason.json", 5_000)
    assert reason =~ "500"
    assert {:ok, _} = HTTP.get(mirror.url <> "/batch.json", 5_000)

    assert [
             %{method: "GET", path: "v2/manifests/jason.json", status: 500, mutated: true},
             %{method: "GET", path: "batch.json", status: 200, mutated: false}
           ] = Mirror.requests(mirror)
  end

  test "a routed path the snapshot lacks is 404 without calling the transform", %{dir: dir} do
    test = self()

    mirror =
      start!(dir,
        transform: fn p, b ->
          send(test, {:called, p})
          {200, b}
        end
      )

    assert raw(mirror, "GET /v2/manifests/plug.json HTTP/1.1") == 404
    refute_received {:called, _}
  end

  test "a transform that raises is a 500 and the mirror keeps serving", %{dir: dir} do
    mirror =
      start!(dir,
        transform: fn
          "root.json", _ -> raise "boom"
          _, b -> {200, b}
        end
      )

    assert raw(mirror, "GET /root.json HTTP/1.1") == 500
    assert {:ok, _} = HTTP.get(mirror.url <> "/batch.json", 5_000)
  end

  test "a transform that throws or exits is a logged 500", %{dir: dir} do
    mirror =
      start!(dir,
        transform: fn
          "root.json", _ -> throw(:boom)
          "batch.json", _ -> exit(:boom)
          _, b -> {200, b}
        end
      )

    assert raw(mirror, "GET /root.json HTTP/1.1") == 500
    assert raw(mirror, "GET /batch.json HTTP/1.1") == 500
    assert {:ok, _} = HTTP.get(mirror.url <> "/batches/7.json", 5_000)

    assert [
             %{path: "root.json", status: 500, mutated: true},
             %{path: "batch.json", status: 500, mutated: true},
             %{path: "batches/7.json", status: 200, mutated: false}
           ] = Mirror.requests(mirror)
  end

  test "a transform answering a bad shape is a 500", %{dir: dir} do
    mirror = start!(dir, transform: fn _, _ -> :nope end)
    assert raw(mirror, "GET /root.json HTTP/1.1") == 500
    assert [%{status: 500, mutated: true}] = Mirror.requests(mirror)
  end

  # The response to one GET, read until the mirror closes: `{head, body}`,
  # `head` the status line and headers as a map of lowercase names.
  defp exchange(mirror, path) do
    response = raw_bytes(mirror, "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
    split(response)
  end

  defp split(""), do: {nil, ""}

  defp split(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status | lines] = String.split(head, "\r\n")

    headers =
      Map.new(lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    {%{status: code(status), headers: headers}, body}
  end

  describe "response contract v2" do
    test "{status, headers, body} sends the headers; the mirror owns content-length",
         %{dir: dir} do
      mirror =
        start!(dir,
          transform: fn _, bytes ->
            {200, [{"Content-Type", "text/plain"}, {"x-a", "1"}], bytes}
          end
        )

      assert {%{status: 200, headers: h}, ~s({"root":1})} = exchange(mirror, "/root.json")
      assert h["content-type"] == "text/plain"
      assert h["x-a"] == "1"
      assert h["content-length"] == "10"
      assert h["connection"] == "close"
      # Even with the same status and bytes, a v2 shape is a change.
      assert [%{status: 200, mutated: true}] = Mirror.requests(mirror)
    end

    test "headers the mirror owns, or that would split the response, are a 500", %{dir: dir} do
      for headers <- [
            [{"content-length", "1"}],
            [{"Connection", "keep-alive"}],
            [{"transfer-encoding", "chunked"}],
            [{"x-a", "1\r\nx-b: 2"}],
            [{"x a", "1"}],
            [{:x, "1"}],
            List.duplicate({"x-a", "1"}, 33),
            [{"x-a", String.duplicate("v", 4097)}],
            :nope
          ] do
        mirror = start!(dir, transform: fn _, b -> {200, headers, b} end)
        assert {%{status: 500}, _} = exchange(mirror, "/root.json"), inspect(headers)
        assert [%{status: 500, mutated: true}] = Mirror.requests(mirror)
      end
    end

    test "a redirect answers a 3xx with location and no body", %{dir: dir} do
      mirror =
        start!(dir, transform: fn _, _ -> {:redirect, 302, "http://127.0.0.1:1/batch.json"} end)

      assert {%{status: 302, headers: h}, ""} = exchange(mirror, "/batch.json")
      assert h["location"] == "http://127.0.0.1:1/batch.json"
      assert h["content-length"] == "0"
      assert [%{status: 302, mutated: true}] = Mirror.requests(mirror)

      for bad <- [{:redirect, 200, "http://x"}, {:redirect, 301, "a\nb"}, {:redirect, 301, :x}] do
        mirror = start!(dir, transform: fn _, _ -> bad end)
        assert {%{status: 500}, _} = exchange(mirror, "/batch.json"), inspect(bad)
      end
    end

    test "a stream sends its chunks with the delay, no content-length, then closes",
         %{dir: dir} do
      mirror = start!(dir, transform: fn _, _ -> {:stream, 200, ["a", "b", "c"], 60} end)
      t0 = System.monotonic_time(:millisecond)

      assert {%{status: 200, headers: h}, "abc"} = exchange(mirror, "/batch.json")
      assert System.monotonic_time(:millisecond) - t0 >= 150
      refute Map.has_key?(h, "content-length")
      assert [%{status: 200, mutated: true}] = Mirror.requests(mirror)
    end

    test "a stream is cut at the mirror's byte and time caps", %{dir: dir} do
      chunks = List.duplicate(String.duplicate("x", 100), 10)

      mirror =
        start!(dir, transform: fn _, _ -> {:stream, 200, chunks, 0} end, stream_max_bytes: 250)

      assert {%{status: 200}, body} = exchange(mirror, "/batch.json")
      assert byte_size(body) <= 250

      mirror =
        start!(dir, transform: fn _, _ -> {:stream, 200, chunks, 100} end, stream_max_ms: 250)

      t0 = System.monotonic_time(:millisecond)
      assert {%{status: 200}, body} = exchange(mirror, "/batch.json")
      assert byte_size(body) < 1000
      assert System.monotonic_time(:millisecond) - t0 < 1_000
    end

    test "a truncated response declares the whole body and sends n bytes", %{dir: dir} do
      mirror = start!(dir, transform: fn _, bytes -> {:truncate, 200, bytes, 3} end)

      assert {%{status: 200, headers: h}, ~s({"r)} = exchange(mirror, "/root.json")
      assert h["content-length"] == "10"
      assert [%{status: 200, mutated: true}] = Mirror.requests(mirror)

      for n <- [10, 11, -1, :x] do
        mirror = start!(dir, transform: fn _, bytes -> {:truncate, 200, bytes, n} end)
        assert {%{status: 500}, _} = exchange(mirror, "/root.json"), inspect(n)
      end
    end

    test ":close closes without a response, logged as status 0 and mutated", %{dir: dir} do
      mirror = start!(dir, transform: fn _, _ -> :close end)
      assert {nil, ""} = exchange(mirror, "/root.json")
      assert {:error, _} = HTTP.get(mirror.url <> "/root.json", 5_000)
      assert [%{status: 0, mutated: true}, %{status: 0, mutated: true}] = Mirror.requests(mirror)
    end

    test "an endless response stops at the byte cap", %{dir: dir} do
      mirror =
        start!(dir,
          transform: fn _, _ -> {:endless, 200, String.duplicate("z", 64), 0} end,
          stream_max_bytes: 4096
        )

      assert {%{status: 200, headers: h}, body} = exchange(mirror, "/batch.json")
      refute Map.has_key?(h, "content-length")
      assert byte_size(body) == 4096
      assert [%{status: 200, mutated: true}] = Mirror.requests(mirror)
    end

    test "an endless response stops at the time cap", %{dir: dir} do
      mirror =
        start!(dir,
          transform: fn _, _ -> {:endless, 200, "z", 20} end,
          stream_max_ms: 200
        )

      t0 = System.monotonic_time(:millisecond)
      assert {%{status: 200}, body} = exchange(mirror, "/batch.json")
      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed >= 150 and elapsed < 1_500
      assert byte_size(body) in 1..20
    end

    test "an endless response ends when the client hangs up; the mirror keeps serving",
         %{dir: dir} do
      mirror =
        start!(dir,
          transform: fn
            "batch.json", _ -> {:endless, 200, String.duplicate("z", 1024), 1}
            _, b -> {200, b}
          end
        )

      {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, mirror.port, [:binary, active: false])
      :ok = :gen_tcp.send(sock, "GET /batch.json HTTP/1.1\r\n\r\n")
      assert {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
      :gen_tcp.close(sock)

      assert {:ok, _} = HTTP.get(mirror.url <> "/root.json", 5_000)
    end

    test "malformed stream and endless shapes are a 500", %{dir: dir} do
      for bad <- [
            {:stream, 200, "abc", 0},
            {:stream, 200, [:a], 0},
            {:stream, 200, ["a"], -1},
            {:stream, 200, ["a"], 60_001},
            {:stream, 99, ["a"], 0},
            {:endless, 200, "", 0},
            {:endless, 200, "z", -1},
            {:endless, 200, String.duplicate("z", 1024 * 1024 + 1), 0},
            {:endless, 200, :z, 0}
          ] do
        mirror = start!(dir, transform: fn _, _ -> bad end)
        assert {%{status: 500}, _} = exchange(mirror, "/batch.json"), inspect(bad)
        assert [%{status: 500, mutated: true}] = Mirror.requests(mirror)
      end
    end

    test "a malformed shape or a crashing transform is logged as a transform_error",
         %{dir: dir} do
      mirror =
        start!(dir,
          transform: fn
            "root.json", b -> {:truncate, 200, b, byte_size(b)}
            "batch.json", _ -> raise "typo"
            _, b -> {200, b}
          end
        )

      assert {%{status: 500}, _} = exchange(mirror, "/root.json")
      assert {%{status: 500}, _} = exchange(mirror, "/batch.json")
      assert {%{status: 200}, _} = exchange(mirror, "/batches/7.json")

      assert [
               %{path: "root.json", status: 500, transform_error: e1},
               %{path: "batch.json", status: 500, transform_error: e2},
               served
             ] = Mirror.requests(mirror)

      assert e1 =~ ":truncate"
      assert e2 =~ "typo"
      refute Map.has_key?(served, :transform_error)
    end

    test "the caps default to 64 MiB and 120 s" do
      assert Mirror.stream_limits() == %{max_bytes: 64 * 1024 * 1024, max_ms: 120_000}
    end
  end

  test "route/1 maps request paths to snapshot paths" do
    assert Mirror.route("/root.json") == {:ok, "root.json"}
    assert Mirror.route("/batches/12.json") == {:ok, "batches/12.json"}

    assert Mirror.route("/v2/manifests/nerves_pack.json") ==
             {:ok, "v2/manifests/nerves_pack.json"}

    assert Mirror.route("/files/" <> @sha) == {:ok, "files/" <> @sha}
    assert Mirror.route("/batches/x.json") == :error
    assert Mirror.route("/v3/manifests/jason.json") == :error
    assert Mirror.route("root.json") == :error
    assert Mirror.route("/root.json\0") == :error
    assert Mirror.route("/root.json\n") == :error
    assert Mirror.route("/manifests/../root.json") == :error
  end

  test "transforms are data: a module and its args" do
    assert Transform.valid?({Identity, %{}})
    assert Transform.valid?({Status, %{paths: ["root.json"], status: 503}})
    refute Transform.valid?({String, %{}})
    refute Transform.valid?({Identity, []})
    refute Transform.valid?(Identity)

    fun = Transform.fun({Status, %{paths: ["root.json"], status: 503}})
    assert fun.("root.json", "x") == {503, ""}
    assert fun.("batch.json", "y") == {200, "y"}
    assert Transform.fun({Identity, %{}}).("root.json", "x") == {200, "x"}
  end

  test "a transform gets the case's runtime context under :case" do
    fun = Transform.fun({ChainTest.TestTransform, %{mirrors: 2}}, %{mirror: 1, second_url: "u"})
    assert fun.("batch.json", "x") == {:redirect, 302, "u/batch.json"}
    fun = Transform.fun({ChainTest.TestTransform, %{mirrors: 2}}, %{mirror: 2, second_url: nil})
    assert fun.("batch.json", "x") == {200, "x"}
  end

  test "mirrors/1 and needs/1 read the transform's args; :case is reserved" do
    assert Transform.mirrors({Identity, %{}}) == 1
    assert Transform.mirrors({ChainTest.TestTransform, %{mirrors: 2}}) == 2
    assert Transform.needs({Identity, %{}}) == []
    assert Transform.needs({ChainTest.TestTransform, %{needs: [:old]}}) == [:old]

    assert Transform.valid?({ChainTest.TestTransform, %{mirrors: 2, needs: [:previous, :old]}})
    refute Transform.valid?({ChainTest.TestTransform, %{mirrors: 3}})
    refute Transform.valid?({ChainTest.TestTransform, %{mirrors: 0}})
    refute Transform.valid?({ChainTest.TestTransform, %{needs: [:newer]}})
    refute Transform.valid?({ChainTest.TestTransform, %{needs: :old}})
    refute Transform.valid?({Identity, %{case: %{}}})
  end
end
