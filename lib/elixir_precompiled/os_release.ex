# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.OsRelease do
  @moduledoc false
  # The running Nerves system, from os-release: NERVES_SYSTEM_NAME and
  # NERVES_SYSTEM_VERSION, which every official Nerves system writes into
  # /usr/lib/os-release. The first path that names a nerves_system_* with
  # a version wins; a plain Linux os-release names none. No Mix.

  @spec system([Path.t()]) :: {String.t(), String.t()} | nil
  def system(paths) do
    Enum.find_value(paths, &system_at/1)
  end

  @spec parse(String.t()) :: %{String.t() => String.t()}
  def parse(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, &parse_line/2)
  end

  defp system_at(path) do
    case File.read(path) do
      {:ok, contents} -> nerves_system(contents)
      {:error, _reason} -> nil
    end
  end

  defp nerves_system(contents) do
    kv = parse(contents)
    name = Map.get(kv, "NERVES_SYSTEM_NAME", "")
    version = Map.get(kv, "NERVES_SYSTEM_VERSION", "")

    if name != "" and version != "" and String.starts_with?(name, "nerves_system_") do
      {name, version}
    end
  end

  defp parse_line(line, acc) do
    line = String.trim(line)

    if line == "" or String.starts_with?(line, "#") do
      acc
    else
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), strip_quotes(String.trim(value)))
        _other -> acc
      end
    end
  end

  defp strip_quotes(value) do
    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
         byte_size(value) >= 2 do
      binary_part(value, 1, byte_size(value) - 2)
    else
      value
    end
  end
end
