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
  def transform(path, bytes, %{paths: paths, status: status}) do
    if path in paths, do: {status, ""}, else: {200, bytes}
  end
end
