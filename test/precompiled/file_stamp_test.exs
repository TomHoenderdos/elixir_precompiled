# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.FileStampTest do
  # A cached file that was verified is not hashed again while nothing about
  # it changed since: its device, inode, size, mtime and ctime, read from the
  # open file, and the sha it was verified against. Any difference is a full
  # re-hash. ctime is set by the kernel on every change and cannot be set
  # from user space, so a rewrite that restores size and mtime still shows,
  # even within the same second as the stamp. Only a cache home that no one
  # else can enter is trusted to hold stamps at all.
  use ExUnit.Case, async: true
  alias Precompiled.FileStamp
  @moduletag :tmp_dir

  @sha String.duplicate("a", 64)

  defp stat!(path), do: File.stat!(path, time: :posix)

  defp home!(dir, mode \\ 0o700) do
    home = Path.join(dir, "home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "files"))
    File.chmod!(home, mode)
    home
  end

  # A file whose ctime and mtime are in a past second, then a table opened
  # after it: the table's clock is past the file, so it may be stamped.
  defp settled_file!(dir, home, bytes) do
    path = Path.join(dir, "cached-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    Process.sleep(1_100)
    table = FileStamp.open(home)
    assert table != nil
    stat = stat!(path)
    assert FileStamp.settled?(table, stat)
    {path, table, stat}
  end

  describe "match?/3" do
    setup %{tmp_dir: dir} do
      path = Path.join(dir, "cached")
      File.write!(path, "bytes")
      stat = stat!(path)
      %{stat: stat, stamp: FileStamp.new(stat, @sha)}
    end

    test "the same file, unchanged, against the same sha", %{stat: stat, stamp: stamp} do
      assert FileStamp.match?(stamp, stat, @sha)
    end

    test "any one changed field is a mismatch", %{stat: stat, stamp: stamp} do
      for {field, change} <- [
            major_device: &(&1 + 1),
            minor_device: &(&1 + 1),
            inode: &(&1 + 1),
            size: &(&1 + 1),
            mtime: &(&1 + 1),
            ctime: &(&1 + 1)
          ] do
        changed = Map.update!(stat, field, change)
        refute FileStamp.match?(stamp, changed, @sha), "#{field} changed and still matched"
      end
    end

    # Content-addressed: a stamp vouches for the sha it was verified against
    # and for no other.
    test "another sha is a mismatch", %{stat: stat, stamp: stamp} do
      refute FileStamp.match?(stamp, stat, String.duplicate("b", 64))
    end

    test "nothing recorded is a mismatch", %{stat: stat} do
      refute FileStamp.match?(nil, stat, @sha)
    end

    test "a stat without integer times never matches", %{stat: stat, stamp: stamp} do
      refute FileStamp.match?(stamp, %{stat | ctime: :undefined}, @sha)
    end
  end

  describe "a file changed after it was stamped" do
    # No sleep between the stamp and the change: the change lands in the
    # same second, or the next, and is caught either way, because only a
    # file whose ctime is older than the table's clock is ever stamped.
    test "rewritten in place, size and mtime put back, right away", %{tmp_dir: dir} do
      home = home!(dir)
      {path, table, before} = settled_file!(dir, home, "bytes")
      stamp = FileStamp.new(before, @sha)

      File.write!(path, "BYTES")
      File.touch!(path, before.mtime)
      later = stat!(path)

      assert later.size == before.size
      assert later.mtime == before.mtime
      assert later.ctime > before.ctime
      refute FileStamp.match?(stamp, later, @sha)
      FileStamp.close(table, home)
    end

    test "replaced by a rename, same size and mtime", %{tmp_dir: dir} do
      home = home!(dir)
      {path, table, before} = settled_file!(dir, home, "bytes")
      stamp = FileStamp.new(before, @sha)

      other = path <> ".swap"
      File.write!(other, "BYTES")
      File.touch!(other, before.mtime)
      File.rename!(other, path)

      refute FileStamp.match?(stamp, stat!(path), @sha)
      FileStamp.close(table, home)
    end

    test "only its times set back", %{tmp_dir: dir} do
      home = home!(dir)
      {path, table, before} = settled_file!(dir, home, "bytes")
      stamp = FileStamp.new(before, @sha)

      File.touch!(path, before.mtime)
      refute FileStamp.match?(stamp, stat!(path), @sha)
      FileStamp.close(table, home)
    end
  end

  describe "settled?/2" do
    # A file changed in the current second (by the file system's own clock,
    # read from a probe written when the table was opened) could change
    # again within that second and keep its ctime: never stamped.
    test "not a file written after the table was opened", %{tmp_dir: dir} do
      home = home!(dir)
      table = FileStamp.open(home)
      path = Path.join(dir, "fresh")
      File.write!(path, "bytes")
      refute FileStamp.settled?(table, stat!(path))
      FileStamp.close(table, home)
    end

    test "nothing is settled without a table", %{tmp_dir: dir} do
      path = Path.join(dir, "file")
      File.write!(path, "bytes")
      refute FileStamp.settled?(nil, stat!(path))
    end

    test "the probe that reads the clock is not left behind", %{tmp_dir: dir} do
      home = home!(dir)
      table = FileStamp.open(home)
      FileStamp.close(table, home)
      assert File.ls!(home) == ["files"]
      assert File.ls!(Path.join(home, "files")) == []
    end

    test "no table while the home has no files dir yet", %{tmp_dir: dir} do
      home = home!(dir)
      File.rmdir!(Path.join(home, "files"))
      assert FileStamp.open(home) == nil
    end
  end

  describe "the stamps file" do
    test "a stamp put is there for the next run", %{tmp_dir: dir} do
      home = home!(dir)
      {path, table, stat} = settled_file!(dir, home, "bytes")
      FileStamp.put(table, FileStamp.new(stat, @sha))
      FileStamp.close(table, home)

      again = FileStamp.open(home)
      assert FileStamp.match?(FileStamp.lookup(again, @sha), stat!(path), @sha)
      FileStamp.close(again, home)
    end

    test "a dropped stamp is gone for the next run", %{tmp_dir: dir} do
      home = home!(dir)
      {_path, table, stat} = settled_file!(dir, home, "bytes")
      FileStamp.put(table, FileStamp.new(stat, @sha))
      FileStamp.close(table, home)

      again = FileStamp.open(home)
      FileStamp.drop(again, @sha)
      FileStamp.close(again, home)

      third = FileStamp.open(home)
      assert FileStamp.lookup(third, @sha) == nil
      FileStamp.close(third, home)
    end

    test "one that is not a stamps file is no stamps", %{tmp_dir: dir} do
      home = home!(dir)
      File.write!(Path.join(home, "file_stamps"), "not a term")
      table = FileStamp.open(home)
      assert FileStamp.lookup(table, @sha) == nil
      FileStamp.close(table, home)
    end

    test "a stamp recorded under one sha does not load under another", %{tmp_dir: dir} do
      home = home!(dir)
      other = String.duplicate("b", 64)
      stamp = {other, 1, 2, 3, 4, 5, 6}
      bin = :erlang.term_to_binary({1, %{@sha => stamp}})
      File.write!(Path.join(home, "file_stamps"), bin)
      table = FileStamp.open(home)
      assert FileStamp.lookup(table, @sha) == nil
      FileStamp.close(table, home)
    end

    test "a link in place of the stamps file is not read", %{tmp_dir: dir} do
      home = home!(dir)
      real = Path.join(dir, "elsewhere")
      File.write!(real, :erlang.term_to_binary({1, %{@sha => {@sha, 1, 2, 3, 4, 5, 6}}}))
      File.ln_s!(real, Path.join(home, "file_stamps"))
      table = FileStamp.open(home)
      assert FileStamp.lookup(table, @sha) == nil
      FileStamp.close(table, home)
    end

    test "forget/1 removes it", %{tmp_dir: dir} do
      home = home!(dir)
      File.write!(Path.join(home, "file_stamps"), "x")
      FileStamp.forget(home)
      refute File.exists?(Path.join(home, "file_stamps"))
    end
  end

  describe "trusted_home?/1" do
    test "a directory only its owner can enter", %{tmp_dir: dir} do
      assert FileStamp.trusted_home?(home!(dir))
    end

    test "not one a group or anyone else can enter or write", %{tmp_dir: dir} do
      for mode <- [0o770, 0o750, 0o720, 0o707, 0o705, 0o755, 0o777, 0o701] do
        home = home!(dir, mode)
        refute FileStamp.trusted_home?(home), "mode #{Integer.to_string(mode, 8)}"
        assert FileStamp.open(home) == nil
      end
    end

    test "not a link, even to a directory only its owner can enter", %{tmp_dir: dir} do
      real = home!(dir)
      link = Path.join(dir, "link")
      File.ln_s!(real, link)
      refute FileStamp.trusted_home?(link)
      assert FileStamp.open(link) == nil
    end

    test "not a home that is missing or not a directory", %{tmp_dir: dir} do
      refute FileStamp.trusted_home?(Path.join(dir, "missing"))
      refute FileStamp.trusted_home?(nil)
      file = Path.join(dir, "file")
      File.write!(file, "")
      refute FileStamp.trusted_home?(file)
    end
  end
end
