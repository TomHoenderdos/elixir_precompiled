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

  describe "older batches" do
    # Serves batches/<n>.json for each `{n, hours_ago}`, signed by `key`
    # (the root's batch key unless given), naming `manifests_v2`.
    defp serve_older(ctx, batches, opts \\ []) do
      key = Keyword.get(opts, :key, ctx.key)
      v2 = Keyword.get(opts, :manifests_v2, %{"jason" => Synthetic.sha(ctx.manifest)})
      File.mkdir_p!(Path.join(ctx.served, "batches"))

      for {n, hours} <- batches do
        issued = DateTime.add(DateTime.utc_now(), -round(hours * 3600), :second)

        File.write!(
          Path.join(ctx.served, "batches/#{n}.json"),
          Signed.batch(key, sequence: n, issued: issued, manifests: %{}, manifests_v2: v2)
        )
      end
    end

    # The batch.json of the setup is sequence 7, issued now.
    @history [{1, 30}, {2, 27}, {3, 25.5}, {4, 24.5}, {5, 10}, {6, 0.25}]

    test "take/1 stores N-1 and the newest batch issued over 25 h before N", ctx do
      serve_older(ctx, @history)
      assert {:ok, snap} = Snapshot.take(ctx.input)

      assert {:ok, %{sequence: 6, path: "batches/6.json", manifests: %{}}} = snap.previous
      assert {:ok, %{sequence: 3, path: "batches/3.json", manifests: %{}}} = snap.old
      assert Snapshot.older(snap, :previous) == snap.previous

      for n <- [3, 6] do
        assert File.read!(Path.join(ctx.input.dir, "batches/#{n}.json")) ==
                 File.read!(Path.join(ctx.served, "batches/#{n}.json"))
      end

      meta = JSON.decode!(File.read!(Path.join(ctx.input.dir, "snapshot.json")))
      assert meta["previous"] == %{"sequence" => 6}
      assert meta["old"] == %{"sequence" => 3}
    end

    test "an older batch naming another manifest for a fixture dep records it", ctx do
      other = String.duplicate("c", 64)
      serve_older(ctx, @history)
      serve_older(ctx, [{3, 25.5}], manifests_v2: %{"jason" => other})

      assert {:ok, snap} = Snapshot.take(ctx.input)

      assert {:ok, %{manifests: %{"jason" => %{dir: "v2/manifests", sha256: ^other}}}} =
               snap.old

      assert {:ok, %{manifests: %{}}} = snap.previous
    end

    test "missing older batches are missing with the reason, and the take still succeeds",
         ctx do
      assert {:ok, snap} = Snapshot.take(ctx.input)
      assert {:missing, why} = snap.previous
      assert why =~ "batches/6.json"
      assert {:missing, why} = snap.old
      assert why =~ "25 h"

      meta = JSON.decode!(File.read!(Path.join(ctx.input.dir, "snapshot.json")))
      assert %{"missing" => _} = meta["previous"]
      assert %{"missing" => _} = meta["old"]
    end

    test "a history that does not reach 25 h back has no old batch", ctx do
      serve_older(ctx, [{5, 10}, {6, 0.25}])
      assert {:ok, snap} = Snapshot.take(ctx.input)
      assert {:ok, %{sequence: 6}} = snap.previous
      assert {:missing, why} = snap.old
      assert why =~ "25 h"
    end

    test "an older batch that does not verify is missing and not stored", ctx do
      serve_older(ctx, @history)
      serve_older(ctx, [{6, 0.25}, {3, 25.5}], key: Signed.key())

      assert {:ok, snap} = Snapshot.take(ctx.input)
      assert {:missing, why} = snap.previous
      assert why =~ "batch_signature"
      assert {:missing, _} = snap.old
      refute File.exists?(Path.join(ctx.input.dir, "batches/6.json"))
      refute File.exists?(Path.join(ctx.input.dir, "batches/3.json"))
    end

    test "a previous batch issued after N, or ahead of the clock, is missing", ctx do
      for hours <- [-60 / 3600, -1] do
        dir = Path.join(ctx.tmp, "snap-#{System.unique_integer([:positive])}")
        serve_older(ctx, @history)
        serve_older(ctx, [{6, hours}])

        assert {:ok, snap} = Snapshot.take(%{ctx.input | dir: dir})
        assert {:missing, why} = snap.previous
        assert why =~ "batches/6.json"
        refute File.exists?(Path.join(dir, "batches/6.json"))
      end
    end

    test "a batch served under another sequence's name is not that batch", ctx do
      serve_older(ctx, @history)
      File.cp!(Path.join(ctx.served, "batches/5.json"), Path.join(ctx.served, "batches/6.json"))

      assert {:ok, snap} = Snapshot.take(ctx.input)
      assert {:missing, why} = snap.previous
      assert why =~ "sequence"
    end

    test "load/2 re-verifies the older batches", ctx do
      serve_older(ctx, @history)
      {:ok, taken} = Snapshot.take(ctx.input)
      opts = %{trust_opts: ctx.input.trust_opts}

      assert {:ok, loaded} = Snapshot.load(ctx.input.dir, opts)
      assert loaded.previous == taken.previous
      assert loaded.old == taken.old

      issued = DateTime.add(DateTime.utc_now(), -26, :hour)

      File.write!(
        Path.join(ctx.input.dir, "batches/3.json"),
        Signed.batch(Signed.key(), sequence: 3, issued: issued, manifests: %{})
      )

      assert {:error, why} = Snapshot.load(ctx.input.dir, opts)
      assert why =~ "batches/3.json"
    end

    test "load/2 of a snapshot taken before older batches marks them missing", ctx do
      serve_older(ctx, @history)
      {:ok, _} = Snapshot.take(ctx.input)
      rewrite_meta(ctx.input.dir, &Map.drop(&1, ["previous", "old"]))

      assert {:ok, snap} = Snapshot.load(ctx.input.dir, %{trust_opts: ctx.input.trust_opts})
      assert {:missing, why} = Snapshot.older(snap, :old)
      assert why =~ "take a new one"
    end

    test "load/2 refuses older entries that name the wrong batch or are malformed", ctx do
      serve_older(ctx, @history)
      {:ok, _} = Snapshot.take(ctx.input)
      opts = %{trust_opts: ctx.input.trust_opts}

      for {key, entry} <- [
            {"previous", %{"sequence" => 3}},
            {"old", %{"sequence" => 7}},
            {"old", %{"sequence" => 6}},
            {"old", "3"}
          ] do
        rewrite_meta(ctx.input.dir, &Map.put(&1, key, entry))
        assert {:error, _} = Snapshot.load(ctx.input.dir, opts), inspect({key, entry})

        rewrite_meta(
          ctx.input.dir,
          &Map.merge(&1, %{"previous" => %{"sequence" => 6}, "old" => %{"sequence" => 3}})
        )
      end

      assert {:ok, _} = Snapshot.load(ctx.input.dir, opts)
    end

    test "older/2 of a snapshot map without them is missing" do
      assert {:missing, _} = Snapshot.older(%{}, :previous)
    end
  end

  describe "needs" do
    defp needs_snap(tmp, opts) do
      key = Signed.key()
      keys = Keyword.get(opts, :batch_keys, [key])

      File.write!(
        Path.join(tmp, "root.json"),
        Signed.root(key, batch_keys: keys, batch_threshold: Keyword.get(opts, :threshold, 1))
      )

      sha = String.duplicate("a", 64)

      %{
        dir: tmp,
        sequence: 7,
        info: Synthetic.info(7, %{"jason" => sha}),
        deps: %{
          "jason" => %{version: "1.4.5", manifest: "v2/manifests/jason.json", builds: 1},
          "nobuild" => %{version: "0.1.0", manifest: nil, builds: 0}
        },
        previous:
          Keyword.get(
            opts,
            :previous,
            {:ok, %{sequence: 6, info: Synthetic.info(6, %{"jason" => sha})}}
          ),
        old: Keyword.get(opts, :old, {:missing, "the portal keeps no batch that old"})
      }
    end

    @tag :tmp_dir
    test "the older batches are available when the snapshot holds them", %{tmp_dir: tmp} do
      snap = needs_snap(tmp, [])
      assert Snapshot.available(snap, :previous) == :ok
      assert {:missing, why} = Snapshot.available(snap, :old)
      assert why == "the old batch: the portal keeps no batch that old"
    end

    @tag :tmp_dir
    test "previous_manifests: the previous batch names N's manifest for every held dep",
         %{tmp_dir: tmp} do
      assert Snapshot.available(needs_snap(tmp, []), :previous_manifests) == :ok

      other =
        {:ok, %{sequence: 6, info: Synthetic.info(6, %{"jason" => String.duplicate("b", 64)})}}

      assert {:missing, why} =
               Snapshot.available(needs_snap(tmp, previous: other), :previous_manifests)

      assert why =~ "jason"
      assert why =~ "previous"

      # A held dep the previous batch does not name at all is a difference too.
      none = {:ok, %{sequence: 6, info: Synthetic.info(6, %{})}}

      assert {:missing, why} =
               Snapshot.available(needs_snap(tmp, previous: none), :previous_manifests)

      assert why =~ "jason"

      missing = {:missing, "404"}

      assert {:missing, why} =
               Snapshot.available(needs_snap(tmp, previous: missing), :previous_manifests)

      assert why =~ "404"
    end

    @tag :tmp_dir
    test "batch_threshold_2: the root's batch role needs two signatures", %{tmp_dir: tmp} do
      assert {:missing, why} = Snapshot.available(needs_snap(tmp, []), :batch_threshold_2)
      assert why =~ "batch threshold is 1 in production"

      two = [Signed.key(), Signed.key()]

      assert Snapshot.available(
               needs_snap(tmp, batch_keys: two, threshold: 2),
               :batch_threshold_2
             ) == :ok
    end

    @tag :tmp_dir
    test "issued/1 is the snapshot batch's issue instant", %{tmp_dir: tmp} do
      key = Signed.key()
      issued = ~U[2026-11-04 10:00:00.000000Z]
      File.write!(Path.join(tmp, "batch.json"), Signed.batch(key, issued: issued))
      assert Snapshot.issued(%{dir: tmp}) == {:ok, issued}

      File.write!(Path.join(tmp, "batch.json"), "{}")
      assert {:error, _} = Snapshot.issued(%{dir: tmp})
    end

    test "need_names/0 lists every need a transform or setup may name" do
      assert Enum.sort(Snapshot.need_names()) ==
               Enum.sort([:previous, :old, :previous_manifests, :batch_threshold_2])
    end
  end
end
