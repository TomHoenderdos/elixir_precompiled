# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Fixture do
  @moduledoc false
  # A fake signed precompiled source: keys, root, batch, manifests and files
  # kept in an Agent that ElixirPrecompiled.TestServer serves under /precompiled.

  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link(), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @spec new(String.t(), keyword()) :: map()
  def new(tmp_dir, opts \\ []) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    keyid = Base.encode16(:crypto.hash(:sha256, public), case: :lower)
    key = %{keyid: keyid, public: public, private: private}
    expires = Keyword.get(opts, :root_expires, "2030-01-01T00:00:00Z")
    root = root_payload(keyid, public, expires, Keyword.get(opts, :root_version, 1))
    root_env = sign(root, [key])
    root_path = Path.join(tmp_dir, "root.json")
    File.write!(root_path, :json.encode(root_env))
    reset()
    put(:root, root_env)
    %{key: key, root_env: root_env, root_path: root_path}
  end

  @spec root_payload(String.t(), binary(), String.t(), pos_integer()) :: iodata()
  def root_payload(keyid, public, expires, version) do
    :json.encode(%{
      "version" => version,
      "expires" => expires,
      "keys" => %{keyid => %{"type" => "ed25519", "public" => b64(public)}},
      "roles" => %{
        "root" => %{"keyids" => [keyid], "threshold" => 1},
        "batch" => %{"keyids" => [keyid], "threshold" => 1}
      }
    })
    |> IO.iodata_to_binary()
  end

  @spec serve_root(map(), map()) :: map()
  def serve_root(fixture, root_env), do: put(:root, root_env) && fixture

  # `format: 2` (the default) stores each package as a format-2 document
  # under :manifests_v2, named by the batch's "manifests_v2" map next to an
  # empty "manifests"; `format: 1` stores today's documents under :manifests
  # and the batch carries no "manifests_v2".
  @spec publish(map(), map(), keyword()) :: map()
  def publish(fixture, packages, opts \\ []) do
    {store, docs} =
      case Keyword.get(opts, :format, 2) do
        2 -> {:manifests_v2, Map.new(packages, fn {n, m} -> {n, Map.put_new(m, "format", 2)} end)}
        1 -> {:manifests, packages}
      end

    hashes =
      Map.new(docs, fn {name, manifest} ->
        bytes = manifest |> :json.encode() |> IO.iodata_to_binary()
        put_in_map(store, name, bytes)
        {name, sha(bytes)}
      end)

    maps =
      case store do
        :manifests_v2 -> %{"manifests" => %{}, "manifests_v2" => hashes}
        :manifests -> %{"manifests" => hashes}
      end

    payload =
      %{
        "version" => 1,
        "sequence" => Keyword.get(opts, :sequence, 1),
        "issued" => "2026-10-21T00:00:00Z",
        "expires" => Keyword.get(opts, :expires, "2030-01-01T00:00:00Z")
      }
      |> Map.merge(maps)
      |> Map.merge(Keyword.get(opts, :batch_extra, %{}))
      |> :json.encode()
      |> IO.iodata_to_binary()

    put(:batch, sign(payload, Keyword.get(opts, :signers, [fixture.key])))
    fixture
  end

  @spec file(map(), binary()) :: String.t()
  def file(_fixture, bytes) do
    s = sha(bytes)
    put_in_map(:files, s, bytes)
    s
  end

  @spec tamper_manifest(map(), String.t()) :: :ok
  def tamper_manifest(_fixture, name) do
    store =
      Enum.find([:manifests_v2, :manifests], fn store ->
        Agent.get(__MODULE__, &get_in(&1, [store, name])) != nil
      end)

    if store == nil, do: raise(ArgumentError, "no manifest #{name} to tamper")

    Agent.update(__MODULE__, fn st ->
      update_in(st, [store, name], fn <<c, rest::binary>> -> <<c + 1, rest::binary>> end)
    end)
  end

  @spec sign(iodata(), list(map())) :: map()
  def sign(payload, keys) do
    %{
      "payload" => b64(payload),
      "signatures" =>
        for k <- keys do
          %{
            "keyid" => k.keyid,
            "sig" => b64(:crypto.sign(:eddsa, :none, payload, [k.private, :ed25519]))
          }
        end
    }
  end

  @spec get(atom()) :: term()
  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  @spec sha(binary()) :: String.t()
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @spec b64(binary()) :: String.t()
  def b64(bin), do: Base.url_encode64(bin, padding: false)

  @spec base_url() :: String.t()
  def base_url(), do: "http://127.0.0.1:#{ElixirPrecompiled.TestServer.port()}/precompiled"

  @spec reset() :: :ok
  defp reset(),
    do: Agent.update(__MODULE__, fn _ -> %{manifests: %{}, manifests_v2: %{}, files: %{}} end)

  @spec put(atom(), term()) :: :ok
  defp put(k, v), do: Agent.update(__MODULE__, &Map.put(&1, k, v))

  @spec put_in_map(atom(), term(), term()) :: :ok
  defp put_in_map(k, key, v), do: Agent.update(__MODULE__, &put_in(&1, [k, key], v))
end
