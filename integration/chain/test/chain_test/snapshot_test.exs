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

    %{input: input, served: served, batch: batch, manifest: manifest, tmp: tmp, key: key}
  end

  # Serves `files` as jason's only build and returns the new manifest bytes.
  defp serve_build(ctx, files) do
    manifest = Synthetic.manifest("1.4.5", [Synthetic.build(files, outer: @outer)])
    Synthetic.serve_manifest(ctx.served, "v2/manifests", "jason", manifest)

    for {_path, bytes} <- files do
      File.write!(Path.join([ctx.served, "files", Synthetic.sha(bytes)]), bytes)
    end

    ctx.batch.(manifests_v2: %{"jason" => Synthetic.sha(manifest)})
    manifest
  end

  defp rewrite_meta(dir, fun) do
    path = Path.join(dir, "snapshot.json")
    meta = path |> File.read!() |> JSON.decode!() |> fun.()
    File.write!(path, JSON.encode!(meta))
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

  describe "obtain/1" do
    test "takes a snapshot when the directory holds none", %{input: input} do
      assert {:ok, snap} = Snapshot.obtain(input)
      assert File.exists?(Path.join(snap.dir, "snapshot.json"))
    end

    test "loads the snapshot the directory already holds, without the portal", ctx do
      {:ok, taken} = Snapshot.take(ctx.input)
      File.rm_rf!(ctx.served)

      assert {:ok, loaded} = Snapshot.obtain(ctx.input)
      assert loaded.taken_at == taken.taken_at and loaded.deps == taken.deps
    end

    test "refuses a kept snapshot older than 24 hours", %{input: input} do
      {:ok, _} = Snapshot.take(input)
      old = DateTime.utc_now() |> DateTime.add(-25, :hour) |> DateTime.to_iso8601()
      rewrite_meta(input.dir, &Map.put(&1, "taken_at", old))

      assert {:error, why} = Snapshot.obtain(input)
      assert why =~ "24 hours"
    end

    test "refuses a kept snapshot of another target, source or fixture lock", ctx do
      {:ok, _} = Snapshot.take(ctx.input)

      assert {:error, why} = Snapshot.obtain(%{ctx.input | target: "rpi0_2"})
      assert why =~ "rpi4"

      assert {:error, why} = Snapshot.obtain(%{ctx.input | source: "http://127.0.0.1:1"})
      assert why =~ "source"

      Synthetic.tree(ctx.input.fixture_dir, "rpi4", %{jason: {"1.4.6", @outer}})
      assert {:error, why} = Snapshot.obtain(ctx.input)
      assert why =~ "jason"
    end
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

  describe "fix round 1" do
    test "a served root other than the pinned one is refused and nothing is stored", ctx do
      File.write!(Path.join(ctx.served, "root.json"), Signed.root(Signed.key()))

      assert {:error, why} = Snapshot.take(ctx.input)
      assert why =~ "served_root"
      refute File.exists?(ctx.input.dir)
      assert Path.wildcard(Path.join(ctx.tmp, ".snap*"), match_dot: true) == []
    end

    test "load/1 refuses a stored root other than the pinned one", %{input: input} do
      {:ok, _} = Snapshot.take(input)
      File.write!(Path.join(input.dir, "root.json"), Signed.root(Signed.key()))

      assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
      assert why =~ "served_root"
    end

    test "a dir reached through a symlink into the repository is refused", ctx do
      File.mkdir_p!(ctx.input.repo_root)
      link = Path.join(ctx.tmp, "link")
      File.ln_s!(ctx.input.repo_root, link)

      assert {:error, why} = Snapshot.take(%{ctx.input | dir: Path.join(link, "snap")})
      assert why =~ "inside the repository"
      assert File.ls!(ctx.input.repo_root) == []
    end

    test "the files are downloaded concurrently, all of them verified", ctx do
      files = Map.new(1..40, fn i -> {"ebin/m#{i}.beam", "beam #{i}"} end)
      serve_build(ctx, files)

      assert {:ok, snap} = Snapshot.take(ctx.input)
      assert snap.deps["jason"].files == 40
      assert length(snap.deps["jason"].file_shas) == 40

      for {_path, bytes} <- files do
        assert File.read!(Path.join([ctx.input.dir, "files", Synthetic.sha(bytes)])) == bytes
      end
    end

    test "one bad file among many fails the take", ctx do
      files = Map.new(1..40, fn i -> {"ebin/m#{i}.beam", "beam #{i}"} end)
      serve_build(ctx, files)
      File.write!(Path.join([ctx.served, "files", Synthetic.sha("beam 17")]), "other")

      assert {:error, why} = Snapshot.take(ctx.input)
      assert why =~ "files/#{Synthetic.sha("beam 17")}"
      refute File.exists?(ctx.input.dir)
    end

    test "snapshot.json lists each dep's file shas", %{input: input} do
      {:ok, snap} = Snapshot.take(input)
      expected = @files |> Map.values() |> Enum.map(&Synthetic.sha/1) |> Enum.sort()

      assert Enum.sort(snap.deps["jason"].file_shas) == expected
      meta = JSON.decode!(File.read!(Path.join(input.dir, "snapshot.json")))
      assert Enum.sort(meta["deps"]["jason"]["file_shas"]) == expected
    end

    test "load/1 refuses a dep without a manifest the batch names one for", %{input: input} do
      {:ok, _} = Snapshot.take(input)

      rewrite_meta(input.dir, fn meta ->
        put_in(meta, ["deps", "jason"], %{
          "version" => "1.4.5",
          "manifest" => nil,
          "sha256" => nil,
          "builds" => 0,
          "files" => 0,
          "file_shas" => []
        })
      end)

      assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
      assert why =~ "jason"
      assert why =~ "batch names"
    end

    test "load/1 refuses a listed file that is missing", %{input: input} do
      {:ok, _} = Snapshot.take(input)
      [file | _] = Path.wildcard(Path.join(input.dir, "files/*"))
      File.rm!(file)

      assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
      assert why =~ "files/#{Path.basename(file)}"
    end

    test "load/1 refuses file counts that do not match the listed shas", %{input: input} do
      {:ok, _} = Snapshot.take(input)
      rewrite_meta(input.dir, &put_in(&1, ["deps", "jason", "files"], 5))

      assert {:error, why} = Snapshot.load(input.dir, %{trust_opts: input.trust_opts})
      assert why =~ "jason"
    end
  end
end
