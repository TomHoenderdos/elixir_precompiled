# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.TestKey do
  @moduledoc """
  Layer 2: a portal of our own, signed with throwaway Ed25519 keys, so a
  conformance case can show the client inputs only a key holder could make
  (a compromised portal) and check how it handles them.

  `prepare/1` generates the keys in memory, once per run, and never writes
  one anywhere. Their private halves live only inside the `sign` closure in
  the layer-2 snapshot (`inspect/1` shows a function, not its bytes); every
  public key and root document may be seen. Everything it writes goes under
  one private (`0700`) directory in the system tmp dir, which `cleanup/1`
  removes:

      trust/root-v1.json            the test root, version 1: root key `root`,
                                    batch key `batch`, threshold 1
      trust/root-threshold-2.json   another test root: root key `t2_root`,
                                    batch keys `pair_a` and `pair_b`, threshold 2
      snapshot/                     the real snapshot's manifests and files
                                    (hard links, or copies), `root.json` the
                                    test root v1, and `batch.json` (and
                                    `batches/<n>.json`) the real batch's payload,
                                    byte for byte, signed by `batch` instead
      snapshot/forged/<kind>.json   the manifests `ChainTest.Mirror.Forge` serves,
                                    with the extra files they name under `files/`

  It also holds two version-2 roots, as JSON envelopes: `rotated_v2` (root
  key `rotated_root`, batch key `rotated`, signed by `root` and
  `rotated_root`: a rotation the client must adopt) and `unchained_v2`
  (root and batch key `unchained`, signed by that key alone: not by v1's
  root key, T7).

  Signers (`sign`'s first argument): `:batch`, `:outside` (a key no test
  root names, T2), `:rotated`, `:unchained`, `:pair_a`, `:pair_b`.

  The test-signed copy is checked by the harness's own `ChainTest.Trust`
  against the test root before any case uses it: the layer-2 control case
  (L2-T0) then shows that the client, pinned to the test root, accepts it
  as it does the real one.
  """

  alias ChainTest.{Mirror, Trust}
  alias ChainTest.Mirror.Forge

  @roots %{v1: "root-v1.json", threshold_2: "root-threshold-2.json"}
  @signers [:batch, :outside, :rotated, :unchained, :pair_a, :pair_b]
  @key_names [:root, :rotated_root, :t2_root | @signers]

  @typedoc "What a test-key case needs in memory: the signing closure and the roots."
  @type test :: %{
          sign: (atom(), binary() -> map()),
          payload: binary(),
          rotated_v2: String.t(),
          unchained_v2: String.t(),
          keyids: [String.t()]
        }

  @type t :: %{
          dir: Path.t(),
          snapshot: map(),
          roots: %{atom() => Path.t()},
          keyids: [String.t()]
        }

  @doc "The test roots a case may pin the client to (`client_config: %{root: {:test_root, name}}`)."
  @spec root_names() :: [atom()]
  def root_names(), do: Map.keys(@roots) |> Enum.sort()

  @doc "The keys a test batch may be signed by."
  @spec signer_names() :: [atom()]
  def signer_names(), do: @signers

  @doc """
  Builds the layer-2 material for `snap` (a `ChainTest.Snapshot`; the
  fixture at `fixture_dir` names P5's deps, `ChainTest.Mirror.Forge`) and checks
  its batch with the harness's own trust checks against the test root; on
  any error nothing is left behind.
  """
  @spec prepare(map(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def prepare(snap, fixture_dir) do
    base = private_dir()

    try do
      with {:ok, l2} <- build(base, snap, fixture_dir),
           :ok <- verify(l2, snap) do
        {:ok, l2}
      else
        {:error, why} ->
          File.rm_rf(base)
          {:error, why}
      end
    rescue
      e ->
        File.rm_rf(base)
        {:error, "cannot prepare the test-key snapshot: " <> Exception.message(e)}
    end
  end

  @doc "Removes everything `prepare/1` wrote."
  @spec cleanup(t() | nil) :: :ok
  def cleanup(%{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  def cleanup(_), do: :ok

  @doc "The envelope JSON over `payload`, one signature per signer in `signers` (repeats kept)."
  @spec envelope(test(), binary(), [atom()]) :: String.t()
  def envelope(%{sign: sign}, payload, signers) when is_binary(payload) and is_list(signers) do
    JSON.encode!(%{
      "payload" => Base.url_encode64(payload, padding: false),
      "signatures" => Enum.map(signers, &sign.(&1, payload))
    })
  end

  @doc "The test material of a layer-2 snapshot; raises on a snapshot signed with the real root."
  @spec test!(map()) :: test()
  def test!(%{test: %{sign: sign} = test}) when is_function(sign, 2), do: test

  def test!(_snap),
    do: raise(ArgumentError, "a test-key transform or setup needs the layer-2 snapshot")

  @doc "The raw payload bytes of a signed envelope; raises when `bytes` is none."
  @spec payload!(binary()) :: binary()
  def payload!(bytes) do
    with {:ok, %{"payload" => p}} when is_binary(p) <- JSON.decode(bytes),
         {:ok, payload} <- Base.url_decode64(p, padding: false) do
      payload
    else
      _ -> raise ArgumentError, "not a signed envelope"
    end
  end

  # building

  defp private_dir() do
    rand = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    dir = Path.join(Path.expand(System.tmp_dir!()), "chain_layer2-" <> rand)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp build(base, snap, fixture_dir) do
    keys = Map.new(@key_names, &{&1, :crypto.generate_key(:eddsa, :ed25519)})
    sign = signer(keys)
    expires = DateTime.utc_now() |> DateTime.add(365, :day) |> DateTime.to_iso8601()

    v1 = root_doc(keys, 1, expires, [:root], [:batch], 1, [:root])
    t2 = root_doc(keys, 1, expires, [:t2_root], [:pair_a, :pair_b], 2, [:t2_root])
    rotated = root_doc(keys, 2, expires, [:rotated_root], [:rotated], 1, [:root, :rotated_root])
    unchained = root_doc(keys, 2, expires, [:unchained], [:unchained], 1, [:unchained])

    trust = Path.join(base, "trust")
    dir = Path.join(base, "snapshot")
    mkdir!(trust)
    mkdir!(dir)

    roots = Map.new(@roots, fn {name, file} -> {name, Path.join(trust, file)} end)
    File.write!(roots.v1, v1)
    File.write!(roots.threshold_2, t2)

    case File.read(Path.join(snap.dir, "batch.json")) do
      {:ok, batch} ->
        payload = payload!(batch)
        signed = envelope(%{sign: sign}, payload, [:batch])

        copy_tree!(snap.dir, dir, ["manifests", "v2", "files"])
        File.write!(Path.join(dir, "root.json"), v1)
        File.write!(Path.join(dir, "batch.json"), signed)
        mkdir!(Path.join(dir, "batches"))
        File.write!(Path.join(dir, "batches/#{snap.sequence}.json"), signed)

        keyids = keys |> Map.values() |> Enum.map(&keyid/1) |> Enum.sort()

        test = %{
          sign: sign,
          payload: payload,
          rotated_v2: rotated,
          unchained_v2: unchained,
          keyids: keyids
        }

        l2_snap =
          Map.merge(snap, %{
            dir: dir,
            info: %{snap.info | root_version: 1},
            previous: {:missing, "a test-key snapshot holds no older batch"},
            old: {:missing, "a test-key snapshot holds no older batch"},
            test: test
          })

        :ok = Forge.prepare(l2_snap, fixture_dir)
        {:ok, %{dir: base, snapshot: l2_snap, roots: roots, keyids: keyids}}

      {:error, why} ->
        {:error, "#{snap.dir}/batch.json: #{:file.format_error(why)}"}
    end
  end

  # The only place a private key is used: captured here, never returned.
  defp signer(keys) do
    fn name, payload when is_binary(payload) ->
      case Map.fetch(keys, name) do
        {:ok, {_pub, priv} = key} when name in @signers ->
          sig = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
          %{"keyid" => keyid(key), "sig" => Base.url_encode64(sig, padding: false)}

        _ ->
          raise ArgumentError, "no test signer #{inspect(name)}"
      end
    end
  end

  defp root_doc(keys, version, expires, root_role, batch_role, threshold, signed_by) do
    named = Enum.uniq(root_role ++ batch_role)

    payload =
      JSON.encode!(%{
        "version" => version,
        "expires" => expires,
        "keys" =>
          Map.new(named, fn name ->
            {pub, _} = key = keys[name]

            {keyid(key),
             %{"type" => "ed25519", "public" => Base.url_encode64(pub, padding: false)}}
          end),
        "roles" => %{
          "root" => %{"keyids" => Enum.map(root_role, &keyid(keys[&1])), "threshold" => 1},
          "batch" => %{
            "keyids" => Enum.map(batch_role, &keyid(keys[&1])),
            "threshold" => threshold
          }
        }
      })

    sigs =
      for name <- signed_by do
        {_pub, priv} = key = keys[name]
        sig = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
        %{"keyid" => keyid(key), "sig" => Base.url_encode64(sig, padding: false)}
      end

    JSON.encode!(%{"payload" => Base.url_encode64(payload, padding: false), "signatures" => sigs})
  end

  defp keyid({pub, _priv}), do: Base.encode16(:crypto.hash(:sha256, pub), case: :lower)

  defp mkdir!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
  end

  # The routed subtrees of the real snapshot, regular files only, each a
  # hard link where the file system allows one.
  defp copy_tree!(from, to, subdirs) do
    for sub <- subdirs,
        src = Path.join(from, sub),
        File.dir?(src),
        path <- Path.wildcard(Path.join(src, "**"), match_dot: true),
        {:ok, %File.Stat{type: :regular}} <- [File.lstat(path)] do
      dest = Path.join(to, Path.relative_to(path, from))
      mkdir!(Path.dirname(dest))

      case File.ln(path, dest) do
        :ok -> :ok
        {:error, _} -> File.cp!(path, dest)
      end
    end

    :ok
  end

  # The test-signed batch must be what the harness itself accepts under the
  # test root, and name exactly the real batch's manifests.
  defp verify(l2, snap) do
    case Mirror.start(l2.snapshot.dir) do
      {:ok, mirror} ->
        try do
          Trust.check(%{
            source: mirror.url,
            root_path: l2.roots.v1,
            library_root_path: l2.roots.v1
          })
          |> verdict(snap)
        after
          Mirror.stop(mirror)
        end

      {:error, why} ->
        {:error, "cannot serve the test-key snapshot: #{inspect(why)}"}
    end
  end

  @same [:sequence, :manifests, :manifests_v2]

  defp verdict({results, info}, snap) do
    served? = Enum.any?(results, &(&1.check == "served_root" and &1.class == :pass))

    cond do
      not (Trust.accepted?(results, info) and served?) ->
        bad = Enum.find(results, &(&1.class != :pass))

        {:error,
         "the harness rejects the test-signed batch: " <>
           if(bad, do: "#{bad.check}: #{bad.detail}", else: "no batch")}

      Map.take(info, @same) != Map.take(snap.info, @same) ->
        {:error, "the test-signed batch names other manifests than the snapshot's"}

      true ->
        :ok
    end
  end
end
