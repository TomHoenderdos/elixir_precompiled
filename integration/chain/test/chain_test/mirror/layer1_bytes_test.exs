# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Layer1BytesTest do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Setup
  alias ChainTest.Conformance.Setup.Cache
  alias ChainTest.Mirror

  alias ChainTest.Mirror.{
    Drip,
    FileBytes,
    ManifestBytes,
    OlderBatch,
    OlderManifest,
    Redirect,
    Status,
    Transform
  }

  @moduletag :tmp_dir

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # A snapshot dir with two held deps' manifests and three files (one empty).
  setup %{tmp_dir: tmp} do
    dir = Path.join(tmp, "snap")
    File.mkdir_p!(Path.join(dir, "v2/manifests"))
    File.mkdir_p!(Path.join(dir, "files"))
    File.write!(Path.join(dir, "v2/manifests/ash.json"), ~s({"ash":1}))
    File.write!(Path.join(dir, "v2/manifests/jason.json"), ~s({"jason":1}))

    files = ["ebin bytes of jason", "ebin bytes of ash", ""]
    for f <- files, do: File.write!(Path.join(dir, "files/" <> sha(f)), f)

    snap = %{
      dir: dir,
      sequence: 9,
      deps: %{
        "jason" => %{
          manifest: "v2/manifests/jason.json",
          builds: 1,
          file_shas: [sha("ebin bytes of jason"), sha("")]
        },
        "ash" => %{
          manifest: "v2/manifests/ash.json",
          builds: 1,
          file_shas: [sha("ebin bytes of ash")]
        },
        "plug" => %{manifest: nil, builds: 0, file_shas: []}
      }
    }

    %{snap: snap, files: files}
  end

  defp args(args, snap, mirror \\ 1, second \\ "http://127.0.0.1:2"),
    do: Map.put(args, :case, %{mirror: mirror, second_url: second, snapshot: snap})

  describe "ManifestBytes (M1, M2)" do
    test "flip_byte changes exactly one byte of every manifest, nothing else", ctx do
      bytes = File.read!(Path.join(ctx.snap.dir, "v2/manifests/jason.json"))
      a = args(%{change: :flip_byte}, ctx.snap)

      for path <- ["v2/manifests/jason.json", "manifests/jason.json"] do
        assert {200, out} = ManifestBytes.transform(path, bytes, a)
        assert byte_size(out) == byte_size(bytes)

        diff =
          for {x, y} <- Enum.zip(:binary.bin_to_list(out), :binary.bin_to_list(bytes)),
              x != y,
              do: x

        assert length(diff) == 1
      end

      assert ManifestBytes.transform("batch.json", "b", a) == {200, "b"}
      assert ManifestBytes.transform("files/" <> sha("x"), "x", a) == {200, "x"}
    end

    test "swap serves another held dep's manifest in place of each", ctx do
      jason = File.read!(Path.join(ctx.snap.dir, "v2/manifests/jason.json"))
      ash = File.read!(Path.join(ctx.snap.dir, "v2/manifests/ash.json"))
      a = args(%{change: :swap}, ctx.snap)

      assert ManifestBytes.transform("v2/manifests/jason.json", jason, a) == {200, ash}
      assert ManifestBytes.transform("v2/manifests/ash.json", ash, a) == {200, jason}
    end

    test "swap with a single manifest raises: nothing to swap with", ctx do
      snap = %{ctx.snap | deps: Map.take(ctx.snap.deps, ["jason"])}
      jason = File.read!(Path.join(ctx.snap.dir, "v2/manifests/jason.json"))

      assert_raise ArgumentError, fn ->
        ManifestBytes.transform("v2/manifests/jason.json", jason, args(%{change: :swap}, snap))
      end
    end

    test "args" do
      assert Transform.valid?({ManifestBytes, %{change: :flip_byte}})
      assert Transform.valid?({ManifestBytes, %{change: :swap}})
      refute Transform.valid?({ManifestBytes, %{change: :other}})
      refute Transform.valid?({ManifestBytes, %{change: :swap, extra: 1}})
    end
  end

  describe "FileBytes (F1, F2)" do
    setup ctx, do: %{f: hd(ctx.files), path: "files/" <> sha(hd(ctx.files))}

    test "flip_byte changes one byte of a file; an empty file is served as it is", ctx do
      assert {200, out} = FileBytes.transform(ctx.path, ctx.f, %{change: :flip_byte})
      assert byte_size(out) == byte_size(ctx.f) and out != ctx.f
      assert FileBytes.transform("files/" <> sha(""), "", %{change: :flip_byte}) == {200, ""}
      assert FileBytes.transform("batch.json", "b", %{change: :flip_byte}) == {200, "b"}
    end

    test "truncate declares the whole file and sends one byte less", ctx do
      n = byte_size(ctx.f) - 1
      assert {:truncate, 200, f, ^n} = FileBytes.transform(ctx.path, ctx.f, %{change: :truncate})
      assert f == ctx.f
      assert FileBytes.transform("files/" <> sha(""), "", %{change: :truncate}) == {200, ""}
    end

    test "larger sends one byte more than the manifest's size", ctx do
      assert {200, out} = FileBytes.transform(ctx.path, ctx.f, %{change: :larger})
      assert byte_size(out) == byte_size(ctx.f) + 1
    end

    test "endless never ends on its own", ctx do
      assert {:endless, 200, chunk, 0} = FileBytes.transform(ctx.path, ctx.f, %{change: :endless})
      assert byte_size(chunk) > 0
    end

    test "args" do
      for c <- [:flip_byte, :truncate, :larger, :endless],
          do: assert(Transform.valid?({FileBytes, %{change: c}}))

      refute Transform.valid?({FileBytes, %{change: :other}})
    end
  end

  describe "Redirect (N1)" do
    test "the case mirror redirects the named paths to the second mirror, which serves them",
         ctx do
      a = args(%{paths: :files, mirrors: 2}, ctx.snap)
      path = "files/" <> sha("x")

      assert Redirect.transform(path, "x", a) ==
               {:redirect, 302, "http://127.0.0.1:2/" <> path}

      assert Redirect.transform("batch.json", "b", a) == {200, "b"}

      assert Redirect.transform(path, "x", args(%{paths: :files, mirrors: 2}, ctx.snap, 2)) ==
               {200, "x"}

      b = args(%{paths: :batch, mirrors: 2}, ctx.snap)

      assert {:redirect, 302, "http://127.0.0.1:2/batch.json"} =
               Redirect.transform("batch.json", "b", b)

      m = args(%{paths: :manifests, mirrors: 2}, ctx.snap)

      assert {:redirect, 302, "http://127.0.0.1:2/v2/manifests/jason.json"} =
               Redirect.transform("v2/manifests/jason.json", "m", m)
    end

    test "args need the second mirror" do
      assert Transform.valid?({Redirect, %{paths: :files, mirrors: 2}})
      refute Transform.valid?({Redirect, %{paths: :files}})
      refute Transform.valid?({Redirect, %{paths: :other, mirrors: 2}})
    end
  end

  describe "Drip (N4)" do
    test "sends the named path one byte at a time, with the delay" do
      assert {:stream, 200, chunks, 2_000} =
               Drip.transform("batch.json", "abc", %{paths: :batch, stream_max_ms: 330_000})

      assert chunks == ["a", "b", "c"]
      assert Drip.transform("root.json", "r", %{paths: :batch, stream_max_ms: 1}) == {200, "r"}
    end

    test "stream_max_ms is the transform's mirror option, bounded" do
      assert Transform.valid?({Drip, %{paths: :batch, stream_max_ms: 330_000}})

      assert Transform.mirror_opts({Drip, %{paths: :batch, stream_max_ms: 330_000}}) ==
               [stream_max_ms: 330_000]

      assert Transform.mirror_opts({ChainTest.Mirror.Identity, %{}}) == []
      refute Transform.valid?({Drip, %{paths: :batch, stream_max_ms: 0}})
      refute Transform.valid?({Drip, %{paths: :batch, stream_max_ms: 600_001}})
      refute Transform.valid?({Drip, %{paths: :batch}})
    end

    @tag timeout: 20_000
    test "a mirror honours it: a drip outliving the cap is cut there", ctx do
      {:ok, m} =
        Mirror.start(ctx.snap.dir,
          transform: Transform.fun({Drip, %{paths: :batch, delay_ms: 50, stream_max_ms: 300}}),
          stream_max_ms: 300
        )

      File.write!(Path.join(ctx.snap.dir, "batch.json"), String.duplicate("x", 100))
      started = System.monotonic_time(:millisecond)
      {:ok, body} = ChainTest.HTTP.get(m.url <> "/batch.json", 5_000)
      took = System.monotonic_time(:millisecond) - started
      Mirror.stop(m)

      assert byte_size(body) < 100
      assert took < 2_000
    end
  end

  describe "OlderManifest (M3) and OlderBatch recheck (R16)" do
    test "OlderManifest needs older manifest bytes and serves them under N's path", ctx do
      assert Transform.needs({OlderManifest, %{}}) == [:older_manifest_bytes]
      old = ~s({"jason":0})
      File.mkdir_p!(Path.join(ctx.snap.dir, "older_manifests"))
      File.write!(Path.join(ctx.snap.dir, "older_manifests/#{sha(old)}.json"), old)

      snap =
        Map.put(
          ctx.snap,
          :previous,
          {:ok, %{sequence: 8, manifests: %{"jason" => %{dir: "v2/manifests", sha256: sha(old)}}}}
        )

      a = args(%{}, snap)
      assert OlderManifest.transform("v2/manifests/jason.json", "new", a) == {200, old}
      assert OlderManifest.transform("v2/manifests/ash.json", "a", a) == {200, "a"}
    end

    test "OlderBatch recheck: true needs a previous batch that differs" do
      assert Transform.needs({OlderBatch, %{batch: :previous, recheck: true}}) ==
               [:previous, :previous_differs]

      refute Transform.valid?({OlderBatch, %{batch: :old, recheck: true}})
      refute Transform.valid?({OlderBatch, %{batch: :previous, recheck: true, hits: true}})
    end
  end

  describe "Setup.Cache (C1, C2, R15)" do
    defp planted(home, ctx, plant) do
      assert :ok = Setup.run({Cache, %{plant: plant}}, home, ctx.snap)
    end

    test "all_files plants every file of every held build, verified", ctx do
      home = Path.join(ctx.tmp_dir, "home")
      planted(home, ctx, :all_files)

      for f <- ctx.files,
          do: assert(File.read!(Path.join(home, "files/" <> sha(f))) == f)
    end

    test "corrupt_files plants each non-empty file with one byte changed, same size", ctx do
      home = Path.join(ctx.tmp_dir, "home")
      planted(home, ctx, :corrupt_files)

      for f <- ctx.files, f != "" do
        got = File.read!(Path.join(home, "files/" <> sha(f)))
        assert byte_size(got) == byte_size(f) and got != f
      end

      refute File.exists?(Path.join(home, "files/" <> sha("")))
    end

    test "link_entries makes each cache entry a symlink to the right bytes outside the cache",
         ctx do
      home = Path.join(ctx.tmp_dir, "home")
      planted(home, ctx, :link_entries)

      for f <- ctx.files do
        entry = Path.join(home, "files/" <> sha(f))
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(entry)
        {:ok, to} = File.read_link(entry)
        assert String.starts_with?(to, Path.join(home, Setup.outside_dir()) <> "/")
        assert File.read!(entry) == f
      end
    end

    test "link_dir makes the cache dir a symlink to an empty dir outside it", ctx do
      home = Path.join(ctx.tmp_dir, "home")
      planted(home, ctx, :link_dir)

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(home, "files"))
      {:ok, to} = File.read_link(Path.join(home, "files"))
      assert String.starts_with?(to, Path.join(home, Setup.outside_dir()))
      assert File.ls!(to) == []
    end

    test "a snapshot with no held files is an error, not a vacuous setup", ctx do
      home = Path.join(ctx.tmp_dir, "home")
      snap = %{ctx.snap | deps: %{}}
      assert {:error, why} = Setup.run({Cache, %{plant: :all_files}}, home, snap)
      assert why =~ "no file"
    end

    test "deps: all_files plants only the named deps' files", ctx do
      home = Path.join(ctx.tmp_dir, "home")
      assert :ok = Setup.run({Cache, %{plant: :all_files, deps: ["jason"]}}, home, ctx.snap)

      assert Enum.sort(File.ls!(Path.join(home, "files"))) ==
               Enum.sort(ctx.snap.deps["jason"].file_shas)

      for sha <- ctx.snap.deps["jason"].file_shas,
          do: assert(sha(File.read!(Path.join(home, "files/" <> sha))) == sha)
    end

    test "deps naming no held file is an error, not a vacuous setup", ctx do
      home = Path.join(ctx.tmp_dir, "home")

      for deps <- [["plug"], ["absent"]] do
        assert {:error, why} =
                 Setup.run({Cache, %{plant: :all_files, deps: deps}}, home, ctx.snap)

        assert why =~ "no file"
      end
    end

    test "args" do
      for p <- [:all_files, :corrupt_files, :link_entries, :link_dir],
          do: assert(Setup.valid?({Cache, %{plant: p}}))

      assert Setup.valid?({Cache, %{plant: :all_files, deps: ["jason"]}})
      refute Setup.valid?({Cache, %{plant: :all_files, deps: []}})
      refute Setup.valid?({Cache, %{plant: :all_files, deps: [:jason]}})
      refute Setup.valid?({Cache, %{plant: :link_dir, deps: ["jason"]}})
      refute Setup.valid?({Cache, %{plant: :other}})
      refute Setup.valid?({Cache, %{}})
    end
  end

  describe "Status files_of (C0)" do
    test "answers the status for every file of the named dep, the rest unchanged", ctx do
      a = args(%{files_of: "jason", status: 404}, ctx.snap)

      for sha <- ctx.snap.deps["jason"].file_shas,
          do: assert(Status.transform("files/" <> sha, "x", a) == {404, ""})

      [ash] = ctx.snap.deps["ash"].file_shas
      assert Status.transform("files/" <> ash, "y", a) == {200, "y"}
      assert Status.transform("v2/manifests/jason.json", "m", a) == {200, "m"}
      assert Status.transform("batch.json", "b", a) == {200, "b"}
    end

    test "args: files_of a dep name instead of paths; only it is a trap" do
      assert Transform.valid?({Status, %{files_of: "jason", status: 404}})
      refute Transform.valid?({Status, %{files_of: "", status: 404}})
      refute Transform.valid?({Status, %{files_of: :jason, status: 404}})
      refute Transform.valid?({Status, %{files_of: "jason", paths: ["batch.json"], status: 404}})

      assert Transform.trap?({Status, %{files_of: "jason", status: 404}})
      refute Transform.trap?({Status, %{paths: ["batch.json"], status: 404}})
      refute Transform.trap?({ChainTest.Mirror.Identity, %{}})
    end
  end
end
