# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Rebar3ArchTest do
  use ExUnit.Case, async: true

  alias Precompiled.Rebar3Arch

  # hackney's own platform_define, unanchored.
  @hackney "R14"

  @arches [
    "27.2.4-x86_64-pc-linux-gnu-64",
    "27.3-aarch64-apple-darwin23.4.0-64",
    "28.1.1-aarch64-apple-darwin24.6.0-64",
    "28.0.2-aarch64-unknown-linux-gnu-64",
    "29.1.1-x86_64-pc-linux-gnu-64",
    "29.0-x86_64-apple-darwin25.0.0-64"
  ]

  test "hackney's R14 matches no arch string of OTP 27, 28 or 29, Linux or macOS" do
    for arch <- @arches, do: assert(Rebar3Arch.match(@hackney, arch) == false, arch)
  end

  test "R14 matches an R14 release, as rebar3 would there" do
    assert Rebar3Arch.match(@hackney, "R14B04-i686-pc-linux-gnu-32")
  end

  test "a regex that matches, and hackney's anchored ones" do
    for arch <- @arches do
      assert Rebar3Arch.match("^[0-9]+", arch)
      refute Rebar3Arch.match("^R", arch)
      refute Rebar3Arch.match("^(1|(20))", arch)
      refute Rebar3Arch.match("^20\\.3", arch)
    end

    assert Rebar3Arch.match("darwin", "28.1.1-aarch64-apple-darwin24.6.0-64")
    refute Rebar3Arch.match("darwin", "28.0.2-aarch64-unknown-linux-gnu-64")
    assert Rebar3Arch.match("-64$", "29.1.1-x86_64-pc-linux-gnu-64")
  end

  test "a regex that does not compile, or is not a string, cannot be evaluated" do
    assert Rebar3Arch.match("(", "28.1.1-x86_64-pc-linux-gnu-64") == :error
    assert Rebar3Arch.match("[a-", "28.1.1-x86_64-pc-linux-gnu-64") == :error
    assert Rebar3Arch.match(<<0xFF>>, "28.1.1-x86_64-pc-linux-gnu-64") == :error
    assert Rebar3Arch.match(14, "28.1.1-x86_64-pc-linux-gnu-64") == :error
    assert Rebar3Arch.match(String.duplicate("a", 5000), "28") == :error
  end

  test "a regex past the match limit cannot be evaluated" do
    assert Rebar3Arch.match("(a+)+$", String.duplicate("a", 40) <> "!") == :error
  end

  test "the arch string is OTP_VERSION, the system architecture and the word size" do
    arch = Rebar3Arch.arch()
    otp = :erlang.system_info(:otp_release) |> List.to_string()
    sys = :erlang.system_info(:system_architecture) |> List.to_string()
    bits = Integer.to_string(:erlang.system_info({:wordsize, :external}) * 8)

    assert arch =~ ~r/\A#{Regex.escape(otp)}(\.[0-9]+)*-/
    assert String.ends_with?(arch, "-" <> sys <> "-" <> bits)
  end

  test "OTP_VERSION's '**' suffix and trailing newlines are dropped as rebar3 drops them" do
    assert Rebar3Arch.otp_version("28", {:ok, "28.1.1\n"}) == "28.1.1"
    assert Rebar3Arch.otp_version("28", {:ok, "28.1.1\n\n"}) == "28.1.1"
    assert Rebar3Arch.otp_version("17", {:ok, "17.0-rc1**\n"}) == "17.0-rc1"
    assert Rebar3Arch.otp_version("28", {:error, :enoent}) == "28"
    assert Rebar3Arch.otp_version("R16B03", {:ok, "ignored"}) == "R16B03"
  end

  # The arch string of the rebar3 Mix runs, computed by that rebar3's own
  # rebar_utils:get_arch/0, loaded from its escript.
  test "the arch string equals rebar3's own get_arch" do
    path = Mix.Rebar.local_rebar_path(:rebar3)

    if File.regular?(path) do
      {:ok, sections} = :escript.extract(String.to_charlist(path), [])
      {:archive, zip} = List.keyfind(sections, :archive, 0)

      wanted = [~c"rebar/ebin/rebar_utils.beam", ~c"rebar/ebin/rebar_string.beam"]
      {:ok, files} = :zip.extract(zip, [:memory, file_list: wanted])

      for {name, bin} <- files do
        mod = name |> Path.basename(".beam") |> String.to_atom()
        {:module, ^mod} = :code.load_binary(mod, name, bin)
      end

      assert Rebar3Arch.arch() == List.to_string(apply(:rebar_utils, :get_arch, []))
    end
  end
end
