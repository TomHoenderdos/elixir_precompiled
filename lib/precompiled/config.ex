# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Config do
  @moduledoc """
  The client's configuration. The source defaults to the official API,
  `https://compatibility.nerves-project.org/api/precompiled`, checked
  against the root this library ships; `config :precompiled, source: url`
  and `root: path` replace them, and `content: [url]` adds mirrors, in the
  project's config only: no option, call or environment variable can,
  since a source or mirror learns which dependencies a project has and a
  root decides whose builds it runs.
  `except: [dep, ...]` skips dependencies; `Precompiled.Host.install/2`
  takes `:except` and `:home` as options.

  Environment variables: `PRECOMPILED=0` disables a run;
  `PRECOMPILED_HOME` moves the cache; `PRECOMPILED_OFFLINE=1`
  is offline mode (below); `PRECOMPILED_CACERTS_PATH` (else
  `HEX_CACERTS_PATH`) names a CA bundle that replaces the OS store;
  `PRECOMPILED_DEBUG=1` prints why each dependency was not a
  candidate.

  Also: `deadline_seconds:` (default 300) bounds a whole run, after which
  every dependency still waiting compiles from source; `root_check_seconds:`
  (default 3600) is how often the served root is fetched; `content: [url]`
  names CDN or mirror origins the files may come from (https only);
  `cache_max_mb:` (default 4096) bounds the download cache, least recently
  used entries going first (checked at most once a day).
  `PRECOMPILED_OFFLINE=1` makes no request: the last verified batch
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
  @official "https://compatibility.nerves-project.org/api/precompiled"

  @doc "The official API, the source when the project's config names none."
  @spec official() :: String.t()
  def official(), do: @official

  @doc """
  The run's config, or nil when it is off (`PRECOMPILED=0`) or the
  configured source is not https. `overrides` may hold `:except` and
  `:home` only: `:source`, `:root` and `:content` come from the project's
  config.
  """
  @spec load(keyword()) :: t() | nil
  def load(overrides \\ []) do
    config_only!(overrides)
    opts = Keyword.merge(app_env(), overrides)

    with false <- disabled?(),
         source = opts[:source] || @official,
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

  @doc false
  # A source or a content origin learns which dependencies a project has,
  # and a root decides whose builds it runs: all are code in the project's
  # config, never an option a pasted snippet can carry. Refused loudly,
  # not ignored.
  @spec config_only!(keyword()) :: :ok
  def config_only!(opts) do
    case Enum.find([:source, :root, :content], &Keyword.has_key?(opts, &1)) do
      nil ->
        :ok

      key ->
        raise ArgumentError,
              "precompiled: #{inspect(key)} is not an option; source, root and content " <>
                "are set in the project's config only " <>
                "(config :precompiled, source: ..., root: ..., content: [...]), " <>
                "see the Trust guide"
    end
  end

  # Test-only clock skew for the freshness checks. Project config only, never
  # an environment variable: whoever can edit the project config can already
  # replace the root, so this adds no new way in.
  defp clock_offset(n) when is_integer(n), do: n
  defp clock_offset(_), do: 0

  @doc "True when `PRECOMPILED=0`, `PRECOMPILED=false` or `PRECOMPILED=no` (the old `NERVES_PRECOMPILED` works the same)."
  @spec disabled?() :: boolean()
  def disabled?(), do: env_var("") in ["0", "false", "no"]

  @doc "True when `PRECOMPILED_OFFLINE` is `1`, `true` or `yes`: no network, the cached batch and cache only."
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
      Precompiled.Output.warning(
        "precompiled: ignoring content origins that are not https: #{inspect(bad)}"
      )
    end

    Enum.map(good, &String.trim_trailing(&1, "/"))
  end

  defp content(other) do
    Precompiled.Output.warning("precompiled: ignoring content, not a list: #{inspect(other)}")

    nil
  end

  @doc "True when `PRECOMPILED_DEBUG` (or the old `NERVES_PRECOMPILED_DEBUG`) is `1`."
  @spec debug?() :: boolean()
  def debug?(), do: env_var("_DEBUG") == "1"

  # The library's own key first; the two names it had before (nerves PR
  # #1220 and the nerves_precompiled extraction) for one release.
  defp app_env() do
    case Application.get_all_env(:precompiled) do
      [] ->
        case Application.get_all_env(:nerves_precompiled) do
          [] -> Application.get_env(:nerves, :precompiled, [])
          env -> env
        end

      env ->
        env
    end
  end

  # PRECOMPILED* wins; the NERVES_PRECOMPILED* names are read when
  # the new one is unset, for one release.
  defp env_var(suffix) do
    System.get_env("PRECOMPILED" <> suffix) ||
      System.get_env("NERVES_PRECOMPILED" <> suffix)
  end

  @doc "The cache home a run would use: `:home`, `PRECOMPILED_HOME`, else the user cache dir; nil when the OS has none."
  @spec home_dir(keyword()) :: Path.t() | nil
  def home_dir(opts \\ []), do: opts[:home] || env_var("_HOME") || default_home()

  @doc false
  # The home a run in this project starts from, with the precedence load/1
  # uses: `config :precompiled, home:` (or an old config key), then
  # `PRECOMPILED_HOME`, then the user cache dir.
  @spec configured_home() :: Path.t() | nil
  def configured_home(), do: home_dir(app_env())

  @doc false
  # The home a run actually uses: `home` when it takes writes, else the
  # fallback under the build lib (none at all, read-only, a pre-seeded CI
  # cache). Shared by the run (Check.with_home/2) and the Mix tasks, so
  # `precompiled.status` and `precompiled.clean --cache` name the same dir
  # a run writes. Probing creates the dir, as a run does.
  @spec run_home(Path.t() | nil, Path.t()) :: {:ok, Path.t()} | {:fallback, Path.t()}
  def run_home(home, build_lib) do
    if is_binary(home) and Precompiled.FileUtil.writable_dir?(home),
      do: {:ok, home},
      else: {:fallback, fallback_home(build_lib)}
  end

  @doc false
  @spec fallback_home(Path.t()) :: Path.t()
  def fallback_home(build_lib), do: Path.join([build_lib, ".precompiled", "home"])

  # :filename.basedir/2 raises when neither HOME nor XDG_CACHE_HOME is set
  # (distroless images, some systemd units); Check then falls back to _build.
  # It reads the home the VM started with (`init:get_argument(home)`), not
  # the environment now, so on Unix the variables are checked here as well.
  defp default_home() do
    if no_user_dirs?(),
      do: nil,
      else: to_string(:filename.basedir(:user_cache, "precompiled"))
  rescue
    # Catches everything: no usable home is the _build fallback, never a crash.
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
  # directory name (`precompiled` or `precompiled-<vsn>`), not
  # the .app file, which is why an archive must keep that name.
  @spec priv_dir(atom()) :: Path.t()
  def priv_dir(app \\ :precompiled) do
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
        Precompiled.Output.warning(
          "precompiled: source must be https (http only on loopback), " <>
            "disabled: #{inspect(source)}"
        )

        :error
    end
  end

  defp except(list) when is_list(list) do
    {good, bad} = Enum.split_with(list, &(is_atom(&1) or is_binary(&1)))

    if bad != [] do
      Precompiled.Output.warning(
        "precompiled: ignoring except entries that are not dependency names: #{inspect(bad)}"
      )
    end

    Enum.map(good, &to_atom/1)
  end

  defp except(nil), do: []

  defp except(other) do
    Precompiled.Output.warning("precompiled: ignoring except, not a list: #{inspect(other)}")

    []
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)
end
