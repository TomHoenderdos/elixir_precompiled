# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Fixture do
  @moduledoc false
  # A fake signed precompiled source: keys, root, batch, manifests and files
  # kept in an Agent that Precompiled.TestServer serves under /precompiled.

  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link(), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @spec new(String.t(), keyword()) :: map()
  def new(tmp_dir, opts \\ []) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    keyid = Base.encode16(:crypto.hash(:sha256, public), case: :lower)
    key = %{keyid: keyid, public: public, private: private}
    expires = Keyword.get(opts, :root_expires, "2030-01-01T00:00:00Z")
    offline_key = if Keyword.get(opts, :offline_key, false), do: generate_key()
    version = Keyword.get(opts, :root_version, 1)
    root = root_payload(keyid, public, expires, version, offline_key)
    root_env = sign(root, [key])
    root_path = Path.join(tmp_dir, "root.json")
    File.write!(root_path, :json.encode(root_env))
    reset()
    put(:root, root_env)
    %{key: key, root_env: root_env, root_path: root_path, offline_key: offline_key}
  end

  @spec root_payload(String.t(), binary(), String.t(), pos_integer()) :: binary()
  def root_payload(keyid, public, expires, version),
    do: root_payload(keyid, public, expires, version, nil)

  # `offline_key`, when given, joins `keys` and is the one key of an
  # `offline` role.
  @spec root_payload(String.t(), binary(), String.t(), pos_integer(), map() | nil) :: binary()
  def root_payload(keyid, public, expires, version, offline_key) do
    keys = %{keyid => %{"type" => "ed25519", "public" => b64(public)}}

    roles = %{
      "root" => %{"keyids" => [keyid], "threshold" => 1},
      "batch" => %{"keyids" => [keyid], "threshold" => 1}
    }

    {keys, roles} =
      case offline_key do
        nil ->
          {keys, roles}

        k ->
          {Map.put(keys, k.keyid, %{"type" => "ed25519", "public" => b64(k.public)}),
           Map.put(roles, "offline", %{"keyids" => [k.keyid], "threshold" => 1})}
      end

    :json.encode(%{"version" => version, "expires" => expires, "keys" => keys, "roles" => roles})
    |> IO.iodata_to_binary()
  end

  # A bundle's offline.json: `packages_v2` (name => manifest sha) signed by
  # `opts[:signers]`, the fixture's offline key by default.
  @spec offline_document(map(), map(), keyword()) :: binary()
  def offline_document(fixture, packages_v2, opts \\ []) do
    :json.encode(%{
      "version" => 1,
      "kind" => "offline",
      "sequence" => Keyword.get(opts, :sequence, 1),
      "issued" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "manifests" => %{},
      "manifests_v2" => packages_v2
    })
    |> IO.iodata_to_binary()
    |> sign(Keyword.get(opts, :signers) || [fixture.offline_key])
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp generate_key() do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{keyid: sha(public), public: public, private: private}
  end

  @spec serve_root(map(), map()) :: map()
  def serve_root(fixture, root_env), do: put(:root, root_env) && fixture

  # Rotates the served root to a freshly generated key, co-signed by the
  # fixture's original key so it chains from whatever root the caller
  # already trusts — the setup "a newer root signed by the current root is
  # adopted and cached" builds inline. Returns the new key, in case a test
  # needs it to sign a later batch or a further rotation.
  @spec rotate_root(map(), keyword()) :: map()
  def rotate_root(fixture, opts) do
    version = Keyword.fetch!(opts, :version)
    expires = Keyword.get(opts, :expires, "2031-01-01T00:00:00Z")
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    k2 = %{keyid: sha(pub), public: pub, private: priv}
    root = root_payload(k2.keyid, pub, expires, version)
    serve_root(fixture, sign(root, [fixture.key, k2]))
    k2
  end

  # `format: 2` (the default) stores each package as a format-2 document
  # under :manifests_v2, named by the batch's "manifests_v2" map next to an
  # empty "manifests"; `format: 1` stores today's documents under :manifests
  # and the batch carries no "manifests_v2". `merge: true` keeps the other
  # format's already-published names in the batch instead of replacing them
  # with an empty map, so a second `publish/3` call can add packages in one
  # format alongside packages an earlier call already published in the other.
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

    maps = batch_maps(store, hashes, Keyword.get(opts, :merge, false))

    payload =
      %{
        "version" => 1,
        "sequence" => Keyword.get(opts, :sequence, 1),
        "issued" => Keyword.get(opts, :issued, DateTime.utc_now() |> DateTime.to_iso8601()),
        "expires" =>
          Keyword.get(
            opts,
            :expires,
            DateTime.utc_now() |> DateTime.add(7 * 86_400, :second) |> DateTime.to_iso8601()
          )
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.merge(maps)
      |> Map.merge(Keyword.get(opts, :batch_extra, %{}))
      |> :json.encode()
      |> IO.iodata_to_binary()

    put(:batch, sign(payload, Keyword.get(opts, :signers, [fixture.key])))
    fixture
  end

  # The source has no batch to serve: batch.json answers 503.
  @spec withdraw_batch() :: :ok
  def withdraw_batch(), do: put(:batch, nil)

  @spec file(map(), binary()) :: String.t()
  def file(_fixture, bytes) do
    s = sha(bytes)
    put_in_map(:files, s, bytes)
    s
  end

  # A systems document served at systems/by-sha/<sha>.json: under its own
  # sha, or under `sha` when given (bytes that do not hash to their name).
  @spec systems(binary(), String.t() | nil) :: String.t()
  def systems(bytes, sha \\ nil) do
    s = sha || sha(bytes)
    put_in_map(:systems, s, bytes)
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

  @spec record(map()) :: :ok
  def record(req),
    do: Agent.update(__MODULE__, &Map.update(&1, :requests, [req], fn l -> [req | l] end))

  @spec requests() :: [map()]
  def requests(), do: Agent.get(__MODULE__, &(Map.get(&1, :requests, []) |> Enum.reverse()))

  @spec clear_requests() :: :ok
  def clear_requests(), do: Agent.update(__MODULE__, &Map.put(&1, :requests, []))

  # Miss reports POSTed to the fixture server, oldest first, and the answer
  # it gives them.
  @default_report_response {201, ~s({"id":"5b2c6f0e-8d1a-4c39-9a57-2f0f3f0f9b11"})}

  @spec report_posts() :: [map()]
  def report_posts(), do: get(:report_posts) || []

  @spec record_report_post(map()) :: :ok
  def record_report_post(post), do: put(:report_posts, report_posts() ++ [post])

  @spec set_report_response({pos_integer(), binary()} | nil) :: :ok
  def set_report_response(response), do: put(:report_response, response)

  @spec report_response() :: {pos_integer(), binary()}
  def report_response(), do: get(:report_response) || @default_report_response

  @spec clear_reports() :: :ok
  def clear_reports() do
    put(:report_posts, [])
    put(:report_response, nil)
  end

  # false: root and batch are served without an ETag and never as 304, as
  # the production portal did until it learned If-None-Match.
  @spec set_etags(boolean()) :: :ok
  def set_etags(on?), do: put(:etags, on?)

  # Every file and manifest the listener on `port` serves has its first
  # byte flipped: a CDN serving wrong bytes. nil turns it off.
  @spec corrupt_port(pos_integer() | nil) :: :ok
  def corrupt_port(port), do: put(:corrupt_port, port)

  @spec get(atom()) :: term()
  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  @spec sha(binary()) :: String.t()
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @spec b64(binary()) :: String.t()
  def b64(bin), do: Base.url_encode64(bin, padding: false)

  @spec base_url() :: String.t()
  def base_url(), do: "http://127.0.0.1:#{Precompiled.TestServer.port()}/precompiled"

  @spec reset() :: :ok
  defp reset(),
    do:
      Agent.update(__MODULE__, fn _ ->
        %{manifests: %{}, manifests_v2: %{}, files: %{}, systems: %{}}
      end)

  @spec put(atom(), term()) :: :ok
  defp put(k, v), do: Agent.update(__MODULE__, &Map.put(&1, k, v))

  @spec put_in_map(atom(), term(), term()) :: :ok
  def put_in_map(k, key, v), do: Agent.update(__MODULE__, &put_in(&1, [k, key], v))

  defp batch_maps(:manifests_v2, hashes, merge?),
    do: %{"manifests" => other_hashes(:manifests, merge?), "manifests_v2" => hashes}

  defp batch_maps(:manifests, hashes, false), do: %{"manifests" => hashes}

  defp batch_maps(:manifests, hashes, true),
    do: %{"manifests" => hashes, "manifests_v2" => other_hashes(:manifests_v2, true)}

  defp other_hashes(_store, false), do: %{}

  defp other_hashes(store, true) do
    Agent.get(__MODULE__, &Map.get(&1, store, %{}))
    |> Map.new(fn {name, bytes} -> {name, sha(bytes)} end)
  end
end
