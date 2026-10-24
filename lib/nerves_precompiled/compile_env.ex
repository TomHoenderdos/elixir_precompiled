# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.CompileEnv do
  @moduledoc false
  # The project's compile-time config, as a build entry's compile_env list
  # names it: application, then a key path. The running application env is
  # the authority in both contexts (loadconfig on a host, the firmware's
  # config on a device).

  @spec lookup(String.t(), [String.t()]) :: {:ok, term()} | :error
  def lookup(app, [first | rest]) do
    with {:ok, app_atom} <- safe_existing_atom(app),
         {:ok, first_atom} <- safe_existing_atom(first),
         {:ok, value} <- Application.fetch_env(app_atom, first_atom) do
      Enum.reduce_while(rest, {:ok, value}, &step/2)
    end
  end

  defp step(key, {:ok, v}) do
    case safe_existing_atom(key) do
      {:ok, k} -> lookup_in(v, k)
      :error -> {:halt, :error}
    end
  end

  defp lookup_in(kw, k) when is_list(kw) do
    if Keyword.keyword?(kw) and Keyword.has_key?(kw, k),
      do: {:cont, {:ok, kw[k]}},
      else: {:halt, :error}
  end

  defp lookup_in(%{} = m, k) do
    if Map.has_key?(m, k), do: {:cont, {:ok, m[k]}}, else: {:halt, :error}
  end

  defp lookup_in(_, _), do: {:halt, :error}

  # A manifest-derived app or key that was never an atom in this VM cannot be
  # in the project's config; don't grow the atom table from untrusted input.
  defp safe_existing_atom(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end
end
