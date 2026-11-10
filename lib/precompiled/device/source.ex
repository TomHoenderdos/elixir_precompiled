# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Source do
  @moduledoc false
  # Where a device install reads from, and how it gets the signed batch,
  # the manifests and the .app files it plans with.
  #
  # The source is the call's :source, else the :device config's, else the
  # official API: nothing else is ever guessed. A call may name only a
  # file:// bundle (Precompiled.install/2 refuses any other per-call
  # source); a network source is the firmware's config or the default.
  # An https source (or http on loopback) is a network source. A file:// source is a bundle on local
  # storage: it is read from the disk only (Fetch's file:// path), its
  # symlinks resolved once here, and the content origins its batch names
  # are never asked, so a bundle install opens no connection at all.
  #
  # A bundle with an offline.json is checked under the root's offline role
  # (Trust.verify_offline/3): no clock, the bundle's own root.json adopted
  # first when it chains (a firmware that shipped a root without the
  # offline role learns it there), and the root's expiry ignored on that
  # path only. Its sequence lives on its own floor and never reaches the
  # batch state. A bundle without one is its batch.json, bounded by the
  # batch's own expiry. Every manifest is fetched by the sha the verified
  # batch (or offline document) names, and a name it does not list is a
  # miss. No Mix, no Hex.

  alias Precompiled.Check
  alias Precompiled.Config
  alias Precompiled.Device.Store
  alias Precompiled.Fetch
  alias Precompiled.Match
  alias Precompiled.Trust

  @default_dir "/data/precompiled"
  @max_offline_bytes 8 * 1_048_576
  @max_app_bytes 1_048_576

  @doc false
  @spec official() :: String.t()
  def official(), do: Config.official()

  @doc false
  @spec default_dir() :: String.t()
  def default_dir(), do: @default_dir

  # The keys `config :precompiled, :device` may set (the "On a device"
  # guide lists them). Any other key there is ignored: the test seams (:env,
  # :clock_synchronized?) and :home in particular are never read from it.
  @device_keys [
    :enabled,
    :allow,
    :source,
    :content,
    :root,
    :cacerts_path,
    :deadline_seconds,
    :dir,
    :max_bytes,
    :max_closure,
    :start,
    :closure,
    :quiet
  ]

  @doc false
  # The firmware's :device config, only the keys it may set.
  @spec device_config() :: keyword()
  def device_config() do
    case Application.get_env(:precompiled, :device, []) do
      kw when is_list(kw) -> if Keyword.keyword?(kw), do: Keyword.take(kw, @device_keys), else: []
      _ -> []
    end
  end

  @doc false
  # The config map Trust and Fetch take. `opts` are the call's options; the
  # :device application config fills what they leave out.
  @spec config(keyword()) :: {:ok, map()} | {:error, term()}
  def config(opts) do
    opts = Keyword.merge(device_config(), opts)
    dir = Path.expand(opts[:dir] || @default_dir)

    with {:ok, source, bundle?} <- source(opts[:source] || Config.official()),
         {:ok, content} <- content(opts[:content]),
         {:ok, deadline_s} <- deadline(opts[:deadline_seconds]),
         :ok <- cacerts_path(opts[:cacerts_path]) do
      {:ok,
       Check.with_deadline(%{
         source: source,
         root_path: opts[:root] || Path.join(Config.priv_dir(), "precompiled/root.json"),
         home: opts[:home] || Path.join(dir, ".trust"),
         dir: dir,
         state_key: "device",
         cache: false,
         offline: false,
         bundle: bundle?,
         # A bundle's root.json is not the network source's: reading it
         # never counts as the online root check (Trust.update_root/4).
         root_check_stamp: not bundle?,
         clock_offset_seconds: 0,
         deadline_ms: deadline_s * 1000,
         metadata_timeout_ms: 15_000,
         connect_timeout_ms: 5_000,
         root_check_seconds: 3600,
         content: [],
         by_sha: false,
         content_override: content,
         cacerts_path: opts[:cacerts_path]
       })}
    end
  end

  defp source("file://" <> path = source) do
    trimmed = String.trim_trailing(path, "/")

    if trimmed != "" and String.valid?(path) and not String.contains?(path, <<0>>) and
         Path.type(trimmed) == :absolute,
       do: {:ok, "file://" <> Store.realpath(Path.expand(trimmed)), true},
       else: {:error, {:bad_source, source}}
  end

  defp source(source) when is_binary(source) do
    if Config.content_origin?(source),
      do: {:ok, String.trim_trailing(source, "/"), false},
      else: {:error, {:bad_source, source}}
  end

  defp source(source), do: {:error, {:bad_source, source}}

  defp content(nil), do: {:ok, nil}

  defp content(list) when is_list(list) do
    if Enum.all?(list, &Config.content_origin?/1),
      do: {:ok, Enum.map(list, &String.trim_trailing(&1, "/"))},
      else: {:error, {:bad_option, :content}}
  end

  defp content(_), do: {:error, {:bad_option, :content}}

  defp cacerts_path(nil), do: :ok
  defp cacerts_path(path) when is_binary(path) and path != "", do: :ok
  defp cacerts_path(_), do: {:error, {:bad_option, :cacerts_path}}

  defp deadline(nil), do: {:ok, 300}
  defp deadline(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp deadline(_), do: {:error, {:bad_option, :deadline_seconds}}

  ## The batch

  @doc false
  # The verified batch for this config: a bundle's offline.json when it
  # has one, else the source's batch.json (Check.fetch_batch/1).
  @spec batch(map()) :: {:ok, Trust.batch()} | {:error, {:batch, String.t()}}
  def batch(%{bundle: true} = config) do
    case Fetch.get_body(config.source <> "/offline.json", max_bytes: @max_offline_bytes) do
      {:ok, body} -> offline_batch(config, body)
      {:error, "not found: " <> _} -> online_batch(config)
      {:error, why} -> {:error, {:batch, why}}
    end
  end

  def batch(config), do: online_batch(config)

  defp online_batch(config) do
    case Check.fetch_batch(config) do
      {:ok, batch} -> {:ok, batch}
      {:error, why} -> {:error, {:batch, why}}
    end
  end

  defp offline_batch(config, body) do
    fetch = &Fetch.get_body(&1, max_bytes: @max_offline_bytes)

    with {:ok, root} <- Trust.load_root(config, offline: true),
         {:ok, root} <- Trust.update_root(config, root, fetch, offline: true),
         {:ok, batch} <- Trust.verify_offline(config, root, body) do
      {:ok, batch}
    else
      {:error, why} -> {:error, {:batch, why}}
    end
  end

  @doc false
  # The config the rest of the call uses: a network source may take its
  # files from the batch's content origins (or the call's own); a bundle
  # never does.
  @spec with_batch(map(), Trust.batch()) :: map()
  def with_batch(%{bundle: true} = config, _batch), do: %{config | content: [], by_sha: false}

  def with_batch(config, batch) do
    %{
      config
      | content: config.content_override || batch.content || [],
        by_sha: is_list(batch.content)
    }
  end

  ## Manifests

  @doc false
  # Plan.build/3's :manifest: the document the batch names, by its sha.
  @spec manifest_fun(map(), Trust.batch()) ::
          (String.t() ->
             {:ok, map(), %{sha: String.t(), path: String.t()}}
             | {:miss, String.t()}
             | {:fail, String.t()})
  def manifest_fun(config, batch) do
    fn name ->
      case manifest_ref(batch, name) do
        {nil, _} -> {:miss, not_listed(batch)}
        {sha, path} -> manifest(config, name, sha, path)
      end
    end
  end

  defp not_listed(%{offline: true}), do: "not in the offline document"
  defp not_listed(_), do: "not in batch"

  defp manifest(config, name, sha, path) do
    case Fetch.manifest(config, name, sha, path) do
      {:ok, manifest} -> {:ok, manifest, %{sha: sha, path: path}}
      {:miss, why} -> {:miss, why}
      {:fail, why} -> {:fail, why}
      {:unreachable, why} -> {:fail, why}
    end
  end

  defp manifest_ref(%{manifests_v2: v2} = batch, name) when is_map(v2) do
    case v2[name] do
      nil -> {(batch.manifests || %{})[name], "manifests"}
      sha -> {sha, "v2/manifests"}
    end
  end

  defp manifest_ref(batch, name), do: {(batch.manifests || %{})[name], "manifests"}

  ## .app files

  @doc false
  # Device.Rules' :app_spec: the build's ebin/<app>.app, checked against
  # the build's own sha256 and size and parsed as a term. A cache entry of
  # the same build is read first, and used only when its bytes check out;
  # otherwise the file is fetched like any other (never kept).
  #
  # opts[:memo], an ets table the caller owns for one call, makes each
  # .app fetched at most once and bounds how many the call fetches at all
  # (opts[:budget]): a manifest with many candidate builds cannot turn
  # planning into an unbounded number of downloads.
  @spec app_spec_fun(map(), keyword()) :: (map() -> {:ok, keyword()} | {:fail, String.t()})
  def app_spec_fun(config, opts \\ []) do
    memo = opts[:memo]
    budget = Keyword.get(opts, :budget, 100)
    # The store's entries, listed once for the whole call (the caller's,
    # or read here once), never once per candidate build.
    entries = Keyword.get_lazy(opts, :entries, fn -> Store.list(config.dir) end)

    fn build ->
      with {:ok, entry, app} <- app_entry(build) do
        memoized(memo, budget, entry["sha256"], fn ->
          app_spec(config, entries, build, entry, app)
        end)
      end
    end
  end

  defp app_entry(%{"ebin" => ebin}) when is_list(ebin) do
    apps =
      for %{"path" => "ebin/" <> name} = e <- ebin,
          String.ends_with?(name, ".app"),
          not String.contains?(name, "/"),
          do: {e, String.trim_trailing(name, ".app")}

    case apps do
      [{%{"sha256" => sha, "size" => size} = e, app}]
      when is_binary(sha) and is_integer(size) and size >= 0 and size <= @max_app_bytes ->
        {:ok, e, app}

      _ ->
        {:fail, "malformed entry"}
    end
  end

  defp app_entry(_), do: {:fail, "malformed entry"}

  defp memoized(nil, _budget, _sha, fun), do: fun.()

  defp memoized(memo, budget, sha, fun) do
    case :ets.lookup(memo, {:app, sha}) do
      [{_, result}] -> result
      [] -> counted(memo, budget, sha, fun)
    end
  end

  defp counted(memo, budget, sha, fun) do
    if :ets.update_counter(memo, :app_fetches, 1, {:app_fetches, 0}) > budget do
      {:fail, "too many builds to check (more than #{budget} .app files)"}
    else
      result = fun.()
      :ets.insert(memo, {{:app, sha}, result})
      result
    end
  end

  defp app_spec(config, entries, build, entry, app) do
    with {:ok, bytes} <- app_bytes(config, entries, build, entry) do
      parse_app(bytes, app)
    end
  end

  defp app_bytes(config, entries, build, entry) do
    case cached_app(entries, build, entry) do
      {:ok, bytes} -> {:ok, bytes}
      :miss -> download(config, entry)
    end
  end

  # An entry of this exact build (by its provenance) whose .app has the
  # signed bytes. The provenance only points; the hash decides.
  defp cached_app(entries, build, entry) do
    hash = Match.files_hash(build)

    Enum.find_value(entries, :miss, fn
      %{provenance: %{"files_sha256" => ^hash}, path: path} ->
        read_checked(Path.join(path, entry["path"]), entry)

      _ ->
        nil
    end)
  end

  defp read_checked(path, entry) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size == entry["size"],
         {:ok, bytes} <- File.read(path),
         :ok <- check(bytes, entry) do
      {:ok, bytes}
    else
      _ -> nil
    end
  end

  defp download(config, entry) do
    origins = config.content ++ [config.source]
    opts = [max_bytes: entry["size"]] ++ Fetch.content_opts(config)

    Enum.reduce_while(origins, {:fail, "file not available (#{entry["path"]})"}, fn origin, _ ->
      with {:ok, bytes} <- Fetch.get_body("#{origin}/files/#{entry["sha256"]}", opts),
           :ok <- check(bytes, entry) do
        {:halt, {:ok, bytes}}
      else
        {:fail, why} -> {:cont, {:fail, "#{why} (#{entry["path"]})"}}
        {:error, why} -> {:cont, {:fail, "file not available: #{why} (#{entry["path"]})"}}
      end
    end)
  end

  defp check(bytes, %{"sha256" => sha, "size" => size}) do
    cond do
      byte_size(bytes) != size -> {:fail, "size mismatch"}
      sha256(bytes) != String.downcase(sha) -> {:fail, "sha256 mismatch"}
      true -> :ok
    end
  end

  @doc false
  # The .app term of `app`, from bytes already checked: never consulted
  # from disk. The one parser of a build's .app: planning, staging and the
  # loader all read it here, so they agree on what is valid (a :modules
  # list of atoms included, refused before any download).
  @spec parse_app(binary(), String.t()) :: {:ok, keyword()} | {:fail, String.t()}
  def parse_app(bytes, app) do
    with chars when is_list(chars) <- :unicode.characters_to_list(bytes),
         {:ok, tokens, _} <- :erl_scan.string(chars),
         {:ok, {:application, name, props}} when is_atom(name) and is_list(props) <-
           :erl_parse.parse_term(tokens),
         true <- Atom.to_string(name) == app and Keyword.keyword?(props),
         mods when is_list(mods) <- props[:modules],
         true <- Enum.all?(mods, &is_atom/1) do
      {:ok, props}
    else
      _ -> {:fail, "malformed ebin/#{app}.app"}
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
