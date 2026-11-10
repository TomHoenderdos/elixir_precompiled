# SPDX-FileCopyrightText: 2025 Frank Hunleth
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.TestServer do
  @moduledoc false
  use Plug.Router

  plug(:record)
  plug(:match)
  plug(:dispatch)

  # 4000 by default; TEST_SERVER_PORT moves it when something else holds 4000.
  @spec port() :: pos_integer()
  def port() do
    case System.get_env("TEST_SERVER_PORT") do
      nil -> 4000
      p -> String.to_integer(p)
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  # `port:` starts another listener, e.g. a content origin (CDN) beside
  # the source; each listener is a separate child.
  def child_spec(options) do
    port = Keyword.get(options, :port, port())
    bandit_opts = [plug: __MODULE__, port: port, ip: :loopback, startup_log: false]
    %{id: {__MODULE__, port}, start: {Bandit, :start_link, [bandit_opts]}}
  end

  defp record(conn, _opts) do
    Precompiled.Fixture.record(%{
      port: listener_port(conn),
      path: conn.request_path,
      if_none_match: List.first(get_req_header(conn, "if-none-match"))
    })

    conn
  end

  # Echoes the Proxy-Authorization header: "" when none was sent.
  get "/proxy-auth" do
    send_resp(conn, 200, List.first(get_req_header(conn, "proxy-authorization"), ""))
  end

  # The port this listener accepted on: conn.port follows the Host header,
  # which names the origin, not the proxy, on a proxied request.
  defp listener_port(conn), do: get_sock_data(conn).port

  get "/always-304" do
    send_resp(conn, 304, "")
  end

  get "/etag" do
    conn = put_resp_header(conn, "etag", ~s("v1"))

    if get_req_header(conn, "if-none-match") == [~s("v1")],
      do: send_resp(conn, 304, ""),
      else: send_resp(conn, 200, "tagged")
  end

  get "/text" do
    send_resp(conn, 200, "hello nerves")
  end

  get "/binary" do
    # 1 KB of recognizable binary content
    body = :binary.copy(<<0xDE, 0xAD, 0xBE, 0xEF>>, 256)

    conn
    |> put_resp_content_type("application/octet-stream")
    |> send_resp(200, body)
  end

  get "/stall" do
    conn = send_chunked(conn, 200)
    Process.sleep(2000)
    {:ok, conn} = chunk(conn, "done")
    conn
  end

  # One small chunk every 300 ms for 2 s: never idle long enough for the
  # inactivity timer, so only the overall deadline stops it.
  get "/drip" do
    conn = send_chunked(conn, 200)
    drip(conn, 7)
  end

  # 4 KiB in 256-byte chunks with no content-length.
  get "/chunked" do
    conn = send_chunked(conn, 200)

    Enum.reduce_while(1..16, conn, fn _, conn ->
      case chunk(conn, :binary.copy("x", 256)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  get "/precompiled/root.json" do
    serve_json(conn, Precompiled.Fixture.get(:root))
  end

  get "/precompiled/batch.json" do
    serve_json(conn, Precompiled.Fixture.get(:batch))
  end

  get "/precompiled/manifests/:name" do
    name = String.replace_suffix(name, ".json", "")

    case get_in(Precompiled.Fixture.get(:manifests) || %{}, [name]) do
      nil ->
        send_resp(conn, 404, "not found")

      bytes ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, corrupt(conn, bytes))
    end
  end

  # Content-addressed manifests: `:file` is one segment, so this never
  # clashes with the by-name route below.
  get "/precompiled/v2/manifests/by-sha/:file" do
    sha = String.replace_suffix(file, ".json", "")
    docs = Precompiled.Fixture.get(:manifests_v2) || %{}

    case Enum.find(docs, fn {_name, bytes} -> Precompiled.Fixture.sha(bytes) == sha end) do
      nil ->
        send_resp(conn, 404, "not found")

      {_name, bytes} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, corrupt(conn, bytes))
    end
  end

  get "/precompiled/v2/manifests/:name" do
    name = String.replace_suffix(name, ".json", "")

    case get_in(Precompiled.Fixture.get(:manifests_v2) || %{}, [name]) do
      nil ->
        send_resp(conn, 404, "not found")

      bytes ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, corrupt(conn, bytes))
    end
  end

  get "/precompiled/files/:sha" do
    case get_in(Precompiled.Fixture.get(:files) || %{}, [sha]) do
      nil ->
        send_resp(conn, 404, "not found")

      bytes ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, corrupt(conn, bytes))
    end
  end

  get "/precompiled/redirect/*rest" do
    conn
    |> put_resp_header(
      "location",
      "http://127.0.0.2:#{port()}/precompiled/" <> Enum.join(rest, "/")
    )
    |> send_resp(302, "")
  end

  get "/precompiled/redirect_port/*rest" do
    conn
    |> put_resp_header(
      "location",
      "http://127.0.0.1:#{port() + 1}/precompiled/" <> Enum.join(rest, "/")
    )
    |> send_resp(302, "")
  end

  # To a second listener (start it with `port: port() + 2`): a content
  # origin the signed batch may allow.
  get "/precompiled/redirect_cdn/*rest" do
    conn
    |> put_resp_header(
      "location",
      "http://127.0.0.1:#{port() + 2}/precompiled/" <> Enum.join(rest, "/")
    )
    |> send_resp(302, "")
  end

  # The same, naming the content origin's host in upper case.
  get "/precompiled/redirect_cdn_upper/*rest" do
    conn
    |> put_resp_header(
      "location",
      "http://LOCALHOST:#{port() + 2}/precompiled/" <> Enum.join(rest, "/")
    )
    |> send_resp(302, "")
  end

  get "/precompiled/redirect_same/*rest" do
    conn
    |> put_resp_header("location", "/" <> Enum.join(rest, "/"))
    |> send_resp(302, "")
  end

  defp drip(conn, 0), do: conn

  defp drip(conn, n) do
    Process.sleep(300)

    case chunk(conn, "x") do
      {:ok, conn} -> drip(conn, n - 1)
      {:error, _} -> conn
    end
  end

  defp serve_json(conn, nil), do: send_resp(conn, 503, "none")

  defp serve_json(conn, map) do
    body = map |> :json.encode() |> IO.iodata_to_binary()
    etag = ~s("#{Precompiled.Fixture.sha(body)}")
    conn = put_resp_content_type(conn, "application/json")

    cond do
      Precompiled.Fixture.get(:etags) == false ->
        send_resp(conn, 200, body)

      etag in get_req_header(conn, "if-none-match") ->
        conn |> put_resp_header("etag", etag) |> send_resp(304, "")

      true ->
        conn |> put_resp_header("etag", etag) |> send_resp(200, body)
    end
  end

  # Fixture.corrupt_port/1: a listener that serves wrong bytes.
  defp corrupt(conn, <<c, rest::binary>>) do
    if Precompiled.Fixture.get(:corrupt_port) == listener_port(conn),
      do: <<c + 1, rest::binary>>,
      else: <<c, rest::binary>>
  end

  defp corrupt(_conn, bytes), do: bytes

  match _ do
    conn
    |> send_resp(404, "Not Found")
    |> Plug.Conn.halt()
  end
end
