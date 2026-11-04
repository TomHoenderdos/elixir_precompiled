# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.BatchSignatures do
  @moduledoc """
  Changes the signatures of the real `batch.json` and nothing else (T1,
  T3); the payload stays the portal's bytes. `change`:

    * `:flip_bit` - one bit of the first signature flipped;
    * `:remove` - no signature at all;
    * `:duplicate` - the first signature only, twice: one key counted twice
      towards the threshold. Meaningful only when the root's batch role
      needs two signatures, so it `needs/1` `:batch_threshold_2`.

  Bytes that are not a signed envelope raise: the mirror logs a transform
  error and the case fails, rather than passing on the mirror's 500.
  """
  @behaviour ChainTest.Mirror.Transform

  @changes [:flip_bit, :remove, :duplicate]

  @impl true
  def valid_args?(%{change: change} = args) when map_size(args) == 1, do: change in @changes
  def valid_args?(_args), do: false

  @impl true
  def needs(%{change: :duplicate}), do: [:batch_threshold_2]
  def needs(_args), do: []

  @impl true
  def transform("batch.json", bytes, %{change: change}) do
    envelope = decode!(bytes)
    {200, JSON.encode!(%{envelope | "signatures" => change(change, envelope["signatures"])})}
  end

  def transform(_path, bytes, _args), do: {200, bytes}

  defp decode!(bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"payload" => p, "signatures" => [%{"sig" => s} | _]} = env}
      when is_binary(p) and is_binary(s) ->
        env

      _ ->
        raise ArgumentError, "batch.json is not a signed envelope"
    end
  end

  defp change(:remove, _sigs), do: []
  defp change(:duplicate, [first | _]), do: [first, first]

  defp change(:flip_bit, [%{"sig" => sig} = first | rest]) do
    <<byte, tail::binary>> = Base.url_decode64!(sig, padding: false)
    flipped = <<Bitwise.bxor(byte, 1), tail::binary>>
    [%{first | "sig" => Base.url_encode64(flipped, padding: false)} | rest]
  end
end
