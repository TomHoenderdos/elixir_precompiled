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

  Five args keys mean something to the runner, so a module that takes
  them must accept them in `valid_args?/1`:

    * `mirrors: 2` - the case gets a second mirror over the snapshot (a
      cross-origin redirect target, say), started before the case's own.
      Both run this transform; see `:case` below.
    * `stream_max_ms` - the case mirror's cap on a streamed body
      (`ChainTest.Mirror.start/2`), 1 to 600000 ms instead of the default
      120 s: a drip that must outlast the client's own deadline (N4).
      `mirror_opts/1` hands it to the runner.
    * `tls` - `:ip`, `:self_signed` or `:wrong_host`: the case mirror
      speaks HTTPS with a new certificate of that kind
      (`ChainTest.TestCert`), not with `mirrors: 2`.
    * `trust_ca` - `true`, only with a `tls` kind that has a CA (`:ip`,
      `:wrong_host`; a self-signed one has none): the case's build trusts that
      certificate's CA, and only it (`ChainTest.Build`'s `:trust_ca`).
      Without it, the build keeps the OS store, which knows no test CA.
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
      stream_cap?(args) and tls_args?(args) and valid_args?(module, args) and
      needs_valid?(module, args)
  end

  def valid?(_), do: false

  @doc "`bytes` with its middle byte changed (one bit flipped), the size kept."
  @spec flip_byte(binary()) :: binary()
  def flip_byte(bytes) when byte_size(bytes) > 0 do
    i = div(byte_size(bytes), 2)

    binary_part(bytes, 0, i) <>
      <<Bitwise.bxor(:binary.at(bytes, i), 1)>> <>
      binary_part(bytes, i + 1, byte_size(bytes) - i - 1)
  end

  @doc "Whether `path` is a manifest's: `manifests/<name>.json` or `v2/manifests/<name>.json`."
  @spec manifest_path?(String.t()) :: boolean()
  def manifest_path?(path), do: path =~ ~r|\A(v2/)?manifests/[^/]+\.json\z|

  @doc "Whether `path` is a file's: `files/<sha256>`."
  @spec file_path?(String.t()) :: boolean()
  def file_path?(path), do: String.starts_with?(path, "files/")

  @max_stream_ms 600_000
  @tls_kinds [:ip, :self_signed, :wrong_host]

  defp tls_args?(args) do
    case {Map.fetch(args, :tls), Map.fetch(args, :trust_ca)} do
      {:error, :error} ->
        true

      {{:ok, kind}, trust} ->
        kind in @tls_kinds and trust_ok?(kind, trust) and
          Map.get(args, :mirrors, 1) == 1

      {:error, _} ->
        false
    end
  end

  defp trust_ok?(_kind, :error), do: true
  defp trust_ok?(kind, {:ok, true}), do: kind in [:ip, :wrong_host]
  defp trust_ok?(_kind, _trust), do: false

  @doc "The certificate kind the case mirror presents (`tls`), or `nil` for plain http."
  @spec tls({module(), map()}) :: ChainTest.TestCert.kind() | nil
  def tls({_module, args}), do: Map.get(args, :tls)

  @doc "Whether the case's build trusts the case mirror's CA (`trust_ca: true`)."
  @spec trust_ca?({module(), map()}) :: boolean()
  def trust_ca?({_module, args}), do: Map.get(args, :trust_ca) == true

  defp stream_cap?(%{stream_max_ms: ms}), do: is_integer(ms) and ms in 1..@max_stream_ms
  defp stream_cap?(_args), do: true

  @doc "The mirror options the args ask for: `stream_max_ms`, when given."
  @spec mirror_opts({module(), map()}) :: keyword()
  def mirror_opts({_module, %{stream_max_ms: ms}}), do: [stream_max_ms: ms]
  def mirror_opts({_module, _args}), do: []

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
