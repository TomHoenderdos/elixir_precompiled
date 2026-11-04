# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.RootSwap do
  @moduledoc """
  T6: serves an attacker's `root.json` in place of the portal's: one
  version newer than the served root, signed only by a fresh key of its own
  (`ChainTest.AttackerRoot`). The client must not adopt it: it does not
  chain from the root in use. Everything else is served unchanged.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.AttackerRoot

  @impl true
  def valid_args?(args), do: args == %{}

  @impl true
  def transform("root.json", bytes, _args), do: {200, AttackerRoot.envelope(version(bytes) + 1)}
  def transform(_path, bytes, _args), do: {200, bytes}

  defp version(bytes) do
    with {:ok, %{"payload" => p}} when is_binary(p) <- JSON.decode(bytes),
         {:ok, payload} <- Base.url_decode64(p, padding: false),
         {:ok, %{"version" => v}} when is_integer(v) and v > 0 <- JSON.decode(payload) do
      v
    else
      _ -> raise ArgumentError, "root.json is not a root envelope"
    end
  end
end
