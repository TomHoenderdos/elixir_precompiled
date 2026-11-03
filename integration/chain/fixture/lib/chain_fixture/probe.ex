# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainFixture.Probe do
  @moduledoc """
  The on-device half of the chain test, run over ssh as
  `ChainFixture.Probe.run([:jason, ...])`.

  Prints exactly one block

      -----BEGIN CHAIN PROBE-----
      {"apps": ..., "modules": ..., "smoke": ..., "files": ..., "firmware_uuid": ..., "nerves_system": ...}
      -----END CHAIN PROBE-----

  in a single write, so the laptop can find it among an IEx banner and log
  lines. Nothing here raises: every check that fails is reported as a
  string starting with `"error: "`.

  The JSON is encoded with Elixir's own `JSON` and the probe calls the test
  subjects only through `apply/3` on a variable, so it depends on none of
  them: a broken precompiled dependency shows up in the report instead of
  breaking the probe.
  """

  @begin "-----BEGIN CHAIN PROBE-----"
  @finish "-----END CHAIN PROBE-----"

  @expected_file Path.expand("../../expected.exs", __DIR__)
  @external_resource @expected_file
  @hits @expected_file |> Code.eval_file() |> elem(0) |> Map.fetch!(:hits)

  @os_release_paths ["/usr/lib/os-release", "/etc/os-release"]

  @doc "Probes the fixture's expected hits (`expected.exs`)."
  @spec run() :: :ok
  def run(), do: run(@hits)

  @doc "Probes `apps` (atoms or strings) and prints the delimited JSON block."
  @spec run([atom() | String.t()]) :: :ok
  def run(apps) when is_list(apps) do
    json = apps |> Enum.map(&to_app/1) |> collect() |> JSON.encode!()
    IO.write([@begin, "\n", json, "\n", @finish, "\n"])
    :ok
  end

  @doc false
  @spec collect([atom()]) :: map()
  def collect(apps) do
    %{
      "apps" => Map.new(apps, &{Atom.to_string(&1), start(&1)}),
      "modules" => modules(apps),
      "smoke" => %{
        "exqlite" => guard(&smoke_exqlite/0),
        "argon2" => guard(&smoke_argon2/0),
        "gpio" => guard(&smoke_gpio/0)
      },
      "files" => Map.new(apps, &{Atom.to_string(&1), files(&1)}),
      "firmware_uuid" => firmware_uuid(),
      "nerves_system" => nerves_system()
    }
  end

  defp to_app(app) when is_atom(app), do: app
  defp to_app(app) when is_binary(app), do: String.to_atom(app)

  ## Apps and modules

  defp start(app) do
    guard(fn ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> "ok"
        {:error, reason} -> "error: " <> inspect(reason)
      end
    end)
  end

  defp modules(apps) do
    results =
      for app <- apps,
          mod <- app_modules(app),
          do: {mod, Code.ensure_loaded(mod)}

    failed =
      for {mod, result} <- results, not match?({:module, _}, result) do
        "#{inspect(mod)}: #{inspect(result)}"
      end

    %{"loaded" => length(results) - length(failed), "failed" => failed}
  end

  defp app_modules(app) do
    _ = Application.load(app)
    Application.spec(app, :modules) || []
  end

  ## Smoke calls, one per NIF

  defp smoke_exqlite() do
    sqlite = Exqlite.Sqlite3
    {:ok, conn} = call(sqlite, :open, [":memory:"])

    try do
      {:ok, stmt} = call(sqlite, :prepare, [conn, "select 1"])
      result = call(sqlite, :step, [conn, stmt])
      :ok = call(sqlite, :release, [conn, stmt])
      if result == {:row, [1]}, do: "ok", else: "error: select 1 gave " <> inspect(result)
    after
      call(sqlite, :close, [conn])
    end
  end

  defp smoke_argon2() do
    argon2 = Argon2
    # Small cost parameters: this proves the NIF runs, not the hash strength.
    hash = call(argon2, :hash_pwd_salt, ["chain probe", [t_cost: 1, m_cost: 8]])

    cond do
      not call(argon2, :verify_pass, ["chain probe", hash]) ->
        "error: verify_pass rejected its own hash"

      call(argon2, :verify_pass, ["wrong", hash]) ->
        "error: verify_pass accepted a wrong password"

      true ->
        "ok"
    end
  end

  defp smoke_gpio() do
    case call(Circuits.GPIO, :enumerate, []) do
      lines when is_list(lines) -> "ok"
      other -> "error: enumerate gave " <> inspect(other)
    end
  end

  # The module is a variable, so the compiler neither inlines nor checks the
  # call: the NIF deps are target-only and absent on host.
  defp call(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      throw({:not_available, mod, fun, length(args)})
    end
  end

  defp guard(fun) do
    fun.()
  rescue
    e -> "error: " <> Exception.format_banner(:error, e, __STACKTRACE__)
  catch
    {:not_available, mod, fun, arity} -> "error: #{inspect(mod)}.#{fun}/#{arity} not available"
    kind, reason -> "error: " <> Exception.format_banner(kind, reason, __STACKTRACE__)
  end

  ## Installed files

  defp files(app) do
    case :code.lib_dir(app) do
      {:error, _reason} ->
        []

      dir ->
        dir = List.to_string(dir)

        for sub <- ["ebin", "priv"],
            path <- walk(Path.join(dir, sub)),
            do: %{"path" => Path.relative_to(path, dir), "sha256" => sha256(path)}
    end
    |> Enum.sort_by(& &1["path"])
  end

  # Follows symlinks (on host, priv is a link into deps/), but not deeper
  # than a sane limit.
  defp walk(path, depth \\ 0) do
    cond do
      depth > 16 ->
        []

      File.dir?(path) ->
        case File.ls(path) do
          {:ok, names} -> Enum.flat_map(names, &walk(Path.join(path, &1), depth + 1))
          {:error, _reason} -> []
        end

      File.regular?(path) ->
        [path]

      true ->
        []
    end
  end

  defp sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      {:error, reason} -> "error: " <> inspect(reason)
    end
  end

  ## Firmware and system

  defp firmware_uuid() do
    case Nerves.Runtime.KV.get_active("nerves_fw_uuid") do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _other -> nil
    end
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  # The running Nerves system, as nerves_system_br writes it into os-release.
  defp nerves_system() do
    Enum.find_value(@os_release_paths, fn path ->
      with {:ok, contents} <- File.read(path),
           kv = parse_os_release(contents),
           "nerves_system_" <> _ = name <- Map.get(kv, "NERVES_SYSTEM_NAME"),
           version when is_binary(version) and version != "" <-
             Map.get(kv, "NERVES_SYSTEM_VERSION") do
        "#{name} #{version}"
      else
        _ -> nil
      end
    end)
  end

  defp parse_os_release(contents) do
    for line <- String.split(contents, "\n"),
        [key, value] <- [String.split(String.trim(line), "=", parts: 2)],
        into: %{},
        do: {key, value |> String.trim() |> String.trim("\"")}
  end
end
