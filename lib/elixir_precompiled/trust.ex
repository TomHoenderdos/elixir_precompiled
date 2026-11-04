# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Trust do
  @moduledoc """
  The trust chain's top: a root document shipped with this library names the
  keys allowed to sign batches; a batch names every manifest by hash. Both
  travel in an envelope signed over raw bytes. Sequence numbers only go up.

  Every entry point here parses attacker-reachable input (a shipped file, a
  cached file, or whatever a server hands back), so every helper is written
  to return an error tuple instead of raising, and the public functions that
  touch the network or disk also carry a function-level `rescue` as a second
  line of defense.
  """

  alias ElixirPrecompiled.Output

  @type root :: map()

  @spec verify_envelope(map() | binary(), %{String.t() => binary()}, pos_integer()) ::
          {:ok, binary()} | {:error, :bad_envelope | :below_threshold}
  def verify_envelope(envelope, keys, threshold) when is_binary(envelope) do
    case safe_decode(envelope) do
      {:ok, map} when is_map(map) -> verify_envelope(map, keys, threshold)
      _ -> {:error, :bad_envelope}
    end
  end

  def verify_envelope(%{"payload" => p, "signatures" => sigs}, keys, threshold)
      when is_binary(p) and is_list(sigs) and is_integer(threshold) and threshold > 0 do
    case Base.url_decode64(p, padding: false) do
      {:ok, payload} ->
        valid =
          sigs
          |> Enum.filter(&valid?(&1, payload, keys))
          |> Enum.map(& &1["keyid"])
          |> Enum.uniq()

        if length(valid) >= threshold, do: {:ok, payload}, else: {:error, :below_threshold}

      :error ->
        {:error, :bad_envelope}
    end
  end

  def verify_envelope(_, _, _), do: {:error, :bad_envelope}

  defp valid?(%{"keyid" => kid, "sig" => sig}, payload, keys)
       when is_binary(kid) and is_binary(sig) do
    with {:ok, public} <- Map.fetch(keys, kid),
         true <- byte_size(public) == 32,
         {:ok, raw} <- Base.url_decode64(sig, padding: false),
         true <- byte_size(raw) == 64 do
      :crypto.verify(:eddsa, :none, payload, raw, [public, :ed25519])
    else
      _ -> false
    end
  end

  defp valid?(_, _, _), do: false

  @doc """
  The keys and threshold for a role, or `{%{}, nil}` when `root` doesn't name
  that role with a usable shape. Total: never raises, whatever `root` is.
  """
  @spec root_keys(root(), String.t()) :: {%{String.t() => binary()}, pos_integer() | nil}
  def root_keys(root, role) when is_map(root) do
    case root["roles"] do
      %{^role => %{"keyids" => ids, "threshold" => t}}
      when is_list(ids) and is_integer(t) and t > 0 ->
        if Enum.all?(ids, &is_binary/1) do
          {resolve_keys(root["keys"], ids), t}
        else
          {%{}, nil}
        end

      _ ->
        {%{}, nil}
    end
  end

  def root_keys(_root, _role), do: {%{}, nil}

  defp resolve_keys(keys, ids) when is_map(keys) do
    Enum.reduce(ids, %{}, fn id, acc ->
      with %{"public" => pub, "type" => "ed25519"} when is_binary(pub) <- keys[id],
           {:ok, bin} <- Base.url_decode64(pub, padding: false),
           true <- sha256_hex(bin) == id do
        Map.put(acc, id, bin)
      else
        _ -> acc
      end
    end)
  end

  defp resolve_keys(_keys, _ids), do: %{}

  @doc """
  Where the batch sequence and adopted roots live for this source: under
  `config.home`, named by the source URL and the shipped root's first root
  key, so two sources (or two trust anchors) never share replay state.
  Always keyed by the SHIPPED root, so a rotation keeps the same dir.
  """
  @spec state_dir(map(), root()) :: Path.t()
  def state_dir(config, shipped_root) do
    hash = sha256_hex(config.source <> "|" <> first_root_keyid(shipped_root))
    Path.join(config.home, binary_part(hash, 0, 16))
  end

  defp first_root_keyid(%{"roles" => %{"root" => %{"keyids" => [id | _]}}}) when is_binary(id),
    do: id

  defp first_root_keyid(_), do: ""

  # The shipped file was verified by `load_root/1`; here it only names the
  # dir and seeds the chain fold.
  defp shipped_root(config) do
    {:ok, body} = File.read(config.root_path)
    {:ok, env} = safe_decode(body)
    {:ok, payload} = decode_payload(env)
    {:ok, root} = safe_decode(payload)
    root
  end

  defp state_dir(config), do: state_dir(config, shipped_root(config))

  defp sha256_hex(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  @doc """
  The root in use: the shipped root, advanced along the adopted chain in
  `roots.json`. The shipped root must verify under its own root role; each
  chain entry must also verify under the previous root's root role and have
  a higher version, and the first one that fails ends the chain. As in TUF,
  only the root in use (the last one) must be unexpired: an expired
  intermediate root does not end the chain, and a release keeps working
  past its shipped root's expiry once a newer root has been adopted.

  The version this ends on can never drop below one `update_root/3` already
  recorded: a stored `root_version` higher than the folded root's version
  means `roots.json` lost the entries that led there (deleted, truncated, or
  rolled back), and that is reported rather than silently accepted.
  """
  @spec load_root(map()) :: {:ok, root()} | {:error, String.t()}
  def load_root(config) do
    with {:ok, shipped} <- read_shipped(config.root_path) do
      dir = state_dir(config, shipped)
      {root, adopted} = fold_chain(shipped, read_chain(dir))

      case version_regression(dir, root) do
        :ok -> expiry_outcome(config, root, adopted)
        error -> error
      end
    end
  rescue
    _ -> {:error, "root document at #{config.root_path} is invalid"}
  end

  defp expiry_outcome(config, root, adopted) do
    case check_expiry(expires_of(root)) do
      :ok ->
        {:ok, root}

      :error when adopted == [] ->
        {:error, "root document at #{config.root_path} expired at #{expires_of(root)}"}

      :error ->
        {:error, "cached root expired at #{expires_of(root)}"}
    end
  end

  defp version_regression(dir, %{"version" => v}) when is_integer(v) do
    path = Path.join(dir, "root_version")
    stored = read_counter(path, "root version")

    if v < stored,
      do:
        {:error,
         "root version #{v} is older than #{stored}: the adopted roots are gone; " <>
           "delete #{path} to start again from version #{v}"},
      else: :ok
  end

  defp version_regression(_dir, _root), do: :ok

  defp read_shipped(path) do
    with {:ok, body} <- File.read(path),
         {:ok, env} <- safe_decode(body),
         {:ok, payload} <- self_verify(env),
         {:ok, root} <- safe_decode(payload) do
      {:ok, root}
    else
      _ -> {:error, "root document at #{path} is invalid"}
    end
  end

  defp read_chain(dir) do
    with {:ok, body} <- File.read(Path.join(dir, "roots.json")),
         {:ok, envs} when is_list(envs) <- safe_decode(body) do
      envs
    else
      _ -> []
    end
  end

  # {root in use, envelopes adopted on the way there}. As in TUF, a step's
  # expiry does not end the chain: v2 expiring after v3 was adopted must not
  # strand a client on v1. Only the root the fold ends on must be unexpired,
  # which load_root/1 checks.
  defp fold_chain(shipped, envs) do
    {root, adopted} =
      Enum.reduce_while(envs, {shipped, []}, fn env, {current, adopted} ->
        case chain_step(env, current) do
          {:ok, next} -> {:cont, {next, [env | adopted]}}
          :error -> {:halt, {current, adopted}}
        end
      end)

    {root, Enum.reverse(adopted)}
  end

  # A root may follow `current` when it verifies under its own root role and
  # under current's, and is newer.
  defp chain_step(env, current) do
    {keys, t} = root_keys(current, "root")

    with {:ok, payload} <- self_verify(env),
         {:ok, root} <- safe_decode(payload),
         true <- newer?(root, current),
         {:ok, _} <- verify_envelope(env, keys, t) do
      {:ok, root}
    else
      _ -> :error
    end
  end

  # A served root becomes the root in use, so it must also be unexpired.
  defp adopt(env, current) do
    with {:ok, root} <- chain_step(env, current),
         :ok <- check_expiry(expires_of(root)) do
      {:ok, root}
    end
  end

  defp self_verify(env) do
    with {:ok, payload} <- decode_payload(env),
         {:ok, root} <- safe_decode(payload),
         {keys, t} <- root_keys(root, "root"),
         {:ok, ^payload} <- verify_envelope(env, keys, t) do
      {:ok, payload}
    else
      _ -> {:error, "root signature invalid"}
    end
  end

  defp expires_of(%{"expires" => e}) when is_binary(e), do: e
  defp expires_of(_), do: nil

  defp check_expiry(exp) when is_binary(exp) do
    case DateTime.from_iso8601(exp) do
      {:ok, dt, _} -> if DateTime.compare(dt, DateTime.utc_now()) == :gt, do: :ok, else: :error
      _ -> :error
    end
  end

  defp check_expiry(_), do: :error

  defp newer?(root, trusted) do
    with %{"version" => rv} when is_integer(rv) <- root,
         %{"version" => tv} when is_integer(tv) <- trusted do
      rv > tv
    else
      _ -> false
    end
  end

  @doc """
  Adopt the source's served root when it chains from `root` (the root in
  use), appending it to `roots.json` and recording its version as the
  floor `load_root/1` will not go back below. Anything else keeps `root`.
  """
  @spec update_root(map(), root(), (String.t() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, root()}
  def update_root(config, root, fetch) do
    case fetch.(config.source <> "/root.json") do
      {:ok, body} ->
        # Fetched is checked, adopted or not: the next check is due an
        # interval from now (see root_check_due?/1). That includes a 2xx
        # root.json that does not chain from the root in use. Safe: a batch
        # signed under a root this client has not adopted fails its
        # signature, and Check then fetches the root again regardless.
        _ = write_atomic(state_dir(config), "root_checked", Integer.to_string(unix_now(config)))
        adopt_served(config, root, body)

      _ ->
        {:ok, root}
    end
  rescue
    _ -> {:ok, root}
  end

  defp adopt_served(config, root, body) do
    with {:ok, env} when is_map(env) <- safe_decode(body),
         {:ok, candidate} <- adopt(env, root),
         shipped = shipped_root(config),
         dir = state_dir(config, shipped),
         {_, adopted} = fold_chain(shipped, read_chain(dir)),
         :ok <- write_atomic(dir, "roots.json", :json.encode(adopted ++ [env])) do
      write_root_version(dir, candidate["version"])
      {:ok, candidate}
    else
      _ -> {:ok, root}
    end
  end

  @doc """
  Whether the served root should be fetched this run: never stamped, the
  stamp `:root_check_seconds` (default an hour) old or older, or a stamp in
  the future (a clock set back). A batch that fails to verify fetches the
  root regardless (see `ElixirPrecompiled.Check`).
  """
  @spec root_check_due?(map()) :: boolean()
  def root_check_due?(config) do
    interval = Map.get(config, :root_check_seconds, 3600)
    now = unix_now(config)

    with {:ok, s} <- File.read(Path.join(state_dir(config), "root_checked")),
         {n, ""} <- Integer.parse(String.trim(s)) do
      n > now or now - n >= interval
    else
      _ -> true
    end
  rescue
    _ -> true
  end

  defp unix_now(config), do: DateTime.to_unix(now(config))

  # Keeps the higher of what was already stored and the newly adopted
  # version, like `write_state/2`. A failure here must not unwind the root
  # this call already adopted and is about to return, so it is only logged.
  defp write_root_version(dir, version) do
    stored = read_counter(Path.join(dir, "root_version"), "root version")

    case write_atomic(dir, "root_version", Integer.to_string(max(stored, version))) do
      :ok ->
        :ok

      {:error, reason} ->
        Output.warning(
          "precompiled: could not write root version state " <>
            "#{Path.join(dir, "root_version")}: #{inspect(reason)}"
        )
    end
  end

  # A unique temp name per writer: two runs sharing one home never trip
  # over each other's half-written file.
  defp write_atomic(dir, name, data),
    do: ElixirPrecompiled.FileUtil.write_atomic(Path.join(dir, name), data)

  # The newest batch is signed every 15 minutes; one older than this is
  # refused whatever its `expires`, which bounds a replayed or frozen batch,
  # and a client with no sequence state yet, to a day.
  @max_age_seconds 24 * 3600
  @max_future_skew_seconds 300
  @max_lifetime_seconds 30 * 86_400
  # A clock earlier than the moment this library was compiled is wrong; the
  # freshness checks cannot be trusted on it.
  @clock_floor DateTime.utc_now() |> DateTime.truncate(:second)

  @doc false
  @spec clock_floor() :: DateTime.t()
  def clock_floor(), do: @clock_floor

  @doc false
  @spec now(map()) :: DateTime.t()
  def now(config),
    do: DateTime.add(DateTime.utc_now(), Map.get(config, :clock_offset_seconds, 0), :second)

  @type batch :: %{
          sequence: integer(),
          manifests: %{String.t() => String.t()},
          manifests_v2: %{String.t() => String.t()} | nil,
          content: [String.t()] | nil
        }

  @type conditional_fetch ::
          (String.t(), String.t() | nil ->
             {:ok, binary(), String.t() | nil} | :not_modified | {:error, term()})

  @spec fetch_batch(map(), root(), (String.t() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, batch()} | {:error, String.t()}
  def fetch_batch(config, root, fetch) do
    with {:ok, body} <- fetch.(config.source <> "/batch.json") |> or_error("batch unavailable") do
      verify_batch(config, root, body, state_dir(config))
    end
  rescue
    _ -> {:error, "batch malformed"}
  end

  @doc """
  The current batch, asking the source only whether it changed: the last
  verified batch and its ETag are kept in the state dir and the ETag is sent
  as `If-None-Match`. A 304 says only that the source still serves those
  bytes: they go through the same signature, freshness, clock and sequence
  checks as fresh ones, every run, so a batch older than a day is refused
  however often the source answers 304. New bytes replace the cache only
  once they verify. Offline, the cached batch is checked the same way and
  no request is made.

  When the source cannot be reached (`{:error, {:unreachable, why}}` from
  `fetch`: a transport error, timeout, 5xx or the run deadline), the cached
  batch is used under the same rule as offline and one line says so. A
  response the source did give and that is refused (bad signature, an
  older sequence, malformed bytes, a 4xx) never falls back to the cache.
  """
  @spec fetch_batch_cached(map(), root(), conditional_fetch()) ::
          {:ok, batch()} | {:error, String.t()}
  def fetch_batch_cached(config, root, fetch) do
    dir = state_dir(config)
    cached = read_cached_batch(dir)
    offline? = Map.get(config, :offline, false)

    cond do
      offline? and cached == nil ->
        {:error, "offline, no cached batch"}

      offline? ->
        verify_batch(config, root, cached.body, dir)

      true ->
        online_batch(config, root, fetch, cached, dir)
    end
  rescue
    _ -> {:error, "batch malformed"}
  end

  defp online_batch(config, root, fetch, cached, dir) do
    case fetch.(config.source <> "/batch.json", cached && cached.etag) do
      :not_modified when cached != nil ->
        verify_batch(config, root, cached.body, dir)

      {:ok, body, etag} when is_binary(body) ->
        with {:ok, batch} <- verify_batch(config, root, body, dir) do
          cache_batch(dir, body, etag, batch.sequence)
          {:ok, batch}
        end

      {:error, {:unreachable, why}} when cached != nil ->
        from_cache(config, root, cached.body, dir, why)

      # The reason stays in the line: "redirect to another host refused"
      # says more than "batch unavailable" alone.
      {:error, {:unreachable, why}} when is_binary(why) ->
        {:error, "batch unavailable: #{why}"}

      {:error, why} when is_binary(why) ->
        {:error, "batch unavailable: #{why}"}

      _ ->
        {:error, "batch unavailable"}
    end
  end

  defp from_cache(config, root, body, dir, why) do
    case verify_batch(config, root, body, dir) do
      {:ok, batch} ->
        Output.warning(
          "precompiled: source unreachable (#{why}); using the cached batch " <>
            "(sequence #{batch.sequence})"
        )

        {:ok, batch}

      {:error, cached_why} ->
        {:error, "batch unavailable: #{why} (cached batch: #{cached_why})"}
    end
  end

  # Same cap as a batch off the network.
  @max_cached_batch_bytes 8_388_608
  @max_etag_bytes 512

  # The cached body (nil when absent, unreadable or over the cap) and its
  # ETag. The ETag file names the sha256 of the body it belongs to: an ETag
  # whose body was replaced (a crash between the two writes, or two runs
  # racing) is never sent, so a 304 can only ever vouch for the bytes it
  # was issued for. Whether the body is any good is verify_batch/4's job.
  defp read_cached_batch(dir) do
    case read_capped(Path.join(dir, "batch.json"), @max_cached_batch_bytes) do
      {:ok, body} -> %{body: body, etag: cached_etag(dir, body)}
      _ -> nil
    end
  end

  defp cached_etag(dir, body) do
    with {:ok, line} <- read_capped(Path.join(dir, "batch.etag"), @max_etag_bytes + 80),
         [sha, etag] <- String.split(line, " ", parts: 2),
         true <- sha == sha256_hex(body),
         true <- etag?(etag) do
      etag
    else
      _ -> nil
    end
  end

  # An ETag is sent back as a header: printable ASCII only, bounded.
  defp etag?(etag) when is_binary(etag) do
    etag != "" and byte_size(etag) <= @max_etag_bytes and
      String.match?(etag, ~r/\A[\x21-\x7e]+\z/)
  end

  defp etag?(_), do: false

  defp read_capped(path, max) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max <- File.stat(path),
         {:ok, body} <- File.read(path),
         true <- byte_size(body) <= max do
      {:ok, body}
    else
      _ -> :error
    end
  end

  @doc false
  # The body first, then its ETag, each written atomically. An old ETag
  # left next to a new body names the old body's sha and is ignored.
  # A concurrent run that already verified a newer sequence (the state
  # file, re-read right before the write, is past this batch's) keeps its
  # batch: this one would only be refused as older by the next run.
  @spec cache_batch(Path.t(), binary(), String.t() | nil, integer()) :: :ok
  def cache_batch(dir, body, etag, seq) do
    if read_counter(Path.join(dir, "state"), "sequence") > seq,
      do: :ok,
      else: write_cache(dir, body, etag)
  end

  defp write_cache(dir, body, etag) do
    case write_atomic(dir, "batch.json", body) do
      :ok when is_binary(etag) ->
        if etag?(etag),
          do: write_atomic(dir, "batch.etag", sha256_hex(body) <> " " <> etag),
          else: File.rm(Path.join(dir, "batch.etag"))

      :ok ->
        File.rm(Path.join(dir, "batch.etag"))

      {:error, reason} ->
        Output.warning("precompiled: could not cache the batch in #{dir}: #{inspect(reason)}")
    end

    :ok
  end

  defp verify_batch(config, root, body, dir) do
    {keys, t} = root_keys(root, "batch")

    with {:ok, payload} <- verify_envelope(body, keys, t) |> or_error("batch signature invalid"),
         {:ok, decoded} <- safe_decode(payload) |> or_error("batch malformed"),
         {:ok, seq, issued, exp, manifests, v2, content} <- batch_fields(decoded),
         now = now(config),
         :ok <- sane_clock(now),
         {:ok, issued_at} <- parse_instant(issued),
         {:ok, expires_at} <- parse_instant(exp),
         :ok <- not_from_future(issued_at, now),
         :ok <- lifetime(issued_at, expires_at),
         :ok <- fresh(issued_at, now),
         :ok <- not_expired(expires_at, now),
         :ok <- monotonic(dir, seq),
         :ok <- write_state(dir, seq) do
      {:ok, %{sequence: seq, manifests: manifests, manifests_v2: v2, content: content}}
    end
  end

  defp sane_clock(now) do
    if DateTime.compare(now, @clock_floor) == :lt,
      do:
        {:error,
         "clock is before #{DateTime.to_iso8601(@clock_floor)}, when this library was built"},
      else: :ok
  end

  defp parse_instant(s) do
    case safe_parse_iso8601(s) do
      {:ok, dt} -> {:ok, dt}
      :error -> {:error, "batch malformed"}
    end
  end

  defp not_from_future(issued, now) do
    if DateTime.diff(issued, now, :second) > @max_future_skew_seconds,
      do: {:error, "clock: batch issued at #{DateTime.to_iso8601(issued)} is in the future"},
      else: :ok
  end

  defp lifetime(issued, expires) do
    if DateTime.diff(expires, issued, :second) > @max_lifetime_seconds,
      do:
        {:error,
         "batch lifetime over 30 days (issued #{DateTime.to_iso8601(issued)}, expires #{DateTime.to_iso8601(expires)})"},
      else: :ok
  end

  defp fresh(issued, now) do
    if DateTime.diff(now, issued, :second) > @max_age_seconds,
      do: {:error, "batch stale: issued #{DateTime.to_iso8601(issued)}, more than 24 h ago"},
      else: :ok
  end

  @doc false
  # Written like roots.json, so a crash mid-write never leaves a torn
  # sequence number behind. The floor is re-read right before the write and
  # only ever raised: a run sharing this home that adopted a newer sequence
  # since monotonic/2 looked keeps its floor.
  @spec write_state(Path.t(), integer()) :: :ok | {:error, String.t()}
  def write_state(dir, seq) do
    stored = read_counter(Path.join(dir, "state"), "sequence")

    case write_atomic(dir, "state", Integer.to_string(max(stored, seq))) do
      :ok -> :ok
      {:error, reason} -> {:error, "state dir unwritable: #{inspect(reason)}"}
    end
  end

  # "manifests" names format-1 documents; "manifests_v2", when present,
  # names format-2 ones under v2/manifests. Both live in a version-1 batch.
  defp batch_fields(
         %{
           "version" => 1,
           "sequence" => seq,
           "issued" => issued,
           "expires" => exp,
           "manifests" => manifests
         } = decoded
       )
       when is_integer(seq) and is_binary(issued) and is_binary(exp) and is_map(manifests) do
    case Map.get(decoded, "manifests_v2") do
      v2 when is_map(v2) or is_nil(v2) ->
        {:ok, seq, issued, exp, manifests, v2, content(Map.get(decoded, "content"))}

      _ ->
        {:error, "batch malformed"}
    end
  end

  defp batch_fields(_), do: {:error, "batch malformed"}

  # Content origins the portal signs into the batch: where files and
  # by-sha manifests may also come from. Anything not https is dropped
  # (http on loopback only through the project's own :content config); a
  # field of the wrong shape is ignored rather than refusing the batch.
  defp content(list) when is_list(list),
    do: for(o <- list, https_origin?(o), do: String.trim_trailing(o, "/"))

  defp content(_), do: nil

  defp https_origin?(o) when is_binary(o) do
    match?(%URI{scheme: "https", host: h} when is_binary(h) and h != "", URI.parse(o))
  rescue
    _ -> false
  end

  defp https_origin?(_), do: false

  defp or_error({:ok, _} = ok, _), do: ok
  defp or_error(_, msg), do: {:error, msg}

  defp not_expired(expires_at, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, "batch expired at #{DateTime.to_iso8601(expires_at)}"}
  end

  defp safe_parse_iso8601(exp) when is_binary(exp) do
    case DateTime.from_iso8601(exp) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp safe_parse_iso8601(_), do: :error

  defp monotonic(dir, seq) do
    stored = read_counter(Path.join(dir, "state"), "sequence")
    if seq >= stored, do: :ok, else: {:error, "batch sequence #{seq} is older than #{stored}"}
  end

  # A counter file (`state`'s sequence, `root_version`'s version) that
  # exists but fails to parse is corrupt rather than merely absent: warn
  # once and treat it as 0 either way.
  defp read_counter(path, label) do
    case File.read(path) do
      {:ok, s} ->
        case s |> String.trim() |> Integer.parse() do
          {n, _} ->
            n

          :error ->
            Output.warning("precompiled: #{label} state #{path} is unreadable; treating it as 0")
            0
        end

      _ ->
        0
    end
  end

  defp decode_payload(%{"payload" => p}) when is_binary(p),
    do: Base.url_decode64(p, padding: false)

  defp decode_payload(_), do: :error

  defp safe_decode(bin) when is_binary(bin) do
    {:ok, :json.decode(bin)}
  rescue
    _ -> :error
  end
end
