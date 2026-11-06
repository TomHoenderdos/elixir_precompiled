# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.FileStampTest do
  # A cached file that was verified is not hashed again while nothing about
  # it changed since: its device, inode, size, mtime and ctime, read from the
  # open file, and the sha it was verified against. Any difference is a full
  # re-hash. ctime cannot be set back from user space, so a rewrite that
  # restores size and mtime still shows. Only a cache home that no one else
  # can write to is trusted to hold stamps at all.
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.FileStamp
  @moduletag :tmp_dir

  @sha String.duplicate("a", 64)

  defp stat!(path), do: File.stat!(path, time: :posix)

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

    # The rewrite stamps cannot hide: same size, mtime put back by hand.
    test "a rewrite that restores size and mtime still mismatches on ctime", %{tmp_dir: dir} do
      path = Path.join(dir, "rewritten")
      File.write!(path, "bytes")
      before = stat!(path)
      stamp = FileStamp.new(before, @sha)

      # ctime has one-second resolution on some file systems.
      Process.sleep(1_100)
      File.write!(path, "BYTES")
      File.touch!(path, before.mtime)
      after_write = stat!(path)

      assert after_write.size == before.size
      assert after_write.mtime == before.mtime
      refute FileStamp.match?(stamp, after_write, @sha)
    end
  end

  describe "trusted_home?/1" do
    test "a directory only its owner can write to", %{tmp_dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(home)
      File.chmod!(home, 0o700)
      assert FileStamp.trusted_home?(home)
    end

    test "not one a group or anyone else can write to", %{tmp_dir: dir} do
      for mode <- [0o770, 0o720, 0o707, 0o777, 0o702] do
        home = Path.join(dir, "home-#{Integer.to_string(mode, 8)}")
        File.mkdir_p!(home)
        File.chmod!(home, mode)
        refute FileStamp.trusted_home?(home), "mode #{Integer.to_string(mode, 8)}"
      end
    end

    test "not a link, even to a directory only its owner can write to", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      File.chmod!(real, 0o700)
      link = Path.join(dir, "link")
      File.ln_s!(real, link)
      refute FileStamp.trusted_home?(link)
    end

    test "not a home that is missing or not a directory", %{tmp_dir: dir} do
      refute FileStamp.trusted_home?(Path.join(dir, "missing"))
      file = Path.join(dir, "file")
      File.write!(file, "")
      refute FileStamp.trusted_home?(file)
    end
  end
end
