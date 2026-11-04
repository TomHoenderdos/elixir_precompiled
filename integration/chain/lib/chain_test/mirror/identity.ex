# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Identity do
  @moduledoc "Serves the snapshot unchanged: the control case."
  @behaviour ChainTest.Mirror.Transform

  @impl true
  def transform(_path, bytes, _args), do: {200, bytes}
end
