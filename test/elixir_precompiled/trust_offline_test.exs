# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.TrustOfflineTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.{Fixture, Trust}

  @moduletag :tmp_dir

  @sha String.duplicate("a", 64)
  @ten_years 10 * 365 * 86_400

  setup %{tmp_dir: dir} do
    fixture = Fixture.new(dir, offline_key: true)
    config = config(dir, fixture, "home")
    {:ok, root} = Trust.load_root(config)
    %{fixture: fixture, config: config, root: root}
  end

  defp config(dir, fixture, home) do
    %{
      source: "file://" <> dir,
      root_path: fixture.root_path,
      home: Path.join(dir, home),
      state_key: "device"
    }
  end

  defp key() do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{keyid: Fixture.sha(pub), public: pub, private: priv}
  end

  defp entry(k), do: {k.keyid, %{"type" => "ed25519", "public" => Fixture.b64(k.public)}}

  # A root signed by `root_key` with the given extra keys and roles, written
  # as the shipped root of a fresh config under `dir/name`.
  defp custom_root(dir, name, root_key, keys, roles, expires \\ "2030-01-01T00:00:00Z") do
    sub = Path.join(dir, name)
    File.mkdir_p!(sub)

    payload =
      %{
        "version" => 1,
        "expires" => expires,
        "keys" => Map.new([entry(root_key) | Enum.map(keys, &entry/1)]),
        "roles" =>
          Map.merge(
            %{
              "root" => %{"keyids" => [root_key.keyid], "threshold" => 1},
              "batch" => %{"keyids" => [root_key.keyid], "threshold" => 1}
            },
            roles
          )
      }
      |> :json.encode()
      |> IO.iodata_to_binary()

    path = Path.join(sub, "root.json")
    File.write!(path, :json.encode(Fixture.sign(payload, [root_key])))
    c = config(sub, %{root_path: path}, "home")
    {:ok, root} = Trust.load_root(c)
    {c, root}
  end

  defp envelope(payload, signers) do
    payload
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> Fixture.sign(signers)
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp doc(overrides) do
    Map.merge(
      %{
        "version" => 1,
        "kind" => "offline",
        "sequence" => 5,
        "issued" => "2026-11-09T00:00:00Z",
        "manifests" => %{},
        "manifests_v2" => %{"recon" => @sha}
      },
      overrides
    )
  end

  describe "an offline document that verifies" do
    test "verifies with no expiry and no clock", %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{"recon" => @sha}, sequence: 10)

      assert {:ok,
              %{
                offline: true,
                sequence: 10,
                manifests: %{},
                manifests_v2: %{"recon" => @sha},
                content: nil
              }} = Trust.verify_offline(c, root, body)

      # Years later, a skewed clock changes nothing.
      assert {:ok, _} =
               Trust.verify_offline(Map.put(c, :clock_offset_seconds, @ten_years), root, body)

      # Nor a clock before this library was built.
      assert {:ok, _} =
               Trust.verify_offline(Map.put(c, :clock_offset_seconds, -@ten_years), root, body)
    end

    test "an issued time years in the past or the future plays no part",
         %{fixture: f, config: c, root: root} do
      old = envelope(doc(%{"sequence" => 1, "issued" => "2001-01-01T00:00:00Z"}), [f.offline_key])
      assert {:ok, %{sequence: 1}} = Trust.verify_offline(c, root, old)

      future =
        envelope(doc(%{"sequence" => 2, "issued" => "2099-01-01T00:00:00Z"}), [f.offline_key])

      assert {:ok, %{sequence: 2}} = Trust.verify_offline(c, root, future)
    end

    test "with a root that expired long ago, on the offline path", %{tmp_dir: dir} do
      sub = Path.join(dir, "expired") |> tap(&File.mkdir_p!/1)
      f = Fixture.new(sub, offline_key: true, root_expires: "2020-01-01T00:00:00Z")
      c = config(sub, f, "home")

      assert {:error, "root document at " <> _} = Trust.load_root(c)
      assert {:ok, root} = Trust.load_root(c, offline: true)
      assert root["expires"] == "2020-01-01T00:00:00Z"

      body = Fixture.offline_document(f, %{"recon" => @sha}, sequence: 3)
      assert {:ok, %{sequence: 3}} = Trust.verify_offline(c, root, body)

      skewed = Map.put(c, :clock_offset_seconds, @ten_years)
      assert {:ok, ^root} = Trust.load_root(skewed, offline: true)
      assert {:ok, %{sequence: 3}} = Trust.verify_offline(skewed, root, body)
    end

    test "an equal sequence is accepted and a higher one raises the floor",
         %{fixture: f, config: c, root: root} do
      assert {:ok, _} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 9))

      assert {:ok, _} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 9))

      assert {:ok, _} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 12))

      dir = Trust.state_dir(c, root)
      assert File.read!(Path.join(dir, "offline_state")) == "12"
    end

    test "keeps its own floor, apart from the batch sequence", %{
      fixture: f,
      config: c,
      root: root
    } do
      dir = Trust.state_dir(c, root)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "state"), "1000")

      assert {:ok, %{sequence: 5}} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 5))

      assert File.read!(Path.join(dir, "state")) == "1000"
    end

    test "the floor never drops when a stored one is higher than this document",
         %{fixture: f, config: c, root: root} do
      dir = Trust.state_dir(c, root)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "offline_state"), "7")

      assert {:ok, _} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 7))

      assert File.read!(Path.join(dir, "offline_state")) == "7"
    end
  end

  describe "keys only from the offline role" do
    test "signed by the batch key instead of the offline role: refused",
         %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{}, sequence: 1, signers: [f.key])
      assert {:error, "offline document signature invalid"} = Trust.verify_offline(c, root, body)
    end

    test "signed by an unknown key: refused", %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{}, sequence: 1, signers: [key()])
      assert {:error, "offline document signature invalid"} = Trust.verify_offline(c, root, body)
    end

    test "an unsigned document is refused", %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{}, sequence: 1, signers: [])
      assert {:error, "offline document signature invalid"} = Trust.verify_offline(c, root, body)
    end

    test "a payload changed after signing is refused", %{fixture: f, config: c, root: root} do
      env = Fixture.offline_document(f, %{"recon" => @sha}, sequence: 4) |> :json.decode()

      forged =
        doc(%{"sequence" => 4, "manifests_v2" => %{"recon" => String.duplicate("b", 64)}})
        |> :json.encode()
        |> IO.iodata_to_binary()

      body =
        env
        |> Map.put("payload", Fixture.b64(forged))
        |> :json.encode()
        |> IO.iodata_to_binary()

      assert {:error, "offline document signature invalid"} = Trust.verify_offline(c, root, body)
    end

    test "a root without an offline role refuses every offline document", %{tmp_dir: dir} do
      f = Fixture.new(Path.join(dir, "plain") |> tap(&File.mkdir_p!/1))
      c = config(dir, f, "h2")
      {:ok, root} = Trust.load_root(c)
      assert {:error, "root has no offline role"} = Trust.verify_offline(c, root, "{}")

      # Even one signed by the root and batch key.
      body = envelope(doc(%{}), [f.key])
      assert {:error, "root has no offline role"} = Trust.verify_offline(c, root, body)
    end

    test "an offline role that names only the online key is no offline role", %{tmp_dir: dir} do
      k = key()

      {c, root} =
        custom_root(dir, "shared", k, [], %{
          "offline" => %{"keyids" => [k.keyid], "threshold" => 1}
        })

      body = envelope(doc(%{}), [k])
      assert {:error, "root has no offline role"} = Trust.verify_offline(c, root, body)
    end

    test "the online key in the offline role next to an offline key never counts",
         %{tmp_dir: dir} do
      k = key()
      off = key()

      {c, root} =
        custom_root(dir, "mixed", k, [off], %{
          "offline" => %{"keyids" => [off.keyid, k.keyid], "threshold" => 1}
        })

      assert {:error, "offline document signature invalid"} =
               Trust.verify_offline(c, root, envelope(doc(%{}), [k]))

      assert {:ok, _} = Trust.verify_offline(c, root, envelope(doc(%{}), [off]))
    end

    test "a key another role names is never an offline key, whatever the role", %{tmp_dir: dir} do
      k = key()
      other = key()

      {c, root} =
        custom_root(dir, "other", k, [other], %{
          "targets" => %{"keyids" => [other.keyid], "threshold" => 1},
          "offline" => %{"keyids" => [other.keyid], "threshold" => 1}
        })

      assert {:error, "root has no offline role"} =
               Trust.verify_offline(c, root, envelope(doc(%{}), [other]))
    end

    test "threshold zero is no offline role", %{tmp_dir: dir} do
      k = key()
      off = key()

      {c, root} =
        custom_root(dir, "zero", k, [off], %{
          "offline" => %{"keyids" => [off.keyid], "threshold" => 0}
        })

      assert {:error, "root has no offline role"} =
               Trust.verify_offline(c, root, envelope(doc(%{}), [off]))
    end

    test "a keyid listed twice or signing twice counts once", %{tmp_dir: dir} do
      k = key()
      off = key()

      {c, root} =
        custom_root(dir, "twice", k, [off], %{
          "offline" => %{"keyids" => [off.keyid, off.keyid], "threshold" => 2}
        })

      assert {:error, "offline document signature invalid"} =
               Trust.verify_offline(c, root, envelope(doc(%{}), [off, off]))
    end

    test "a threshold of two needs two distinct offline keys", %{tmp_dir: dir} do
      k = key()
      a = key()
      b = key()

      {c, root} =
        custom_root(dir, "two", k, [a, b], %{
          "offline" => %{"keyids" => [a.keyid, b.keyid], "threshold" => 2}
        })

      assert {:error, "offline document signature invalid"} =
               Trust.verify_offline(c, root, envelope(doc(%{}), [a, k]))

      assert {:ok, _} = Trust.verify_offline(c, root, envelope(doc(%{}), [a, b]))
    end
  end

  describe "the sequence floor" do
    test "a lower sequence than one seen is refused", %{fixture: f, config: c, root: root} do
      assert {:ok, _} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 9))

      assert {:error, "offline sequence 8 is below 9"} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 8))
    end

    test "the floor survives a new process: it is read from the state dir",
         %{fixture: f, config: c, root: root} do
      dir = Trust.state_dir(c, root)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "offline_state"), "1762646400")

      assert {:error, "offline sequence 1762646399 is below 1762646400"} =
               Trust.verify_offline(
                 c,
                 root,
                 Fixture.offline_document(f, %{}, sequence: 1_762_646_399)
               )
    end

    test "a state dir that cannot be written refuses the document",
         %{fixture: f, config: c, root: root} do
      File.write!(c.home, "not a directory")

      assert {:error, "state dir unwritable: " <> _} =
               Trust.verify_offline(c, root, Fixture.offline_document(f, %{}, sequence: 1))
    end
  end

  describe "malformed documents" do
    test "a document that is a batch (kind missing) is malformed",
         %{fixture: f, config: c, root: root} do
      payload =
        :json.encode(%{
          "version" => 1,
          "sequence" => 3,
          "manifests" => %{},
          "manifests_v2" => %{}
        })
        |> IO.iodata_to_binary()

      body = Fixture.sign(payload, [f.offline_key]) |> :json.encode() |> IO.iodata_to_binary()
      assert {:error, "offline document malformed"} = Trust.verify_offline(c, root, body)
    end

    test "every wrong field shape is malformed", %{fixture: f, config: c, root: root} do
      for overrides <- [
            %{"kind" => "batch"},
            %{"version" => 2},
            %{"sequence" => "5"},
            %{"sequence" => 5.0},
            %{"sequence" => 0},
            %{"sequence" => -1},
            %{"manifests" => []},
            %{"manifests_v2" => nil},
            %{"manifests_v2" => %{"recon" => "short"}},
            %{"manifests_v2" => %{"recon" => String.duplicate("A", 64)}},
            %{"manifests_v2" => %{"../recon" => @sha}},
            %{"manifests" => %{"recon" => 1}}
          ] do
        body = envelope(doc(overrides), [f.offline_key])

        assert {:error, "offline document malformed"} = Trust.verify_offline(c, root, body),
               "accepted #{inspect(overrides)}"
      end

      for key <- ["kind", "version", "sequence", "manifests", "manifests_v2"] do
        body = envelope(Map.delete(doc(%{}), key), [f.offline_key])
        assert {:error, "offline document malformed"} = Trust.verify_offline(c, root, body)
      end

      refute File.exists?(Path.join(Trust.state_dir(c, root), "offline_state"))
    end

    test "a signed payload that is not a JSON object is malformed",
         %{fixture: f, config: c, root: root} do
      for payload <- ["not json", "[1,2]", "5"] do
        body = Fixture.sign(payload, [f.offline_key]) |> :json.encode() |> IO.iodata_to_binary()
        assert {:error, "offline document malformed"} = Trust.verify_offline(c, root, body)
      end
    end

    test "a body that is not an envelope is refused", %{config: c, root: root} do
      for body <- ["", "not json", "[]", ~s({"payload": 1})] do
        assert {:error, "offline document signature invalid"} =
                 Trust.verify_offline(c, root, body)
      end
    end
  end

  describe "the source an offline document is read from" do
    test "an https source is refused and the floor is not written",
         %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{"recon" => @sha}, sequence: 10)
      https = Map.put(c, :source, "https://example.com")

      assert {:error, "offline documents are only read from a file:// source"} =
               Trust.verify_offline(https, root, body)

      refute File.exists?(Path.join(Trust.state_dir(c, root), "offline_state"))
    end

    test "a file:// source is accepted", %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{"recon" => @sha}, sequence: 1)
      assert {:ok, %{sequence: 1}} = Trust.verify_offline(c, root, body)
    end
  end

  describe "a trusted root that cannot be read" do
    test "is reported distinctly from a malformed document",
         %{fixture: f, config: c, root: root} do
      body = Fixture.offline_document(f, %{"recon" => @sha}, sequence: 10)
      unreadable = Map.put(c, :root_path, Path.join(c.home, "no-such-root.json"))

      assert {:error, "cannot read trusted root"} = Trust.verify_offline(unreadable, root, body)
    end
  end

  describe "the bundle's root on the offline path" do
    setup %{fixture: f} do
      next = key()
      expired = Fixture.root_payload(f.key.keyid, f.key.public, "2020-01-01T00:00:00Z", 2, next)
      %{next: next, expired_env: Fixture.sign(expired, [f.key])}
    end

    test "a newer root that expired is adopted for offline use only",
         %{config: c, root: root, expired_env: env, next: next} do
      fetch = fn _url -> {:ok, env |> :json.encode() |> IO.iodata_to_binary()} end

      assert {:ok, %{"version" => 1}} = Trust.update_root(c, root, fetch)
      assert {:ok, %{"version" => 2} = v2} = Trust.update_root(c, root, fetch, offline: true)

      # Online, the root in use has expired; offline it is still the root.
      assert {:error, "cached root expired at 2020-01-01T00:00:00Z"} = Trust.load_root(c)
      assert {:ok, ^v2} = Trust.load_root(c, offline: true)

      body = envelope(doc(%{"sequence" => 1}), [next])
      assert {:ok, %{sequence: 1}} = Trust.verify_offline(c, v2, body)
    end

    test "a root that does not chain is never adopted, offline or not",
         %{config: c, root: root, next: next} do
      stranger = key()

      foreign =
        Fixture.root_payload(stranger.keyid, stranger.public, "2030-01-01T00:00:00Z", 2, next)
        |> Fixture.sign([stranger])
        |> :json.encode()
        |> IO.iodata_to_binary()

      assert {:ok, ^root} = Trust.update_root(c, root, fn _ -> {:ok, foreign} end, offline: true)
      assert {:ok, ^root} = Trust.load_root(c, offline: true)
    end
  end
end
