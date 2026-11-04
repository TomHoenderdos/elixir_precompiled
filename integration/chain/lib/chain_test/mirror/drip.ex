# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Drip do
  @moduledoc """
  N4: the named resource (`paths: :batch`, `batch.json`, or `:files`) sent
  one byte at a time, `delay_ms` (default 2000) before each, without a
  `content-length`. `stream_max_ms` (required) is the case mirror's cap on
  that stream: set it past the client's own deadline, so a refusal can only
  come from the client giving up, and the run stays bounded by the cap.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Mirror.Transform

  @impl true
  def valid_args?(%{paths: paths, stream_max_ms: _} = args) do
    paths in [:batch, :files] and
      Enum.all?(Map.keys(args), &(&1 in [:paths, :stream_max_ms, :delay_ms])) and
      Map.get(args, :delay_ms, 2_000) in 0..60_000
  end

  def valid_args?(_args), do: false

  @impl true
  def transform(path, bytes, %{paths: paths} = args) do
    if named?(paths, path),
      do: {:stream, 200, for(<<b <- bytes>>, do: <<b>>), Map.get(args, :delay_ms, 2_000)},
      else: {200, bytes}
  end

  defp named?(:batch, path), do: path == "batch.json"
  defp named?(:files, path), do: Transform.file_path?(path)
end
