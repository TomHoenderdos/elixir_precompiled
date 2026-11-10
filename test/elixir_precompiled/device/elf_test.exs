# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Device.ElfTest do
  use ExUnit.Case, async: true
  import ElixirPrecompiled.DeviceFixture, only: [elf_header: 2]
  alias ElixirPrecompiled.Device.Elf

  @aarch64 "aarch64-unknown-linux-gnu"

  test "an aarch64 .so on an aarch64 device passes" do
    assert Elf.check("priv/gpio_nif.so", elf_header(64, :aarch64), @aarch64) == :ok
  end

  test "a 32-bit ARM .so on an aarch64 device is refused" do
    assert Elf.check("priv/gpio_nif.so", elf_header(32, :arm), @aarch64) ==
             {:fail, "priv/gpio_nif.so is arm (32-bit), device runs aarch64"}
  end

  test "an aarch64 .so on a 32-bit ARM userland is refused" do
    assert Elf.check("priv/x.so", elf_header(64, :aarch64), "arm-unknown-linux-gnueabihf") ==
             {:fail, "priv/x.so is aarch64, device runs armv7"}
  end

  test "x86_64 and riscv64 are told apart" do
    assert {:fail, _} =
             Elf.check("priv/x.so", elf_header(64, :x86_64), "riscv64-unknown-linux-gnu")

    assert :ok = Elf.check("priv/x.so", elf_header(64, :riscv), "riscv64-unknown-linux-gnu")
  end

  test "a big-endian or unknown-class ELF is refused" do
    <<head::binary-size(5), _data, rest::binary>> = elf_header(64, :aarch64)

    assert Elf.check("priv/x.so", head <> <<2>> <> rest, @aarch64) ==
             {:fail, "priv/x.so is big-endian, device runs little-endian"}

    assert Elf.check("priv/x.so", head <> <<0>> <> rest, @aarch64) ==
             {:fail, "priv/x.so has an unknown ELF byte order (0)"}

    <<magic::binary-size(4), _class, tail::binary>> = elf_header(64, :aarch64)

    assert Elf.check("priv/x.so", magic <> <<3>> <> tail, @aarch64) ==
             {:fail, "priv/x.so has an unknown ELF class (3)"}
  end

  test "non-ELF priv files pass; a truncated ELF header is refused" do
    assert Elf.check("priv/data.txt", "hello", @aarch64) == :ok

    assert Elf.check("priv/x.so", <<0x7F, "ELF", 2>>, @aarch64) ==
             {:fail, "priv/x.so has a truncated ELF header"}
  end

  test "an unknown device cpu refuses any ELF rather than guessing" do
    assert Elf.check("priv/x.so", elf_header(64, :aarch64), "mips-unknown-linux") ==
             {:fail, "priv/x.so is aarch64, device cpu mips-unknown-linux is not known"}
  end

  test "the class matters as well as the machine" do
    assert Elf.check("priv/x.so", elf_header(32, :x86), "x86_64-pc-linux-gnu") ==
             {:fail, "priv/x.so is x86, device runs x86_64"}

    assert Elf.check("priv/x.so", elf_header(32, :x86), "i686-pc-linux-gnu") == :ok
  end

  test "expected/1 maps the system architecture to a class and machine" do
    assert Elf.expected(@aarch64) == {64, :aarch64}
    assert Elf.expected("armv7l-unknown-linux-gnueabihf") == {32, :arm}
    assert Elf.expected("arm-unknown-linux-gnueabihf") == {32, :arm}
    assert Elf.expected("x86_64-pc-linux-gnu") == {64, :x86_64}
    assert Elf.expected("riscv64-unknown-linux-gnu") == {64, :riscv}
    assert Elf.expected("i386-pc-linux-gnu") == {32, :x86}
    assert Elf.expected("mips-unknown-linux") == :unknown
  end

  test "the fixture header is 64 bytes" do
    assert byte_size(elf_header(64, :aarch64)) == 64
  end
end
