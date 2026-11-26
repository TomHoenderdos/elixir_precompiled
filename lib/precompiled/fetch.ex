# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Fetch do
  @moduledoc """
  Bytes in, verified files in the project's `_build` out. Manifests are checked against
  the hash the batch names; files against the hash the manifest names,
  before anything reaches the build directory. Install is atomic per
  dependency: staged under `_build/<t>/lib/.precompiled/<dep>.<os pid>-<n>`
  (one dir per install), renamed into place with Mix's "already compiled"
  marker.
  """

  alias Precompiled.{FileUtil, ForeignPriv, ForeignPrivFiles, Manifest, Relocate}

  @typep reason :: Precompiled.Reason.t()

  # 8 MiB: root, batch and any other document
  # httpc's request errors that mean the connection failed or broke.
  @transport_errors [
    :socket_closed_remotely,
    :session_remotely_closed,
    :timeout,
    :connect_timeout,
    :econnrefused,
    :econnreset,
    :etimedout,
    :ehostunreach,
    :enetunreach,
    :nxdomain,
    :closed
  ]
  @max_body_bytes 8_388_608
  # 64 MiB: manifests of packages with many versions and systems run past 8 MiB
  @max_manifest_bytes 67_108_864
  # 4 MiB: the systems table, every release of every Nerves system
  @max_systems_bytes 4_194_304
  @ok_modes [0o644, 0o755, 0o100644, 0o100755]
  @provenance_file "precompiled.json"
  @file_concurrency 8
  @day 86_400

  @doc """
  GET `url`'s body, capped at `:max_bytes`. A `file://` URL is read from
  the local disk instead: an absolute, canonical path with no symlink on
  it (else `{:error, "unsafe file URL"}`), and a missing file is
  `{:error, "not found: <path>"}`.
  """
  @spec get_body(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def get_body(url, opts \\ []) do
    case raw_get(url, opts) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  defp raw_get("file://" <> path, opts),
    do: file_get(path, Keyword.get(opts, :max_bytes, @max_body_bytes))

  defp raw_get(url, opts) do
    http_opts =
      [max_bytes: Keyword.get(opts, :max_bytes, @max_body_bytes), same_origin: true] ++
        Keyword.take(opts, [
          :deadline_at,
          :connect_timeout_ms,
          :deadline_ms,
          :allowed_origins,
          :offline,
          :cacerts_path
        ])

    guarded(opts, url, fn -> Precompiled.HTTP.get(url, http_opts) end)
  end

  # A `file://` URL: a bundle on local storage (a USB stick, an SD card,
  # /data), read from the disk with no :inets, :ssl or network at all. The
  # path must be absolute and already canonical (Path.expand/1 leaves it as
  # it is: no "..", ".", empty component or trailing slash), and nothing on
  # it may be a symlink, from "/" down to the file itself: a bundle is read
  # where it is, never wherever a link someone left on the stick points.
  # A caller whose storage sits under a symlink (Nerves' /data) resolves it
  # once and passes the real path. The read is capped at `max` bytes, like
  # a response body.
  defp file_get(path, max) do
    with :ok <- canonical_file_path(path),
         {:ok, stat} <- unlinked(path) do
      read_file(path, stat, max)
    end
  end

  defp canonical_file_path(path) do
    if String.valid?(path) and not String.contains?(path, <<0>>) and
         Path.type(path) == :absolute and Path.expand(path) == path and
         ".." not in Path.split(path),
       do: :ok,
       else: {:error, "unsafe file URL"}
  end

  # lstat of every prefix of `path`, from the top: a symlink anywhere is
  # refused, a missing component is "not found".
  defp unlinked(path) do
    [root | parts] = Path.split(path)

    [root | Enum.scan(parts, root, &Path.join(&2, &1))]
    |> Enum.reduce_while(nil, fn prefix, _ ->
      case File.lstat(prefix) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, "unsafe file URL"}}
        {:ok, stat} -> {:cont, {:ok, stat}}
        {:error, _} -> {:halt, {:error, "not found: #{path}"}}
      end
    end)
  end

  defp read_file(_path, %File.Stat{type: :regular, size: size}, max) when size > max,
    do: {:error, {:too_large, max}}

  defp read_file(path, %File.Stat{type: :regular} = stat, max) do
    case read_regular(path, stat, max) do
      {:ok, bytes} -> {:ok, bytes}
      # Unreadable, or grown past the cap since the lstat.
      :absent -> {:error, "cannot read #{path}"}
      {:fail, _} -> {:error, "#{path} changed while being read"}
    end
  end

  defp read_file(path, %File.Stat{}, _max), do: {:error, "not a regular file: #{path}"}

  @doc false
  # The origins that failed to connect so far in one run (Check makes one
  # table per run and passes it as :dead_origins). A content origin (a CDN)
  # that failed to connect is not asked again that run: the source is
  # still tried after it, so nothing is lost. The source is skipped only
  # once the batch itself came from the cache because the source was
  # unreachable (source_unreachable/1); until then a connect failure to it
  # fails only that one fetch. A skipped request fails at once with the
  # error the origin first failed with, so the line a user reads is the
  # same either way. Only connection failures count; an origin that
  # answered (a 5xx, a 404, wrong bytes) is asked again.
  @spec new_dead_origins() :: :ets.tid()
  def new_dead_origins(), do: :ets.new(__MODULE__, [:set, :public])

  @doc false
  # The batch came from the cache because the source could not be reached:
  # the source, if it failed to connect this run, is skipped from now on.
  @spec source_unreachable(map()) :: :ok
  def source_unreachable(config) do
    case dead_origins(config) do
      {table, source} when source != nil -> _ = :ets.update_element(table, source, {3, :dead})
      _ -> :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp dead_origins(config) do
    case Map.get(config, :dead_origins) do
      nil -> nil
      table -> {table, origin_key(Map.get(config, :source, ""))}
    end
  end

  defp guarded(opts, url, request) do
    {table, source} = Keyword.get(opts, :dead_origins) || {nil, nil}
    key = origin_key(url)

    case dead(table, key) do
      {:error, _} = error ->
        error

      nil ->
        result = request.()

        if connect_failure?(result),
          do: record(table, key, result, if(key == source, do: :seen, else: :dead))

        result
    end
  end

  defp origin_key(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) -> {scheme, host, port}
      _ -> nil
    end
  end

  # A table from a run that is over (deleted) is no table.
  defp dead(nil, _), do: nil
  defp dead(_, nil), do: nil

  defp dead(table, key) do
    case :ets.lookup(table, key) do
      [{^key, error, :dead}] -> error
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp record(nil, _, _, _), do: :ok
  defp record(_, nil, _, _), do: :ok

  defp record(table, key, error, state) do
    :ets.insert_new(table, {key, error, state})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @connect_errors [:econnrefused, :ehostunreach, :enetunreach, :nxdomain, :connect_timeout]

  defp connect_failure?({:error, {:failed_connect, _}}), do: true
  defp connect_failure?({:error, reason}) when reason in @connect_errors, do: true
  defp connect_failure?(_), do: false

  @doc """
  GET a metadata document (the batch), sending `etag` as `If-None-Match`
  when there is one: the body and its ETag, or `:not_modified`. A failure
  to reach the source (transport error, timeout, the run deadline, a 5xx,
  offline) is `{:error, {:unreachable, reason}}`; anything the source
  actually answered (a 4xx, an oversized or refused redirect) is
  `{:error, reason}`.

  A `file://` URL (a bundle on local storage) is read from the disk, never
  over HTTP, and never answers `:not_modified`: see `get_body/2`.
  """
  @spec get_conditional(map(), String.t(), String.t() | nil) ::
          {:ok, binary(), String.t() | nil}
          | :not_modified
          | {:error, String.t() | {:unreachable, String.t()}}
  def get_conditional(_config, "file://" <> path, _etag) do
    case file_get(path, @max_body_bytes) do
      {:ok, body} -> {:ok, body, nil}
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  def get_conditional(config, url, etag) do
    headers = if is_binary(etag), do: [{"if-none-match", etag}], else: []

    opts =
      [headers: headers, max_bytes: @max_body_bytes, same_origin: true] ++ metadata_opts(config)

    http_opts = Keyword.delete(opts, :dead_origins)

    case guarded(opts, url, fn -> Precompiled.HTTP.request(url, http_opts) end) do
      {:ok, body, etag} -> {:ok, body, etag}
      :not_modified -> :not_modified
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  defp classify(reason) do
    why = describe_error(reason)
    if unreachable?(reason), do: {:unreachable, why}, else: why
  end

  @doc false
  # Unreachable: the source could not be asked (a transport error, a 5xx,
  # the deadline, offline), so a still-valid cached batch may stand in.
  # httpc's transport errors are named one by one; a shape not listed here
  # is treated as a refusal, which never falls back.
  @spec unreachable?(term()) :: boolean()
  def unreachable?("Status 5" <> _), do: true
  def unreachable?("offline"), do: true
  def unreachable?("run deadline passed"), do: true
  def unreachable?("no response within " <> _), do: true
  def unreachable?("no data for " <> _), do: true
  def unreachable?(reason) when is_binary(reason), do: false
  def unreachable?({:failed_connect, _}), do: true
  def unreachable?({:send_failed, _}), do: true
  def unreachable?(reason) when reason in @transport_errors, do: true
  def unreachable?(_), do: false

  @doc false
  # Root and batch: a short connect timeout, and both together inside
  # :metadata_timeout_ms (Check narrows :deadline_at for them).
  @spec metadata_opts(map()) :: keyword()
  def metadata_opts(config), do: common_opts(config) ++ deadline_opt(config)

  @doc false
  # Manifests and files: the run deadline, and redirects to the content
  # origins the batch (or the project) allows.
  @spec content_opts(map()) :: keyword()
  def content_opts(config),
    do:
      [allowed_origins: Map.get(config, :content) || []] ++
        common_opts(config) ++ deadline_opt(config)

  defp common_opts(config) do
    [
      connect_timeout_ms: Map.get(config, :connect_timeout_ms, 5_000),
      offline: Map.get(config, :offline, false),
      dead_origins: dead_origins(config)
    ] ++ cacerts_opt(config)
  end

  defp cacerts_opt(config) do
    case Map.get(config, :cacerts_path) do
      path when is_binary(path) -> [cacerts_path: path]
      _ -> []
    end
  end

  defp deadline_opt(config) do
    case Map.get(config, :deadline_at) do
      at when is_integer(at) -> [deadline_at: at]
      _ -> []
    end
  end

  # The reason a fetch failed, as the line a user reads next to the dependency.
  defp describe_error({:too_large, max_bytes}), do: "response larger than #{max_bytes} bytes"
  defp describe_error(:cross_origin_redirect), do: "redirect to another host refused"
  defp describe_error(:too_many_redirects), do: "too many redirects"
  defp describe_error(reason) when is_binary(reason), do: reason

  defp describe_error({:failed_connect, info}) when is_list(info) do
    case List.keyfind(info, :inet, 0) do
      {:inet, _, why} when is_atom(why) -> "cannot connect (#{why})"
      _ -> "cannot connect"
    end
  end

  defp describe_error(reason), do: inspect(reason)

  @doc """
  The manifest the batch names by `expected_sha`, under `path`: "manifests"
  for a format-1 document, "v2/manifests" for a format-2 one. Either comes
  back as format 2 (see `Precompiled.Manifest`).

  Looked up, in order: the cache (`<home>/manifests/<sha>.json`, re-hashed
  on every read); where by-sha paths exist, `<origin>/<path>/by-sha/<sha>.json`
  for each content origin and then the source; and last the source's
  `<path>/<name>.json`, whose answer decides the result. Whatever bytes come
  back are used only if they hash to `expected_sha`.

  `{:unreachable, why}`: the manifest is not cached and the network could
  not deliver it (offline, a transport error, a 5xx, the run deadline), as
  opposed to a source that answered and refused.
  """
  @spec manifest(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:miss, String.t()} | {:fail, String.t()} | {:unreachable, String.t()}
  def manifest(config, name, expected_sha, path \\ "manifests") do
    with true <- sha256?(expected_sha) || {:fail, "manifest hash malformed"},
         {:ok, _dir} <- cache_dir(config, "manifests") do
      case cached_manifest(config, expected_sha) do
        {:ok, bytes} -> decode_manifest(bytes)
        :absent -> uncached_manifest(config, name, expected_sha, path)
        {:fail, _} = fail -> fail
      end
    end
  end

  defp uncached_manifest(config, name, sha, path) do
    if Map.get(config, :offline, false),
      do: {:unreachable, "offline: manifest not cached"},
      else: fetch_manifest(config, name, sha, path)
  end

  defp fetch_manifest(config, name, sha, path) do
    by_sha = for origin <- by_sha_origins(config), do: "#{origin}/#{path}/by-sha/#{sha}.json"

    Enum.find_value(by_sha, &try_manifest(config, &1, sha)) ||
      named_manifest(config, name, sha, path)
  end

  # By-sha paths exist where the signed batch advertises content origins:
  # the portal signs "content" into batches once it serves them. Only Check
  # sets :by_sha, from the batch; a :content list alone (the project's own
  # origins) does not say the source has them.
  defp by_sha_origins(config) do
    content = Map.get(config, :content)

    if is_list(content) and Map.get(config, :by_sha, false),
      do: content ++ [config.source],
      else: []
  end

  # Any failure here (unreachable, 404, wrong bytes) only moves on.
  defp try_manifest(config, url, sha) do
    with {:ok, bytes} <- get_body(url, [max_bytes: @max_manifest_bytes] ++ content_opts(config)),
         ^sha <- sha256(bytes) do
      _ = cache_manifest(config, sha, bytes)
      decode_manifest(bytes)
    else
      _ -> nil
    end
  end

  defp named_manifest(config, name, sha, path) do
    case raw_get(
           "#{config.source}/#{path}/#{name}.json",
           [max_bytes: @max_manifest_bytes] ++ content_opts(config)
         ) do
      {:ok, bytes} ->
        if sha256(bytes) == sha do
          _ = cache_manifest(config, sha, bytes)
          decode_manifest(bytes)
        else
          {:fail, "manifest hash differs from batch"}
        end

      {:error, reason} ->
        case classify(reason) do
          "Status 404 Not Found" -> {:miss, "no manifest"}
          {:unreachable, why} -> {:unreachable, "manifest unavailable: #{why}"}
          why -> {:miss, "manifest unavailable: #{why}"}
        end
    end
  end

  @doc """
  The systems table the batch names by `sha`: the `"systems"` map of a
  `{"format": 1, "systems": {...}}` document, which says what each release
  of a Nerves system ships (its OTP, toolchain and libraries).

  Looked up, in order: the cache (`<home>/systems/<sha>.json`, re-hashed on
  every read), then `<origin>/systems/by-sha/<sha>.json` for each content
  origin and last the source. Bytes are used only when they hash to `sha`,
  are at most 4 MiB and decode to that shape; only then are they cached.
  JSON `null` (a release's `"libs"` or `"otp"`) comes back as `nil`.

  The table only widens matching, so nothing about it is an error: a
  malformed sha, an offline run with nothing cached, a refused cache dir,
  a network failure or bytes that do not verify are all `:none`.
  """
  @spec systems(map(), String.t()) :: {:ok, map()} | :none
  def systems(config, sha) do
    with true <- sha256?(sha),
         {:ok, _dir} <- cache_dir(config, "systems"),
         {:ok, table} <- cached_systems(config, sha) do
      {:ok, table}
    else
      :absent -> uncached_systems(config, sha)
      _ -> :none
    end
  end

  # A cache entry that is not a regular file is left as it is and the
  # table not used, as read_cached/2 refuses it for a manifest.
  defp cached_systems(config, sha) do
    path = systems_cache_path(config, sha)

    with true <- cache?(config),
         {:ok, bytes} <- read_cached(path, @max_systems_bytes),
         ^sha <- sha256(bytes),
         {:ok, table} <- decode_systems(bytes) do
      used(path, {:ok, table})
    else
      {:fail, _} -> :none
      _ -> :absent
    end
  end

  defp uncached_systems(config, sha) do
    if Map.get(config, :offline, false) do
      :none
    else
      content = Map.get(config, :content)
      origins = if(is_list(content), do: content, else: []) ++ [config.source]

      Enum.find_value(
        origins,
        :none,
        &try_systems(config, "#{&1}/systems/by-sha/#{sha}.json", sha)
      )
    end
  end

  # Any failure here (unreachable, 404, too large, wrong bytes) only moves on.
  defp try_systems(config, url, sha) do
    with {:ok, bytes} <- get_body(url, [max_bytes: @max_systems_bytes] ++ content_opts(config)),
         ^sha <- sha256(bytes),
         {:ok, table} <- decode_systems(bytes) do
      if cache?(config), do: _ = FileUtil.write_atomic(systems_cache_path(config, sha), bytes)
      {:ok, table}
    else
      _ -> nil
    end
  end

  # JSON null decodes to nil here: a release's "libs" and "otp" may be
  # null. Anything after the document but whitespace refuses it.
  defp decode_systems(bytes) do
    case :json.decode(bytes, :ok, %{null: nil}) do
      {%{"format" => 1, "systems" => table}, :ok, rest} when is_map(table) ->
        if rest =~ ~r/\A[ \t\r\n]*\z/, do: {:ok, table}, else: :none

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  defp systems_cache_path(config, sha), do: Path.join([config.home, "systems", sha <> ".json"])

  @doc """
  0.10.0 (S10 round 5): a release index document the batch names by `sha`
  (`release_index`): a shard of read releases, `{"format": 1, "shard",
  "read": {package => [version]}}`, or a probed module's definer set,
  `{"format": 1, "module", "definers": {package => [version]}}`. Looked up
  as the systems table is: the cache (`<home>/release/<sha>.json`), then
  each content origin and the source at `release-index/by-sha/<sha>.json`;
  used only when the bytes hash to `sha`, are at most 4 MiB and decode to
  one of those shapes. Anything else is `:none`, and a declared probe item
  that needed it misses.
  """
  @spec release_doc(map(), String.t()) :: {:ok, map()} | :none
  def release_doc(config, sha) do
    with true <- sha256?(sha),
         {:ok, _dir} <- cache_dir(config, "release"),
         {:ok, doc} <- cached_release_doc(config, sha) do
      {:ok, doc}
    else
      :absent -> uncached_release_doc(config, sha)
      _ -> :none
    end
  end

  defp cached_release_doc(config, sha) do
    path = Path.join([config.home, "release", sha <> ".json"])

    with true <- cache?(config),
         {:ok, bytes} <- read_cached(path, @max_systems_bytes),
         ^sha <- sha256(bytes),
         {:ok, doc} <- decode_release_doc(bytes) do
      used(path, {:ok, doc})
    else
      {:fail, _} -> :none
      _ -> :absent
    end
  end

  defp uncached_release_doc(config, sha) do
    if Map.get(config, :offline, false) do
      :none
    else
      content = Map.get(config, :content)
      origins = if(is_list(content), do: content, else: []) ++ [config.source]

      Enum.find_value(origins, :none, fn origin ->
        url = "#{origin}/release-index/by-sha/#{sha}.json"

        with {:ok, bytes} <-
               get_body(url, [max_bytes: @max_systems_bytes] ++ content_opts(config)),
             ^sha <- sha256(bytes),
             {:ok, doc} <- decode_release_doc(bytes) do
          if cache?(config),
            do:
              _ =
                FileUtil.write_atomic(Path.join([config.home, "release", sha <> ".json"]), bytes)

          {:ok, doc}
        else
          _ -> nil
        end
      end)
    end
  end

  defp decode_release_doc(bytes) do
    case :json.decode(bytes, :ok, %{null: nil}) do
      {%{"format" => 1} = doc, :ok, rest} ->
        if rest =~ ~r/\A[ \t\r\n]*\z/ and release_doc?(doc), do: {:ok, doc}, else: :none

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  defp release_doc?(%{"read" => read}) when is_map(read), do: versions_map?(read)
  defp release_doc?(%{"definers" => definers}) when is_map(definers), do: versions_map?(definers)
  defp release_doc?(_doc), do: false

  defp versions_map?(map),
    do:
      Enum.all?(map, fn {k, v} -> is_binary(k) and is_list(v) and Enum.all?(v, &is_binary/1) end)

  defp decode_manifest(bytes), do: with({:ok, map} <- decode(bytes), do: Manifest.normalize(map))

  defp cached_manifest(config, sha) do
    if cache?(config), do: read_cached_manifest(config, sha), else: :absent
  end

  defp read_cached_manifest(config, sha) do
    path = manifest_cache_path(config, sha)

    case read_cached_entry(path, @max_manifest_bytes) do
      {:ok, bytes, mtime} ->
        if sha256(bytes) == sha, do: used(path, mtime, {:ok, bytes}), else: :absent

      other ->
        other
    end
  end

  # A verified hit marks its entry as used (mtime), so the cache gc
  # (Precompiled.Cache) evicts by last use. A home that takes no
  # writes makes it a no-op.
  defp used(path, result) do
    _ = Precompiled.FileUtil.mark_used(path)
    result
  end

  # The same, for an entry whose mtime the read already has: one marked in
  # the last day is not marked again. Setting times is the dearest call a
  # cached install makes per file, and the gc orders by day anyway.
  defp used(path, mtime, result) do
    now = System.os_time(:second)
    if mtime > now or now - mtime >= @day, do: _ = Precompiled.FileUtil.mark_used(path)
    result
  end

  # A cache write that fails costs only the next run a download.
  defp cache_manifest(config, sha, bytes) do
    if cache?(config),
      do: Precompiled.FileUtil.write_atomic(manifest_cache_path(config, sha), bytes),
      else: :ok
  end

  # `cache: false` (a device, which keeps verified files in its own store):
  # the home's files and manifests are neither read, written nor created.
  defp cache?(config), do: Map.get(config, :cache, true) != false

  defp manifest_cache_path(config, sha), do: Path.join([config.home, "manifests", sha <> ".json"])

  # A cache entry is read only when it is a regular file itself. Anything
  # else under that name (a symlink, whatever it points at, a FIFO, a
  # directory) means someone else has been writing the cache: the dep is
  # refused and the entry left as it is, never replaced through. A regular
  # file with the wrong bytes (or more than `max` of them) is `:absent`: it
  # is fetched again and replaced.
  #
  # The file is opened only after lstat says it is regular, and the open
  # handle must be that same file (inode and device). The read stops at
  # `max` + 1 bytes, whatever the file has grown to since.
  #
  # Another file under the name by the open is what every writer of this
  # cache does: write_atomic/2 renames a new file over the entry, and two
  # runs sharing a home, or two deps of one run whose builds share a file,
  # write the same entry. So the name is looked at again: a regular file
  # is read as before, anything else refused as above. Every caller
  # re-hashes the bytes, so a file that keeps changing under the name only
  # costs a download (`:absent`), never the dep.
  @cache_read_attempts 3

  defp read_cached(path, max) do
    case read_cached_entry(path, max) do
      {:ok, bytes, _mtime} -> {:ok, bytes}
      other -> other
    end
  end

  # read_cached/2, plus the read file's mtime (posix seconds).
  defp read_cached_entry(path, max), do: read_cached_entry(path, max, @cache_read_attempts)

  defp read_cached_entry(path, max, attempts) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max -> :absent
      {:ok, %File.Stat{type: :regular} = stat} -> read_entry(path, stat, max, attempts)
      {:ok, %File.Stat{}} -> {:fail, "cache refused (#{path} is not a regular file; remove it)"}
      {:error, _} -> :absent
    end
  end

  defp read_entry(path, stat, max, attempts) do
    case read_regular_entry(path, stat, max) do
      {:fail, _} when attempts > 1 -> read_cached_entry(path, max, attempts - 1)
      {:fail, _} -> :absent
      other -> other
    end
  end

  # Not closed: a regular file swapped for a FIFO between the lstat and this
  # open blocks the open until a writer comes (Erlang has neither
  # O_NONBLOCK nor O_NOFOLLOW for files). It needs someone who can already
  # write the user's own cache; a swap to a symlink or another file is
  # caught by the inode check after the open.
  defp read_regular(path, lstat, max) do
    case read_regular_entry(path, lstat, max) do
      {:ok, bytes, _mtime} -> {:ok, bytes}
      other -> other
    end
  end

  defp read_regular_entry(path, lstat, max) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          read_open(fd, path, lstat, max)
        after
          :file.close(fd)
        end

      {:error, _} ->
        :absent
    end
  end

  defp read_open(fd, path, lstat, max) do
    with {:ok, info} <- :file.read_file_info(fd, time: :posix),
         %File.Stat{type: :regular} = stat <- File.Stat.from_record(info),
         true <- {stat.inode, stat.major_device} == {lstat.inode, lstat.major_device},
         {:ok, bytes} when byte_size(bytes) <= max <- read_capped(fd, max + 1, []) do
      {:ok, bytes, stat.mtime}
    else
      {:ok, _too_long} -> :absent
      {:error, _} -> :absent
      _ -> {:fail, "cache refused (#{path} changed while being read)"}
    end
  end

  defp read_capped(fd, left, acc) when left > 0 do
    case :file.read(fd, left) do
      {:ok, data} -> read_capped(fd, left - byte_size(data), [acc | data])
      :eof -> {:ok, IO.iodata_to_binary(acc)}
      {:error, _} = error -> error
    end
  end

  defp read_capped(_fd, _left, acc), do: {:ok, IO.iodata_to_binary(acc)}

  # `files` and `manifests` under the home must be plain directories:
  # created when missing, refused when a symlink (by lstat, so a link is
  # never followed) or anything else, and never written through. A plain
  # directory in the home holds whatever is under it inside the home.
  defp cache_dir(config, name) do
    if cache?(config), do: plain_cache_dir(config, name), else: {:ok, nil}
  end

  defp plain_cache_dir(config, name) do
    dir = Path.join(config.home, name)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, dir}

      {:error, :enoent} ->
        # A home that cannot take the dir only costs downloads: reads miss,
        # writes fail quietly.
        _ = File.mkdir_p(dir)

        if match?({:ok, %File.Stat{type: :symlink}}, File.lstat(dir)),
          do: refused(dir),
          else: {:ok, dir}

      {:ok, %File.Stat{}} ->
        refused(dir)

      # eacces and the like: nothing is there that could be followed, and
      # reads and writes under it then fail on their own, costing only a
      # download, as a home that takes no writes does.
      {:error, _} ->
        {:ok, dir}
    end
  end

  defp refused(dir), do: {:fail, "cache refused (#{dir} is not a plain directory; remove it)"}

  @doc """
  Removes the temp files (`*.tmp-*`) that runs killed mid-write left in
  the cache's `files`, `manifests` and `systems` dirs, when last modified before
  `cutoff` (Unix seconds). Another run sharing the home may be writing its
  own right now, so the cutoff is well before this run started. Only
  regular files directly in a plain cache dir are removed, and a failure
  is ignored: it costs disk, never a build.
  """
  @spec sweep_tmp(map(), integer()) :: :ok
  def sweep_tmp(config, cutoff) do
    for name <- ["files", "manifests", "systems"],
        dir = Path.join(config.home, name),
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir)),
        {:ok, entries} <- [File.ls(dir)],
        entry <- entries,
        String.contains?(entry, ".tmp-"),
        path = Path.join(dir, entry),
        match?(
          {:ok, %File.Stat{type: :regular, mtime: m}} when m < cutoff,
          File.lstat(path, time: :posix)
        ) do
      File.rm(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp decode(bytes) do
    {:ok, :json.decode(bytes)}
  rescue
    _ -> {:fail, "manifest is not JSON"}
  end

  @doc """
  Verifies and installs one dependency's build into `build_lib`.
  Everything (files, Mix's marker, provenance, the include/src links) is
  put together in staging first; replacing the old dep dir by a rename is
  the last step, so any failure leaves `_build` as it was.

  Options: `:deps_path` (required), `:provenance`, `:verify_app` (a check
  on the staged `.app`), and `:link_sources`, a test seam that replaces
  the linker (`(dep, entry, staging, dest, deps_path -> :ok)`).
  """
  @spec install(map(), atom(), map(), tuple(), Path.t(), keyword()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer(), cached: non_neg_integer()}}
          | {:fail, String.t() | reason()}
  def install(config, dep, entry, lock_entry, build_lib, opts \\ []) do
    staging = staging_path(build_lib, dep)
    dest = Path.join(build_lib, Atom.to_string(dep))
    verify_app = Keyword.get(opts, :verify_app, fn _ -> :ok end)
    link = Keyword.get(opts, :link_sources, &link_sources/5)

    try do
      # What a killed run left staged.
      for stale <- staging_dirs(build_lib, dep, :stale), do: File.rm_rf(stale)

      with {:ok, stats} <- stage_verified(config, dep, entry, staging, verify_app: verify_app),
           {:ok, relocated} <- relocate_staged(dep, entry, staging, Keyword.get(opts, :relocate)) do
        write_marker(staging, lock_entry)
        write_provenance(staging, put_relocated(Keyword.get(opts, :provenance), relocated))
        :ok = link.(dep, entry, staging, dest, Keyword.fetch!(opts, :deps_path))
        # Everything is in staging before _build changes: a failure up to
        # here leaves the old dep dir as it was.
        carry_foreign(dep, entry, staging, dest, build_lib)
        File.rm_rf!(dest)
        File.mkdir_p!(build_lib)
        File.rename!(staging, dest)
        {:ok, stats}
      else
        {:fail, _} = fail ->
          File.rm_rf!(staging)
          fail
      end
    rescue
      e ->
        # Archives carried into staging go with it: their owners recompile.
        if dep == ForeignPriv.target() do
          case ForeignPrivFiles.unshipped(staging, entry) do
            [] -> :ok
            carried -> ForeignPrivFiles.mark_owners(build_lib, carried)
          end
        end

        File.rm_rf!(staging)
        {:fail, "install failed: #{Exception.message(e)}"}
    end
  end

  # 0.9.0: a relocated entry's beams (`relocation`), rewritten in staging to
  # this project's slots (`:relocate`, Precompiled.Relocate.user_slots/2)
  # once the served files are verified, and their new hashes and sizes,
  # which the provenance records with the slots. Nothing for any other
  # entry; without slots nothing is installed.
  defp relocate_staged(dep, %{"relocation" => %{} = record} = entry, staging, %{} = slots) do
    with :ok <- Relocate.apply_staged(staging, entry, slots, dep) do
      files =
        Map.new(record["files"], fn %{"path" => path} ->
          bytes = File.read!(Path.join(staging, path))
          {path, %{"sha256" => sha256(bytes), "size" => byte_size(bytes)}}
        end)

      {:ok, Map.put(slots, "files", files)}
    end
  end

  defp relocate_staged(_dep, %{"relocation" => _}, _staging, _slots),
    do: {:fail, "relocation refused: this project's paths are not its own real paths"}

  defp relocate_staged(_dep, _entry, _staging, _slots), do: {:ok, nil}

  defp put_relocated(nil, _relocated), do: nil
  defp put_relocated(provenance, nil), do: provenance
  defp put_relocated(provenance, relocated), do: Map.put(provenance, :relocated, relocated)

  # 0.8.0: kino's archives of other deps (and of the project) its new entry
  # does not ship go along, so a replace never drops them; where they
  # cannot (a staged priv that links to the sources), their Mix-built
  # owners are marked to recompile after kino instead.
  defp carry_foreign(dep, entry, staging, dest, build_lib) do
    if dep == ForeignPriv.target() do
      case ForeignPrivFiles.carry(dest, staging, entry) do
        :ok -> :ok
        :mark_owners -> ForeignPrivFiles.mark_owners(build_lib)
      end
    end
  end

  @doc """
  Fetches `entry`'s files into `staging` and verifies them: the entry's
  paths and modes, each file's size and sha256, `opts[:verify_app]` (a
  check on the staged `.app`, `fn path -> :ok | {:fail, why} end`), and
  the `.app` owning exactly the staged beams. Nothing else: no Mix marker,
  no provenance, no links, no rename, so it serves an install outside a
  Mix project too. On a failure `staging` is removed.
  """
  @spec stage_verified(map(), atom(), map(), Path.t(), keyword()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer(), cached: non_neg_integer()}}
          | {:fail, String.t() | reason()}
  def stage_verified(config, dep, entry, staging, opts) do
    files = (entry["ebin"] || []) ++ (entry["priv"] || [])
    verify_app = Keyword.get(opts, :verify_app, fn _ -> :ok end)

    with :ok <- validate(files, dep),
         {:ok, stats} <- stage(config, files, staging),
         :ok <- verify_app.(Path.join([staging, "ebin", "#{dep}.app"])),
         :ok <- modules_ok(staging, dep) do
      {:ok, stats}
    else
      {:fail, _} = fail ->
        File.rm_rf!(staging)
        fail
    end
  rescue
    e ->
      File.rm_rf(staging)
      {:fail, "install failed: #{Exception.message(e)}"}
  end

  @doc false
  # One staging dir per install: two Mix processes (or two calls) on one
  # _build never remove or rename each other's half-written dir. Named
  # `<dep>.<os pid>-<unique>`, so this OS process's own can be found again
  # (staging_dirs/2) after a worker died.
  @spec staging_path(Path.t(), atom()) :: Path.t()
  def staging_path(build_lib, dep) do
    unique = "#{System.pid()}-#{System.unique_integer([:positive])}"
    Path.join([build_lib, ".precompiled", "#{dep}.#{unique}"])
  end

  @doc false
  # The staging dirs of `dep` this OS process made, or, with `:stale`, the
  # ones any process left over an hour ago (a killed Mix run).
  @spec staging_dirs(Path.t(), atom(), :own | :stale) :: [Path.t()]
  def staging_dirs(build_lib, dep, which) do
    dir = Path.join(build_lib, ".precompiled")
    prefix = if which == :own, do: "#{dep}.#{System.pid()}-", else: "#{dep}."
    cutoff = System.os_time(:second) - 3600

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, prefix),
            path = Path.join(dir, name),
            which == :own or old_dir?(path, cutoff),
            do: path

      {:error, _} ->
        []
    end
  end

  defp old_dir?(path, cutoff),
    do:
      match?(
        {:ok, %File.Stat{type: :directory, mtime: m}} when m < cutoff,
        File.lstat(path, time: :posix)
      )

  # Mix links deps/<dep>/include (and src for rebar deps, and priv) into
  # _build when it builds a dep; a dep installed here is never built, so
  # mirror that or a dependent's -include_lib/Record.extract fails. The
  # links are made in staging but relative to where they will live after
  # the rename (`dest`), as Mix makes them, so a moved project tree keeps
  # its links; a copy where the filesystem refuses one.
  defp link_sources(dep, entry, staging, dest, deps_path) do
    source = Path.join(deps_path, Atom.to_string(dep))
    priv = if (entry["priv"] || []) == [], do: ["priv"], else: []

    for name <- ["include", "src" | priv],
        from = Path.join(source, name),
        to = Path.join(staging, name),
        File.dir?(from) and not File.exists?(to) do
      case File.ln_s(Path.relative_to(from, dest, force: true), to) do
        :ok -> :ok
        {:error, _} -> File.cp_r!(from, to)
      end
    end

    :ok
  end

  defp validate(files, dep) do
    app = "ebin/#{dep}.app"

    cond do
      why = Enum.find_value(files, &bad_file/1) -> {:fail, why}
      why = collision(files) -> {:fail, why}
      why = foreign(files, app) -> {:fail, why}
      not Enum.any?(files, &(&1["path"] == app)) -> {:fail, "no #{app} in entry"}
      true -> :ok
    end
  end

  @doc false
  # Two entries that are one file on a case-insensitive or normalising
  # filesystem (APFS, NTFS) would overwrite each other: refused before
  # anything is written (spec P8). Runs after bad_file/1, so every path is
  # valid UTF-8.
  @spec collision([map()]) :: String.t() | nil
  def collision(files) do
    files
    |> Enum.group_by(&fold(&1["path"]))
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.min_by(fn {key, _} -> key end, fn -> nil end)
    |> case do
      nil -> nil
      {_key, group} -> "path collision: " <> Enum.map_join(group, ", ", &inspect(&1["path"]))
    end
  end

  defp fold(path) do
    path
    |> :unicode.characters_to_nfc_binary()
    |> :string.casefold()
    |> :unicode.characters_to_nfc_binary()
  end

  # ebin holds the dep's own .app, at ebin/<dep>.app, its own .appup
  # (release-upgrade data, never loaded as code), and beams directly
  # in it with an exact lower-case ".beam", nothing else: another .app (the
  # project's own, or another dep's) would sit on the code path ahead of
  # the real one (spec P3), and "X.BEAM" loads as X on a case-insensitive
  # filesystem without counting as a beam for modules_ok/2.
  defp foreign(files, app) do
    Enum.find_value(files, fn %{"path" => path} ->
      case path do
        "ebin/" <> name ->
          unless path in [app, Path.rootname(app) <> ".appup"] or
                   (String.ends_with?(name, ".beam") and not (name =~ "/")),
                 do: "foreign path: #{inspect(path)} does not belong in ebin"

        _ ->
          nil
      end
    end)
  end

  @doc false
  # The beams in ebin must be exactly the modules the .app lists: a beam
  # the app does not own could shadow another application's module through
  # code-path order.
  @spec modules_ok(Path.t(), atom()) :: :ok | {:fail, String.t()}
  def modules_ok(staging, dep) do
    ebin = Path.join(staging, "ebin")

    with {:ok, [{:application, _, props}]} when is_list(props) <-
           :file.consult(String.to_charlist(Path.join(ebin, "#{dep}.app"))),
         mods when is_list(mods) <- Keyword.get(props, :modules, []),
         true <- Enum.all?(mods, &is_atom/1) do
      listed = MapSet.new(mods, &Atom.to_string/1)

      beams =
        ebin
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(String.downcase(&1), ".beam"))
        |> MapSet.new(&binary_part(&1, 0, byte_size(&1) - 5))

      cond do
        beams == listed ->
          :ok

        extra = first(MapSet.difference(beams, listed)) ->
          {:fail, "#{extra}.beam is not a module of #{dep}"}

        true ->
          {:fail,
           "#{dep}.app lists #{first(MapSet.difference(listed, beams))}, which the build lacks"}
      end
    else
      _ -> {:fail, "staged .app unreadable"}
    end
  end

  defp first(set), do: Enum.min(set, fn -> nil end)

  # `sha256` becomes a cache file name and `size` a download cap, so both
  # are checked as strictly as the path before anything touches the disk.
  defp bad_file(%{} = f) do
    cond do
      not (safe_path?(f["path"]) and safe_mode?(f["mode"])) ->
        "unsafe path or mode (#{inspect(f["path"])})"

      not (sha256?(f["sha256"]) and is_integer(f["size"]) and f["size"] >= 0) ->
        "unsafe file entry (#{f["path"]})"

      true ->
        nil
    end
  end

  defp bad_file(other), do: "unsafe file entry (#{inspect(other)})"

  defp sha256?(sha), do: is_binary(sha) and sha =~ ~r/\A[0-9a-f]{64}\z/

  @spec safe_path?(term()) :: boolean()
  def safe_path?(path) when is_binary(path) do
    String.valid?(path) and not String.contains?(path, <<0>>) and
      not String.contains?(path, "\\") and
      (String.starts_with?(path, "ebin/") or String.starts_with?(path, "priv/")) and
      Path.type(path) == :relative and canonical?(path) and
      Path.expand(path, "/x") |> String.starts_with?("/x/")
  end

  def safe_path?(_), do: false

  # One spelling per file: no "..", "." or empty component and no trailing
  # slash, so "ebin/./a.beam" or "ebin//a.beam" can never be a second name
  # for "ebin/a.beam" that the collision check would not see.
  defp canonical?(path),
    do: path |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))

  @spec safe_mode?(term()) :: boolean()
  def safe_mode?(mode), do: mode in @ok_modes

  # Up to @file_concurrency files of one dep download at once, each bounded
  # by its declared size and the run deadline; results are taken in order,
  # so the first failing file (in manifest order) is the one reported.
  #
  # The dirs are made once, before any file; a file is written only as a
  # new one, and set to its mode only when that is not already the mode a
  # new file gets (the umask's, read from a probe file).
  defp stage(config, files, staging) do
    with {:ok, _dir} <- cache_dir(config, "files") do
      File.mkdir_p!(staging)

      for dir <- files |> Enum.map(&Path.dirname(&1["path"])) |> Enum.uniq(),
          do: File.mkdir_p!(Path.join(staging, dir))

      stage_files(config, files, staging, new_file_mode(staging))
    end
  end

  # Validated paths are all under ebin/ or priv/: the probe's name at the
  # top of staging is never one of them.
  defp new_file_mode(staging) do
    probe = Path.join(staging, ".mode-probe")
    File.write!(probe, "", [:exclusive])
    mode = Bitwise.band(File.lstat!(probe).mode, 0o777)
    File.rm!(probe)
    mode
  end

  defp stage_files(config, files, staging, new_mode) do
    files
    |> Task.async_stream(&stage_file(config, &1, staging, new_mode),
      max_concurrency: @file_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.reduce_while({:ok, %{files: 0, bytes: 0, cached: 0}}, fn
      {:ok, {:ok, f, cached?}}, {:ok, acc} ->
        {:cont,
         {:ok,
          %{
            acc
            | files: acc.files + 1,
              bytes: acc.bytes + f["size"],
              cached: acc.cached + if(cached?, do: 1, else: 0)
          }}}

      {:ok, {:fail, _} = fail}, _ ->
        {:halt, fail}

      # stage_file never raises, and the tasks are linked: a task that dies
      # anyway (killed from outside) takes this process with it unless it
      # traps exits. Only then does the stream yield {:exit, _}; it is
      # handled so even that case is one dep's FAIL, not a crash.
      {:exit, reason}, _ ->
        {:halt, {:fail, "install failed: #{inspect(reason)}"}}
    end)
  end

  # Runs in a task linked to the caller: it never raises, or the exit would
  # take the caller (and the user's build) down with it.
  defp stage_file(config, f, staging, new_mode) do
    with {:ok, bytes, cached?} <- fetch_file(config, f) do
      target = Path.join(staging, f["path"])
      mode = Bitwise.band(f["mode"], 0o777)
      File.write!(target, bytes, [:exclusive])
      if mode != new_mode, do: File.chmod!(target, mode)
      {:ok, f, cached?}
    end
  rescue
    e -> {:fail, "install failed: #{Exception.message(e)}"}
  catch
    kind, reason -> {:fail, "install failed: #{inspect({kind, reason})}"}
  end

  @doc false
  # One file of an entry, from the cache or a download, its size and sha256
  # checked: what `install/6` stages, for the archives a foreign priv build
  # places into kino (Precompiled.ForeignPrivFiles).
  @spec fetch_verified(map(), map()) :: {:ok, binary(), boolean()} | {:fail, String.t()}
  def fetch_verified(config, entry), do: fetch_file(config, entry)

  defp fetch_file(config, %{"sha256" => sha, "size" => size, "path" => path}) do
    case cached_file(config, sha, size) do
      {:ok, bytes} -> {:ok, bytes, true}
      :absent -> download_file(config, sha, size, path)
      {:fail, _} = fail -> fail
    end
  end

  # The cached copy, re-hashed on every use; a wrong size or a wrong hash
  # is no copy at all, and anything but a regular file refuses the dep.
  defp cached_file(config, sha, size) do
    if cache?(config), do: read_cached_file(config, sha, size), else: :absent
  end

  defp read_cached_file(config, sha, size) do
    path = file_cache_path(config, sha)

    case read_cached_entry(path, size) do
      {:ok, bytes, mtime} ->
        if check_bytes(bytes, sha, size) == :ok,
          do: used(path, mtime, {:ok, bytes}),
          else: :absent

      other ->
        other
    end
  end

  # Each content origin, then the source. A content origin's failure
  # (unreachable, 404, wrong bytes) only moves on to the next URL, and only
  # bytes that match the manifest's sha and size are ever kept; the last
  # failure is the one reported.
  defp download_file(config, sha, size, path) do
    if Map.get(config, :offline, false) do
      {:fail, "offline: file not cached (#{path})"}
    else
      urls =
        for(o <- Map.get(config, :content) || [], do: "#{o}/files/#{sha}") ++
          ["#{config.source}/files/#{sha}"]

      Enum.reduce_while(urls, nil, fn url, _ ->
        case download(config, url, sha, size, path) do
          {:ok, _, _} = ok -> {:halt, ok}
          fail -> {:cont, fail}
        end
      end)
    end
  end

  defp download(config, url, sha, size, path) do
    with {:ok, body} <-
           get_body(url, [max_bytes: size] ++ content_opts(config)) |> file_error(sha),
         :ok <- check_bytes(body, sha, size) |> name_path(path) do
      cache_file(config, sha, body)
      {:ok, body, false}
    end
  end

  # A cache write that fails costs only the next run a download.
  defp cache_file(config, sha, body) do
    if cache?(config),
      do: Precompiled.FileUtil.write_atomic(file_cache_path(config, sha), body),
      else: :ok
  end

  defp file_cache_path(config, sha), do: Path.join([config.home, "files", sha])

  defp file_error({:ok, _} = ok, _), do: ok

  defp file_error({:error, "response larger" <> _}, _),
    do: {:fail, "file larger than declared size"}

  defp file_error({:error, reason}, sha), do: {:fail, "file not available: #{sha} (#{reason})"}

  defp check_bytes(bytes, sha, size) do
    cond do
      byte_size(bytes) != size -> {:fail, "size mismatch"}
      sha256(bytes) != sha -> {:fail, "sha256 mismatch"}
      true -> :ok
    end
  end

  defp name_path(:ok, _), do: :ok
  defp name_path({:fail, why}, path), do: {:fail, "#{why} (#{path})"}

  defp write_marker(staging, lock_entry) do
    vsn = {System.version(), :erlang.system_info(:otp_release)}
    marker = :erlang.term_to_binary(marker_term(vsn, Hex.SCM, lock_entry))

    File.mkdir_p!(Path.join(staging, ".mix"))
    File.write!(Path.join([staging, ".mix", "compile.elixir_scm"]), marker)
    # deps.compile's mark: without it Elixir 1.17 and 1.18 count a Hex dep
    # as freshly fetched and compile it over the install. 1.19 and later
    # ignore the file.
    File.touch!(Path.join([staging, ".mix", "compile.fetch"]))
  end

  # Which signed manifest this install came from, so a later run can tell a
  # build the portal has since withdrawn (dropped from the batch) from one it
  # still vouches for.
  defp write_provenance(_staging, nil), do: :ok

  defp write_provenance(staging, provenance) do
    File.mkdir_p!(Path.join(staging, ".mix"))
    File.write!(Path.join([staging, ".mix", @provenance_file]), provenance_doc(provenance))
  end

  @doc """
  Rewrites an installed dep's provenance: a kept build that a newer
  manifest still lists. Only into a `.mix` that is a plain directory.
  """
  @spec write_provenance_file(Path.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def write_provenance_file(build_lib, dep, provenance) do
    path = provenance_path(build_lib, dep)

    # 0.9.0: a kept relocated build keeps the record of its rewrite.
    provenance =
      case {provenance[:relocated], recorded_relocation(build_lib, dep)} do
        {nil, %{} = relocated} -> Map.put(provenance, :relocated, relocated)
        _ -> provenance
      end

    doc = provenance_doc(provenance)

    cond do
      not real_dir?(Path.dirname(path)) ->
        {:error, "#{Path.dirname(path)} is not a plain directory"}

      # A kept build under an unchanged batch: nothing to write.
      File.read(path) == {:ok, doc} ->
        :ok

      true ->
        FileUtil.write_atomic(path, doc)
    end
  end

  defp provenance_doc(%{sha: sha, path: path, sequence: seq} = p) do
    %{"manifest_sha256" => sha, "manifest_path" => path, "batch_sequence" => seq}
    |> put_present("files_sha256", p[:files_sha256])
    |> put_present("source", p[:source])
    |> put_present("foreign", p[:foreign])
    |> put_present("relocated", p[:relocated])
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Whether `dep`'s build dir holds exactly `entry`'s files, judged from the
  disk alone, never from the provenance file: the entry passes the same
  checks as an install; ebin (and priv, when the entry ships one) are
  plain directories holding only regular files, exactly the entry's paths;
  each has the entry's mode and size, and its bytes hash to the entry's
  sha256; and the .app owns exactly the beams. A priv the entry does not
  ship must be absent, or Mix's symlink to deps/<dep>/priv, which is not
  followed: Mix makes and remakes that link itself from the sources
  deps.get verified, so it holds nothing an install placed. A real priv
  dir, even an empty one, is refused. Other top-level entries (`.mix`, a
  `consolidated` dir, Mix's `include` link) are not looked at: Mix
  writes them, and none of them is code the build's .app loads.
  """
  @spec installed_as?(Path.t(), atom(), map(), keyword()) :: boolean()
  def installed_as?(build_lib, dep, entry, opts \\ []) do
    foreign = if dep == ForeignPriv.target(), do: [foreign_priv: true], else: []

    case as_installed(entry, build_lib, dep, Keyword.get(opts, :relocate)) do
      {:ok, entry} ->
        installed_at?(
          Path.join(build_lib, Atom.to_string(dep)),
          dep,
          entry,
          [mix_priv_link: true] ++ foreign
        )

      :error ->
        false
    end
  end

  @doc """
  0.9.0: whether `dep`'s install of the relocated `entry` was rewritten to
  `slots`, by its provenance's record; always true for an entry that is not
  relocated. Under an unchanged manifest the disk is not re-hashed, but a
  moved project (other slots) must be installed again.
  """
  @spec relocated_for?(Path.t(), atom(), map(), map() | nil) :: boolean()
  def relocated_for?(build_lib, dep, %{"relocation" => %{}}, slots) do
    match?(
      %{"deps" => d, "build" => b} when %{"deps" => d, "build" => b} == slots,
      recorded_relocation(build_lib, dep)
    ) and is_map(slots)
  end

  def relocated_for?(_build_lib, _dep, _entry, _slots), do: true

  # A relocated entry as its install holds it: each rewritten beam's hash
  # and size the provenance recorded for `slots`, the project's own.
  defp as_installed(%{"relocation" => %{"files" => files}} = entry, build_lib, dep, slots)
       when is_map(slots) and is_list(files) do
    with true <- relocated_for?(build_lib, dep, entry, slots),
         %{"files" => %{} = recorded} <- recorded_relocation(build_lib, dep),
         paths = for(%{"path" => path} <- files, do: path),
         true <- Enum.all?(paths, &match?(%{"sha256" => _, "size" => _}, recorded[&1])) do
      ebin =
        for file <- entry["ebin"] || [] do
          case recorded[file["path"]] do
            %{"sha256" => sha, "size" => size} -> %{file | "sha256" => sha, "size" => size}
            nil -> file
          end
        end

      {:ok, %{entry | "ebin" => ebin}}
    else
      _ -> :error
    end
  end

  defp as_installed(%{"relocation" => _}, _build_lib, _dep, _slots), do: :error
  defp as_installed(entry, _build_lib, _dep, _slots), do: {:ok, entry}

  defp recorded_relocation(build_lib, dep) do
    with {:ok, bytes} <- File.read(provenance_path(build_lib, dep)),
         %{"relocated" => %{} = relocated} <- decode_provenance(bytes) do
      relocated
    else
      _ -> nil
    end
  end

  defp decode_provenance(bytes) do
    :json.decode(bytes)
  rescue
    _ -> nil
  end

  @doc """
  `installed_as?/3` for a directory named anything (`<app>-<vsn>` in a
  store, say): `dir` is the entry's own directory and `dep` the app whose
  `.app` it must hold. A `priv` the entry does not ship must be absent:
  even an empty one is refused, since `:code.priv_dir/1` points there.
  Only with `mix_priv_link: true` (a Mix project's `_build`) may it be a
  symlink to `.../<dep>/priv`, Mix's link to the dep's sources.
  """
  @spec installed_at?(Path.t(), atom(), map(), keyword()) :: boolean()
  def installed_at?(dir, dep, entry, opts \\ []) do
    files = (entry["ebin"] || []) ++ (entry["priv"] || [])

    validate(files, dep) == :ok and real_dir?(dir) and
      priv_ok?(dir, dep, entry, opts) and
      dir |> on_disk(tops(dir, entry, opts)) |> drop_unshipped(dir, entry, opts) ==
        {:ok, MapSet.new(files, & &1["path"])} and
      Enum.all?(files, &same_file?(dir, &1)) and modules_ok(dir, dep) == :ok
  rescue
    _ -> false
  end

  defp ships_priv?(entry), do: (entry["priv"] || []) != []

  # With `foreign_priv: true` (kino in a Mix project's _build), a real priv
  # the entry does not ship is walked too: it may hold only the archives of
  # other deps and of the project, which drop_unshipped/4 passes over.
  defp tops(dir, entry, opts) do
    if ships_priv?(entry) or (opts[:foreign_priv] == true and real_dir?(Path.join(dir, "priv"))),
      do: ["ebin", "priv"],
      else: ["ebin"]
  end

  # 0.8.0: kino's priv/assets holds the Kino.JS archives of other deps and
  # of the project beside its own. A `priv/assets/<d>` directory its entry
  # ships no file in is not kino's (Precompiled.ForeignPrivFiles), and is
  # not looked at; every file kino itself ships is still checked exactly.
  defp drop_unshipped({:ok, paths}, dir, entry, opts) do
    if opts[:foreign_priv] == true do
      prefixes = for d <- ForeignPrivFiles.unshipped(dir, entry), do: "priv/assets/" <> d <> "/"
      {:ok, MapSet.reject(paths, fn p -> String.starts_with?(p, prefixes) end)}
    else
      {:ok, paths}
    end
  end

  defp drop_unshipped(other, _dir, _entry, _opts), do: other

  defp priv_ok?(dir, dep, entry, opts),
    do: ships_priv?(entry) or undeclared_priv_ok?(dir, dep, opts)

  defp undeclared_priv_ok?(dir, dep, opts) do
    priv = Path.join(dir, "priv")

    case File.lstat(priv) do
      {:error, :enoent} -> true
      {:ok, %File.Stat{type: :directory}} -> opts[:foreign_priv] == true
      {:ok, %File.Stat{type: :symlink}} -> opts[:mix_priv_link] == true and mix_link?(priv, dep)
      _ -> false
    end
  end

  # Mix links _build/<env>/lib/<dep>/priv to deps/<dep>/priv.
  defp mix_link?(priv, dep) do
    case :file.read_link_all(String.to_charlist(priv)) do
      {:ok, target} ->
        Enum.take(Path.split(to_string(target)), -2) == [Atom.to_string(dep), "priv"]

      _ ->
        false
    end
  end

  # Relative paths of every regular file under `tops`, walked by lstat: a
  # symlink or any other non-regular entry anywhere is :error.
  defp on_disk(dir, tops) do
    Enum.reduce_while(tops, {:ok, MapSet.new()}, fn top, {:ok, acc} ->
      case walk(dir, top, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp walk(dir, rel, acc) do
    case File.lstat(Path.join(dir, rel)) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, MapSet.put(acc, rel)}

      {:ok, %File.Stat{type: :directory}} ->
        walk_dir(dir, rel, acc)

      _ ->
        :error
    end
  end

  defp walk_dir(dir, rel, acc) do
    case File.ls(Path.join(dir, rel)) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, acc} ->
          case walk(dir, rel <> "/" <> name, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            :error -> {:halt, :error}
          end
        end)

      {:error, _} ->
        :error
    end
  end

  defp same_file?(dir, %{"path" => path, "sha256" => sha, "size" => size, "mode" => mode}) do
    full = Path.join(dir, path)

    with {:ok, %File.Stat{type: :regular, size: ^size, mode: on_disk}} <- File.lstat(full),
         true <- same_mode?(on_disk, mode),
         {:ok, bytes} <- read_cached(full, size) do
      byte_size(bytes) == size and sha256(bytes) == sha
    else
      _ -> false
    end
  end

  # Windows has no exec bit to compare.
  defp same_mode?(on_disk, mode) do
    match?({:win32, _}, :os.type()) or Bitwise.band(on_disk, 0o777) == Bitwise.band(mode, 0o777)
  end

  defp real_dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  @doc """
  The provenance file under a dependency's build dir, written by `install/6`
  when it is given `:provenance`.
  """
  @spec provenance_path(Path.t(), atom() | String.t()) :: Path.t()
  def provenance_path(build_lib, dep),
    do: Path.join([build_lib, to_string(dep), ".mix", @provenance_file])

  @doc """
  Mix's "already compiled" marker (`Mix.Dep.ElixirSCM`) in the format the
  running Mix reads: Elixir 1.20 added the lock (format 2); 1.17 to 1.19
  read format 1 and would treat format 2 as stale and recompile the dep.
  """
  @spec marker_term({String.t(), charlist()}, module(), tuple()) :: tuple()
  def marker_term(vsn, scm, lock_entry), do: marker_term(System.version(), vsn, scm, lock_entry)

  @spec marker_term(String.t(), {String.t(), charlist()}, module(), tuple()) :: tuple()
  def marker_term(elixir_version, vsn, scm, lock_entry) do
    if Version.match?(elixir_version, ">= 1.20.0"),
      do: {2, vsn, scm, lock_entry},
      else: {1, vsn, scm}
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
