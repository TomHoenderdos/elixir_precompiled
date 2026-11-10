# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.StoreTest do
  use ExUnit.Case, async: true
  alias Precompiled.Device.Store
  alias Precompiled.Fetch
  alias Precompiled.Match

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    assert :ok = Store.ensure_root(dir)
    :ok
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A staged build plus the manifest entry and provenance that describe it.
  defp stage_entry(dir, app, vsn, bytes, last_used) do
    app_bytes = "{application,#{app},[{vsn,\"#{vsn}\"},{modules,[]}]}.\n"

    entry = %{
      "ebin" => [
        %{
          "path" => "ebin/#{app}.app",
          "sha256" => sha(app_bytes),
          "size" => byte_size(app_bytes),
          "mode" => 420
        }
      ],
      "priv" => [
        %{
          "path" => "priv/data.bin",
          "sha256" => sha(bytes),
          "size" => byte_size(bytes),
          "mode" => 420
        }
      ]
    }

    s = Store.staging(dir, app, vsn)
    File.mkdir_p!(Path.join(s, "ebin"))
    File.mkdir_p!(Path.join(s, "priv"))
    File.write!(Path.join([s, "ebin", "#{app}.app"]), app_bytes)
    File.write!(Path.join([s, "priv", "data.bin"]), bytes)
    File.chmod!(Path.join([s, "ebin", "#{app}.app"]), 0o644)
    File.chmod!(Path.join([s, "priv", "data.bin"]), 0o644)

    prov = %{
      "package" => "#{app}",
      "version" => vsn,
      "files_sha256" => Match.files_hash(entry),
      "files" => entry["ebin"] ++ entry["priv"],
      "last_used" => last_used
    }

    {s, entry, prov}
  end

  # A committed build that ships no priv.
  defp put_ebin_only(dir, app, vsn) do
    {s, entry, prov} = stage_entry(dir, app, vsn, "x", 0)
    File.rm_rf!(Path.join(s, "priv"))
    entry = Map.put(entry, "priv", [])

    prov =
      prov
      |> Map.put("files_sha256", Match.files_hash(entry))
      |> Map.put("files", entry["ebin"])

    {:ok, path} = Store.commit(s, dir, app, vsn, prov, %{})
    {path, entry}
  end

  # A cache entry on disk plus the manifest entry that describes it.
  defp put_entry(dir, app, vsn, bytes \\ "beam-bytes", last_used \\ 0) do
    {s, entry, prov} = stage_entry(dir, app, vsn, bytes, last_used)
    {:ok, path} = Store.commit(s, dir, app, vsn, prov, %{})
    {path, entry}
  end

  # Which build the disk holds, judged without touching it (cached/4
  # removes what does not match).
  defp on_disk(dir, app, vsn, old, new) do
    path = Path.join(dir, "#{app}-#{vsn}")

    cond do
      not File.exists?(path) -> :none
      whole?(path, app, old) -> :old
      whole?(path, app, new) -> :new
      true -> :broken
    end
  end

  defp whole?(path, app, entry) do
    with {:ok, bytes} <- File.read(Path.join(path, ".precompiled.json")),
         %{"files_sha256" => hash} <- :json.decode(bytes) do
      hash == Match.files_hash(entry) and Fetch.installed_at?(path, app, entry)
    else
      _ -> false
    end
  end

  defp age_staging(dir) do
    staging = Path.join(dir, ".staging")

    for name <- File.ls!(staging),
        do: File.touch!(Path.join(staging, name), System.os_time(:second) - 7200)
  end

  defp renamed?(step), do: step == :renamed

  # Runs commit in its own process and kills that process at `step`.
  defp crash_commit(s, dir, app, vsn, prov, step) do
    {pid, ref} =
      spawn_monitor(fn ->
        hook = fn at -> if at == step, do: Process.exit(self(), :kill) end
        Store.commit(s, dir, app, vsn, prov, %{}, hook: hook)
        exit(:finished)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5000
    reason
  end

  describe "commit" do
    test "commit is a rename: the entry appears whole, with provenance", %{tmp_dir: dir} do
      {path, _} = put_entry(dir, :recon, "2.5.6")
      assert path == Path.join(dir, "recon-2.5.6")
      assert File.regular?(Path.join(path, ".precompiled.json"))
      assert File.ls!(Path.join(dir, ".staging")) == []
      assert [%{app: :recon, version: "2.5.6"}] = Store.list(dir)
    end

    test "a new build of the same app and version replaces the entry unless it is loaded",
         %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6", "one")
      {_, entry2} = put_entry(dir, :recon, "2.5.6", "two")
      assert {:hit, _} = Store.cached(dir, :recon, "2.5.6", entry2)
      s = Store.staging(dir, :recon, "2.5.6")

      assert {:error, {:already_present, :recon, "2.5.6"}} =
               Store.commit(s, dir, :recon, "2.5.6", %{}, %{recon: "2.5.6"})
    end

    test "provenance gets a last_used when the caller gives none", %{tmp_dir: dir} do
      {s, _entry, prov} = stage_entry(dir, :recon, "2.5.6", "x", 0)
      {:ok, _} = Store.commit(s, dir, :recon, "2.5.6", Map.delete(prov, "last_used"), %{})
      [%{provenance: %{"last_used" => t}}] = Store.list(dir)
      assert t >= System.os_time(:second) - 5
    end

    test "refuses a staging dir outside the store's .staging", %{tmp_dir: dir} do
      outside = Path.join(dir, "elsewhere")
      File.mkdir_p!(outside)

      assert {:error, {:bad_staging, _}} =
               Store.commit(outside, dir, :recon, "2.5.6", %{}, %{})

      sneaky = Path.join([dir, ".staging", "..", "elsewhere"])
      assert {:error, {:bad_staging, _}} = Store.commit(sneaky, dir, :recon, "2.5.6", %{}, %{})
      assert File.dir?(outside)
    end

    test "refuses a version that is not one path component", %{tmp_dir: dir} do
      s = Store.staging(dir, :recon, "2.5.6")

      for vsn <- ["../x", "1.0/..", "", "1.0\0", "..", "x1.0"] do
        assert {:error, {:bad_version, ^vsn}} = Store.commit(s, dir, :recon, vsn, %{}, %{})
      end

      assert File.dir?(s)
    end

    test "refuses a store without the marker", %{tmp_dir: dir} do
      bare = Path.join(dir, "bare")
      File.mkdir_p!(Path.join(bare, ".staging/recon-1.0.0.1-1"))
      s = Path.join(bare, ".staging/recon-1.0.0.1-1")

      assert {:error, {:unsafe_store, :no_marker}} =
               Store.commit(s, bare, :recon, "1.0.0", %{}, %{})
    end
  end

  describe "crash safety" do
    for step <- [:staged, :provenance, :moved_old, :renamed] do
      test "a commit killed at #{step} leaves the old build or the new one, never a mix",
           %{tmp_dir: dir} do
        step = unquote(step)
        {_, old} = put_entry(dir, :recon, "2.5.6", "one")
        {s, new, prov} = stage_entry(dir, :recon, "2.5.6", "two", 5)

        assert crash_commit(s, dir, :recon, "2.5.6", prov, step) == :killed

        # Before any recovery nothing on disk verifies as a mix of the two.
        assert on_disk(dir, :recon, "2.5.6", old, new) in [:old, :new, :none]

        # The sweep at the start of the next call restores the state.
        :ok = Store.sweep(dir)
        expected = if renamed?(step), do: :new, else: :old
        assert on_disk(dir, :recon, "2.5.6", old, new) == expected

        hit = if renamed?(step), do: new, else: old
        assert {:hit, _} = Store.cached(dir, :recon, "2.5.6", hit)

        age_staging(dir)
        :ok = Store.sweep(dir)
        assert File.ls!(Path.join(dir, ".staging")) == []
      end
    end

    for step <- [:staged, :provenance, :renamed] do
      test "a first install killed at #{step} leaves nothing or the whole build",
           %{tmp_dir: dir} do
        step = unquote(step)
        {s, new, prov} = stage_entry(dir, :recon, "2.5.6", "two", 5)
        assert crash_commit(s, dir, :recon, "2.5.6", prov, step) == :killed
        :ok = Store.sweep(dir)

        if renamed?(step) do
          assert {:hit, _} = Store.cached(dir, :recon, "2.5.6", new)
        else
          assert :miss = Store.cached(dir, :recon, "2.5.6", new)
          assert Store.list(dir) == []
        end
      end
    end

    test "a staged build is never a hit, however complete", %{tmp_dir: dir} do
      {_s, entry, _prov} = stage_entry(dir, :recon, "2.5.6", "two", 5)
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      assert Store.list(dir) == []
    end

    test "an entry whose files did not reach the disk is a miss and is removed",
         %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6", "some-bytes")
      File.write!(Path.join(path, "priv/data.bin"), "")
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      refute File.exists?(path)

      {path, entry} = put_entry(dir, :recon, "2.5.6", "some-bytes")
      File.rm!(Path.join(path, "priv/data.bin"))
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      refute File.exists?(path)
    end

    test "a torn or missing provenance is a miss, and the sweep removes the entry",
         %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      File.write!(Path.join(path, ".precompiled.json"), "{\"files_sha")
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      refute File.exists?(path)

      {path, _entry} = put_entry(dir, :recon, "2.5.6")
      File.write!(Path.join(path, ".precompiled.json"), "{\"files_sha")
      :ok = Store.sweep(dir)
      refute File.exists?(path)
    end

    test "a stray top-level entry next to ebin and priv is a miss", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      File.mkdir_p!(Path.join(path, "include"))
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
    end

    test "touch rewrites the provenance atomically", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      :ok = Store.touch(dir, :recon, "2.5.6")
      assert Enum.sort(File.ls!(path)) == [".precompiled.json", "ebin", "priv"]
      assert {:hit, _} = Store.cached(dir, :recon, "2.5.6", entry)
    end
  end

  describe "cached/4" do
    test "an ebin-only build with an undeclared priv is a miss", %{tmp_dir: dir} do
      {path, entry} = put_ebin_only(dir, :recon, "2.5.6")
      assert {:hit, ^path} = Store.cached(dir, :recon, "2.5.6", entry)
      File.mkdir_p!(Path.join(path, "priv"))
      File.write!(Path.join(path, "priv/evil.so"), "elf")
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      refute File.exists?(path)

      {path, entry} = put_ebin_only(dir, :recon, "2.5.6")
      File.mkdir_p!(Path.join(path, "priv"))
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
    end

    test "a symlinked entry is a miss, and only the link is removed", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      elsewhere = Path.join(dir, "elsewhere")
      File.rename!(path, elsewhere)
      File.ln_s!(elsewhere, path)
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      assert {:error, :enoent} = File.lstat(path)
      assert File.dir?(elsewhere)
    end

    test "a hit only when every file still has its signed hash", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      assert {:hit, ^path} = Store.cached(dir, :recon, "2.5.6", entry)
      File.write!(Path.join(path, "priv/data.bin"), "evil-bytes")
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      refute File.exists?(path)
    end

    test "an extra file or another build is a miss", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      File.write!(Path.join(path, "ebin/Elixir.Extra.beam"), "x")
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      {_, entry} = put_entry(dir, :recon, "2.5.6")
      other = put_in(entry, ["priv", Access.at(0), "sha256"], String.duplicate("f", 64))
      assert :miss = Store.cached(dir, :recon, "2.5.6", other)
    end

    test "a changed mode is a miss", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      File.chmod!(Path.join(path, "priv/data.bin"), 0o755)
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
    end

    test "a provenance that names another build is a miss even with the right files",
         %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6")
      prov = Path.join(path, ".precompiled.json")
      doc = prov |> File.read!() |> :json.decode() |> Map.put("files_sha256", "0")
      File.write!(prov, :json.encode(doc))
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
    end

    test "no entry is a miss", %{tmp_dir: dir} do
      assert :miss = Store.cached(dir, :recon, "2.5.6", %{"ebin" => []})
      assert :miss = Store.cached(dir, :recon, "../x", %{"ebin" => []})
    end
  end

  describe "sweep" do
    test "entries survive a sweep; stale staging and entries without provenance do not",
         %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6")
      stale = Store.staging(dir, :x, "1.0.0")
      File.touch!(stale, System.os_time(:second) - 7200)
      File.mkdir_p!(Path.join(dir, "junk-1.0.0/ebin"))
      Store.sweep(dir)
      assert [%{app: :recon}] = Store.list(dir)
      refute File.exists?(stale)
      refute File.exists?(Path.join(dir, "junk-1.0.0"))
    end

    test "fresh staging, .trust and the marker stay; unknown names go", %{tmp_dir: dir} do
      {path, _} = put_entry(dir, :recon, "2.5.6")
      fresh = Store.staging(dir, :x, "1.0.0")
      File.mkdir_p!(Path.join(dir, ".trust"))
      File.write!(Path.join(dir, ".trust/state"), "5")
      File.mkdir_p!(Path.join(dir, "notes/deep"))
      File.write!(Path.join(dir, "notes/deep/big"), :binary.copy("x", 1000))
      File.write!(Path.join(dir, "junk.bin"), "x")
      File.write!(Path.join(dir, "jason-1.4.5"), "a file named like an entry")
      File.mkdir_p!(Path.join(dir, ".hidden"))
      :ok = Store.sweep(dir)
      assert File.dir?(fresh)
      assert File.regular?(Path.join(dir, ".trust/state"))
      assert File.regular?(Path.join(dir, ".precompiled-store"))
      assert File.dir?(path)

      assert Enum.sort(File.ls!(dir)) ==
               [".precompiled-store", ".staging", ".trust", "recon-2.5.6"]
    end

    test "another call's ownership probe and lost+found stay; a stale probe goes", %{
      tmp_dir: dir
    } do
      put_entry(dir, :recon, "2.5.6")
      # A concurrent list/1 or uninstall/2 checks the store outside the
      # lock, through a probe file it removes again a moment later.
      probe = Path.join(dir, ".probe.123-45")
      File.write!(probe, "")
      stale = Path.join(dir, ".probe.123-46")
      File.write!(stale, "")
      File.touch!(stale, System.os_time(:second) - 7200)
      # The store dir may be a mount of its own.
      File.mkdir_p!(Path.join(dir, "lost+found"))

      :ok = Store.sweep(dir)
      assert File.regular?(probe)
      refute File.exists?(stale)
      assert File.dir?(Path.join(dir, "lost+found"))
      assert [%{app: :recon}] = Store.list(dir)
    end

    test "a symlinked entry is removed, not what it points to", %{tmp_dir: dir} do
      {path, _} = put_entry(dir, :recon, "2.5.6")
      File.mkdir_p!(Path.join(dir, ".trust"))
      elsewhere = Path.join(dir, ".trust/elsewhere")
      File.rename!(path, elsewhere)
      File.ln_s!(elsewhere, path)
      :ok = Store.sweep(dir)
      assert {:error, :enoent} = File.lstat(path)
      assert File.regular?(Path.join(elsewhere, ".precompiled.json"))
    end

    test "does nothing in a directory that is not a store", %{tmp_dir: dir} do
      bare = Path.join(dir, "bare")
      File.mkdir_p!(Path.join(bare, "photos-2024/ebin"))
      assert :ok = Store.sweep(bare)
      assert File.dir?(Path.join(bare, "photos-2024/ebin"))
    end

    test "never raises", %{tmp_dir: dir} do
      assert :ok = Store.sweep(Path.join(dir, "missing"))
    end
  end

  describe "the store root" do
    test "is created private, with a marker", %{tmp_dir: dir} do
      root = Path.join(dir, "data/precompiled")
      assert :ok = Store.ensure_root(root)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(root)
      assert Bitwise.band(mode, 0o777) == 0o700
      assert File.regular?(Path.join(root, ".precompiled-store"))
      assert :ok = Store.ensure_root(root)
    end

    test "refuses a symlink", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      link = Path.join(dir, "link")
      File.ln_s!(real, link)
      assert {:error, {:unsafe_store, :symlink}} = Store.ensure_root(link)
    end

    test "refuses a directory others can write", %{tmp_dir: dir} do
      open = Path.join(dir, "open")
      File.mkdir_p!(open)
      File.chmod!(open, 0o777)
      assert {:error, {:unsafe_store, :writable_by_others}} = Store.ensure_root(open)
      File.chmod!(open, 0o770)
      assert {:error, {:unsafe_store, :writable_by_others}} = Store.ensure_root(open)
    end

    test "refuses a file", %{tmp_dir: dir} do
      file = Path.join(dir, "file")
      File.write!(file, "")
      assert {:error, {:unsafe_store, :not_a_directory}} = Store.ensure_root(file)
    end

    test "refuses a directory another user owns" do
      assert {:error, {:unsafe_store, _}} = Store.ensure_root("/usr")
    end
  end

  describe "staging" do
    test "every call gets a fresh, empty directory under .staging", %{tmp_dir: dir} do
      a = Store.staging(dir, :recon, "2.5.6")
      b = Store.staging(dir, :recon, "2.5.6")
      assert a != b
      assert File.ls!(a) == [] and File.ls!(b) == []
      assert Path.dirname(a) == Path.join(dir, ".staging")
      assert Path.basename(a) =~ ~r/\Arecon-2\.5\.6\.\d+-\d+\z/
    end
  end

  describe "eviction" do
    test "make_room evicts least recently used first", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6", :binary.copy("a", 400), 100)
      put_entry(dir, :jason, "1.4.5", :binary.copy("b", 400), 200)
      used = Store.used_bytes(dir)
      assert :ok = Store.make_room(dir, 250, used + 100, %{}, [])
      assert [%{app: :jason}] = Store.list(dir)
      assert File.ls!(Path.join(dir, ".staging")) == []
    end

    test "eviction skips loaded entries and the plan's own reuses, then refuses",
         %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6", :binary.copy("a", 400), 100)
      put_entry(dir, :jason, "1.4.5", :binary.copy("b", 400), 200)
      used = Store.used_bytes(dir)

      assert {:error, {:too_big, 250, _free}} =
               Store.make_room(dir, 250, used + 100, %{recon: "2.5.6"}, [:jason])

      assert length(Store.list(dir)) == 2
    end

    test "a plan of 60% of max_bytes fits an empty store: staging is renamed, not copied",
         %{tmp_dir: dir} do
      used = Store.used_bytes(dir)
      assert {:ok, []} = Store.room(dir, 60, used + 100, %{}, [])
      assert {:error, {:too_big, 160, 100}} = Store.room(dir, 160, used + 100, %{}, [])
    end

    test "a store dir reached through a symlink is the same store", %{tmp_dir: dir} do
      {path, _} = put_entry(dir, :recon, "2.5.6", :binary.copy("a", 400), 100)
      ebin = String.to_charlist(Path.join(path, "ebin"))
      true = :code.add_pathz(ebin)
      on_exit(fn -> :code.del_path(ebin) end)
      # /data -> /root on Nerves: a parent of the store is the link.
      parent = Path.dirname(dir)
      link = parent <> "-link-#{System.unique_integer([:positive])}"
      File.ln_s!(parent, link)
      on_exit(fn -> File.rm(link) end)
      via_link = Path.join(link, Path.basename(dir))

      assert %{removed: [], kept: [:recon]} = Store.clean(via_link, %{})
      assert [%{path: ^path}] = Store.list(via_link)
    end

    test "a plan that fits evicts nothing", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6", "a", 100)
      assert :ok = Store.make_room(dir, 10, Store.used_bytes(dir) + 20, %{}, [])
      assert [%{app: :recon}] = Store.list(dir)
    end

    test "free is never reported below zero", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6", "a", 100)
      assert {:error, {:too_big, 10, 0}} = Store.make_room(dir, 10, 1, %{recon: "2.5.6"}, [])
    end

    test "an entry whose ebin is on the code path is in use and never evicted",
         %{tmp_dir: dir} do
      {path, _} = put_entry(dir, :recon, "2.5.6", :binary.copy("a", 400), 100)
      ebin = String.to_charlist(Path.join(path, "ebin"))
      true = :code.add_pathz(ebin)
      on_exit(fn -> :code.del_path(ebin) end)

      used = Store.used_bytes(dir)
      assert {:error, {:too_big, _, _}} = Store.make_room(dir, 250, used + 100, %{}, [])
      assert [%{app: :recon}] = Store.list(dir)
    end

    test "an entry a loaded module came from is in use", %{tmp_dir: dir} do
      {path, entry} = put_entry(dir, :recon, "2.5.6", :binary.copy("a", 400), 100)
      mod = :"Elixir.StoreInUseProbe#{System.unique_integer([:positive])}"
      {:ok, ^mod, bin} = :compile.forms([{:attribute, 1, :module, mod}], [:binary])
      beam = String.to_charlist(Path.join([path, "ebin", "#{mod}.beam"]))
      {:module, ^mod} = :code.load_binary(mod, beam, bin)

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end)

      used = Store.used_bytes(dir)
      assert {:error, {:too_big, _, _}} = Store.make_room(dir, 250, used + 100, %{}, [])
      assert %{removed: [], kept: [:recon]} = Store.clean(dir, %{})

      s = Store.staging(dir, :recon, "2.5.6")

      assert {:error, {:already_present, :recon, "2.5.6"}} =
               Store.commit(s, dir, :recon, "2.5.6", %{}, %{})

      assert {:error, {:in_use, :recon}} = Store.remove(dir, :recon)

      # A changed file is a miss, but a loaded entry is left where it is.
      File.write!(Path.join(path, "priv/data.bin"), "evil")
      assert :miss = Store.cached(dir, :recon, "2.5.6", entry)
      assert File.dir?(path)
    end
  end

  describe "clean, remove and list" do
    test "clean removes everything but loaded entries and .trust", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6")
      put_entry(dir, :jason, "1.4.5")
      File.mkdir_p!(Path.join(dir, ".trust"))
      File.write!(Path.join(dir, ".trust/state"), "5")
      Store.staging(dir, :x, "1.0.0")

      assert %{removed: [:jason], kept: [:recon], bytes: bytes} =
               Store.clean(dir, %{recon: "2.5.6"})

      assert bytes > 0
      assert File.regular?(Path.join(dir, ".trust/state"))
      refute File.exists?(Path.join(dir, ".staging"))
      assert [%{app: :recon}] = Store.list(dir)
    end

    test "clean does nothing in a directory that is not a store", %{tmp_dir: dir} do
      bare = Path.join(dir, "bare")
      File.mkdir_p!(Path.join(bare, "recon-2.5.6/ebin"))
      assert %{removed: [], kept: [], bytes: 0} = Store.clean(bare, %{})
      assert File.dir?(Path.join(bare, "recon-2.5.6"))
    end

    test "remove takes every version of the app", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6")
      put_entry(dir, :recon, "2.5.5")
      put_entry(dir, :jason, "1.4.5")
      assert :ok = Store.remove(dir, :recon)
      assert [%{app: :jason}] = Store.list(dir)
    end

    test "list gives each entry's bytes and skips one without provenance", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6")
      File.mkdir_p!(Path.join(dir, "#{fresh_name()}-1.0.0/ebin"))
      assert [%{app: :recon, path: path, bytes: bytes}] = Store.list(dir)
      assert path == Path.join(dir, "recon-2.5.6")
      assert bytes > 0
    end

    test "used_bytes counts everything but .trust", %{tmp_dir: dir} do
      before = Store.used_bytes(dir)
      File.mkdir_p!(Path.join(dir, ".trust"))
      File.write!(Path.join(dir, ".trust/state"), :binary.copy("x", 1000))
      assert Store.used_bytes(dir) == before
      File.write!(Path.join(dir, "other"), :binary.copy("x", 1000))
      assert Store.used_bytes(dir) == before + 1000
    end

    test "touch records the last use", %{tmp_dir: dir} do
      put_entry(dir, :recon, "2.5.6")
      :ok = Store.touch(dir, :recon, "2.5.6")
      [%{provenance: %{"last_used" => t}}] = Store.list(dir)
      assert t >= System.os_time(:second) - 5
    end
  end

  # A fresh VM after a reboot: an entry on disk whose app name has never
  # been an atom in this VM.
  describe "entries whose app is not an atom yet" do
    test "list/1 includes it", %{tmp_dir: dir} do
      {name, path} = put_fresh(dir, 100)
      assert [%{app: app, version: "1.0.0", path: ^path}] = Store.list(dir)
      assert Atom.to_string(app) == name
    end

    test "sweep keeps it", %{tmp_dir: dir} do
      {name, path} = put_fresh(dir, 100)
      :ok = Store.sweep(dir)
      assert File.regular?(Path.join(path, ".precompiled.json"))
      assert [%{app: app}] = Store.list(dir)
      assert Atom.to_string(app) == name
    end

    test "clean removes it and reports it", %{tmp_dir: dir} do
      {name, path} = put_fresh(dir, 100)
      assert %{removed: [app], kept: [], bytes: bytes} = Store.clean(dir, %{})
      assert Atom.to_string(app) == name
      assert bytes > 400
      refute File.exists?(path)
    end

    test "eviction counts it", %{tmp_dir: dir} do
      {_name, fresh} = put_fresh(dir, 100)
      put_entry(dir, :jason, "1.4.5", :binary.copy("b", 400), 200)
      used = Store.used_bytes(dir)
      assert {:ok, [^fresh]} = Store.room(dir, 250, used + 100, %{}, [])
      assert :ok = Store.make_room(dir, 250, used + 100, %{}, [])
      assert [%{app: :jason}] = Store.list(dir)
      refute File.exists?(fresh)
    end

    test "remove takes it by name", %{tmp_dir: dir} do
      {name, path} = put_fresh(dir, 100)
      [%{app: app}] = Store.list(dir)
      assert Atom.to_string(app) == name
      assert :ok = Store.remove(dir, app)
      refute File.exists?(path)
    end
  end

  defp fresh_name() do
    name = "zzfresh#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    name
  end

  # Written straight to disk, the way a previous boot left it: nothing in
  # this VM names the app.
  defp put_fresh(dir, last_used) do
    name = fresh_name()
    path = Path.join(dir, "#{name}-1.0.0")
    File.mkdir_p!(Path.join(path, "ebin"))
    File.mkdir_p!(Path.join(path, "priv"))
    File.write!(Path.join([path, "ebin", "#{name}.app"]), "{application,x,[]}.\n")
    File.write!(Path.join([path, "priv", "data.bin"]), :binary.copy("a", 400))
    prov = %{"package" => name, "version" => "1.0.0", "last_used" => last_used}
    File.write!(Path.join(path, ".precompiled.json"), :json.encode(prov))
    {name, path}
  end

  describe "noexec/2" do
    test "the longest matching mount decides" do
      mounts = [{"/", ["ro"]}, {"/root", ["rw", "noexec"]}, {"/root/precompiled", ["rw"]}]
      assert Store.noexec("/root/other", mounts) == "/root"
      assert Store.noexec("/root/precompiled", mounts) == nil
    end

    test "prefixes match whole path components only" do
      mounts = [{"/", ["rw"]}, {"/data", ["rw", "noexec"]}]
      assert Store.noexec("/database/x", mounts) == nil
      assert Store.noexec("/data", mounts) == "/data"
    end

    test "a symlinked path is judged by where it points", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      link = Path.join(dir, "link")
      File.ln_s!(real, link)
      {:ok, resolved} = :file.read_link_all(String.to_charlist(link))
      mounts = [{"/", ["rw"]}, {to_string(resolved), ["noexec"]}]
      assert Store.noexec(Path.join(link, "precompiled"), mounts) == to_string(resolved)
    end
  end

  describe "write_file/2" do
    @tag :linux
    test "enospc while writing is reported with the path" do
      assert {:error, {:enospc, "/dev/full"}} = Store.write_file("/dev/full", "x")
    end

    test "writes and syncs", %{tmp_dir: dir} do
      path = Path.join(dir, "f")
      assert :ok = Store.write_file(path, "bytes")
      assert File.read!(path) == "bytes"
      assert {:error, :enoent} = Store.write_file(Path.join(dir, "no/such"), "x")
    end
  end

  describe "with_lock" do
    test "with_lock serializes two callers" do
      parent = self()

      t =
        Task.async(fn ->
          Store.with_lock(fn ->
            send(parent, :in)
            Process.sleep(200)
            :first
          end)
        end)

      assert_receive :in
      started = System.monotonic_time(:millisecond)
      assert Store.with_lock(fn -> :second end) == :second
      assert System.monotonic_time(:millisecond) - started >= 100
      assert Task.await(t) == :first
    end

    test "is busy once the retries run out" do
      parent = self()

      t =
        Task.async(fn ->
          Store.with_lock(fn ->
            send(parent, :in)

            receive do
              :go -> :first
            end
          end)
        end)

      assert_receive :in
      assert Store.with_lock(fn -> :second end, 0) == {:error, :busy}
      send(t.pid, :go)
      assert Task.await(t) == :first
    end

    test "a raise releases the lock" do
      assert_raise RuntimeError, fn -> Store.with_lock(fn -> raise "boom" end) end
      t = Task.async(fn -> Store.with_lock(fn -> :next end, 0) end)
      assert Task.await(t) == :next
    end
  end
end
