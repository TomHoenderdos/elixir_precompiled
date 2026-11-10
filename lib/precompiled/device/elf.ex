# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Elf do
  @moduledoc false
  # Every priv file that is ELF must be built for the device's class and
  # machine. Cheap, after the hash and before the rename; catches a
  # mislabelled system, a reused system name and a 32/64-bit userland
  # mismatch, which the system name alone would not show.

  @machines %{183 => :aarch64, 40 => :arm, 62 => :x86_64, 243 => :riscv, 3 => :x86}

  @typedoc "An ELF class (32 or 64) and e_machine."
  @type kind :: {32 | 64, atom()}

  @doc false
  @spec machines() :: %{non_neg_integer() => atom()}
  def machines(), do: @machines

  @doc false
  @spec expected(String.t()) :: kind() | :unknown
  def expected("aarch64-" <> _), do: {64, :aarch64}
  def expected("arm" <> _), do: {32, :arm}
  def expected("x86_64-" <> _), do: {64, :x86_64}
  def expected("riscv64-" <> _), do: {64, :riscv}
  def expected(<<"i", _, "86-", _::binary>>), do: {32, :x86}
  def expected(_), do: :unknown

  @doc false
  @spec check(String.t(), binary(), String.t()) :: :ok | {:fail, String.t()}
  # Every target this knows is little-endian (EI_DATA 1); a big-endian
  # or unknown byte order, or a class other than 32 (1) or 64 (2) bits, is
  # refused rather than read as something else.
  def check(path, <<0x7F, "ELF", class, _data, _::binary>>, _cpu) when class not in [1, 2],
    do: {:fail, "#{path} has an unknown ELF class (#{class})"}

  def check(path, <<0x7F, "ELF", _class, 2, _::binary>>, _cpu),
    do: {:fail, "#{path} is big-endian, device runs little-endian"}

  def check(path, <<0x7F, "ELF", _class, data, _::binary>>, _cpu) when data != 1,
    do: {:fail, "#{path} has an unknown ELF byte order (#{data})"}

  def check(path, <<0x7F, "ELF", class, 1, _::binary-size(12), m1, m2, _::binary>>, cpu) do
    found = {if(class == 2, do: 64, else: 32), Map.get(@machines, m2 * 256 + m1, :unknown)}
    compare(path, found, expected(cpu), cpu)
  end

  def check(path, <<0x7F, "ELF", _::binary>>, _cpu),
    do: {:fail, "#{path} has a truncated ELF header"}

  def check(_path, _bytes, _cpu), do: :ok

  defp compare(_path, same, same, _cpu), do: :ok

  defp compare(path, found, :unknown, cpu),
    do: {:fail, "#{path} is #{name(found)}, device cpu #{cpu} is not known"}

  defp compare(path, found, want, _cpu),
    do: {:fail, "#{path} is #{name(found)}, device runs #{device_name(want)}"}

  defp name({32, :arm}), do: "arm (32-bit)"
  defp name({_, m}), do: Atom.to_string(m)

  defp device_name({32, :arm}), do: "armv7"
  defp device_name({_, m}), do: Atom.to_string(m)
end
