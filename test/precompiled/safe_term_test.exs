# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.SafeTermTest do
  use ExUnit.Case, async: true
  alias Precompiled.SafeTerm

  @cap 65_536

  test "plain values decode" do
    for term <- [
          :fast,
          :error,
          "a string",
          [mode: :fast, level: 3],
          %{"a" => %{b: [1, 2.5, {:ok, <<1, 2>>}]}},
          [1 | 2],
          {}
        ] do
      assert {:ok, ^term} = SafeTerm.decode(:erlang.term_to_binary(term), @cap)
    end
  end

  test "compressed ETF is refused before it is inflated" do
    bin = :erlang.term_to_binary(:binary.copy(<<0>>, 50_000_000), [:compressed])
    assert <<131, 80, _::binary>> = bin
    assert byte_size(bin) < @cap
    {us, :error} = :timer.tc(fn -> SafeTerm.decode(bin, @cap) end)
    assert us < 50_000
  end

  test "a binary over the cap is refused" do
    bin = :erlang.term_to_binary(:binary.copy("a", @cap))
    assert byte_size(bin) > @cap
    assert :error = SafeTerm.decode(bin, @cap)
    assert {:ok, _} = SafeTerm.decode(bin, byte_size(bin))
  end

  test "funs, pids, ports and references are refused anywhere in the term" do
    port = Port.list() |> hd()

    for bad <- [&Enum.map/2, self(), port, make_ref()],
        term <- [
          bad,
          [1, bad],
          [1 | bad],
          {:ok, {bad}},
          %{key: bad},
          %{bad => 1},
          %{"a" => [x: %{b: bad}]}
        ] do
      assert :error = SafeTerm.decode(:erlang.term_to_binary(term), @cap), inspect(term)
    end
  end

  test "not ETF, a bad term, or trailing bytes are refused" do
    good = :erlang.term_to_binary(:ok)

    for bin <- ["", <<131>>, "plain text", <<130, 100>>, <<131, 255, 0>>, good <> <<0>>] do
      assert :error = SafeTerm.decode(bin, @cap), inspect(bin)
    end
  end

  test "a deeply nested term does not blow the stack" do
    deep = Enum.reduce(1..5_000, :leaf, &[&2 | &1])
    assert {:ok, ^deep} = SafeTerm.decode(:erlang.term_to_binary(deep), @cap)
    deep_tuple = Enum.reduce(1..5_000, :leaf, fn _, acc -> {acc} end)
    assert {:ok, _} = SafeTerm.decode(:erlang.term_to_binary(deep_tuple), @cap)
  end
end
