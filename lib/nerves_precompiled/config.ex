# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.Config do
  @moduledoc """
  The client's configuration: `config :nerves_precompiled, source: url` plus
  `except: [dep, ...]` and `root: path`; `NervesPrecompiled.install/2` passes
  the same keys as options. `NERVES_PRECOMPILED=0` disables a run and
  `NERVES_PRECOMPILED_HOME` moves the cache.
  """

  @type t :: %{source: String.t(), except: [atom()], root_path: Path.t(), home: Path.t()}

  @spec load(keyword()) :: t() | nil
  def load(overrides \\ []) do
    opts = Keyword.merge(app_env(), overrides)

    with false <- System.get_env("NERVES_PRECOMPILED") in ["0", "false", "no"],
         source when is_binary(source) <- opts[:source],
         :ok <- transport_ok(source) do
      %{
        source: String.trim_trailing(source, "/"),
        except: except(opts[:except]),
        root_path: opts[:root] || Path.join(priv_dir(), "precompiled/root.json"),
        home:
          opts[:home] || System.get_env("NERVES_PRECOMPILED_HOME") ||
            Path.expand("~/.nerves/precompiled")
      }
    else
      _ -> nil
    end
  end

  # `config :nerves_precompiled, source: ...` is this library's key; the
  # `config :nerves, :precompiled, ...` form from nerves PR #1220 still works.
  defp app_env() do
    case Application.get_all_env(:nerves_precompiled) do
      [] -> Application.get_env(:nerves, :precompiled, [])
      env -> env
    end
  end

  defp priv_dir() do
    case :code.priv_dir(:nerves_precompiled) do
      {:error, _} -> "priv"
      dir -> to_string(dir)
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
        NervesPrecompiled.Output.warning(
          "precompiled: source must be https (http only on loopback), " <>
            "disabled: #{inspect(source)}"
        )

        :error
    end
  end

  defp except(list) when is_list(list) do
    {good, bad} = Enum.split_with(list, &(is_atom(&1) or is_binary(&1)))

    if bad != [] do
      NervesPrecompiled.Output.warning(
        "precompiled: ignoring except entries that are not dependency names: #{inspect(bad)}"
      )
    end

    Enum.map(good, &to_atom/1)
  end

  defp except(nil), do: []

  defp except(other) do
    NervesPrecompiled.Output.warning(
      "precompiled: ignoring except, not a list: #{inspect(other)}"
    )

    []
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)
end
