# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Redirect do
  @moduledoc """
  N1: the case mirror answers the named resources with a `302` to the same
  path on the second mirror (`mirrors: 2`), another origin (another port of
  127.0.0.1) that serves the snapshot unchanged. `paths` is `:batch`
  (`batch.json`), `:manifests` or `:files`. A client that follows has the
  second mirror's log to show for it.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Mirror.Transform

  @impl true
  def valid_args?(%{paths: paths, mirrors: 2} = args) when map_size(args) == 2,
    do: paths in [:batch, :manifests, :files]

  def valid_args?(_args), do: false

  @impl true
  def transform(path, bytes, %{paths: paths, case: %{mirror: 1, second_url: url}})
      when is_binary(url) do
    if named?(paths, path), do: {:redirect, 302, url <> "/" <> path}, else: {200, bytes}
  end

  def transform(_path, bytes, _args), do: {200, bytes}

  defp named?(:batch, path), do: path == "batch.json"
  defp named?(:manifests, path), do: Transform.manifest_path?(path)
  defp named?(:files, path), do: Transform.file_path?(path)
end
