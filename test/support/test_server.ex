# SPDX-FileCopyrightText: 2025 Frank Hunleth
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.TestServer do
  @moduledoc false
  use Plug.Router

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
  def child_spec(_options) do
    bandit_opts = [plug: __MODULE__, port: port()]

    %{
      id: __MODULE__,
      start: {Bandit, :start_link, [bandit_opts]}
    }
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

  get "/precompiled/root.json" do
    serve_json(conn, NervesPrecompiled.Fixture.get(:root))
  end

  get "/precompiled/batch.json" do
    serve_json(conn, NervesPrecompiled.Fixture.get(:batch))
  end

  get "/precompiled/manifests/:name" do
    name = String.replace_suffix(name, ".json", "")

    case get_in(NervesPrecompiled.Fixture.get(:manifests) || %{}, [name]) do
      nil -> send_resp(conn, 404, "not found")
      bytes -> conn |> put_resp_content_type("application/json") |> send_resp(200, bytes)
    end
  end

  get "/precompiled/files/:sha" do
    case get_in(NervesPrecompiled.Fixture.get(:files) || %{}, [sha]) do
      nil -> send_resp(conn, 404, "not found")
      bytes -> conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, bytes)
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

  get "/precompiled/redirect_same/*rest" do
    conn
    |> put_resp_header("location", "/" <> Enum.join(rest, "/"))
    |> send_resp(302, "")
  end

  defp serve_json(conn, nil), do: send_resp(conn, 503, "none")

  defp serve_json(conn, map),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, :json.encode(map))

  match _ do
    conn
    |> send_resp(404, "Not Found")
    |> Plug.Conn.halt()
  end
end
