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
    shas = files_of(snap, dep)

    if Transform.file_path?(path) and String.replace_prefix(path, "files/", "") in shas,
      do: {status, ""},
      else: {200, bytes}
  end

  @doc """
  The sha256 of every file the snapshot holds for `dep`: what a `files_of`
  trap answers with its status. Empty, the trap cannot spring, and the
  runner fails the case before building (`trap_problem/2`).
  """
  @spec files_of(map(), String.t()) :: [String.t()]
  def files_of(snap, dep), do: get_in(snap, [:deps, dep, :file_shas]) || []

  @doc "Why the snapshot cannot back this trap's args, or `nil`."
  @spec trap_problem(map(), map()) :: String.t() | nil
  def trap_problem(%{files_of: dep}, snap) do
    if files_of(snap, dep) == [],
      do: "the trap names files_of #{inspect(dep)}, and the snapshot holds no file of #{dep}"
  end

  def trap_problem(_args, _snap), do: nil
end
