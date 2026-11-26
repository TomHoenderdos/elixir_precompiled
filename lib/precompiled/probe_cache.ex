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
  # The key is a hash of everything a dep's match reads (re-review R2):
  # the whole Env the run took (the lock, each dep's tree, source, compile
  # env and build method, which carries the `system_env:`, `compile:` and
  # `manager:` a dep's declaration sets, the non-Hex and inert deps, the
  # project's paths, the target and the Nerves system), the beams in each
  # inert dep's ebin dirs, the batch matched against, the toolchain, source
  # and host the config names, this machine's environment, the config of
  # every application this VM holds config for or has loaded (not only the
  # locked ones: a build's compile_env items name any app), which of them
  # are loaded and at what version, the compiler options, and the global
  # rebar3 config's bytes (and its `.script`). Any change is another key,
  # so a stale list is never read; the cache's gc bounds the files. A file
  # that does not read back as lists of names is no cache. Check stores
  # only a list whose match read no probe item, which also reads the VM's
  # code path, none built on a cut cycle, and no unknown from a manifest it
  # could not fetch.

  @version 2

  @spec key(map(), map(), map()) :: String.t()
  def key(env, config, batch) do
    lock = Map.get(env, :lock) || %{}

    term = {
      @version,
      env |> plain() |> Map.drop([:probe]) |> Enum.sort(),
      inert(env),
      Map.get(batch, :sequence),
      Map.get(batch, :manifests_v2),
      Map.take(config, [:toolchain, :source, :native_host]),
      System.get_env() |> Map.to_list() |> Enum.sort(),
      app_config(lock),
      Code.compiler_options(),
      rebar3_global()
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp plain(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp plain(map) when is_map(map), do: map

  # Each inert dep with its ebin dirs and the beams in them now (a list
  # resting on one is decided by what is on disk).
  defp inert(env) do
    for {app, dirs} <- Enum.sort(Map.get(env, :inert_deps) || %{}),
        do: {app, dirs, dirs |> Precompiled.Check.beams_in() |> Enum.sort()}
  end

  # Every application this VM holds config for (the config files set it,
  # loaded or not) or has loaded, and the locked ones: its config, and its
  # version when it is loaded.
  defp app_config(lock) do
    apps =
      (configured_apps() ++
         Enum.map(Application.loaded_applications(), &elem(&1, 0)) ++ Map.keys(lock))
      |> Enum.uniq()
      |> Enum.sort()

    for app <- apps,
        do: {app, Application.spec(app, :vsn), app |> Application.get_all_env() |> Enum.sort()}
  end

  # The application controller's table holds one `{{:env, app, key}, value}`
  # row per configured key.
  defp configured_apps() do
    :ac_tab |> :ets.match({{:env, :"$1", :_}, :_}) |> List.flatten() |> Enum.uniq()
  rescue
    _ -> []
  end

  defp rebar3_global() do
    case Precompiled.Rebar3Config.path(&System.get_env/1) do
      path when is_binary(path) -> {File.read(path), File.read(path <> ".script")}
      nil -> nil
    end
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
