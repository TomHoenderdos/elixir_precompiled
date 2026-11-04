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

  Also: `deadline_seconds:` (default 300) bounds a whole run, after which
  every dependency still waiting compiles from source; `root_check_seconds:`
  (default 3600) is how often the served root is fetched; `content: [url]`
  names CDN or mirror origins the files may come from (https only);
  `cache_max_mb:` (default 4096) bounds the download cache, least recently
  used entries going first (checked at most once a day).
  `ELIXIR_PRECOMPILED_OFFLINE=1` makes no request: the last verified batch
  and the cache only, and only while that batch is still fresh.
  """

  @type t :: %{
          source: String.t(),
          except: [atom()],
          root_path: Path.t(),
          home: Path.t() | nil,
          clock_offset_seconds: integer(),
          offline: boolean(),
          deadline_ms: non_neg_integer(),
          metadata_timeout_ms: pos_integer(),
          connect_timeout_ms: pos_integer(),
          root_check_seconds: non_neg_integer(),
          cache_max_bytes: non_neg_integer(),
          content_override: [String.t()] | nil
        }

  @loopback ["127.0.0.1", "::1", "localhost"]

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
        home: home_dir(opts),
        clock_offset_seconds: clock_offset(opts[:clock_offset_seconds]),
        offline: offline?(),
        deadline_ms: non_neg(opts[:deadline_seconds], 300) * 1000,
        # Root and batch together; connects to any host.
        metadata_timeout_ms: 15_000,
        connect_timeout_ms: 5_000,
        root_check_seconds: non_neg(opts[:root_check_seconds], 3600),
        cache_max_bytes: non_neg(opts[:cache_max_mb], 4096) * 1_048_576,
        content_override: content(opts[:content])
      }
    else
      _ -> nil
    end
  end

  # Test-only clock skew for the freshness checks. Project config only, never
  # an environment variable: whoever can edit the project config can already
  # replace the root, so this adds no new way in.
  defp clock_offset(n) when is_integer(n), do: n
  defp clock_offset(_), do: 0

  @doc "True when `ELIXIR_PRECOMPILED` (or the old `NERVES_PRECOMPILED`) is `0`, `false` or `no`."
  @spec disabled?() :: boolean()
  def disabled?(), do: env_var("") in ["0", "false", "no"]

  @doc "True when `ELIXIR_PRECOMPILED_OFFLINE` is `1`, `true` or `yes`: no network, the cached batch and cache only."
  @spec offline?() :: boolean()
  def offline?(), do: env_var("_OFFLINE") in ["1", "true", "yes"]

  # A non-negative integer, else the default.
  defp non_neg(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_neg(_, default), do: default

  @doc false
  # A content origin (a CDN or mirror for files and manifests): https, or
  # http on loopback, like the source.
  @spec content_origin?(term()) :: boolean()
  def content_origin?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: "https", host: h} when is_binary(h) and h != "" -> true
      %URI{scheme: "http", host: h} when is_binary(h) -> String.downcase(h) in @loopback
      _ -> false
    end
  rescue
    _ -> false
  end

  def content_origin?(_), do: false

  defp content(nil), do: nil

  defp content(list) when is_list(list) do
    {good, bad} = Enum.split_with(list, &content_origin?/1)

    if bad != [] do
      ElixirPrecompiled.Output.warning(
        "precompiled: ignoring content origins that are not https: #{inspect(bad)}"
      )
    end

    Enum.map(good, &String.trim_trailing(&1, "/"))
  end

  defp content(other) do
    ElixirPrecompiled.Output.warning(
      "precompiled: ignoring content, not a list: #{inspect(other)}"
    )

    nil
  end

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

  @doc "The cache home a run would use: `:home`, `ELIXIR_PRECOMPILED_HOME`, else the user cache dir; nil when the OS has none."
  @spec home_dir(keyword()) :: Path.t() | nil
  def home_dir(opts \\ []), do: opts[:home] || env_var("_HOME") || default_home()

  # :filename.basedir/2 raises when neither HOME nor XDG_CACHE_HOME is set
  # (distroless images, some systemd units); Check then falls back to _build.
  # It reads the home the VM started with (`init:get_argument(home)`), not
  # the environment now, so on Unix the variables are checked here as well.
  defp default_home() do
    if no_user_dirs?(),
      do: nil,
      else: to_string(:filename.basedir(:user_cache, "elixir_precompiled"))
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp no_user_dirs?() do
    match?({:unix, _}, :os.type()) and System.get_env("HOME") in [nil, ""] and
      System.get_env("XDG_CACHE_HOME") in [nil, ""]
  end

  @doc false
  # The root of trust ships in the library's priv/; a cwd-relative fallback
  # would let whatever directory the caller is in supply it. Both
  # :code.priv_dir/1 and Application.app_dir/2 key off the app's code-path
  # directory name (`elixir_precompiled` or `elixir_precompiled-<vsn>`), not
  # the .app file, which is why an archive must keep that name.
  @spec priv_dir(atom()) :: Path.t()
  def priv_dir(app \\ :elixir_precompiled) do
    case :code.priv_dir(app) do
      {:error, reason} ->
        raise ArgumentError,
              "#{app} is not on the code path (#{inspect(reason)}), " <>
                "so its root of trust (priv/precompiled/root.json) cannot be found"

      dir ->
        to_string(dir)
    end
  end

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
