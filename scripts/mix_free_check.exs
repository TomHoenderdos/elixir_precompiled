# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Proves the device layer never calls Mix or Hex: walks the local calls and
# captured funs reachable from Precompiled (with its structs) and every
# Precompiled.Device* module through this library's own modules, and fails
# on any reference to Mix* or Hex*, found through any of three beam chunks:
#
#   - :imports, for a plain remote call (Mix.env()) — gives the precise
#     module/function/arity;
#   - :literals, for a captured external fun (&Mix.env/0) — the compiler
#     stores the whole fun value as one literal, never as a call_ext, so it
#     gives the same precision once decoded;
#   - :atoms, for a module threaded through a variable before a dynamic
#     apply/3 (a literal `apply(Mix, :env, [])` is folded by the compiler
#     into the same call_ext as a direct call and is already caught by
#     :imports; only a module that first passes through a variable or a
#     parameter defeats that fold) — this only proves a forbidden module
#     was referenced at all, not which function.
#
# The two allowed references are Precompiled.Output's Mix.shell/0
# (behind mix_running?/0, which is false on a device) and
# Precompiled.Fetch's bare Hex.SCM marker atom (never called).
#
# Run on the prod build: MIX_ENV=prod mix compile, then
# elixir scripts/mix_free_check.exs _build/prod/lib/precompiled/ebin.
defmodule MixFreeCheck do
  # The device API: Precompiled and its structs. Every other Precompiled.*
  # module outside Precompiled.Device is host code, checked only when the
  # device layer reaches it.
  @api [Precompiled, Precompiled.Installed, Precompiled.Plan]
  @allowed_calls [{Precompiled.Output, Mix, :shell, 0}]
  @allowed_atoms [{Precompiled.Output, Mix}, {Precompiled.Fetch, Hex.SCM}]

  @spec run(Path.t()) :: {:ok, [module()]} | {:error, [String.t()]}
  def run(ebin) do
    modules = scan(ebin)
    roots = for m <- Map.keys(modules), root?(m), do: m

    if roots == [] do
      {:error, ["no device-layer modules in #{ebin}"]}
    else
      reached = reach(roots, modules, MapSet.new())
      bad = for m <- Enum.sort(reached), line <- offenses(m, modules[m]), do: line
      if bad == [], do: {:ok, Enum.sort(roots)}, else: {:error, Enum.uniq(bad)}
    end
  end

  defp scan(ebin) do
    for beam <- Path.wildcard(Path.join(ebin, "*.beam")), into: %{} do
      # :allow_missing_chunks, because a module with no complex literal
      # terms carries no "LitT" chunk at all, and chunks/3 otherwise errors
      # out the whole call rather than just that one key.
      {:ok, {mod, chunks}} = chunks(String.to_charlist(beam))
      {mod, Map.new(chunks, fn {k, v} -> {k, present(v)} end)}
    end
  end

  # beam_lib names the literals chunk only from OTP 28 on. On OTP 27 the
  # raw "LitT" chunk is read and decoded the same way: a zlib-compressed
  # count and size-prefixed external terms, as [{index, term}].
  defp chunks(beam) do
    case :beam_lib.chunks(beam, [:imports, :atoms, :literals], [:allow_missing_chunks]) do
      {:error, :beam_lib, {:unknown_chunk, _, :literals}} ->
        {:ok, {mod, chunks}} =
          :beam_lib.chunks(beam, [:imports, :atoms, ~c"LitT"], [:allow_missing_chunks])

        {:ok, {mod, Enum.map(chunks, &lit_t/1)}}

      result ->
        result
    end
  end

  defp lit_t({~c"LitT", :missing_chunk}), do: {:literals, :missing_chunk}

  defp lit_t({~c"LitT", <<_size::32, compressed::binary>>}) do
    <<_count::32, terms::binary>> = :zlib.uncompress(compressed)
    {:literals, terms |> literal_terms() |> Enum.with_index(fn t, i -> {i, t} end)}
  end

  defp lit_t(other), do: other

  defp literal_terms(<<>>), do: []

  defp literal_terms(<<size::32, term::binary-size(size), rest::binary>>),
    do: [:erlang.binary_to_term(term) | literal_terms(rest)]

  defp present(:missing_chunk), do: []
  defp present(list), do: list

  defp root?(m) do
    s = Atom.to_string(m)

    m in @api or s == "Elixir.Precompiled.Device" or
      String.starts_with?(s, "Elixir.Precompiled.Device.")
  end

  defp reach([], _modules, seen), do: seen

  defp reach([m | rest], modules, seen) do
    if MapSet.member?(seen, m) or not Map.has_key?(modules, m) do
      reach(rest, modules, seen)
    else
      next = for mod <- callees(modules[m]), Map.has_key?(modules, mod), do: mod
      reach(next ++ rest, modules, MapSet.put(seen, m))
    end
  end

  # The project modules a module calls: remote calls (:imports) and
  # captured external funs (&Mod.fun/n, stored as :literals), so a helper
  # reached only through a capture is walked like a called one.
  defp callees(%{imports: imports, literals: literals}) do
    Enum.map(imports, fn {mod, _, _} -> mod end) ++
      Enum.flat_map(literals, fn {_i, v} -> for {mod, _, _} <- fun_targets(v), do: mod end)
  end

  defp offenses(m, %{imports: imports, atoms: atoms, literals: literals}) do
    call_offenses(m, imports) ++
      literal_offenses(m, literals) ++ atom_offenses(m, atoms, imports, literals)
  end

  defp call_offenses(m, imports) do
    for {mod, f, a} <- imports, forbidden?(mod), not allowed_call?(m, mod, f, a) do
      "#{m} calls #{mod}.#{f}/#{a}"
    end
  end

  defp literal_offenses(m, literals) do
    for {_index, value} <- literals,
        {mod, f, a} <- fun_targets(value),
        forbidden?(mod),
        not allowed_call?(m, mod, f, a) do
      "#{m} calls #{mod}.#{f}/#{a}"
    end
  end

  # Every module a direct call or a captured fun already names precisely is
  # excluded here, so a plain `Mix.env()` reports exactly one line, not one
  # precise line plus one vague one for the same module.
  defp atom_offenses(m, atoms, imports, literals) do
    precise =
      MapSet.new(
        Enum.map(imports, fn {mod, _, _} -> mod end) ++
          Enum.flat_map(literals, fn {_i, v} -> for {mod, _, _} <- fun_targets(v), do: mod end)
      )

    for {_index, mod} <- atoms,
        is_atom(mod),
        forbidden?(mod),
        not MapSet.member?(precise, mod),
        not allowed_atom?(m, mod) do
      "#{m} calls #{mod} dynamically"
    end
    |> Enum.uniq()
  end

  defp fun_targets(fun) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} ->
        {:module, mod} = :erlang.fun_info(fun, :module)
        {:name, name} = :erlang.fun_info(fun, :name)
        {:arity, arity} = :erlang.fun_info(fun, :arity)
        [{mod, name, arity}]

      _ ->
        []
    end
  end

  defp fun_targets(list) when is_list(list), do: Enum.flat_map(list, &fun_targets/1)
  defp fun_targets(tuple) when is_tuple(tuple), do: fun_targets(Tuple.to_list(tuple))
  defp fun_targets(map) when is_map(map), do: fun_targets(Map.to_list(map))
  defp fun_targets(_other), do: []

  defp forbidden?(mod) do
    s = Atom.to_string(mod)
    s in ["Elixir.Mix", "Elixir.Hex"] or String.starts_with?(s, ["Elixir.Mix.", "Elixir.Hex."])
  end

  defp allowed_call?(caller, mod, f, a), do: {caller, mod, f, a} in @allowed_calls
  defp allowed_atom?(caller, mod), do: {caller, mod} in @allowed_atoms
end

# Gated on ExUnit actually running, not on System.argv(): `mix test <path>`
# leaves ["test", path, ...] in System.argv() for the whole VM, so an
# argv-based guard would run this branch (and System.halt(1) the entire
# suite) the moment this script is Code.require_file'd from a test's
# setup_all. ExUnit itself is always loadable (it ships with Elixir), but
# only `mix test` actually starts its application.
ex_unit_running? = Enum.any?(Application.started_applications(), &match?({:ex_unit, _, _}, &1))

unless ex_unit_running? do
  ebin = List.first(System.argv()) || "_build/prod/lib/precompiled/ebin"

  case MixFreeCheck.run(ebin) do
    {:ok, roots} ->
      IO.puts(
        "mix-free: #{length(roots)} modules reachable from the device layer, no Mix or Hex calls"
      )

    {:error, lines} ->
      Enum.each(lines, &IO.puts(:stderr, &1))
      System.halt(1)
  end
end
