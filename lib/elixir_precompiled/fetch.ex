# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Fetch do
  @moduledoc """
  Bytes in, verified files in the project's `_build` out. Manifests are checked against
  the hash the batch names; files against the hash the manifest names,
  before anything reaches the build directory. Install is atomic per
  dependency: staged under `_build/<t>/lib/.precompiled/<dep>`, renamed
  into place with Mix's "already compiled" marker.
  """

  alias ElixirPrecompiled.Manifest

  # 8 MiB: root, batch and any other document
  @max_body_bytes 8_388_608
  # 64 MiB: manifests of packages with many versions and systems run past 8 MiB
  @max_manifest_bytes 67_108_864
  @ok_modes [0o644, 0o755, 0o100644, 0o100755]
  @provenance_file "elixir_precompiled.json"
  @file_concurrency 8

  @spec get_body(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def get_body(url, opts \\ []) do
    http_opts =
      [max_bytes: Keyword.get(opts, :max_bytes, @max_body_bytes), same_origin: true] ++
        Keyword.take(opts, [
          :deadline_at,
          :connect_timeout_ms,
          :deadline_ms,
          :allowed_origins,
          :offline
        ])

    case ElixirPrecompiled.HTTP.get(url, http_opts) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  @doc """
  GET a metadata document (the batch), sending `etag` as `If-None-Match`
  when there is one: the body and its ETag, or `:not_modified`. A failure
  to reach the source (transport error, timeout, the run deadline, a 5xx,
  offline) is `{:error, {:unreachable, reason}}`; anything the source
  actually answered (a 4xx, an oversized or refused redirect) is
  `{:error, reason}`.
  """
  @spec get_conditional(map(), String.t(), String.t() | nil) ::
          {:ok, binary(), String.t() | nil}
          | :not_modified
          | {:error, String.t() | {:unreachable, String.t()}}
  def get_conditional(config, url, etag) do
    headers = if is_binary(etag), do: [{"if-none-match", etag}], else: []

    opts =
      [headers: headers, max_bytes: @max_body_bytes, same_origin: true] ++ metadata_opts(config)

    case ElixirPrecompiled.HTTP.request(url, opts) do
      {:ok, body, etag} -> {:ok, body, etag}
      :not_modified -> :not_modified
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  defp classify(reason) do
    why = describe_error(reason)
    if unreachable?(reason), do: {:unreachable, why}, else: why
  end

  defp unreachable?("Status 5" <> _), do: true
  defp unreachable?("offline"), do: true
  defp unreachable?("run deadline passed"), do: true
  defp unreachable?("no response within " <> _), do: true
  defp unreachable?("no data for " <> _), do: true
  defp unreachable?(reason) when is_binary(reason), do: false
  defp unreachable?(:too_many_redirects), do: false
  defp unreachable?(:cross_origin_redirect), do: false
  defp unreachable?({:too_large, _}), do: false
  # httpc's own transport errors: {:failed_connect, _}, :socket_closed_remotely, ...
  defp unreachable?(_), do: true

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

  defp common_opts(config),
    do: [
      connect_timeout_ms: Map.get(config, :connect_timeout_ms, 5_000),
      offline: Map.get(config, :offline, false)
    ]

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
  defp describe_error(reason), do: inspect(reason)

  @doc """
  The manifest the batch names by `expected_sha`, under `path`: "manifests"
  for a format-1 document, "v2/manifests" for a format-2 one. Either comes
  back as format 2 (see `ElixirPrecompiled.Manifest`).

  Looked up, in order: the cache (`<home>/manifests/<sha>.json`, re-hashed
  on every read); where by-sha paths exist, `<origin>/<path>/by-sha/<sha>.json`
  for each content origin and then the source; and last the source's
  `<path>/<name>.json`, whose answer decides the result. Whatever bytes come
  back are used only if they hash to `expected_sha`.
  """
  @spec manifest(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:miss, String.t()} | {:fail, String.t()}
  def manifest(config, name, expected_sha, path \\ "manifests") do
    if sha256?(expected_sha) do
      case cached_manifest(config, expected_sha) do
        {:ok, bytes} -> decode_manifest(bytes)
        :error -> uncached_manifest(config, name, expected_sha, path)
      end
    else
      {:fail, "manifest hash malformed"}
    end
  end

  defp uncached_manifest(config, name, sha, path) do
    if Map.get(config, :offline, false),
      do: {:miss, "offline: manifest not cached"},
      else: fetch_manifest(config, name, sha, path)
  end

  defp fetch_manifest(config, name, sha, path) do
    by_sha = for origin <- by_sha_origins(config), do: "#{origin}/#{path}/by-sha/#{sha}.json"

    Enum.find_value(by_sha, &try_manifest(config, &1, sha)) ||
      named_manifest(config, name, sha, path)
  end

  # By-sha paths exist where the signed batch advertises content origins:
  # the portal signs "content" into batches once it serves them. Check sets
  # :by_sha from the batch; without it, a :content list stands for it.
  defp by_sha_origins(config) do
    content = Map.get(config, :content)

    if is_list(content) and Map.get(config, :by_sha, true),
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
    case get_body(
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

      {:error, "Status 404 Not Found"} ->
        {:miss, "no manifest"}

      {:error, reason} ->
        {:miss, "manifest unavailable: #{reason}"}
    end
  end

  defp decode_manifest(bytes), do: with({:ok, map} <- decode(bytes), do: Manifest.normalize(map))

  defp cached_manifest(config, sha) do
    case read_regular(manifest_cache_path(config, sha), @max_manifest_bytes) do
      {:ok, bytes} -> if sha256(bytes) == sha, do: {:ok, bytes}, else: :error
      :error -> :error
    end
  end

  # A cache write that fails costs only the next run a download.
  defp cache_manifest(config, sha, bytes),
    do: ElixirPrecompiled.FileUtil.write_atomic(manifest_cache_path(config, sha), bytes)

  defp manifest_cache_path(config, sha), do: Path.join([config.home, "manifests", sha <> ".json"])

  # A cache entry is read only when it is a regular file itself: never
  # through a symlink, whatever it points at, and never past `max` bytes.
  defp read_regular(path, max) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp decode(bytes) do
    {:ok, :json.decode(bytes)}
  rescue
    _ -> {:fail, "manifest is not JSON"}
  end

  @spec install(map(), atom(), map(), tuple(), Path.t(), keyword()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer(), cached: non_neg_integer()}}
          | {:fail, String.t()}
  def install(config, dep, entry, lock_entry, build_lib, opts \\ []) do
    files = (entry["ebin"] || []) ++ (entry["priv"] || [])
    staging = Path.join([build_lib, ".precompiled", Atom.to_string(dep)])
    dest = Path.join(build_lib, Atom.to_string(dep))
    verify_app = Keyword.get(opts, :verify_app, fn _ -> :ok end)

    try do
      with :ok <- validate(files, dep),
           {:ok, stats} <- stage(config, files, staging),
           :ok <- verify_app.(Path.join([staging, "ebin", "#{dep}.app"])) do
        write_marker(staging, lock_entry)
        write_provenance(staging, Keyword.get(opts, :provenance))
        File.rm_rf!(dest)
        File.mkdir_p!(build_lib)
        File.rename!(staging, dest)

        link_sources(dep, entry, dest, Keyword.fetch!(opts, :deps_path))

        {:ok, stats}
      else
        {:fail, _} = fail ->
          File.rm_rf!(staging)
          fail
      end
    rescue
      e ->
        File.rm_rf!(staging)
        {:fail, "install failed: #{Exception.message(e)}"}
    end
  end

  # Mix links deps/<dep>/include (and src for rebar deps, and priv) into
  # _build when it builds a dep; a dep installed here is never built, so
  # mirror that or a dependent's -include_lib/Record.extract fails.
  defp link_sources(dep, entry, dest, deps_path) do
    source = Path.join(deps_path, Atom.to_string(dep))
    priv = if (entry["priv"] || []) == [], do: ["priv"], else: []

    for name <- ["include", "src" | priv],
        from = Path.join(source, name),
        to = Path.join(dest, name),
        File.dir?(from) and not File.exists?(to) do
      symlink_or_copy(from, to)
    end

    :ok
  end

  # Mix.Utils.symlink_or_copy/2 without Mix: a relative symlink, as Mix
  # makes, so a moved project tree keeps its links; a copy where the
  # filesystem refuses one.
  defp symlink_or_copy(from, to) do
    relative = Path.relative_to(from, Path.dirname(to), force: true)

    case File.ln_s(relative, to) do
      :ok -> :ok
      {:error, _} -> File.cp_r!(from, to) && :ok
    end
  end

  defp validate(files, dep) do
    app = "ebin/#{dep}.app"

    cond do
      why = Enum.find_value(files, &bad_file/1) -> {:fail, why}
      not Enum.any?(files, &(&1["path"] == app)) -> {:fail, "no #{app} in entry"}
      true -> :ok
    end
  end

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
      Path.type(path) == :relative and not Enum.member?(Path.split(path), "..") and
      Path.expand(path, "/x") |> String.starts_with?("/x/")
  end

  def safe_path?(_), do: false

  @spec safe_mode?(term()) :: boolean()
  def safe_mode?(mode), do: mode in @ok_modes

  # Up to @file_concurrency files of one dep download at once, each bounded
  # by its declared size and the run deadline; results are taken in order,
  # so the first failing file (in manifest order) is the one reported.
  defp stage(config, files, staging) do
    File.rm_rf!(staging)
    File.mkdir_p!(staging)
    File.mkdir_p!(Path.join(config.home, "files"))

    files
    |> Task.async_stream(&stage_file(config, &1, staging),
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

      {:exit, reason}, _ ->
        {:halt, {:fail, "install failed: #{inspect(reason)}"}}
    end)
  end

  # Runs in a task linked to the caller: it never raises, or the exit would
  # take the caller (and the user's build) down with it.
  defp stage_file(config, f, staging) do
    with {:ok, bytes, cached?} <- fetch_file(config, f) do
      target = Path.join(staging, f["path"])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
      File.chmod!(target, Bitwise.band(f["mode"], 0o777))
      {:ok, f, cached?}
    end
  rescue
    e -> {:fail, "install failed: #{Exception.message(e)}"}
  catch
    kind, reason -> {:fail, "install failed: #{inspect({kind, reason})}"}
  end

  defp fetch_file(config, %{"sha256" => sha, "size" => size, "path" => path}) do
    case cached_file(config, sha, size) do
      {:ok, bytes} -> {:ok, bytes, true}
      :error -> download_file(config, sha, size, path)
    end
  end

  # The cached copy, re-hashed on every use; a symlink, a wrong size or a
  # wrong hash is no copy at all.
  defp cached_file(config, sha, size) do
    with {:ok, bytes} <- read_regular(file_cache_path(config, sha), size),
         :ok <- check_bytes(bytes, sha, size) do
      {:ok, bytes}
    else
      _ -> :error
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
      # A cache write that fails costs only the next run a download.
      _ = ElixirPrecompiled.FileUtil.write_atomic(file_cache_path(config, sha), body)
      {:ok, body, false}
    end
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

  defp write_provenance(staging, %{sha: sha, path: path, sequence: seq}) do
    File.mkdir_p!(Path.join(staging, ".mix"))

    File.write!(
      Path.join([staging, ".mix", @provenance_file]),
      :json.encode(%{"manifest_sha256" => sha, "manifest_path" => path, "batch_sequence" => seq})
    )
  end

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
