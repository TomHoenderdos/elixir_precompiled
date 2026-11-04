# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Transform do
  @moduledoc """
  A change to what the mirror serves, as data: a module implementing this
  behaviour plus its args map, written `{module, args}` in a conformance
  case. `fun/2` turns it into the mirror's `(path, bytes) ->
  ChainTest.Mirror.response()` hook.

  Two args keys mean something to the runner, so a module that takes them
  must accept them in `valid_args?/1`:

    * `mirrors: 2` - the case gets a second mirror over the snapshot (a
      cross-origin redirect target, say), started before the case's own.
      Both run this transform; see `:case` below.
    * `:case` - reserved: never in a case file. At run time the runner puts
      the case's context there: `%{mirror: 1 | 2, second_url: url | nil,
      snapshot: snapshot}`, `mirror` saying which mirror is answering and
      `second_url` the second mirror's base URL (on mirror 1 of a
      two-mirror case only).

  A module that needs something of the snapshot (`t:ChainTest.Snapshot.need/0`:
  an older batch, `:previous`, `:old`; `:previous_manifests`;
  `:batch_threshold_2`) says so in `needs/1`; a case whose snapshot lacks
  it is not testable here and is never run.
  """

  @callback transform(path :: String.t(), bytes :: binary(), args :: map()) ::
              ChainTest.Mirror.response()

  @doc "Whether `args` is an args map this transform accepts. Optional: without it, any map is."
  @callback valid_args?(args :: map()) :: boolean()

  @doc "What the transform needs of the snapshot. Optional: without it, nothing."
  @callback needs(args :: map()) :: [ChainTest.Snapshot.need()]

  @optional_callbacks valid_args?: 1, needs: 1

  @doc """
  The mirror hook for `{module, args}`; `context`, when given, is put in the
  args as `:case` (see the moduledoc).
  """
  @spec fun({module(), map()}, map() | nil) :: ChainTest.Mirror.transform()
  def fun(transform, context \\ nil)

  def fun({module, args}, nil) when is_atom(module) and is_map(args),
    do: fn path, bytes -> module.transform(path, bytes, args) end

  def fun({module, args}, context) when is_atom(module) and is_map(args) and is_map(context),
    do: fun({module, Map.put(args, :case, context)}, nil)

  @doc """
  Whether `term` is `{module, args}` with a loaded module implementing
  `transform/3`, `args` without the reserved `:case`, `mirrors` (when given)
  1 or 2, `needs/1` (when defined) naming only `t:ChainTest.Snapshot.need/0`s,
  and `valid_args?/1` (when defined) accepting `args`.
  """
  @spec valid?(term()) :: boolean()
  def valid?({module, args}) when is_atom(module) and is_map(args) do
    Code.ensure_loaded?(module) and function_exported?(module, :transform, 3) and
      not Map.has_key?(args, :case) and Map.get(args, :mirrors, 1) in [1, 2] and
      valid_args?(module, args) and needs_valid?(module, args)
  end

  def valid?(_), do: false

  @doc "How many mirrors the case runs: 2 when the args say `mirrors: 2`, else 1."
  @spec mirrors({module(), map()}) :: 1 | 2
  def mirrors({_module, args}), do: Map.get(args, :mirrors, 1)

  @doc "What `{module, args}` needs of the snapshot (`needs/1`, else nothing)."
  @spec needs({module(), map()}) :: [ChainTest.Snapshot.need()]
  def needs({module, args}), do: module_needs(module, args)

  @doc false
  # Shared with ChainTest.Conformance.Setup, whose modules take the same
  # optional callbacks.
  @spec valid_args?(module(), map()) :: boolean()
  def valid_args?(module, args) do
    Code.ensure_loaded?(module) and
      (not function_exported?(module, :valid_args?, 1) or module.valid_args?(args) == true)
  end

  @doc false
  @spec needs_valid?(module(), map()) :: boolean()
  def needs_valid?(module, args) do
    case module_needs(module, args) do
      list when is_list(list) -> Enum.all?(list, &(&1 in ChainTest.Snapshot.need_names()))
      _ -> false
    end
  end

  @doc false
  @spec module_needs(module(), map()) :: term()
  def module_needs(module, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, :needs, 1),
      do: module.needs(args),
      else: []
  end
end
