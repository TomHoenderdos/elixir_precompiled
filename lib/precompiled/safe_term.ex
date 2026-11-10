# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.SafeTerm do
  @moduledoc false
  # Decodes an external term format binary that came from somewhere this
  # library does not control, or that a third-party build chose. [:safe]
  # alone is not enough:
  #
  # - a compressed term (<<131, 80, ...>>) is inflated in full before
  #   [:safe] looks at it, so a few hundred bytes can ask for gigabytes;
  #   it is refused before decoding, and so is anything over `max_bytes`;
  # - [:safe] still decodes funs of modules already loaded, and pids,
  #   ports and references. None of them is a value a config or a cache
  #   entry here can hold, so a term holding one anywhere is refused.
  #
  # Bytes after the term are refused too. The walk is iterative, so a
  # deeply nested term cannot exhaust the stack; `max_bytes` bounds how
  # many nodes it visits.

  @spec decode(binary(), pos_integer()) :: {:ok, term()} | :error
  def decode(bin, max_bytes) when is_binary(bin) and byte_size(bin) <= max_bytes do
    case bin do
      <<131, 80, _::binary>> -> :error
      <<131, _, _::binary>> -> decode_plain(bin)
      _ -> :error
    end
  end

  def decode(_bin, _max_bytes), do: :error

  defp decode_plain(bin) do
    {term, used} = :erlang.binary_to_term(bin, [:safe, :used])

    if used == byte_size(bin) and plain?([term]), do: {:ok, term}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp plain?([]), do: true

  defp plain?([t | _rest]) when is_function(t) or is_pid(t) or is_port(t) or is_reference(t),
    do: false

  defp plain?([t | rest]) when is_tuple(t), do: plain?(Tuple.to_list(t) ++ rest)
  defp plain?([t | rest]) when is_map(t), do: plain?(Enum.flat_map(t, &Tuple.to_list/1) ++ rest)
  defp plain?([[h | tl] | rest]), do: plain?([h, tl | rest])
  defp plain?([_ | rest]), do: plain?(rest)
end
