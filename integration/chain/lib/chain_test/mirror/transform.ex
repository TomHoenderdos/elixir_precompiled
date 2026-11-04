# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Transform do
  @moduledoc """
  A change to what the mirror serves, as data: a module implementing this
  behaviour plus its args map, written `{module, args}` in a conformance
  case. `fun/1` turns it into the mirror's `(path, bytes) -> {status,
  bytes}` hook.
  """

  @callback transform(path :: String.t(), bytes :: binary(), args :: map()) ::
              {pos_integer(), binary()}

  @doc "The mirror hook for `{module, args}`."
  @spec fun({module(), map()}) :: ChainTest.Mirror.transform()
  def fun({module, args}) when is_atom(module) and is_map(args),
    do: fn path, bytes -> module.transform(path, bytes, args) end

  @doc "Whether `term` is `{module, args}` with a loaded module implementing `transform/3`."
  @spec valid?(term()) :: boolean()
  def valid?({module, args}) when is_atom(module) and is_map(args),
    do: Code.ensure_loaded?(module) and function_exported?(module, :transform, 3)

  def valid?(_), do: false
end
