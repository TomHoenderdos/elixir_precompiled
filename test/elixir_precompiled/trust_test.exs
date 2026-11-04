# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.TrustTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.Fixture, as: F
  alias ElixirPrecompiled.Trust
  @moduletag :tmp_dir

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    f = F.new(dir)

    config = %{
      source: F.base_url(),
      except: [],
      root_path: f.root_path,
      home: Path.join(dir, "home")
    }

    %{f: f, config: config, fetch: &fetch/1}
  end

  defp shipped(config) do
    config.root_path
    |> File.read!()
    |> :json.decode()
    |> Map.fetch!("payload")
    |> Base.url_decode64!(padding: false)
    |> :json.decode()
  end

  defp state_dir(config), do: Trust.state_dir(config, shipped(config))

  defp fetch(url) do
    case ElixirPrecompiled.HTTP.get(url) do
      {:ok, body} -> {:ok, body}
      other -> other
    end
  end

  test "loads and verifies the shipped root", %{config: config, f: f} do
    assert {:ok, root} = Trust.load_root(config)
    assert {keys, 1} = Trust.root_keys(root, "batch")
    assert Map.keys(keys) == [f.key.keyid]
  end

  test "a shipped root with a bad signature is refused", %{config: config, f: f} do
    bad = put_in(f.root_env, ["signatures"], [])
    File.write!(config.root_path, :json.encode(bad))
    assert {:error, _} = Trust.load_root(config)
  end

  test "fetches a valid batch and stores the sequence", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{"ash" => %{"versions" => %{}}}, sequence: 5, format: 1)
    {:ok, root} = Trust.load_root(config)

    assert {:ok, %{sequence: 5, manifests: %{"ash" => _}, manifests_v2: nil}} =
             Trust.fetch_batch(config, root, fetch)

    assert File.read!(Path.join(state_dir(config), "state")) =~ "5"
  end

  test "a batch with manifests_v2 returns it", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{"ash" => %{"versions" => %{}}})
    {:ok, root} = Trust.load_root(config)

    assert {:ok, %{manifests: %{}, manifests_v2: %{"ash" => sha}}} =
             Trust.fetch_batch(config, root, fetch)

    assert sha =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a batch whose manifests_v2 is not a map is malformed", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{}, format: 1, batch_extra: %{"manifests_v2" => ["ash"]})
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch malformed"} = Trust.fetch_batch(config, root, fetch)
  end

  test "an expired batch is refused", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{}, expires: "2020-01-01T00:00:00Z")
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch expired" <> _} = Trust.fetch_batch(config, root, fetch)
  end

  test "a replayed older batch is refused and state unchanged", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    {:ok, root} = Trust.load_root(config)
    F.publish(f, %{}, sequence: 7)
    assert {:ok, _} = Trust.fetch_batch(config, root, fetch)
    F.publish(f, %{}, sequence: 6)
    assert {:error, "batch sequence 6 is older than 7"} = Trust.fetch_batch(config, root, fetch)
    assert File.read!(Path.join(state_dir(config), "state")) =~ "7"
  end

  test "a batch signed by an unknown key is refused", %{config: config, f: f, fetch: fetch} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    other = %{
      keyid: Base.encode16(:crypto.hash(:sha256, pub), case: :lower),
      public: pub,
      private: priv
    }

    F.publish(f, %{}, signers: [other])
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch signature invalid"} = Trust.fetch_batch(config, root, fetch)
  end

  test "a newer root signed by the current root is adopted and cached", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    k2 = %{
      keyid: Base.encode16(:crypto.hash(:sha256, pub), case: :lower),
      public: pub,
      private: priv
    }

    root2 = F.root_payload(k2.keyid, pub, "2031-01-01T00:00:00Z", 2)
    F.serve_root(f, F.sign(root2, [f.key, k2]))
    {:ok, root} = Trust.load_root(config)
    assert {:ok, new_root} = Trust.update_root(config, root, fetch)
    assert {%{} = keys, 1} = Trust.root_keys(new_root, "batch")
    assert Map.keys(keys) == [k2.keyid]
    assert File.exists?(Path.join(state_dir(config), "roots.json"))
    assert {:ok, ^new_root} = Trust.load_root(config)
  end

  test "a newer root signed only by a stranger is ignored", %{config: config, f: f, fetch: fetch} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    k2 = %{
      keyid: Base.encode16(:crypto.hash(:sha256, pub), case: :lower),
      public: pub,
      private: priv
    }

    F.serve_root(f, F.sign(F.root_payload(k2.keyid, pub, "2031-01-01T00:00:00Z", 2), [k2]))
    {:ok, root} = Trust.load_root(config)
    assert {:ok, ^root} = Trust.update_root(config, root, fetch)
    refute File.exists?(Path.join(state_dir(config), "roots.json"))
  end

  test "a served root with a missing or zero root threshold is ignored, never raises", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    keyid = Base.encode16(:crypto.hash(:sha256, pub), case: :lower)
    k2 = %{keyid: keyid, public: pub, private: priv}
    {:ok, root} = Trust.load_root(config)

    missing_threshold =
      raw_root(keyid, pub, "2031-01-01T00:00:00Z", 2, root: %{"keyids" => [keyid]})

    F.serve_root(f, F.sign(missing_threshold, [f.key, k2]))
    assert {:ok, ^root} = Trust.update_root(config, root, fetch)
    refute File.exists?(Path.join(state_dir(config), "roots.json"))

    zero_threshold =
      raw_root(keyid, pub, "2031-01-01T00:00:00Z", 2,
        root: %{"keyids" => [keyid], "threshold" => 0}
      )

    F.serve_root(f, F.sign(zero_threshold, [f.key, k2]))
    assert {:ok, ^root} = Trust.update_root(config, root, fetch)
    refute File.exists?(Path.join(state_dir(config), "roots.json"))
  end

  test "a served root whose only key is undersized is ignored, never raises", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    keyid = Base.encode16(:crypto.hash(:sha256, pub), case: :lower)
    short_pub = :crypto.strong_rand_bytes(10)
    {:ok, root} = Trust.load_root(config)

    payload =
      :json.encode(%{
        "version" => 2,
        "expires" => "2031-01-01T00:00:00Z",
        "keys" => %{keyid => %{"type" => "ed25519", "public" => F.b64(short_pub)}},
        "roles" => %{
          "root" => %{"keyids" => [keyid], "threshold" => 1},
          "batch" => %{"keyids" => [keyid], "threshold" => 1}
        }
      })
      |> IO.iodata_to_binary()

    F.serve_root(f, F.sign(payload, [%{keyid: keyid, public: pub, private: priv}]))
    assert {:ok, ^root} = Trust.update_root(config, root, fetch)
    refute File.exists?(Path.join(state_dir(config), "roots.json"))
  end

  test "a batch whose root lacks a batch role is refused, not raised", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    payload =
      :json.encode(%{
        "version" => 1,
        "expires" => "2030-01-01T00:00:00Z",
        "keys" => %{f.key.keyid => %{"type" => "ed25519", "public" => F.b64(f.key.public)}},
        "roles" => %{
          "root" => %{"keyids" => [f.key.keyid], "threshold" => 1}
        }
      })
      |> IO.iodata_to_binary()

    File.write!(config.root_path, :json.encode(F.sign(payload, [f.key])))
    F.publish(f, %{}, sequence: 1)
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch signature invalid"} = Trust.fetch_batch(config, root, fetch)
  end

  test "a shipped root past its own expiry is refused, not raised", %{tmp_dir: dir} do
    f = F.new(dir, root_expires: "2020-01-01T00:00:00Z")

    config = %{
      source: F.base_url(),
      except: [],
      root_path: f.root_path,
      home: Path.join(dir, "home")
    }

    assert {:error, "root document at " <> rest} = Trust.load_root(config)
    assert rest =~ "expired at 2020-01-01T00:00:00Z"
  end

  test "a served root with a higher version but expired is ignored, never raises", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    k2 = %{
      keyid: Base.encode16(:crypto.hash(:sha256, pub), case: :lower),
      public: pub,
      private: priv
    }

    root2 = F.root_payload(k2.keyid, pub, "2020-01-01T00:00:00Z", 2)
    F.serve_root(f, F.sign(root2, [f.key, k2]))
    {:ok, root} = Trust.load_root(config)
    assert {:ok, ^root} = Trust.update_root(config, root, fetch)
    refute File.exists?(Path.join(state_dir(config), "roots.json"))
  end

  # Builds a root payload like F.root_payload/4 but lets the caller override
  # the "root" role's shape (to exercise a missing/zero threshold).
  defp raw_root(keyid, public, expires, version, root: root_role) do
    :json.encode(%{
      "version" => version,
      "expires" => expires,
      "keys" => %{keyid => %{"type" => "ed25519", "public" => F.b64(public)}},
      "roles" => %{
        "root" => root_role,
        "batch" => %{"keyids" => [keyid], "threshold" => 1}
      }
    })
    |> IO.iodata_to_binary()
  end

  test "verify_envelope rejects garbage and duplicate signatures" do
    assert {:error, :bad_envelope} = Trust.verify_envelope("nope", %{}, 1)
    f = F.new(System.tmp_dir!())
    env = F.sign("x", [f.key])
    dup = Map.update!(env, "signatures", fn [s] -> [s, s] end)

    assert {:error, :below_threshold} =
             Trust.verify_envelope(dup, %{f.key.keyid => f.key.public}, 2)
  end

  test "state is kept per source: two sources do not see each other's sequence", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    other = %{
      config
      | source: "http://localhost:#{ElixirPrecompiled.TestServer.port()}/precompiled"
    }

    {:ok, root} = Trust.load_root(config)

    F.publish(f, %{}, sequence: 7)
    assert {:ok, %{sequence: 7}} = Trust.fetch_batch(config, root, fetch)
    F.publish(f, %{}, sequence: 6)
    assert {:ok, %{sequence: 6}} = Trust.fetch_batch(other, root, fetch)
    assert {:error, "batch sequence 6 is older than 7"} = Trust.fetch_batch(config, root, fetch)

    refute state_dir(config) == state_dir(other)
    assert Path.dirname(state_dir(config)) == config.home
    assert File.read!(Path.join(state_dir(other), "state")) =~ "6"

    # R19: adopting a new root for source A is state kept per source too;
    # it must not raise source B's root_version floor.
    k2 = key()
    F.serve_root(f, root_env(k2, 2, "2031-01-01T00:00:00Z", [f.key, k2]))
    assert {:ok, %{"version" => 2}} = Trust.update_root(config, root, fetch)
    assert File.exists?(Path.join(state_dir(config), "root_version"))
    refute File.exists?(Path.join(state_dir(other), "root_version"))
    assert {:ok, %{"version" => 1}} = Trust.load_root(other)
  end

  test "the state dir is keyed by the shipped root, not a rotated one", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    k2 = %{keyid: F.sha(pub), public: pub, private: priv}
    F.serve_root(f, F.sign(F.root_payload(k2.keyid, pub, "2031-01-01T00:00:00Z", 2), [f.key, k2]))
    {:ok, root} = Trust.load_root(config)
    {:ok, rotated} = Trust.update_root(config, root, fetch)
    F.publish(f, %{}, sequence: 4, signers: [k2])
    assert {:ok, %{sequence: 4}} = Trust.fetch_batch(config, rotated, fetch)
    assert File.read!(Path.join(state_dir(config), "state")) =~ "4"
  end

  defp key() do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{keyid: F.sha(pub), public: pub, private: priv}
  end

  defp root_env(k, version, expires, signers),
    do: F.sign(F.root_payload(k.keyid, k.public, expires, version), signers)

  defp write_chain(config, envs) do
    File.mkdir_p!(state_dir(config))
    File.write!(Path.join(state_dir(config), "roots.json"), :json.encode(envs))
  end

  defp version(root), do: root["version"]

  test "two-hop rotation: v2 signed by v1, then v3 signed by v2 only, ends on v3", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    k2 = key()
    k3 = key()
    {:ok, v1} = Trust.load_root(config)

    F.serve_root(f, root_env(k2, 2, "2031-01-01T00:00:00Z", [f.key, k2]))
    assert {:ok, v2} = Trust.update_root(config, v1, fetch)
    assert version(v2) == 2

    F.serve_root(f, root_env(k3, 3, "2031-01-01T00:00:00Z", [k2, k3]))
    assert {:ok, v3} = Trust.update_root(config, v2, fetch)
    assert version(v3) == 3

    assert {:ok, ^v3} = Trust.load_root(config)

    chain =
      Path.join(state_dir(config), "roots.json") |> File.read!() |> :json.decode()

    assert length(chain) == 2
  end

  test "a self-signed root dropped into roots.json is ignored", %{config: config} do
    k9 = key()
    {:ok, v1} = Trust.load_root(config)
    write_chain(config, [root_env(k9, 9, "2031-01-01T00:00:00Z", [k9])])
    assert {:ok, ^v1} = Trust.load_root(config)
  end

  test "an expired shipped root is fine when the chain leads to an unexpired root", %{
    tmp_dir: dir
  } do
    f = F.new(dir, root_expires: "2020-01-01T00:00:00Z")

    config = %{
      source: F.base_url(),
      except: [],
      root_path: f.root_path,
      home: Path.join(dir, "h")
    }

    k2 = key()
    write_chain(config, [root_env(k2, 2, "2031-01-01T00:00:00Z", [f.key, k2])])

    assert {:ok, v2} = Trust.load_root(config)
    assert version(v2) == 2
  end

  # TUF: every step must verify under the previous root's root role and be
  # newer; only the root the fold ends on must be unexpired.
  test "an expired intermediate root does not stop the chain: v1 -> v2 (expired) -> v3", %{
    config: config,
    f: f
  } do
    k2 = key()
    k3 = key()

    write_chain(config, [
      root_env(k2, 2, "2020-01-01T00:00:00Z", [f.key, k2]),
      root_env(k3, 3, "2031-01-01T00:00:00Z", [k2, k3])
    ])

    File.write!(Path.join(state_dir(config), "root_version"), "3")

    assert {:ok, v3} = Trust.load_root(config)
    assert version(v3) == 3
  end

  test "a chain whose final root is expired is refused", %{config: config, f: f} do
    k2 = key()
    k3 = key()

    write_chain(config, [
      root_env(k2, 2, "2031-01-01T00:00:00Z", [f.key, k2]),
      root_env(k3, 3, "2020-01-01T00:00:00Z", [k2, k3])
    ])

    assert {:error, "cached root expired at 2020-01-01T00:00:00Z"} = Trust.load_root(config)
  end

  test "an expired intermediate not signed by the previous root still stops the chain", %{
    config: config
  } do
    k2 = key()
    k3 = key()
    {:ok, v1} = Trust.load_root(config)

    write_chain(config, [
      root_env(k2, 2, "2020-01-01T00:00:00Z", [k2]),
      root_env(k3, 3, "2031-01-01T00:00:00Z", [k2, k3])
    ])

    assert {:ok, ^v1} = Trust.load_root(config)
  end

  test "update_root adopts across an expired intermediate and keeps the chain", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    k2 = key()
    k3 = key()
    k4 = key()

    write_chain(config, [
      root_env(k2, 2, "2020-01-01T00:00:00Z", [f.key, k2]),
      root_env(k3, 3, "2031-01-01T00:00:00Z", [k2, k3])
    ])

    {:ok, v3} = Trust.load_root(config)
    assert version(v3) == 3

    F.serve_root(f, root_env(k4, 4, "2031-01-01T00:00:00Z", [k3, k4]))
    assert {:ok, v4} = Trust.update_root(config, v3, fetch)
    assert version(v4) == 4

    chain = Path.join(state_dir(config), "roots.json") |> File.read!() |> :json.decode()
    assert length(chain) == 3
    assert {:ok, ^v4} = Trust.load_root(config)
  end

  test "a chain entry after a bad one is not used", %{config: config, f: f} do
    k2 = key()
    k3 = key()
    k4 = key()
    {:ok, v1} = Trust.load_root(config)

    write_chain(config, [
      root_env(k2, 2, "2031-01-01T00:00:00Z", [f.key, k2]),
      root_env(k3, 3, "2031-01-01T00:00:00Z", [k3]),
      root_env(k4, 4, "2031-01-01T00:00:00Z", [k3, k4])
    ])

    assert {:ok, v2} = Trust.load_root(config)
    assert version(v2) == 2
    refute v2 == v1
  end

  test "an unwritable state dir is named as such, not as a malformed batch", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{}, sequence: 2)
    {:ok, root} = Trust.load_root(config)
    File.mkdir_p!(config.home)
    File.write!(state_dir(config), "a file where the state dir should be")

    assert {:error, "state dir unwritable: " <> _} = Trust.fetch_batch(config, root, fetch)
  end

  test "R17: an adopted root version survives roots.json disappearing", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    # Adopt v2 through the existing rotation path (copy the setup of
    # "a newer root signed by the current root is adopted and cached").
    v2 = F.rotate_root(f, version: 2)
    {:ok, root} = Trust.load_root(config)
    assert {:ok, %{"version" => 2}} = Trust.update_root(config, root, fetch)
    File.rm!(Path.join(state_dir(config), "roots.json"))
    path = Path.join(state_dir(config), "root_version")

    assert {:error, "root version 1 is older than 2" <> rest} = Trust.load_root(config)
    assert rest =~ "delete #{path}"
    _ = v2
  end

  test "R4: a corrupt state file warns and counts as 0", %{config: config, f: f, fetch: fetch} do
    File.mkdir_p!(state_dir(config))
    File.write!(Path.join(state_dir(config), "state"), "not a number")
    F.publish(f, %{}, sequence: 4)
    {:ok, root} = Trust.load_root(config)
    {result, log} = capture_warning(fn -> Trust.fetch_batch(config, root, fetch) end)
    assert {:ok, %{sequence: 4}} = result
    assert log =~ "sequence state"
  end

  test "a root_version write failure is named, not raised, and the adopted root is kept", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    v2 = F.rotate_root(f, version: 2)
    dir = state_dir(config)
    # roots.json writes fine; renaming root_version.tmp onto this directory
    # fails with EISDIR, isolating write_root_version/2's own rescue from
    # the write that precedes it.
    File.mkdir_p!(Path.join(dir, "root_version"))
    {:ok, root} = Trust.load_root(config)

    {result, log} = capture_warning(fn -> Trust.update_root(config, root, fetch) end)
    assert {:ok, %{"version" => 2}} = result
    assert File.exists?(Path.join(dir, "roots.json"))
    assert log =~ "root version state"
    _ = v2
  end

  # Output.warning/1 goes through Mix.shell().info (stdout) when Mix is
  # running and IO.puts(:stderr) otherwise; capture both so this is not
  # fragile to which applies under `mix test` (see config_test.exs).
  defp capture_warning(fun) do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        stdio = ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, fun.()}) end)
        send(self(), {:stdio, stdio})
      end)

    assert_received {:result, result}
    assert_received {:stdio, stdio}
    {result, stdio <> stderr}
  end

  defp iso(dt), do: DateTime.to_iso8601(dt)
  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  test "R1: a batch issued 15 minutes ago is accepted", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{}, sequence: 3, issued: iso(ago(15 * 60)))
    {:ok, root} = Trust.load_root(config)
    assert {:ok, %{sequence: 3}} = Trust.fetch_batch(config, root, fetch)
  end

  test "R2: an unexpired batch issued 25 hours ago is refused as stale", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{}, sequence: 3, issued: iso(ago(25 * 3600)))
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch stale" <> _} = Trust.fetch_batch(config, root, fetch)
    refute File.exists?(Path.join(state_dir(config), "state"))
  end

  test "R7/R8: the clock offset moves now: 23 h accepted, 25 h stale", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{}, sequence: 3, issued: iso(DateTime.utc_now()))
    {:ok, root} = Trust.load_root(config)

    assert {:ok, _} =
             Trust.fetch_batch(Map.put(config, :clock_offset_seconds, 23 * 3600), root, fetch)

    assert {:error, "batch stale" <> _} =
             Trust.fetch_batch(Map.put(config, :clock_offset_seconds, 25 * 3600), root, fetch)
  end

  test "R9: issued an hour in the future is refused as clock", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{}, issued: iso(DateTime.add(DateTime.utc_now(), 3600, :second)))
    {:ok, root} = Trust.load_root(config)
    assert {:error, "clock" <> _} = Trust.fetch_batch(config, root, fetch)
  end

  test "R10: issued 2 minutes in the future is accepted", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{}, issued: iso(DateTime.add(DateTime.utc_now(), 120, :second)))
    {:ok, root} = Trust.load_root(config)
    assert {:ok, _} = Trust.fetch_batch(config, root, fetch)
  end

  test "R12: a clock before the library's compile-time floor is refused as clock", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{})
    {:ok, root} = Trust.load_root(config)
    behind = DateTime.diff(Trust.clock_floor(), DateTime.utc_now(), :second) - 86_400

    assert {:error, "clock" <> _} =
             Trust.fetch_batch(Map.put(config, :clock_offset_seconds, behind), root, fetch)
  end

  test "R13: a clock a year ahead sees an expired batch", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{}, expires: iso(DateTime.add(DateTime.utc_now(), 86_400, :second)))
    {:ok, root} = Trust.load_root(config)

    assert {:error, reason} =
             Trust.fetch_batch(Map.put(config, :clock_offset_seconds, 365 * 86_400), root, fetch)

    assert reason =~ ~r/^batch (expired|stale)/
  end

  test "T8: a batch whose expires is more than 30 days after issued is refused", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    now = DateTime.utc_now()
    F.publish(f, %{}, issued: iso(now), expires: iso(DateTime.add(now, 31 * 86_400, :second)))
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch lifetime" <> _} = Trust.fetch_batch(config, root, fetch)
  end

  test "R11: a 30-day batch is still refused once 24 h past issued", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    issued = ago(25 * 3600)

    F.publish(f, %{},
      issued: iso(issued),
      expires: iso(DateTime.add(issued, 30 * 86_400, :second))
    )

    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch stale" <> _} = Trust.fetch_batch(config, root, fetch)
  end

  test "a batch without issued is malformed", %{config: config, f: f, fetch: fetch} do
    F.publish(f, %{}, issued: nil)
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch malformed"} = Trust.fetch_batch(config, root, fetch)
  end

  test "issued without any offset is malformed, never read as local time", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{}, issued: Calendar.strftime(ago(600), "%Y-%m-%dT%H:%M:%S"))
    {:ok, root} = Trust.load_root(config)
    assert {:error, "batch malformed"} = Trust.fetch_batch(config, root, fetch)
  end

  test "issued with an offset is read as an instant", %{config: config, f: f, fetch: fetch} do
    # The same instant as 10 minutes ago, written in +01:00 local time.
    offset =
      Calendar.strftime(DateTime.add(ago(600), 3600, :second), "%Y-%m-%dT%H:%M:%S") <> "+01:00"

    F.publish(f, %{}, issued: offset)
    {:ok, root} = Trust.load_root(config)
    assert {:ok, _} = Trust.fetch_batch(config, root, fetch)
  end

  test "root_keys drops keys whose keyid is not their hash or whose type is not ed25519" do
    good = key()
    misnamed = key()
    other_type = key()

    root = %{
      "keys" => %{
        good.keyid => %{"type" => "ed25519", "public" => F.b64(good.public)},
        "not-the-hash" => %{"type" => "ed25519", "public" => F.b64(misnamed.public)},
        other_type.keyid => %{"type" => "rsa", "public" => F.b64(other_type.public)}
      },
      "roles" => %{
        "batch" => %{
          "keyids" => [good.keyid, "not-the-hash", other_type.keyid],
          "threshold" => 1
        }
      }
    }

    assert {keys, 1} = Trust.root_keys(root, "batch")
    assert Map.keys(keys) == [good.keyid]
  end

  test "two concurrent batch fetches on one home both succeed", %{
    config: config,
    f: f,
    fetch: fetch
  } do
    F.publish(f, %{"ash" => %{"versions" => %{}}}, sequence: 5)
    {:ok, root} = Trust.load_root(config)

    results =
      1..8
      |> Task.async_stream(fn _ -> Trust.fetch_batch(config, root, fetch) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, %{sequence: 5}}, &1))
  end
end
