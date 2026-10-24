# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Config do
  @moduledoc """
  The client's configuration: `config :elixir_precompiled, source: url` plus
  `except: [dep, ...]` and `root: path`; `ElixirPrecompiled.install/2` passes
  the same keys as options. `ELIXIR_PRECOMPILED=0` disables a run and
  `ELIXIR_PRECOMPILED_HOME` moves the cache.
  """

  @type t :: %{source: String.t(), except: [atom()], root_path: Path.t(), home: Path.t()}

  @spec load(keyword()) :: t() | nil
  def load(overrides \\ []) do
    opts = Keyword.merge(app_env(), overrides)

    with false <- disabled?(),
         source when is_binary(source) <- opts[:source],
         :ok <- transport_ok(source) do
      %{
        source: String.trim_trailing(source, "/"),
        except: except(opts[:except]),
        root_path: opts[:root] || Path.join(priv_dir(), "precompiled/root.json"),
        home: opts[:home] || env_var("_HOME") || default_home()
      }
    else
      _ -> nil
    end
  end

  @doc "True when `ELIXIR_PRECOMPILED` (or the old `NERVES_PRECOMPILED`) is `0`, `false` or `no`."
  @spec disabled?() :: boolean()
  def disabled?(), do: env_var("") in ["0", "false", "no"]

  @doc "True when `ELIXIR_PRECOMPILED_DEBUG` (or the old `NERVES_PRECOMPILED_DEBUG`) is `1`."
  @spec debug?() :: boolean()
  def debug?(), do: env_var("_DEBUG") == "1"

  # The library's own key first; the two names it had before (nerves PR
  # #1220 and the nerves_precompiled extraction) for one release.
  defp app_env() do
    case Application.get_all_env(:elixir_precompiled) do
      [] ->
        case Application.get_all_env(:nerves_precompiled) do
          [] -> Application.get_env(:nerves, :precompiled, [])
          env -> env
        end

      env ->
        env
    end
  end

  # ELIXIR_PRECOMPILED* wins; the NERVES_PRECOMPILED* names are read when
  # the new one is unset, for one release.
  defp env_var(suffix) do
    System.get_env("ELIXIR_PRECOMPILED" <> suffix) ||
      System.get_env("NERVES_PRECOMPILED" <> suffix)
  end

  defp default_home(), do: to_string(:filename.basedir(:user_cache, "elixir_precompiled"))

  @doc false
  # The root of trust ships in the library's priv/; a cwd-relative fallback
  # would let whatever directory the caller is in supply it. :code.priv_dir/1
  # keys off the app's .app file name, which an archive built with a
  # non-standard output name (`mix archive.build -o /tmp/x.ez`) does not
  # carry, so fall back to the application directory before giving up.
  @spec priv_dir(atom()) :: Path.t()
  def priv_dir(app \\ :elixir_precompiled) do
    case :code.priv_dir(app) do
      {:error, reason} ->
        if Application.spec(app) do
          Application.app_dir(app, "priv")
        else
          raise ArgumentError,
                "#{app} is not on the code path (#{inspect(reason)}), " <>
                  "so its root of trust (priv/precompiled/root.json) cannot be found"
        end

      dir ->
        to_string(dir)
    end
  end

  @loopback ["127.0.0.1", "::1", "localhost"]

  # Signatures make the content tamper-proof, but plain http still leaks
  # which dependencies a project uses and lets a network attacker withhold
  # updates; allow it only for a source on this machine.
  defp transport_ok(source) do
    case URI.parse(source) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        :ok

      %URI{scheme: "http", host: host} when host in @loopback ->
        :ok

      _ ->
        ElixirPrecompiled.Output.warning(
          "precompiled: source must be https (http only on loopback), " <>
            "disabled: #{inspect(source)}"
        )

        :error
    end
  end

  defp except(list) when is_list(list) do
    {good, bad} = Enum.split_with(list, &(is_atom(&1) or is_binary(&1)))

    if bad != [] do
      ElixirPrecompiled.Output.warning(
        "precompiled: ignoring except entries that are not dependency names: #{inspect(bad)}"
      )
    end

    Enum.map(good, &to_atom/1)
  end

  defp except(nil), do: []

  defp except(other) do
    ElixirPrecompiled.Output.warning(
      "precompiled: ignoring except, not a list: #{inspect(other)}"
    )

    []
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)
end
