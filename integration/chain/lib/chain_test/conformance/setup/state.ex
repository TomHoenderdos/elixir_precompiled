# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Setup.State do
  @moduledoc """
  Writes the client's batch sequence state before the build, as a client
  that ran earlier would have left it (R3-R5, T4, T5, R19). `sequence`:

    * `:snapshot` - the snapshot batch's sequence `N`;
    * `{:below, n}` - `N - n` (at least 0): an older run, with a gap;
    * `:corrupt` - bytes that are no sequence number at all.

  `source` (default `:case`) names whose state: the case's source, or
  `:second`, the case's second mirror (a two-mirror transform), so a case
  can check that one source's state leaves the other's alone.
  """
  @behaviour ChainTest.Conformance.Setup

  alias ChainTest.Conformance.Setup

  @corrupt "\xFF\xFEnot a sequence number\n"

  @impl true
  def valid_args?(%{sequence: sequence} = args) do
    Enum.all?(Map.keys(args), &(&1 in [:sequence, :source])) and sequence?(sequence) and
      Map.get(args, :source, :case) in [:case, :second]
  end

  def valid_args?(_args), do: false

  defp sequence?(s) when s in [:snapshot, :corrupt], do: true
  defp sequence?({:below, n}) when is_integer(n) and n >= 0, do: true
  defp sequence?(_), do: false

  @impl true
  def setup(home, %{case: ctx} = snap, %{sequence: sequence} = args) do
    with {:ok, source} <- source(Map.get(args, :source, :case), ctx),
         {:ok, dir} <- Setup.state_dir(home, source, ctx.root) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "state"), bytes(sequence, snap.sequence))
      :ok
    end
  end

  defp source(:case, ctx), do: {:ok, ctx.source}
  defp source(:second, %{mirrors: [_, second | _]}), do: {:ok, second}
  defp source(:second, _ctx), do: {:error, "source: :second needs the case's second mirror"}

  defp bytes(:snapshot, n), do: Integer.to_string(n)
  defp bytes({:below, gap}, n), do: Integer.to_string(max(n - gap, 0))
  defp bytes(:corrupt, _n), do: @corrupt
end
