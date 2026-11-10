# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CacheTest do
  use ExUnit.Case, async: true
  alias Precompiled.Cache
  @moduletag :tmp_dir

  defp put(home, rel, bytes, mtime) do
    path = Path.join(home, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    File.touch!(path, mtime)
    path
  end

  test "gc evicts least recently used entries down to the bound and drops stale temp files", %{
    tmp_dir: home
  } do
    now = 1_800_000_000
    old = put(home, "files/" <> String.duplicate("a", 64), String.duplicate("x", 600), now - 300)

    new =
      put(
        home,
        "manifests/" <> String.duplicate("b", 64) <> ".json",
        String.duplicate("y", 600),
        now - 10
      )

    stale = put(home, "files/" <> String.duplicate("c", 64) <> ".tmp-12-34", "t", now - 7200)
    live = put(home, "files/" <> String.duplicate("d", 64) <> ".tmp-12-35", "t", now - 60)
    state = put(home, "0123456789abcdef/state", "9", now - 99_999)

    assert %{removed: 2} = Cache.gc(home, 1000, now: now)
    refute File.exists?(old)
    refute File.exists?(stale)
    assert File.exists?(new) and File.exists?(live) and File.exists?(state)
  end

  test "gc evicts scan results too, and never trust state or batch files", %{tmp_dir: home} do
    now = 1_800_000_000
    scan = put(home, "scan/v1/" <> String.duplicate("e", 64) <> ".term", "s", now - 500)
    keep = for f <- ~w(batch.json batch.etag gc_at roots), do: put(home, f, "k", now - 99_999)
    state = put(home, "0123456789abcdef/state", "9", now - 99_999)

    assert %{removed: 1, bytes: 1} = Cache.gc(home, 0, now: now)
    refute File.exists?(scan)
    assert Enum.all?([state | keep], &File.exists?/1)
  end

  test "gc never follows links: linked entries and linked cache dirs are left alone", %{
    tmp_dir: dir
  } do
    home = Path.join(dir, "home")
    outside = Path.join(dir, "outside")
    target = put(outside, "big", String.duplicate("z", 5000), 1)
    put(outside, "files/" <> String.duplicate("f", 64), "o", 1)
    File.mkdir_p!(Path.join(home, "files"))
    link = Path.join(home, "files/" <> String.duplicate("a", 64))
    File.ln_s!(target, link)
    # manifests/ a link to a dir outside the home.
    File.ln_s!(Path.join(outside, "files"), Path.join(home, "manifests"))

    assert %{removed: 0, bytes: 0} = Cache.gc(home, 0, now: 1_800_000_000)
    assert File.read!(target) == String.duplicate("z", 5000)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    assert File.exists?(Path.join(outside, "files/" <> String.duplicate("f", 64)))
  end

  test "a home that may be a link (cache moved to another disk) is still collected", %{
    tmp_dir: dir
  } do
    real = Path.join(dir, "real")
    f = put(real, "files/" <> String.duplicate("a", 64), "x", 1)
    File.ln_s!(real, Path.join(dir, "home"))
    assert %{removed: 1} = Cache.gc(Path.join(dir, "home"), 0, now: 1_800_000_000)
    refute File.exists?(f)
  end

  test "maybe_gc runs at most once a day", %{tmp_dir: home} do
    config = %{home: home, cache_max_bytes: 0}
    f = put(home, "files/" <> String.duplicate("a", 64), "x", 1)
    assert Cache.maybe_gc(config) == :ok
    refute File.exists?(f)
    g = put(home, "files/" <> String.duplicate("b", 64), "x", 1)
    assert Cache.maybe_gc(config) == :ok
    assert File.exists?(g)
  end

  test "maybe_gc with no home does nothing" do
    assert Cache.maybe_gc(%{home: nil, cache_max_bytes: 0}) == :ok
  end

  test "clear removes cached files, manifests and scans, never trust state", %{tmp_dir: home} do
    put(home, "files/x", "1", 1)
    put(home, "manifests/y", "1", 1)
    put(home, "scan/z", "1", 1)
    state = put(home, "0123456789abcdef/state", "9", 1)
    assert Cache.clear(home) == :ok
    assert File.ls!(home) |> Enum.sort() == ["0123456789abcdef"]
    assert File.exists?(state)
  end

  test "clear never follows links", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    outside = Path.join(dir, "outside")
    kept = put(outside, "keep", "k", 1)
    File.mkdir_p!(Path.join(home, "files"))
    File.ln_s!(outside, Path.join(home, "files/linked"))
    File.ln_s!(outside, Path.join(home, "manifests"))

    assert Cache.clear(home) == :ok
    assert File.read!(kept) == "k"
    refute File.exists?(Path.join(home, "files"))
    # A cache dir that is a link is not ours to clear; Fetch refuses it too.
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(home, "manifests"))
  end
end
