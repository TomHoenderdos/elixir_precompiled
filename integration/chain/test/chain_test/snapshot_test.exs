# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.SnapshotTest do
  use ExUnit.Case, async: true

  alias ChainTest.{LocalServer, Signed, Snapshot, Synthetic}

  @moduletag :tmp_dir

  @outer String.duplicate("a", 64)
  @files %{"ebin/Elixir.Jason.beam" => "jason beam", "ebin/jason.app" => "jason app"}

  # A served "portal": a test root, a batch naming jason's v2 manifest, the
  # manifest with one pure build, and its files. The fixture lock pins jason
  # and the rpi4 system (for which the batch names no manifest).
  setup %{tmp_dir: tmp} do
    key = Signed.key()
    root = Signed.root(key)
    root_path = Path.join(tmp, "root.json")
    File.write!(root_path, root)

    served = Path.join(tmp, "served")
    manifest = Synthetic.manifest("1.4.5", [Synthetic.build(@files, outer: @outer)])
    Synthetic.serve_manifest(served, "v2/manifests", "jason", manifest)

    for {_path, bytes} <- @files do
      File.mkdir_p!(Path.join(served, "files"))
      File.write!(Path.join([served, "files", Synthetic.sha(bytes)]), bytes)
    end

    File.write!(Path.join(served, "root.json"), root)

    batch = fn opts ->
      opts =
        Keyword.merge(
          [manifests: %{}, manifests_v2: %{"jason" => Synthetic.sha(manifest)}],
          opts
        )

      File.write!(Path.join(served, "batch.json"), Signed.batch(key, opts))
    end

    batch.([])
    {source, pid} = LocalServer.serve(served)
    on_exit(fn -> LocalServer.stop(pid) end)

    fixture = Path.join(tmp, "fixture")
    Synthetic.tree(fixture, "rpi4", %{jason: {"1.4.5", @outer}})

    input = %{
      source: source,
      fixture_dir: fixture,
      target: "rpi4",
      dir: Path.join(tmp, "snap"),
      repo_root: Path.join(tmp, "repo"),
      trust_opts: %{root_path: root_path, library_root_path: root_path}
    }

    %{input: input, served: served, batch: batch, manifest: manifest, tmp: tmp}
  end

  test "take/1 stores the verified layout and describes it", %{input: input, manifest: manifest} do
    assert {:ok, snap} = Snapshot.take(input)
    dir = input.dir

    assert snap.dir == dir
    assert snap.sequence == 7

    assert File.read!(Path.join(dir, "batches/7.json")) ==
             File.read!(Path.join(dir, "batch.json"))

    assert File.read!(Path.join(dir, "v2/manifests/jason.json")) == manifest

    for {_path, bytes} <- @files do
      assert File.read!(Path.join([dir, "files", Synthetic.sha(bytes)])) == bytes
    end

    assert %{version: "1.4.5", manifest: "v2/manifests/jason.json", builds: 1, files: 2} =
             snap.deps["jason"]

    assert %{manifest: nil, builds: 0} = snap.deps["nerves_system_rpi4"]

    meta = JSON.decode!(File.read!(Path.join(dir, "snapshot.json")))
    assert meta["sequence"] == 7 and meta["target"] == "rpi4"
    assert meta["deps"]["jason"]["sha256"] == Synthetic.sha(manifest)
  end

  test "take/1 keeps the snapshot private to its owner", %{input: input} do
    assert {:ok, _} = Snapshot.take(input)

    for path <- [input.dir | Path.wildcard(Path.join(input.dir, "**"), match_dot: true)] do
      %File.Stat{mode: mode, type: type} = File.lstat!(path)

      expected = if type == :directory, do: 0o700, else: 0o600

      assert Bitwise.band(mode, 0o777) == expected,
             "#{path} has mode #{inspect(mode, base: :octal)}"
    end
  end

  test "take/1 accepts an existing empty directory", %{input: input} do
    File.mkdir_p!(input.dir)
    assert {:ok, _} = Snapshot.take(input)
    assert File.exists?(Path.join(input.dir, "snapshot.json"))
  end

  test "a directory inside the repository is refused before any download", %{input: input} do
    inside = Path.join(input.repo_root, "integration/chain/snap")

    assert {:error, why} = Snapshot.take(%{input | dir: inside})
    assert why =~ "inside the repository"
    refute File.exists?(inside)
  end

  test "a directory that is not empty is refused", %{input: input} do
    File.mkdir_p!(input.dir)
    File.write!(Path.join(input.dir, "x"), "x")
    assert {:error, why} = Snapshot.take(input)
    assert why =~ "not empty"
  end

  test "a symlink as the directory is refused", %{input: input, tmp: tmp} do
    target = Path.join(tmp, "elsewhere")
    File.mkdir_p!(target)
    File.ln_s!(target, input.dir)

    assert {:error, why} = Snapshot.take(input)
    assert why =~ "not a directory"
    assert File.ls!(target) == []
  end

  test "a manifest that no longer hashes to the batch means production moved", ctx do
    Synthetic.serve_manifest(ctx.served, "v2/manifests", "jason", ctx.manifest <> " ")

    assert {:error, why} = Snapshot.take(ctx.input)
    assert why =~ "production moved"
    refute File.exists?(Path.join(ctx.input.dir, "snapshot.json"))
  end

  test "a failed take leaves nothing behind, not even a partial directory", ctx do
    Synthetic.serve_manifest(ctx.served, "v2/manifests", "jason", ctx.manifest <> " ")

    assert {:error, _} = Snapshot.take(ctx.input)
    refute File.exists?(ctx.input.dir)
    assert Path.wildcard(Path.join(ctx.tmp, ".snap*"), match_dot: true) == []
  end

  test "a file whose bytes do not hash to its name is refused", ctx do
    [{_, bytes} | _] = Enum.to_list(@files)
    File.write!(Path.join([ctx.served, "files", Synthetic.sha(bytes)]), "other bytes")

    assert {:error, why} = Snapshot.take(ctx.input)
    assert why =~ "files/"
    refute File.exists?(Path.join(ctx.input.dir, "snapshot.json"))
  end

  test "a stale batch is refused", ctx do
    ctx.batch.(issued: DateTime.add(DateTime.utc_now(), -25, :hour))

    assert {:error, why} = Snapshot.take(ctx.input)
    assert why =~ "rejects the snapshot's batch"
  end

  test "load/1 re-verifies a taken snapshot", %{input: input} do
    {:ok, taken} = Snapshot.take(input)
    assert {:ok, loaded} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
    assert loaded.deps == taken.deps and loaded.sequence == taken.sequence
    assert loaded.taken_at == taken.taken_at
  end

  test "load/1 refuses a snapshot whose stored bytes changed", %{input: input} do
    {:ok, _} = Snapshot.take(input)
    [file | _] = Path.wildcard(Path.join(input.dir, "files/*"))
    File.write!(file, "tampered")

    assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
    assert why =~ "files/"
  end

  test "load/1 refuses a stored batch copy that differs from batch.json", %{input: input} do
    {:ok, _} = Snapshot.take(input)
    File.write!(Path.join(input.dir, "batches/7.json"), "{}")

    assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
    assert why =~ "batches/7.json"
  end

  test "load/1 refuses a snapshot taken more than 24 hours ago", %{input: input} do
    {:ok, _} = Snapshot.take(input)
    path = Path.join(input.dir, "snapshot.json")
    old = DateTime.utc_now() |> DateTime.add(-25, :hour) |> DateTime.to_iso8601()
    meta = path |> File.read!() |> JSON.decode!() |> Map.put("taken_at", old)
    File.write!(path, JSON.encode!(meta))

    assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
    assert why =~ "older than 24 hours"
  end

  test "load/1 refuses an incomplete snapshot", %{input: input} do
    File.mkdir_p!(input.dir)
    assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
    assert why =~ "not a complete snapshot"
  end

  test "default_dir/0 is outside the repository and unique" do
    a = Snapshot.default_dir()
    assert String.starts_with?(a, Path.expand(System.tmp_dir!()))
    refute a == Snapshot.default_dir()
  end
end
