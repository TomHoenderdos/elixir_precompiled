# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Status do
  @moduledoc """
  Answers `status` with an empty body for every path in `paths`
  (`%{paths: ["v2/manifests/jason.json"], status: 500}`) and serves the rest
  unchanged.
  """
  @behaviour ChainTest.Mirror.Transform

  @impl true
  def valid_args?(%{paths: [_ | _] = paths, status: status} = args)
      when map_size(args) == 2 and is_integer(status) and status in 100..599,
      do: Enum.all?(paths, &is_binary/1)

  def valid_args?(_args), do: false

  @impl true
  def transform(path, bytes, %{paths: paths, status: status}) do
    if path in paths, do: {status, ""}, else: {200, bytes}
  end
end
