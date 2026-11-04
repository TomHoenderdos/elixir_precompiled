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

  @doc """
  The locked deps `nerves` pulls in, sorted: the client's Nerves tooling,
  which `nerves_bootstrap` compiles together with `nerves` before the
  client runs, so the client never considers them
  (`ElixirPrecompiled.Match.nerves_children/1`).

  The closure follows each Hex entry's dependency list in the lock, as the
  client does. A git or path `nerves` has no list in the lock, so its own
  children come from the `applications` and `optional_applications` of the
  `nerves.app` Mix compiled into `build_lib`; without that file it has none.
  """
  @spec nerves_children(t(), Path.t()) :: [String.t()]
  def nerves_children(lock, build_lib) do
    case lock["nerves"] do
      nil ->
        []

      entry ->
        entry
        |> children(lock, build_lib)
        |> closure(lock, MapSet.new())
        |> MapSet.delete("nerves")
        |> Enum.sort()
    end
  end

  defp closure([], _lock, seen), do: seen

  defp closure([name | rest], lock, seen) do
    if MapSet.member?(seen, name),
      do: closure(rest, lock, seen),
      else: closure(lock_children(lock[name], lock) ++ rest, lock, MapSet.put(seen, name))
  end

  defp children({:hex, _, _, _, _, _, _, _} = entry, lock, _build_lib),
    do: lock_children(entry, lock)

  defp children(_entry, lock, build_lib) do
    path = Path.join([build_lib, "nerves", "ebin", "nerves.app"])

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, :nerves, props}]} ->
        apps =
          Keyword.get(props, :applications, []) ++ Keyword.get(props, :optional_applications, [])

        for app <- apps, name = Atom.to_string(app), Map.has_key?(lock, name), do: name

      _ ->
        []
    end
  end

  defp lock_children({:hex, _, _, _, _, deps, _, _}, lock) when is_list(deps) do
    for {dep, _req, _opts} <- deps, name = Atom.to_string(dep), Map.has_key?(lock, name), do: name
  end

  defp lock_children(_entry, _lock), do: []
end
