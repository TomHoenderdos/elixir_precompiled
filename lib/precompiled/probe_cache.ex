# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ProbeCache do
  @moduledoc false
  # 0.10.0: the exact module lists of a project's deps
  # (Precompiled.Check.module_provider/4), kept across runs under the home's
  # probe/v1/, one file per key, so a project that keeps probe builds
  # installed does not match every dep's build again on every `mix compile`.
  #
  # The key is everything a dep's match reads: the lock, the batch it was
  # matched against, the toolchain, the Nerves system and Mix target, each
  # dep's tree and compile env, the non-Hex and inert deps (with the beams
  # in an inert dep's ebin dirs), this machine's environment, every locked
  # app's config and the compiler options. Any change is another key, so a
  # stale list is never read; the cache's gc bounds the files. A file that
  # does not read back as lists of names is no cache. Check stores only a
  # list whose match read no probe item, which also reads the VM's code
  # path, and none built on a cut cycle.

  @version 1

  @spec key(map(), map(), map()) :: String.t()
  def key(env, config, batch) do
    lock = Map.get(env, :lock) || %{}

    term = {
      @version,
      lock |> Map.to_list() |> Enum.sort(),
      Map.get(batch, :sequence),
      Map.get(batch, :manifests_v2),
      Map.get(config, :toolchain),
      Map.get(config, :source),
      Map.get(env, :system),
      Map.get(env, :mix_target),
      Map.get(env, :present_deps),
      Map.get(env, :dep_envs),
      Map.get(env, :non_hex_deps),
      inert(env),
      Map.get(env, :config_unreadable),
      System.get_env() |> Map.to_list() |> Enum.sort(),
      for(app <- lock |> Map.keys() |> Enum.sort(), do: {app, Application.get_all_env(app)}),
      Code.compiler_options()
    }

    :sha256 |> :crypto.hash(:erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end

  # Each inert dep with its ebin dirs and the beams in them now (a list
  # resting on one is decided by what is on disk).
  defp inert(env) do
    for {app, dirs} <- Enum.sort(Map.get(env, :inert_deps) || %{}),
        do: {app, dirs, dirs |> Precompiled.Check.beams_in() |> Enum.sort()}
  end

  @spec load(map(), String.t()) :: %{optional(String.t()) => {:ok, MapSet.t()} | :unknown}
  def load(config, key) do
    with path when is_binary(path) <- path(config, key),
         {:ok, bin} <- File.read(path),
         %{} = map <- decode(bin) do
      map
    else
      _ -> %{}
    end
  end

  @spec store(map(), String.t(), String.t(), {:ok, MapSet.t()} | :unknown) :: :ok
  def store(config, key, app, modules) do
    case path(config, key) do
      path when is_binary(path) ->
        map =
          config
          |> load(key)
          |> Map.put(app, modules)
          |> Map.new(fn
            {a, {:ok, set}} -> {a, {:ok, set |> Enum.sort()}}
            {a, other} -> {a, other}
          end)

        _ = Precompiled.FileUtil.write_atomic(path, :erlang.term_to_binary(map))
        :ok

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp path(%{home: home}, key) when is_binary(home),
    do: Path.join([home, "probe", "v1", key <> ".etf"])

  defp path(_config, _key), do: nil

  # Our own file, but read as untrusted: only a map of app names to
  # `{:ok, [module name]}` or `:unknown`.
  defp decode(bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      %{} = map ->
        if Enum.all?(map, &entry?/1),
          do: Map.new(map, &to_set/1),
          else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp entry?({app, :unknown}) when is_binary(app), do: true

  defp entry?({app, {:ok, list}}) when is_binary(app) and is_list(list),
    do: Enum.all?(list, &is_binary/1)

  defp entry?(_entry), do: false

  defp to_set({app, {:ok, list}}), do: {app, {:ok, MapSet.new(list)}}
  defp to_set(pair), do: pair
end
