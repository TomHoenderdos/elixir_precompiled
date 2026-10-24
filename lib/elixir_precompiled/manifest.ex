# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Manifest do
  @moduledoc false
  # Manifest documents come in two formats. Format 1 (the portal until
  # 2026-10) keys each version's entries by target; format 2 lists builds,
  # each naming its target and carrying the dependency's compile env. Only
  # format 2 reaches Match, so format 1 is translated here, with
  # dep_env "prod": every build the portal ever made compiled its package
  # the way Mix compiles dependencies, as prod.

  @spec normalize(map()) :: {:ok, map()} | {:fail, String.t()}
  def normalize(%{"format" => 2, "versions" => versions} = doc) when is_map(versions) do
    if Enum.all?(versions, fn {_, v} -> match?(%{"builds" => b} when is_list(b), v) end),
      do: {:ok, doc},
      else: {:fail, "manifest malformed"}
  end

  def normalize(%{"format" => n}) when is_integer(n) and n > 2,
    do: {:fail, "manifest format #{n} not supported"}

  def normalize(%{"versions" => versions} = doc)
      when is_map(versions) and not is_map_key(doc, "format") do
    if Enum.all?(versions, fn {_, v} -> is_map(v) and Enum.all?(v, fn {_, e} -> is_map(e) end) end) do
      {:ok,
       doc
       |> Map.put("format", 2)
       |> Map.put(
         "versions",
         Map.new(versions, fn {v, entries} -> {v, %{"builds" => builds(entries)}} end)
       )}
    else
      {:fail, "manifest malformed"}
    end
  end

  def normalize(_), do: {:fail, "manifest malformed"}

  defp builds(entries) do
    for {target, entry} <- entries do
      entry
      |> Map.put("target", target)
      |> Map.update("build", %{"dep_env" => "prod"}, &with_dep_env/1)
    end
  end

  # A build that is not a map is left for Match to call malformed.
  defp with_dep_env(build) when is_map(build), do: Map.put_new(build, "dep_env", "prod")
  defp with_dep_env(build), do: build
end
