# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.LibsTest do
  use ExUnit.Case, async: true
  alias Precompiled.Device.Libs
  alias Precompiled.Reason

  @moduletag :tmp_dir
  @libz Path.expand("../../fixtures/elf/libz_aarch64.so.1", __DIR__)

  # A device root: lib/libz.so.1.3.2 (the fixture) and the symlink
  # lib/libz.so.1 a rootfs has; usr/lib empty.
  setup %{tmp_dir: dir} do
    lib = Path.join(dir, "lib")
    usr = Path.join(dir, "usr/lib")
    File.mkdir_p!(lib)
    File.mkdir_p!(usr)
    File.cp!(@libz, Path.join(lib, "libz.so.1.3.2"))
    File.ln_s!("libz.so.1.3.2", Path.join(lib, "libz.so.1"))
    %{roots: [lib, usr], lib: lib, usr: usr}
  end

  defp code_of({:miss, %Reason{code: code, args: args}}), do: {code, args}

  defp counting_reader(test_pid) do
    fn path ->
      send(test_pid, {:read, path})
      Precompiled.Elf.read_file(path)
    end
  end

  test "a soname reached through a symlink, defining the needed version, passes", %{roots: r} do
    assert Libs.check(%{"libz.so.1" => ["ZLIB_1.2.9"]}, r) == :ok
  end

  test "an empty needs map passes, and so does a library needing no version", %{roots: r} do
    assert Libs.check(%{}, r) == :ok
    assert Libs.check(%{"libz.so.1" => []}, r) == :ok
  end

  test "a version the library does not define is symbol_version_missing", %{roots: r} do
    result = Libs.check(%{"libz.so.1" => ["ZLIB_1.4.0"]}, r)
    assert code_of(result) == {:symbol_version_missing, ["libz.so.1", "ZLIB_1.4.0"]}
    assert {:miss, %Reason{text: "libz.so.1 lacks ZLIB_1.4.0"}} = result
  end

  test "non-numeric versions are not needs", %{roots: r} do
    assert Libs.check(%{"libz.so.1" => ["ZLIB_1.2.9", "GLIBC_PRIVATE"]}, r) == :ok
  end

  test "a soname under no root is needed_lib_missing", %{roots: r} do
    result = Libs.check(%{"libssl.so.3" => []}, r)
    assert code_of(result) == {:needed_lib_missing, ["libssl.so.3"]}
    assert {:miss, %Reason{text: "libssl.so.3 missing on target"}} = result
  end

  test "the first root that has the file wins", %{roots: [lib, usr]} do
    File.cp!(@libz, Path.join(usr, "libz.so.1"))
    File.write!(Path.join(lib, "libother.so.1"), "")

    assert Libs.check(%{"libz.so.1" => ["ZLIB_1.2.9"]}, [usr, lib], read: counting_reader(self())) ==
             :ok

    assert_received {:read, path}
    assert path == Path.join(usr, "libz.so.1")
  end

  test "a library that does not read as ELF counts as missing", %{roots: r, lib: lib} do
    File.write!(Path.join(lib, "libtext.so.1"), "INPUT(libc.so.6)\n")
    # The ELF magic and class, then nothing a reader can use.
    File.write!(Path.join(lib, "libbad.so.1"), <<0x7F, "ELF", 2, 1, 1, 0, 1, 2, 3>>)
    File.mkdir_p!(Path.join(lib, "libdir.so.1"))

    for soname <- ["libtext.so.1", "libbad.so.1", "libdir.so.1"] do
      assert code_of(Libs.check(%{soname => []}, r)) == {:needed_lib_missing, [soname]}
    end
  end

  test "any read error counts as missing", %{roots: r} do
    for error <- [{:error, :bounds}, {:error, :eacces}, :not_elf, :garbage] do
      read = fn _ -> error end

      assert code_of(Libs.check(%{"libz.so.1" => []}, r, read: read)) ==
               {:needed_lib_missing, ["libz.so.1"]}
    end
  end

  test "a dangling symlink counts as missing", %{roots: r, lib: lib} do
    File.ln_s!("libnowhere.so.9", Path.join(lib, "libdangling.so.1"))

    assert code_of(Libs.check(%{"libdangling.so.1" => []}, r)) ==
             {:needed_lib_missing, ["libdangling.so.1"]}
  end

  test "a soname that is not a plain file name is never looked up", %{roots: r} do
    for soname <- ["../lib/libz.so.1", "lib/libz.so.1", "/lib/libz.so.1", "..", ".", ""] do
      read = fn path -> flunk("read #{path}") end

      assert {:miss, %Reason{code: :needed_lib_missing}} =
               Libs.check(%{soname => []}, r, read: read)
    end
  end

  test "malformed needs are a malformed entry, never a crash", %{roots: r} do
    for needs <- [nil, [], %{"libz.so.1" => "ZLIB_1.2.9"}, %{"libz.so.1" => [1]}, %{1 => []}] do
      assert code_of(Libs.check(needs, r)) == {:malformed_entry, []}
    end
  end

  test "two needs on the same library read it once", %{roots: r} do
    needs = %{"libz.so.1" => ["ZLIB_1.2.9"], "libz.so.1.3.2" => ["ZLIB_1.3.2"]}
    assert Libs.check(needs, r, read: counting_reader(self())) == :ok

    assert_received {:read, _}
    refute_received {:read, _}
  end

  test "a memo shared across checks reads each library once for the run", %{roots: r} do
    memo = :ets.new(:libs_memo, [:set, :private])
    read = counting_reader(self())

    assert Libs.check(%{"libz.so.1" => ["ZLIB_1.2.9"]}, r, read: read, memo: memo) == :ok
    assert Libs.check(%{"libz.so.1.3.2" => ["ZLIB_1.3.2"]}, r, read: read, memo: memo) == :ok
    missing = Libs.check(%{"libz.so.1" => ["ZLIB_9.9"]}, r, read: read, memo: memo)
    assert code_of(missing) == {:symbol_version_missing, ["libz.so.1", "ZLIB_9.9"]}

    assert_received {:read, _}
    refute_received {:read, _}
  end

  test "the default roots are /lib and /usr/lib" do
    assert Libs.default_roots() == ["/lib", "/usr/lib"]
  end
end
