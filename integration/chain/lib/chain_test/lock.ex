# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Lock do
  @moduledoc """
  The fixture's `mix.lock`, read as Mix reads it (it is Elixir source that
  quotes its keys), with string keys so names from a manifest or a report
  never become atoms; and the lookups the steps share.
  """

  @type t :: %{String.t() => tuple()}

  @doc "Reads `path`. A missing, unparsable or non-map lock is `{:error, reason}`; never raises."
  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(text, file: path, emit_warnings: false),
         {lock, _binding} when is_map(lock) <- Code.eval_quoted(quoted, [], file: path) do
      {:ok, Map.new(lock, fn {k, v} -> {to_string(k), v} end)}
    else
      {:error, reason} when is_atom(reason) -> {:error, to_string(:file.format_error(reason))}
      {:error, _parse_error} -> {:error, "not valid Elixir"}
      {_other, _binding} -> {:error, "not a map"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "The locked Hex version of `name`, or `nil` (not locked, or not a Hex dep)."
  @spec hex_version(t(), String.t()) :: String.t() | nil
  def hex_version(lock, name) do
    case lock[name] do
      {:hex, _, vsn, _, _, _, _, _} -> vsn
      _ -> nil
    end
  end

  @doc "`{\"nerves_system_<target>\", version}` when the lock pins that system, else `nil`."
  @spec system(t(), String.t()) :: {String.t(), String.t()} | nil
  def system(lock, target) do
    name = "nerves_system_#{target}"

    case hex_version(lock, name) do
      nil -> nil
      vsn -> {name, vsn}
    end
  end

  @doc "The commit a git dep is locked at, or `nil`."
  @spec git_ref(t(), String.t()) :: String.t() | nil
  def git_ref(lock, name) do
    case lock[name] do
      {:git, _url, sha, _opts} -> sha
      _ -> nil
    end
  end
end
