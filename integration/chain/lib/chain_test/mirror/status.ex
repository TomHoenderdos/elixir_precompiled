# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Status do
  @moduledoc """
  Answers `status` with an empty body for some paths and serves the rest
  unchanged. The paths are either:

    * `paths` - a list of snapshot paths
      (`%{paths: ["v2/manifests/jason.json"], status: 500}`); or
    * `files_of` - a dep's name: every `files/<sha256>` the snapshot holds
      for that dep (`%{files_of: "jason", status: 404}`). A trap (C0): the
      case expects the client never to ask for them, its cache holding
      them, so nothing changed is the expected outcome (`trap?/1`).
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Mirror.Transform

  @impl true
  def valid_args?(%{paths: [_ | _] = paths, status: status} = args)
      when map_size(args) == 2 and is_integer(status) and status in 100..599,
      do: Enum.all?(paths, &is_binary/1)

  def valid_args?(%{files_of: dep, status: status} = args)
      when map_size(args) == 2 and is_binary(dep) and dep != "" and is_integer(status) and
             status in 100..599,
      do: true

  def valid_args?(_args), do: false

  @impl true
  def trap?(args), do: Map.has_key?(args, :files_of)

  @impl true
  def transform(path, bytes, %{paths: paths, status: status}) do
    if path in paths, do: {status, ""}, else: {200, bytes}
  end

  def transform(path, bytes, %{files_of: dep, status: status, case: %{snapshot: snap}}) do
    shas = get_in(snap, [:deps, dep, :file_shas]) || []

    if Transform.file_path?(path) and String.replace_prefix(path, "files/", "") in shas,
      do: {status, ""},
      else: {200, bytes}
  end
end
