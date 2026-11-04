# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.SourceScan do
  @moduledoc false
  # What a dependency's own sources read at compile time that no build
  # records: Mix.target() (module level in lib/, anywhere in mix.exs) and
  # module-level env reads (System.get_env/fetch_env/fetch_env!,
  # :os.getenv) in lib/. Function bodies run at runtime and are skipped;
  # macro bodies are walked (code outside their quote runs when the caller
  # compiles); quoted code runs in its caller and is skipped. The sources
  # are the ones deps.get already fetched, keyed by the lock's checksum.
  #
  # The sources are parsed with every atom, identifier and alias encoded as
  # {:ep_atom, name}: a dependency's source never creates an atom here.
  # Sources that do not parse, or that are over 2 MB a file or 20 MB a dep,
  # are not scannable, and their dep is a miss.
  #
  # Best effort; still not seen, and left to a tracer on the portal side:
  # - env reads in mix.exs (dropped on purpose: many packages read CC, MAKE
  #   and the like there for their native build, and a rule on them would
  #   refuse every build of those);
  # - module-body Application.get_env and other config reads;
  # - calls through `import System` / `import Mix`, or an alias of System
  #   or Mix (`alias System, as: S`), or apply/3;
  # - sources outside lib/ (custom elixirc_paths) and Erlang sources;
  # - unquote fragments inside a module-level quote, and code a macro from
  #   another package injects.

  @type t :: %{target: boolean(), env: [String.t()]} | {:unscannable, String.t()}

  @skipped_defs ~w(def defp defguard defguardp defdelegate defn defnp)
  @env_funs ~w(get_env fetch_env fetch_env!)
  @checksum ~r/\A[0-9a-fA-F]{16,128}\z/
  @max_file_bytes 2 * 1024 * 1024
  @max_dep_bytes 20 * 1024 * 1024
  @deadline "run deadline passed"

  @doc false
  # Cached under `<home>/scan/v1/<checksum>.term`. A checksum that is not
  # plain hex never becomes a file name: that dep is scanned every time.
  # Only a regular file is read back; anything else there is ignored and
  # the dep scanned. A scan the run deadline cut short is not cached.
  @spec cached(Path.t() | nil, Path.t(), String.t(), integer() | nil) :: t()
  def cached(home, dep_dir, checksum, deadline_at \\ nil) do
    path =
      if is_binary(home) and is_binary(checksum) and checksum =~ @checksum,
        do: Path.join([home, "scan", "v1", checksum <> ".term"])

    case path && read(path) do
      nil ->
        result = scan(dep_dir, deadline_at)

        if path && result != {:unscannable, @deadline},
          do: _ = ElixirPrecompiled.FileUtil.write_atomic(path, :erlang.term_to_binary(result))

        result

      hit ->
        hit
    end
  end

  defp read(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bin} <- File.read(path) do
      valid(:erlang.binary_to_term(bin, [:safe]))
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp valid(%{target: t, env: e} = hit) when is_boolean(t) and is_list(e) do
    if Enum.all?(e, &is_binary/1), do: hit
  end

  defp valid({:unscannable, why} = hit) when is_binary(why), do: hit
  defp valid(_), do: nil

  @doc false
  @spec scan(Path.t(), integer() | nil) :: t()
  def scan(dep_dir, deadline_at \\ nil) do
    files =
      [{Path.join(dep_dir, "mix.exs"), :anywhere}] ++
        for f <- Path.wildcard(Path.join([dep_dir, "lib", "**", "*.ex"])), do: {f, :module}

    files
    |> Enum.reduce_while({[], [], 0}, fn {path, mode}, {lib, mix, total} ->
      with :ok <- in_time(deadline_at),
           {:ok, src, size} <- source(path, dep_dir, total),
           {:ok, found} <- reads(src, path, dep_dir, mode) do
        if mode == :module,
          do: {:cont, {found ++ lib, mix, total + size}},
          else: {:cont, {lib, found ++ mix, total + size}}
      else
        :absent -> {:cont, {lib, mix, total}}
        {:unscannable, _} = no -> {:halt, no}
      end
    end)
    |> summarize()
  end

  defp summarize({:unscannable, _} = no), do: no

  defp summarize({lib, mix, _total}) do
    %{
      target: :target in lib or :target in mix,
      env: lib |> Enum.flat_map(&env_name/1) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp env_name({:env, name}), do: [name]
  defp env_name(_), do: []

  defp in_time(at) when is_integer(at) do
    if System.monotonic_time(:millisecond) < at, do: :ok, else: {:unscannable, @deadline}
  end

  defp in_time(_), do: :ok

  defp source(path, dep_dir, total) do
    rel = Path.relative_to(path, dep_dir)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_file_bytes ->
        {:unscannable, "#{rel} is over 2 MB"}

      {:ok, %File.Stat{type: :regular, size: size}} when total + size > @max_dep_bytes ->
        {:unscannable, "sources over 20 MB"}

      {:ok, %File.Stat{type: :regular}} ->
        read_source(path, rel)

      {:ok, %File.Stat{}} ->
        {:unscannable, "#{rel} is not a regular file"}

      {:error, :enoent} ->
        :absent

      {:error, why} ->
        {:unscannable, "#{rel}: #{:file.format_error(why)}"}
    end
  end

  # The size again from the bytes read: the file may have grown since.
  defp read_source(path, rel) do
    case File.read(path) do
      {:ok, src} when byte_size(src) <= @max_file_bytes -> {:ok, src, byte_size(src)}
      {:ok, _} -> {:unscannable, "#{rel} is over 2 MB"}
      {:error, why} -> {:unscannable, "#{rel}: #{:file.format_error(why)}"}
    end
  end

  defp reads(src, path, dep_dir, mode) do
    case Code.string_to_quoted(src,
           emit_warnings: false,
           static_atoms_encoder: fn name, _meta -> {:ok, {:ep_atom, name}} end
         ) do
      {:ok, ast} -> {:ok, walk(ast, [], mode)}
      _ -> {:unscannable, "#{Path.relative_to(path, dep_dir)} does not parse"}
    end
  rescue
    _ -> {:unscannable, "#{Path.relative_to(path, dep_dir)} does not parse"}
  end

  defp walk({{:ep_atom, def}, _, _}, acc, :module) when def in @skipped_defs, do: acc
  defp walk({{:ep_atom, "quote"}, _, _}, acc, _mode), do: acc

  defp walk({{:., _, [{:__aliases__, _, mod}, {:ep_atom, fun}]}, _, args} = node, acc, mode)
       when is_list(args) do
    case {alias_name(mod), fun, args} do
      {"Mix", "target", _} -> [:target | acc]
      {"System", f, []} when f in @env_funs -> [{:env, "(all variables)"} | acc]
      {"System", f, [name | _]} when f in @env_funs -> [env_read(name) | walk(args, acc, mode)]
      _ -> walk_node(node, acc, mode)
    end
  end

  defp walk({{:., _, [{:ep_atom, "os"}, {:ep_atom, "getenv"}]}, _, args}, acc, mode)
       when is_list(args) do
    case args do
      [] -> [{:env, "(all variables)"} | acc]
      [name | _] -> [env_read(name) | walk(args, acc, mode)]
    end
  end

  defp walk(node, acc, mode), do: walk_node(node, acc, mode)

  defp walk_node({form, _, args}, acc, mode) when is_list(args),
    do: walk(args, walk(form, acc, mode), mode)

  defp walk_node({a, b}, acc, mode), do: walk(b, walk(a, acc, mode), mode)

  defp walk_node(list, acc, mode) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, &2, mode))

  defp walk_node(_other, acc, _mode), do: acc

  defp alias_name([{:ep_atom, "Elixir"}, {:ep_atom, name}]), do: name
  defp alias_name([{:ep_atom, name}]), do: name
  defp alias_name(_), do: nil

  defp env_read(name) do
    case literal(name) do
      "MIX_TARGET" -> :target
      name when is_binary(name) -> {:env, name}
      nil -> {:env, "(computed name)"}
    end
  end

  defp literal(name) when is_binary(name), do: name

  defp literal(name) when is_list(name) do
    if List.ascii_printable?(name), do: List.to_string(name)
  end

  defp literal({sigil, _, [{:<<>>, _, [name]}, []]})
       when sigil in [:sigil_c, :sigil_C] and is_binary(name),
       do: name

  defp literal(_), do: nil
end
