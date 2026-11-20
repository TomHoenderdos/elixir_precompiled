# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ForeignPrivFilesTest do
  # The files a foreign priv build places into kino's build priv (0.8.0),
  # on a fake build lib against the local signed fixture.
  use ExUnit.Case, async: false

  alias Precompiled.{Fetch, ForeignPrivFiles, Status}
  alias Precompiled.Fixture, as: F

  @moduletag :tmp_dir
  @h "uxwh53kfq2wszgf23hqwgkuiza"
  @kino_lock {:hex, :kino, "0.19.1", "i", [:mix], [], "hexpm", "K"}

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    f = F.new(dir)
    lib = Path.join(dir, "_build/dev/lib")
    File.mkdir_p!(lib)
    # As fetch_test.exs's setup builds it.
    config = %{
      source: F.base_url(),
      except: [],
      root_path: f.root_path,
      home: Path.join(dir, "home")
    }

    %{f: f, lib: lib, config: config, deps: Path.join(dir, "deps")}
  end

  defp entry(f, d, bytes),
    do: %{
      "app" => "kino",
      "path" => "priv/assets/#{d}/#{@h}.tar.gz",
      "sha256" => F.file(f, bytes),
      "size" => byte_size(bytes),
      "mode" => 33_188
    }

  defp file(f, path, bytes),
    do: %{
      "path" => path,
      "sha256" => F.file(f, bytes),
      "size" => byte_size(bytes),
      "mode" => 33_188
    }

  defp kino_dir(lib, priv? \\ true) do
    dir = Path.join(lib, "kino")
    File.mkdir_p!(Path.join(dir, "ebin"))
    if priv?, do: File.mkdir_p!(Path.join(dir, "priv/assets/Kino_HTML"))
    dir
  end

  # A kino build: its .app, one beam, and (unless `priv` is []) its own archive.
  defp kino_entry(f, priv \\ nil) do
    app = "{application, kino, [{vsn, \"0.19.1\"}, {modules, ['Elixir.Kino.HTML']}]}.\n"

    %{
      "target" => "pure_elixir",
      "ebin" => [file(f, "ebin/Elixir.Kino.HTML.beam", "beam"), file(f, "ebin/kino.app", app)],
      "priv" => priv || [file(f, "priv/assets/Kino_HTML/#{@h}.tar.gz", "html archive")]
    }
  end

  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.contains?(&1, "/.precompiled"))
    |> Map.new(fn p ->
      {Path.relative_to(p, dir), if(File.regular?(p), do: File.read!(p), else: :dir)}
    end)
  end

  defp app!(lib, app, module) do
    File.mkdir_p!(Path.join([lib, app, "ebin"]))
    File.mkdir_p!(Path.join([lib, app, ".mix"]))

    File.write!(
      Path.join([lib, app, "ebin", app <> ".app"]),
      "{application, #{app}, [{vsn, \"1\"}, {modules, ['#{module}']}]}.\n"
    )

    # Both of Mix's marks: Mix 1.19 and later recompile a dep without
    # compile.elixir_scm, 1.17 and 1.18 one without compile.fetch.
    File.write!(Path.join([lib, app, ".mix/compile.elixir_scm"]), "scm")
    File.write!(Path.join([lib, app, ".mix/compile.fetch"]), "")
  end

  # Mix's "compiled" marks both still there, or both gone.
  defp marked?(lib, app),
    do:
      Enum.all?(
        ~w(compile.elixir_scm compile.fetch),
        &File.exists?(Path.join([lib, app, ".mix", &1]))
      )

  defp unmarked?(lib, app),
    do:
      not Enum.any?(
        ~w(compile.elixir_scm compile.fetch),
        &File.exists?(Path.join([lib, app, ".mix", &1]))
      )

  test "target_state/1: settled, linked or missing", %{lib: lib, tmp_dir: dir} do
    assert ForeignPrivFiles.target_state(lib) == :missing
    kino = kino_dir(lib, false)
    assert ForeignPrivFiles.target_state(lib) == :settled
    File.mkdir_p!(Path.join(kino, "priv/assets"))
    assert ForeignPrivFiles.target_state(lib) == :settled
    File.rm_rf!(Path.join(kino, "priv"))
    File.mkdir_p!(Path.join(dir, "deps/kino/priv"))
    File.ln_s!(Path.join(dir, "deps/kino/priv"), Path.join(kino, "priv"))
    assert ForeignPrivFiles.target_state(lib) == :linked

    File.rm!(Path.join(kino, "priv"))
    File.mkdir_p!(Path.join(kino, "priv"))
    File.ln_s!(Path.join(dir, "deps/kino/priv"), Path.join(kino, "priv/assets"))
    assert ForeignPrivFiles.target_state(lib) == :linked
  end

  test "stage, place and on_disk?: exactly what Kino.JS writes, and nothing else",
       %{f: f, lib: lib, config: config} do
    kino = kino_dir(lib)
    File.mkdir_p!(Path.join(kino, "priv/assets/Kino_VegaLite"))
    File.write!(Path.join(kino, "priv/assets/Kino_VegaLite/old.tar.gz"), "stale")
    before = tree(kino)
    entries = [entry(f, "Kino_VegaLite", "archive")]

    assert {:ok, staging} = ForeignPrivFiles.stage(config, :kino_vega_lite, entries, lib)
    assert File.regular?(Path.join([staging, "foreign/Kino_VegaLite/#{@h}.tar.gz"]))
    assert :ok = ForeignPrivFiles.place(lib, staging, entries)
    refute File.exists?(staging)

    after_ = tree(kino)
    assert after_["priv/assets/Kino_VegaLite/#{@h}.tar.gz"] == "archive"
    refute Map.has_key?(after_, "priv/assets/Kino_VegaLite/old.tar.gz")

    assert Map.drop(after_, ["priv/assets/Kino_VegaLite/#{@h}.tar.gz"]) ==
             Map.drop(before, ["priv/assets/Kino_VegaLite/old.tar.gz"])

    placed = Path.join(kino, "priv/assets/Kino_VegaLite/#{@h}.tar.gz")
    assert Bitwise.band(File.lstat!(placed).mode, 0o777) == 0o644
    assert ForeignPrivFiles.on_disk?(lib, entries)

    File.write!(Path.join(kino, "priv/assets/Kino_VegaLite/extra"), "x")
    refute ForeignPrivFiles.on_disk?(lib, entries)
    File.rm!(Path.join(kino, "priv/assets/Kino_VegaLite/extra"))
    assert ForeignPrivFiles.on_disk?(lib, entries)

    File.chmod!(placed, 0o755)
    refute ForeignPrivFiles.on_disk?(lib, entries)
    File.chmod!(placed, 0o644)
    File.write!(placed, "archivf")
    refute ForeignPrivFiles.on_disk?(lib, entries)
    File.rm_rf!(Path.join(kino, "priv/assets/Kino_VegaLite"))
    refute ForeignPrivFiles.on_disk?(lib, entries)
  end

  test "place creates priv and priv/assets, and nothing else", %{f: f, lib: lib, config: config} do
    kino = kino_dir(lib, false)
    entries = [entry(f, "Kino_VegaLite", "archive")]
    {:ok, staging} = ForeignPrivFiles.stage(config, :kino_vega_lite, entries, lib)
    assert :ok = ForeignPrivFiles.place(lib, staging, entries)

    assert tree(kino) == %{
             "ebin" => :dir,
             "priv" => :dir,
             "priv/assets" => :dir,
             "priv/assets/Kino_VegaLite" => :dir,
             "priv/assets/Kino_VegaLite/#{@h}.tar.gz" => "archive"
           }
  end

  test "place refuses a kino priv/assets that is not a directory, and changes nothing",
       %{f: f, lib: lib, config: config} do
    kino = kino_dir(lib, false)
    File.mkdir_p!(Path.join(kino, "priv"))
    File.write!(Path.join(kino, "priv/assets"), "a file")
    entries = [entry(f, "Kino_VegaLite", "archive")]
    {:ok, staging} = ForeignPrivFiles.stage(config, :kino_vega_lite, entries, lib)
    before = tree(lib)

    assert {:fail, "kino's priv/assets is not a directory"} =
             ForeignPrivFiles.place(lib, staging, entries)

    assert tree(lib) == before
    refute File.exists?(staging)
  end

  test "place refuses a kino that is not a real directory", %{f: f, lib: lib, config: config} do
    entries = [entry(f, "Kino_VegaLite", "archive")]
    {:ok, staging} = ForeignPrivFiles.stage(config, :kino_vega_lite, entries, lib)

    assert {:fail, "kino's build dir is not a directory"} =
             ForeignPrivFiles.place(lib, staging, entries)

    refute File.exists?(Path.join(lib, "kino"))
  end

  test "a staged file that is not its sha fails before anything is placed",
       %{f: f, lib: lib, config: config} do
    kino_dir(lib)
    bad = %{entry(f, "Kino_VegaLite", "archive") | "sha256" => String.duplicate("0", 64)}
    assert {:fail, _} = ForeignPrivFiles.stage(config, :kino_vega_lite, [bad], lib)
    refute File.exists?(Path.join(lib, "kino/priv/assets/Kino_VegaLite"))
    assert File.ls!(Path.join(lib, ".precompiled")) == []
  end

  # D2.
  test "a kino replace carries over the archives its new entry does not ship",
       %{f: f, lib: lib, config: config, deps: deps} do
    kino = kino_dir(lib)
    File.mkdir_p!(Path.join(kino, "priv/assets/Kino_VegaLite"))
    File.write!(Path.join(kino, "priv/assets/Kino_VegaLite/#{@h}.tar.gz"), "writer")
    File.mkdir_p!(Path.join(kino, "priv/assets/ProjWidget"))
    File.write!(Path.join(kino, "priv/assets/ProjWidget/#{@h}.tar.gz"), "project's own")
    new_kino = kino_entry(f)

    assert {:ok, _} = Fetch.install(config, :kino, new_kino, @kino_lock, lib, deps_path: deps)
    assert File.read!(Path.join(kino, "priv/assets/Kino_VegaLite/#{@h}.tar.gz")) == "writer"
    assert File.read!(Path.join(kino, "priv/assets/ProjWidget/#{@h}.tar.gz")) == "project's own"
    assert File.read!(Path.join(kino, "priv/assets/Kino_HTML/#{@h}.tar.gz")) == "html archive"
    assert Fetch.installed_as?(lib, :kino, new_kino)
    refute Fetch.installed_at?(kino, :kino, new_kino)

    # Every file kino ships is still checked exactly.
    File.write!(Path.join(kino, "priv/assets/Kino_HTML/#{@h}.tar.gz"), "html archivf")
    refute Fetch.installed_as?(lib, :kino, new_kino)
    File.write!(Path.join(kino, "priv/assets/Kino_HTML/#{@h}.tar.gz"), "html archive")
    File.write!(Path.join(kino, "priv/assets/Kino_HTML/extra"), "x")
    refute Fetch.installed_as?(lib, :kino, new_kino)
    File.rm!(Path.join(kino, "priv/assets/Kino_HTML/extra"))

    # ... and only real directories under priv/assets are passed over.
    File.write!(Path.join(kino, "priv/assets/loose"), "x")
    refute Fetch.installed_as?(lib, :kino, new_kino)
    File.rm!(Path.join(kino, "priv/assets/loose"))
    assert Fetch.installed_as?(lib, :kino, new_kino)

    # Another dep is checked as before.
    app = "{application, kino_db, [{vsn, \"1\"}, {modules, []}]}.\n"
    other = %{"ebin" => [file(f, "ebin/kino_db.app", app)], "priv" => []}
    assert {:ok, _} = Fetch.install(config, :kino_db, other, @kino_lock, lib, deps_path: deps)
    File.mkdir_p!(Path.join(lib, "kino_db/priv/assets/X"))
    refute Fetch.installed_as?(lib, :kino_db, other)
  end

  # Removing the old kino dir fails after the carry: the carried archives
  # go with the staging dir, so their Mix-built owners must recompile.
  @tag :non_root
  test "a kino replace that fails after the carry marks the carried archives' owners",
       %{f: f, lib: lib, config: config, deps: deps} do
    kino = kino_dir(lib)
    File.mkdir_p!(Path.join(kino, "priv/assets/Kino_VegaLite"))
    File.write!(Path.join(kino, "priv/assets/Kino_VegaLite/#{@h}.tar.gz"), "writer")
    app!(lib, "kino_vega_lite", "Elixir.Kino.VegaLite")
    File.write!(Path.join(kino, "ebin/old.beam"), "old")
    File.chmod!(Path.join(kino, "ebin"), 0o555)
    on_exit(fn -> File.chmod(Path.join(kino, "ebin"), 0o755) end)

    assert {:fail, "install failed: " <> _} =
             Fetch.install(config, :kino, kino_entry(f), @kino_lock, lib, deps_path: deps)

    assert unmarked?(lib, "kino_vega_lite")
    assert Fetch.staging_dirs(lib, :kino, :own) == []
  end

  test "a kino build that ships no priv carries the archives over all the same",
       %{f: f, lib: lib, config: config, deps: deps} do
    kino = kino_dir(lib, false)
    File.mkdir_p!(Path.join(kino, "priv/assets/Kino_VegaLite"))
    File.write!(Path.join(kino, "priv/assets/Kino_VegaLite/#{@h}.tar.gz"), "writer")
    new_kino = kino_entry(f, [])

    assert {:ok, _} = Fetch.install(config, :kino, new_kino, @kino_lock, lib, deps_path: deps)
    assert File.read!(Path.join(kino, "priv/assets/Kino_VegaLite/#{@h}.tar.gz")) == "writer"
    assert Fetch.installed_as?(lib, :kino, new_kino)
    File.write!(Path.join(kino, "priv/stray"), "x")
    refute Fetch.installed_as?(lib, :kino, new_kino)
  end

  test "unshipped/2 and carry/3", %{f: f, tmp_dir: dir} do
    dest = Path.join(dir, "dest")
    staging = Path.join(dir, "staging")
    File.mkdir_p!(Path.join(dest, "priv/assets/Kino_HTML"))
    File.mkdir_p!(Path.join(dest, "priv/assets/Kino_VegaLite"))
    File.write!(Path.join(dest, "priv/assets/Kino_VegaLite/a"), "a")
    File.write!(Path.join(dest, "priv/assets/loose"), "x")
    File.ln_s!(dir, Path.join(dest, "priv/assets/Linked"))
    entry = kino_entry(f)

    assert ForeignPrivFiles.unshipped(dest, entry) == ["Kino_VegaLite"]
    assert ForeignPrivFiles.unshipped(Path.join(dir, "none"), entry) == []

    File.mkdir_p!(staging)
    assert :ok = ForeignPrivFiles.carry(dest, staging, entry)
    assert File.read!(Path.join(staging, "priv/assets/Kino_VegaLite/a")) == "a"
    refute File.exists?(Path.join(dest, "priv/assets/Kino_VegaLite"))

    # Nothing to carry: nothing done.
    other = Path.join(dir, "other")
    File.mkdir_p!(other)
    assert :ok = ForeignPrivFiles.carry(other, Path.join(dir, "nowhere"), entry)
    refute File.exists?(Path.join(dir, "nowhere"))

    # A staged priv that links to the sources cannot take them: owners are marked instead.
    File.mkdir_p!(Path.join(dest, "priv/assets/Kino_Other"))
    linked = Path.join(dir, "linked")
    File.mkdir_p!(linked)
    File.ln_s!(dir, Path.join(linked, "priv"))
    assert :mark_owners = ForeignPrivFiles.carry(dest, linked, entry)
    assert File.dir?(Path.join(dest, "priv/assets/Kino_Other"))
  end

  test "removing kino marks its Mix-built owners, never a client install", %{lib: lib} do
    kino = kino_dir(lib)
    for d <- ~w(KinoDB_Cell Kino_VegaLite), do: File.mkdir_p!(Path.join(kino, "priv/assets/#{d}"))

    app!(lib, "kino_db", "Elixir.KinoDB.Cell")
    app!(lib, "kino_vega_lite", "Elixir.Kino.VegaLite")
    app!(lib, "unrelated", "Elixir.Unrelated")

    # kino_vega_lite is a client install: it has a provenance file and no newer Mix manifest.
    File.write!(Fetch.provenance_path(lib, :kino_vega_lite), "{}")
    assert Status.installed?(lib, "kino_vega_lite")
    refute Status.installed?(lib, "kino_db")

    assert :ok = ForeignPrivFiles.mark_owners(lib)
    assert unmarked?(lib, "kino_db")
    assert marked?(lib, "kino_vega_lite")
    assert marked?(lib, "unrelated")

    assert :ok = ForeignPrivFiles.mark_owners(Path.join(lib, "nowhere"))
  end

  test "Status.remove/2 of an installed kino marks the owners first", %{lib: lib} do
    kino = kino_dir(lib)
    File.mkdir_p!(Path.join(kino, ".mix"))
    File.write!(Fetch.provenance_path(lib, :kino), "{}")
    File.mkdir_p!(Path.join(kino, "priv/assets/KinoDB_Cell"))
    app!(lib, "kino_db", "Elixir.KinoDB.Cell")

    assert :ok = Status.remove(lib, "kino")
    refute File.exists?(kino)
    assert unmarked?(lib, "kino_db")
  end

  test "an install that places archives records them in its provenance",
       %{f: f, lib: lib, config: config, deps: deps} do
    app = "{application, kino_db, [{vsn, \"1\"}, {modules, []}]}.\n"
    other = %{"ebin" => [file(f, "ebin/kino_db.app", app)], "priv" => []}
    foreign = [entry(f, "KinoDB_Cell", "archive")]

    provenance = %{sha: "s", path: "v2/manifests", sequence: 1, foreign: foreign}

    assert {:ok, _} =
             Fetch.install(config, :kino_db, other, @kino_lock, lib,
               deps_path: deps,
               provenance: provenance
             )

    doc = :json.decode(File.read!(Fetch.provenance_path(lib, :kino_db)))
    assert doc["foreign"] == foreign

    assert {:ok, _} =
             Fetch.install(config, :kino_db, other, @kino_lock, lib,
               deps_path: deps,
               provenance: Map.delete(provenance, :foreign)
             )

    refute Map.has_key?(:json.decode(File.read!(Fetch.provenance_path(lib, :kino_db))), "foreign")
  end
end
