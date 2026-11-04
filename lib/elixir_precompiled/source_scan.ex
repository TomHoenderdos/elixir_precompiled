# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.SourceScan do
  @moduledoc false
  # What a dependency's own sources read at compile time that no build
  # records: Mix.target() (module level in lib/, anywhere in mix.exs) and
  # module-level System.get_env in lib/. Function bodies run at runtime and
  # are skipped; quoted code runs in its caller and is skipped. The sources
  # are the ones deps.get already fetched, keyed by the lock's checksum.
  #
  # Env reads in mix.exs are left out on purpose: many packages read CC,
  # MAKE and the like there for their native build, and a rule on them
  # would refuse every build of those. Module-body Application.get_env and
  # env reads in mix.exs are left to a tracer on the portal side.

  @type t :: %{target: boolean(), env: [String.t()]}

  @defs [
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp,
    :defdelegate,
    :defn,
    :defnp
  ]
  @env_funs [:get_env, :fetch_env, :fetch_env!]
  @checksum ~r/\A[0-9a-fA-F]{16,128}\z/

  @doc false
  # Cached under `<home>/scan/<checksum>.term`. A checksum that is not
  # plain hex never becomes a file name: that dep is scanned every time.
  # Only a regular file is read back; anything else there is ignored and
  # the dep scanned.
  @spec cached(Path.t() | nil, Path.t(), String.t()) :: t()
  def cached(home, dep_dir, checksum) do
    path =
      if is_binary(home) and is_binary(checksum) and checksum =~ @checksum,
        do: Path.join([home, "scan", checksum <> ".term"])

    case path && read(path) do
      %{target: t, env: e} = hit when is_boolean(t) and is_list(e) ->
        hit

      _ ->
        result = scan(dep_dir)

        if path,
          do: _ = ElixirPrecompiled.FileUtil.write_atomic(path, :erlang.term_to_binary(result))

        result
    end
  end

  defp read(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bin} <- File.read(path) do
      :erlang.binary_to_term(bin, [:safe])
    end
  rescue
    _ -> nil
  end

  @doc false
  @spec scan(Path.t()) :: t()
  def scan(dep_dir) do
    lib = Path.wildcard(Path.join([dep_dir, "lib", "**", "*.ex"]))
    module_level = Enum.flat_map(lib, &reads(&1, :module))
    mix_exs = reads(Path.join(dep_dir, "mix.exs"), :anywhere)

    %{
      target: :target in module_level or :target in mix_exs,
      env: module_level |> Enum.flat_map(&env_name/1) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp env_name({:env, name}), do: [name]
  defp env_name(_), do: []

  defp reads(path, mode) do
    case File.read(path) do
      {:ok, src} ->
        case Code.string_to_quoted(src, emit_warnings: false) do
          {:ok, ast} -> walk(ast, [], mode)
          _ -> [:target, {:env, "(unparsable source)"}]
        end

      _ ->
        []
    end
  end

  defp walk({def, _, _}, acc, :module) when def in @defs, do: acc
  defp walk({:quote, _, _}, acc, _mode), do: acc

  defp walk({{:., _, [{:__aliases__, _, [:Mix]}, :target]}, _, _}, acc, _mode),
    do: [:target | acc]

  defp walk({{:., _, [{:__aliases__, _, [:System]}, fun]}, _, [name | _]}, acc, _mode)
       when fun in @env_funs do
    cond do
      name == "MIX_TARGET" -> [:target | acc]
      is_binary(name) -> [{:env, name} | acc]
      true -> [{:env, "(computed name)"} | acc]
    end
  end

  defp walk({form, _, args}, acc, mode) when is_list(args),
    do: walk(args, walk(form, acc, mode), mode)

  defp walk({a, b}, acc, mode), do: walk(b, walk(a, acc, mode), mode)
  defp walk(list, acc, mode) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, &2, mode))
  defp walk(_other, acc, _mode), do: acc
end
