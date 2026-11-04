# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Snapshot do
  @moduledoc """
  The portal's bytes a conformance or reproduce run needs, downloaded once
  from `source` and verified by the harness, in a directory outside the
  repository laid out the way `ChainTest.Mirror` serves it:

      root.json, batch.json     as served
      batches/<sequence>.json   the batch's bytes again
      batches/<n>.json          the older batches below, when the portal has them
      <dir>/<name>.json         the manifest the batch names for each Hex dep
                                of the fixture lock (dir: manifests or v2/manifests)
      files/<sha256>            every file of every build the client could
                                select for the target and this Elixir/OTP
      snapshot.json             what was taken, written last

  The batch is verified with `ChainTest.Trust.check/1` against the snapshot
  itself, served by a `ChainTest.Mirror` over the directory, so what is
  verified is exactly what is stored. Each manifest must hash to the sha the
  verified batch names (otherwise production published a batch while the
  snapshot was taken: take it again) and each file to its name.

  Everything is downloaded into a private (`0700`, files `0600`) staging
  directory next to the target and renamed into place only once it is
  complete and verified, so the target either holds a whole snapshot or does
  not exist; a failed `take/1` removes its staging directory.

  Two older batches are kept too, for the cases that serve one: `previous`,
  the batch `N-1` before the current `N`, and `old`, the newest batch
  issued more than 25 hours before `N` (found by probing `batches/<n>.json`
  downwards, then bisecting; at most 64 probes). Each is verified like
  the current one except for its age: freshness and expiry are what the
  cases using it test. Each records, as `manifests`, the fixture deps it
  names a manifest for that differs from `N`'s (`%{dep => %{dir, sha256}}`);
  their bytes are not stored, since the portal serves only the current
  batch's manifests. An older batch the portal does not have is
  `{:missing, why}` (the cases that need it are not testable here), one it
  could not be fetched is `{:unavailable, why}` (not exercised), one that
  does not verify is `{:invalid, why}` (a failure); none of them is stored,
  each is recorded under its own key in `snapshot.json`, and the snapshot
  is still taken. `older/2` reads
  them.

  A snapshot is good for 24 hours: after that its batch is stale for the
  client and for `ChainTest.Trust`, and `load/2` refuses it. A directory
  without `snapshot.json` is not a snapshot, and `load/2` refuses it too.

  `load/2` is for reusing a kept snapshot: `obtain/1` (what `mix
  chain_conformance` calls) loads the one a `--snapshot-dir` already holds
  instead of downloading again, and later work that reproduces a run from
  its stored bytes starts from it.
  """

  alias ChainTest.{HTTP, Integrity, Lock, Mirror, Trust}

  @timeout_ms 60_000
  @max_manifest_bytes 64 * 1024 * 1024
  @concurrency 8
  @max_age_s 24 * 3600
  @max_future_s 300
  @repo_root Path.expand("../../../..", __DIR__)
  @old_after_s 25 * 3600
  @probe_step 100
  @max_probes 64
  # The checks an older batch is excused: its age is what the cases test.
  @age_checks ["batch_freshness", "batch_expiry"]

  @type dep :: %{
          version: String.t(),
          manifest: String.t() | nil,
          sha256: String.t() | nil,
          builds: non_neg_integer(),
          files: non_neg_integer(),
          file_shas: [String.t()]
        }

  @type older_name :: :previous | :old
  @type older_batch :: %{
          sequence: integer(),
          path: String.t(),
          issued: DateTime.t(),
          info: Trust.info(),
          manifests: %{String.t() => %{dir: String.t(), sha256: String.t()}}
        }
  @typedoc """
  An older batch, or why the snapshot has none: `:missing`, the portal does
  not have it (a 404, or no batch issued over 25 h before `N` within the
  probes); `:unavailable`, it could not be fetched (a transport error, a
  timeout, another status); `:invalid`, it was served but does not verify
  (signature, sequence, issue instant, not a batch), a finding about the
  source.
  """
  @type older ::
          {:ok, older_batch()}
          | {:missing, String.t()}
          | {:unavailable, String.t()}
          | {:invalid, String.t()}

  @absent [:missing, :unavailable, :invalid]

  @type t :: %{
          dir: Path.t(),
          source: String.t(),
          target: String.t(),
          sequence: integer(),
          info: Trust.info(),
          taken_at: DateTime.t(),
          deps: %{String.t() => dep()},
          previous: older(),
          old: older()
        }

  @doc """
  The snapshot's older batch `name` (`:previous` or `:old`, see the
  moduledoc), `{:missing, why}` when it has none.
  """
  @spec older(map(), older_name()) :: older()
  def older(snap, name) when name in [:previous, :old],
    do: Map.get(snap, name, {:missing, "the snapshot holds no #{name} batch"})

  @typedoc """
  What a case may need of the snapshot (a transform's or setup's
  `needs/1`): an older batch (`:previous`, `:old`); `:previous_manifests`,
  a previous batch naming the same manifest as `N` for every dep the
  snapshot holds a build of (the portal serves only `N`'s manifest bytes,
  so a case that installs from `N-1` can only be served those);
  `:previous_differs`, a previous batch that names another manifest, or
  none, for at least one dep the snapshot holds a build of (`recheck/1`:
  a warm `_build` installed from `N` holds a build that batch no longer
  vouches for, R16); `:older_manifest_bytes`, the bytes of a manifest an
  older batch names and `N` does not (M3), which the snapshot holds only
  as `older_manifests/<sha256>.json` (the portal serves only the current
  batch's manifests, so today it never does).
  """
  @type need ::
          older_name()
          | :previous_manifests
          | :previous_differs
          | :older_manifest_bytes

  @needs [
    :previous,
    :old,
    :previous_manifests,
    :previous_differs,
    :older_manifest_bytes
  ]

  @doc "Every `t:need/0`."
  @spec need_names() :: [need()]
  def need_names(), do: @needs

  @doc """
  `:ok` when the snapshot has what `need` names, else `{kind, why}`: the
  case that needs it is not testable here (`:missing`), not exercised
  (`:unavailable`) or a failure (`:invalid`); see `t:older/0`.
  """
  @spec available(map(), need()) :: :ok | {:missing | :unavailable | :invalid, String.t()}
  def available(snap, name) when name in [:previous, :old] do
    case older(snap, name) do
      {:ok, _} -> :ok
      {kind, why} when kind in @absent -> {kind, "the #{name} batch: #{why}"}
    end
  end

  def available(snap, :previous_manifests) do
    case older(snap, :previous) do
      {:ok, previous} -> same_manifests(snap, previous)
      {kind, why} when kind in @absent -> {kind, "the previous batch: #{why}"}
    end
  end

  def available(snap, :previous_differs) do
    case older(snap, :previous) do
      {:ok, previous} ->
        if recheck(snap) == %{},
          do:
            {:missing,
             "the previous batch (#{previous.sequence}) names the same manifest as batch " <>
               "#{snap.sequence} for every dep the snapshot holds a build of: no installed " <>
               "build of N is one it no longer vouches for"},
          else: :ok

      {kind, why} when kind in @absent ->
        {kind, "the previous batch: #{why}"}
    end
  end

  def available(snap, :older_manifest_bytes) do
    case older_manifests(snap) do
      [_ | _] ->
        :ok

      [] ->
        lacking =
          for name <- [:previous, :old],
              {kind, why} <- [older(snap, name)],
              kind in @absent,
              do: {kind, "the #{name} batch: #{why}"}

        older_manifest_lack(snap, lacking)
    end
  end

  # Without the bytes: the worst reason an older batch is lacking, else why
  # the ones it has give nothing to serve.
  defp older_manifest_lack(snap, lacking) do
    by = fn kind -> for {^kind, why} <- lacking, do: why end

    cond do
      by.(:invalid) != [] ->
        {:invalid, Enum.join(by.(:invalid), "; ")}

      by.(:unavailable) != [] ->
        {:unavailable, Enum.join(by.(:unavailable), "; ")}

      true ->
        named =
          for name <- [:previous, :old],
              {:ok, b} <- [older(snap, name)],
              {dep, _} <- b.manifests,
              do: "#{dep} (batch #{b.sequence})"

        why =
          if named == [],
            do:
              "no older batch the snapshot holds names a fixture manifest batch " <>
                "#{snap.sequence} does not",
            else:
              "older batches name other manifests (#{Enum.join(Enum.uniq(named), ", ")}), " <>
                "but the portal serves only the current batch's manifest bytes"

        {:missing, Enum.join(by.(:missing) ++ [why], "; ")}
    end
  end

  @doc """
  The older manifests whose bytes the snapshot holds: for each dep an older
  batch (`:previous`, then `:old`) names another manifest for than `N`,
  `{dep, path}` when `older_manifests/<sha256>.json` exists under the
  snapshot and hashes to that sha (M3).
  """
  @spec older_manifests(map()) :: [{String.t(), Path.t()}]
  def older_manifests(snap) do
    for name <- [:previous, :old],
        {:ok, b} <- [older(snap, name)],
        {dep, %{sha256: sha}} <- Enum.sort(b.manifests),
        rel = "older_manifests/#{sha}.json",
        {:ok, bytes} <- [File.read(Path.join(snap.dir, rel))],
        sha256(bytes) == sha,
        uniq: true,
        do: {dep, rel}
  end

  @doc """
  The held deps (a build of each in the snapshot) the previous batch names
  another manifest for than `N` (`:differs`) or none (`:unnamed`); empty
  without a previous batch. A warm `_build` installed from `N` holds a
  build of each that the previous batch no longer vouches for (R16).
  """
  @spec recheck(map()) :: %{String.t() => :differs | :unnamed}
  def recheck(snap) do
    case older(snap, :previous) do
      {:ok, previous} ->
        for {name, %{builds: n}} <- Map.get(snap, :deps, %{}),
            is_integer(n) and n > 0,
            # A tuple, never falsy: a `nil` binding would filter the dep out.
            {ours, theirs} =
              {Trust.manifest_sha(snap.info, name), Trust.manifest_sha(previous.info, name)},
            theirs != ours,
            into: %{},
            do: {name, if(theirs == nil, do: :unnamed, else: :differs)}

      _ ->
        %{}
    end
  end

  defp same_manifests(snap, previous) do
    differ =
      for {name, %{builds: n}} <- Enum.sort(Map.get(snap, :deps, %{})),
          is_integer(n) and n > 0,
          Trust.manifest_sha(previous.info, name) != Trust.manifest_sha(snap.info, name),
          do: name

    case differ do
      [] ->
        :ok

      names ->
        {:missing,
         "the previous batch names other manifests than batch #{snap.sequence} for " <>
           Enum.join(names, ", ") <> ", and the portal serves only the current batch's"}
    end
  end

  @doc "The issue instant of the snapshot's batch (`batch.json` under `dir`)."
  @spec issued(%{dir: Path.t()}) :: {:ok, DateTime.t()} | {:error, String.t()}
  def issued(%{dir: dir}), do: issued_at(dir, "batch.json")

  @doc "A fresh directory name under the system tmp dir."
  @spec default_dir() :: Path.t()
  def default_dir() do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(Path.expand(System.tmp_dir!()), "chain_snapshot-#{stamp}-#{random()}")
  end

  @doc """
  Downloads, verifies and stores a snapshot (see the moduledoc).

  Input `%{source, fixture_dir, target}`; optional `:dir` (default
  `default_dir/0`; must not exist or be an empty directory, and lie outside
  the repository), `:timeout_ms` per request, `:trust_opts` (merged into the
  `ChainTest.Trust` config) and `:repo_root`.
  """
  @spec take(map()) :: {:ok, t()} | {:error, String.t()}
  def take(%{source: source, fixture_dir: fixture, target: target} = input) do
    source = String.trim_trailing(source, "/")
    dir = Path.expand(Map.get(input, :dir) || default_dir())
    timeout = Map.get(input, :timeout_ms, @timeout_ms)
    trust_opts = Map.get(input, :trust_opts, %{})

    with :ok <- outside_repo(dir, Map.get(input, :repo_root, @repo_root)),
         {:ok, existing} <- target_dir(dir),
         {:ok, lock} <- lock(fixture),
         {:ok, staging} <- staging_dir(dir) do
      # After a successful rename the staging path no longer exists; on an
      # error or a raise it is removed here.
      try do
        with {:ok, snap} <- fill(staging, source, lock, target, trust_opts, timeout),
             :ok <- write(staging, "snapshot.json", JSON.encode!(meta(snap))),
             :ok <- move(staging, dir, existing) do
          {:ok, %{snap | dir: dir}}
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  @doc """
  The snapshot a run uses: when `input.dir` already holds one (it has a
  `snapshot.json`), that one through `load/2`, refused unless it was taken
  from the same `source`, for the same `target` and of the same fixture
  lock; otherwise a fresh one through `take/1`. Input as for `take/1`.
  """
  @spec obtain(map()) :: {:ok, t()} | {:error, String.t()}
  def obtain(%{source: _, fixture_dir: _, target: _} = input) do
    dir = Map.get(input, :dir)

    if dir != nil and File.exists?(Path.join(Path.expand(dir), "snapshot.json")) do
      with {:ok, snap} <- load(dir, Map.take(input, [:trust_opts])),
           :ok <- same_input(snap, input) do
        {:ok, snap}
      end
    else
      take(input)
    end
  end

  defp same_input(snap, input) do
    source = String.trim_trailing(input.source, "/")

    cond do
      snap.target != input.target ->
        {:error,
         "the snapshot in #{snap.dir} is for #{snap.target}, not #{input.target}; " <>
           "take a new one"}

      snap.source != source ->
        {:error,
         "the snapshot in #{snap.dir} was taken from source #{snap.source}, not #{source}; " <>
           "take a new one"}

      true ->
        same_lock(snap, input.fixture_dir)
    end
  end

  # The snapshot holds the deps of the lock it was taken for; any other
  # lock would be judged against builds it never looked for.
  defp same_lock(snap, fixture) do
    with {:ok, lock} <- lock(fixture) do
      want =
        for name <- Map.keys(lock), v = Lock.hex_version(lock, name), into: %{}, do: {name, v}

      have = Map.new(snap.deps, fn {name, d} -> {name, d.version} end)

      case Enum.sort(Map.to_list(want) -- Map.to_list(have)) ++
             Enum.sort(Map.to_list(have) -- Map.to_list(want)) do
        [] ->
          :ok

        diff ->
          names = diff |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")

          {:error,
           "the snapshot in #{snap.dir} was taken for another fixture lock (#{names}); " <>
             "take a new one"}
      end
    end
  end

  @doc """
  Re-verifies a stored snapshot: complete, taken less than 24 hours ago, the
  batch accepted by `ChainTest.Trust` now (so at most 24 hours old) and equal
  to its `batches/<sequence>.json` copy, taken under this Elixir and OTP,
  every manifest hashing to what the batch names and every file to its
  name. Option `:trust_opts` as for `take/1`.
  """
  @spec load(Path.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def load(dir, opts \\ %{}) do
    dir = Path.expand(dir)

    with {:ok, meta} <- read_meta(dir),
         {:ok, taken_at} <- fresh(meta),
         :ok <- same_toolchain(meta),
         {:ok, info} <- verify(dir, trust_opts(opts)),
         :ok <- same_sequence(meta, info),
         :ok <- same_batch(dir, info),
         {:ok, stored} <- stored_files(dir),
         {:ok, deps} <- stored_deps(dir, meta, info, stored),
         {:ok, older} <- stored_older(dir, meta, info, trust_opts(opts), Map.keys(deps)) do
      {:ok,
       Map.merge(
         %{
           dir: dir,
           source: meta["source"],
           target: meta["target"],
           sequence: info.sequence,
           info: info,
           taken_at: taken_at,
           deps: deps
         },
         older
       )}
    end
  end

  # taking

  # Both sides resolved through symlinks, so a dir reached through a link
  # into the repository is caught.
  defp outside_repo(dir, repo_root) do
    {dir, root} = {real_path(dir), real_path(repo_root)}

    if dir == root or String.starts_with?(dir, root <> "/"),
      do:
        {:error, "snapshot dir #{dir} is inside the repository; downloaded bytes stay out of it"},
      else: :ok
  end

  # `path` with every symlink among its existing components resolved; the
  # components that do not exist are kept as they are.
  defp real_path(path), do: resolve(Path.split(Path.expand(path)), "/", 0)

  defp resolve([], acc, _hops), do: acc

  defp resolve([part | rest], acc, hops) do
    next = Path.join(acc, part)

    case File.read_link(next) do
      {:ok, target} when hops < 40 ->
        resolve(Path.split(Path.expand(target, acc)) ++ rest, "/", hops + 1)

      _ ->
        resolve(rest, next, hops)
    end
  end

  # `{:ok, :absent | :empty}`: the target must not exist or be an empty,
  # real directory (never a symlink to one).
  defp target_dir(dir) do
    case File.lstat(dir) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(dir) do
          {:ok, []} -> {:ok, :empty}
          {:ok, _} -> {:error, "snapshot dir #{dir} is not empty"}
          {:error, why} -> {:error, "snapshot dir #{dir}: #{:file.format_error(why)}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "snapshot dir #{dir} is not a directory (#{type})"}

      {:error, why} ->
        {:error, "snapshot dir #{dir}: #{:file.format_error(why)}"}
    end
  end

  defp lock(fixture) do
    path = Path.join(fixture, "mix.lock")

    case Lock.read(path) do
      {:ok, lock} -> {:ok, lock}
      {:error, why} -> {:error, "fixture lock #{path}: #{why}"}
    end
  end

  # A private sibling of the target, so the final rename stays on one
  # file system.
  defp staging_dir(dir) do
    parent = Path.dirname(dir)
    staging = Path.join(parent, ".#{Path.basename(dir)}.partial-#{random()}")

    with :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(staging),
         :ok <- File.chmod(staging, 0o700) do
      {:ok, staging}
    else
      {:error, why} -> {:error, "staging dir #{staging}: #{:file.format_error(why)}"}
    end
  end

  defp fill(staging, source, lock, target, trust_opts, timeout) do
    with {:ok, _} <- download(source, "root.json", staging, timeout, HTTP.max_bytes()),
         {:ok, batch} <- download(source, "batch.json", staging, timeout, HTTP.max_bytes()),
         {:ok, info} <- verify(staging, trust_opts),
         :ok <- write(staging, "batches/#{info.sequence}.json", batch),
         {:ok, deps} <- collect(source, staging, lock, target, info, timeout),
         {:ok, older} <-
           take_older(source, staging, info, trust_opts, timeout, Map.keys(deps)) do
      {:ok,
       Map.merge(
         %{
           dir: staging,
           source: source,
           target: target,
           sequence: info.sequence,
           info: info,
           taken_at: DateTime.utc_now() |> DateTime.truncate(:second),
           deps: deps
         },
         older
       )}
    end
  end

  defp move(staging, dir, existing) do
    with :ok <- if(existing == :empty, do: File.rmdir(dir), else: :ok),
         :ok <- File.rename(staging, dir) do
      :ok
    else
      {:error, why} ->
        {:error, "cannot move the snapshot into #{dir}: #{:file.format_error(why)}"}
    end
  end

  defp download(source, rel, dir, timeout, max_bytes) do
    case HTTP.get("#{source}/#{rel}", timeout, max_bytes: max_bytes) do
      {:ok, bytes} -> with :ok <- write(dir, rel, bytes), do: {:ok, bytes}
      {:error, why} -> {:error, why}
    end
  end

  # Writes `rel` under `dir`, every directory it creates `0700`, the file `0600`.
  defp write(dir, rel, bytes) do
    path = Path.join(dir, rel)

    with :ok <- mkdirs(dir, Path.dirname(rel)),
         :ok <- File.write(path, bytes),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, why} -> {:error, "#{path}: #{:file.format_error(why)}"}
    end
  end

  defp mkdirs(_dir, "."), do: :ok

  defp mkdirs(dir, rel) do
    rel
    |> Path.split()
    |> Enum.reduce_while({:ok, dir}, fn part, {:ok, parent} ->
      path = Path.join(parent, part)

      case File.mkdir(path) do
        :ok ->
          case File.chmod(path, 0o700) do
            :ok -> {:cont, {:ok, path}}
            error -> {:halt, error}
          end

        {:error, :eexist} ->
          {:cont, {:ok, path}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # The harness's own trust checks, on the stored bytes as a mirror serves
  # them. The mirror is not linked to the caller: it is always stopped here.
  defp verify(dir, trust_opts, batch_path \\ "batch.json", excused \\ []) do
    case Mirror.start(dir) do
      {:ok, mirror} ->
        try do
          cfg = Map.merge(trust_opts, %{source: mirror.url, batch_path: batch_path})
          {results, info} = Trust.check(cfg)
          kept = Enum.reject(results, &(&1.check in excused))

          cond do
            not Trust.accepted?(kept, info) ->
              what = if batch_path == "batch.json", do: "the snapshot's batch", else: batch_path
              {:error, "the harness rejects #{what}: " <> problem(kept)}

            not served_root_pinned?(results) ->
              {:error, "the harness rejects the snapshot's root: " <> served_root(results)}

            true ->
              {:ok, info}
          end
        after
          Mirror.stop(mirror)
        end

      {:error, why} ->
        {:error, "cannot serve #{dir}: #{inspect(why)}"}
    end
  end

  # `Trust.accepted?/2` tolerates a served root other than the pinned one;
  # a snapshot stores the served root as its baseline, so it must not.
  defp served_root_pinned?(results),
    do: Enum.any?(results, &(&1.check == "served_root" and &1.class == :pass))

  defp served_root(results) do
    case Enum.find(results, &(&1.check == "served_root")) do
      nil -> "served_root: not checked"
      r -> "served_root: #{r.detail}"
    end
  end

  defp problem(results) do
    case Enum.find(results, &(&1.class != :pass and &1.check != "served_root")) do
      nil -> "no batch"
      r -> "#{r.check}: #{r.detail}"
    end
  end

  defp collect(source, dir, lock, target, info, timeout) do
    selection = %{
      lock: lock,
      system: Lock.system(lock, target) || {"host", ""},
      elixir: System.version(),
      otp: System.otp_release()
    }

    lock
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, acc} ->
      case dep(source, dir, name, selection, info, timeout) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, d} -> {:cont, {:ok, Map.put(acc, name, d)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp dep(source, dir, name, selection, info, timeout) do
    case {Lock.hex_version(selection.lock, name), Trust.manifest_sha(info, name)} do
      {nil, _} ->
        {:ok, nil}

      {vsn, nil} ->
        {:ok, %{version: vsn, manifest: nil, sha256: nil, builds: 0, files: 0, file_shas: []}}

      {vsn, {sha, mdir}} ->
        rel = "#{mdir}/#{name}.json"

        with {:ok, bytes} <- download(source, rel, dir, timeout, @max_manifest_bytes),
             :ok <- manifest_sha(bytes, sha, rel),
             {:ok, doc} <- manifest_doc(bytes, rel),
             builds = Integrity.eligible_builds(doc, name, vsn, selection),
             {:ok, shas} <- files(source, dir, builds, timeout) do
          {:ok,
           %{
             version: vsn,
             manifest: rel,
             sha256: sha,
             builds: length(builds),
             files: length(shas),
             file_shas: shas
           }}
        end
    end
  end

  defp manifest_doc(bytes, rel) do
    case Integrity.normalize_manifest(bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, why} -> {:error, "#{rel}: #{why}"}
    end
  end

  defp manifest_sha(bytes, sha, rel) do
    got = sha256(bytes)

    if got == sha,
      do: :ok,
      else:
        {:error,
         "#{rel} hashes to #{got}, the verified batch names #{sha}: production moved " <>
           "during the snapshot; take it again"}
  end

  # At most @concurrency downloads at once; the first error halts the
  # stream (which shuts the other downloads down) and fails the take.
  defp files(source, dir, builds, timeout) do
    entries =
      builds
      |> Enum.flat_map(&(List.wrap(&1["ebin"]) ++ List.wrap(&1["priv"])))
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(& &1["sha256"])

    case mkdirs(dir, "files") do
      :ok -> download_files(source, dir, entries, timeout)
      {:error, why} -> {:error, "#{dir}/files: #{:file.format_error(why)}"}
    end
  end

  defp download_files(source, dir, entries, timeout) do
    entries
    |> Task.async_stream(&file(source, dir, &1, timeout),
      max_concurrency: @concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, sha}}, {:ok, acc} -> {:cont, {:ok, [sha | acc]}}
      {:ok, {:error, _} = error}, _ -> {:halt, error}
    end)
    |> case do
      {:ok, shas} -> {:ok, Enum.reverse(shas)}
      error -> error
    end
  end

  defp file(source, dir, %{"sha256" => sha, "size" => size}, timeout)
       when is_binary(sha) and is_integer(size) and size >= 0 do
    rel = "files/#{sha}"

    with :ok <- file_name(sha),
         {:ok, bytes} <- download(source, rel, dir, timeout, size) do
      if sha256(bytes) == sha,
        do: {:ok, sha},
        else: {:error, "#{rel}: the bytes do not hash to their name"}
    end
  end

  defp file(_source, _dir, entry, _timeout),
    do: {:error, "malformed manifest file entry #{inspect(entry)}"}

  defp file_name(sha) do
    if sha =~ ~r/\A[0-9a-f]{64}\z/,
      do: :ok,
      else: {:error, "a manifest names file #{inspect(sha)}"}
  end

  defp trust_opts(opts), do: Map.get(opts, :trust_opts, %{})

  # older batches

  defp take_older(source, dir, info, trust_opts, timeout, names) do
    with {:ok, issued} <- issued_at(dir, "batch.json") do
      previous = take_previous(source, dir, {info, issued}, trust_opts, timeout, names)
      old = take_old(source, dir, {info, issued}, trust_opts, timeout, names)
      {:ok, %{previous: previous, old: old}}
    end
  end

  defp take_previous(source, dir, {info, issued}, trust_opts, timeout, names) do
    n = info.sequence - 1
    rel = "batches/#{n}.json"

    case HTTP.get("#{source}/#{rel}", timeout, max_bytes: HTTP.max_bytes()) do
      {:ok, bytes} ->
        keep_older(dir, n, bytes, info, trust_opts, names, previous_check(issued, n))

      {:error, why} ->
        if not_found?(why),
          do: {:missing, "#{rel}: #{why}"},
          else: {:unavailable, "#{rel}: #{why}"}
    end
  end

  defp not_found?(why), do: String.ends_with?(why, "answered 404")

  defp take_old(source, dir, {info, issued}, trust_opts, timeout, names) do
    probe = &probe(source, &1, issued, timeout)

    case search_old(probe, info.sequence) do
      {:ok, n, bytes} -> keep_older(dir, n, bytes, info, trust_opts, names, old_check(issued, n))
      {kind, why} when kind in @absent -> {kind, why}
    end
  end

  # N-1 is excused freshness and expiry only: it was issued no later than
  # N and not more than 300 s ahead of this clock.
  defp previous_check(n_issued, n) do
    fn issued ->
      cond do
        DateTime.compare(issued, n_issued) == :gt ->
          {:error,
           "batches/#{n}.json was issued #{DateTime.to_iso8601(issued)}, after the current " <>
             "batch (#{DateTime.to_iso8601(n_issued)})"}

        DateTime.diff(issued, DateTime.utc_now(), :second) > @max_future_s ->
          {:error,
           "batches/#{n}.json was issued #{DateTime.to_iso8601(issued)}, more than 300 s " <>
             "ahead of this clock"}

        true ->
          :ok
      end
    end
  end

  defp old_check(n_issued, n) do
    fn issued ->
      if DateTime.diff(n_issued, issued, :second) > @old_after_s,
        do: :ok,
        else:
          {:error,
           "batches/#{n}.json was issued #{DateTime.to_iso8601(issued)}, not more than " <>
             "25 h before the current batch"}
    end
  end

  # Stores an older batch's bytes, verified; one that does not verify is
  # removed again and invalid (one that cannot even be stored, unavailable).
  defp keep_older(dir, n, bytes, info, trust_opts, names, check) do
    rel = "batches/#{n}.json"

    case write(dir, rel, bytes) do
      :ok ->
        case older_batch(dir, n, info, trust_opts, names, check) do
          {:ok, older} ->
            {:ok, older}

          {:error, why} ->
            File.rm(Path.join(dir, rel))
            {:invalid, why}
        end

      {:error, why} ->
        {:unavailable, why}
    end
  end

  # The stored batches/<n>.json, verified except for its age, carrying
  # sequence n and passing `check` on its issue instant.
  defp older_batch(dir, n, info, trust_opts, names, check) do
    rel = "batches/#{n}.json"

    with {:ok, older} <- verify(dir, trust_opts, rel, @age_checks),
         :ok <- same_number(older.sequence, n, rel),
         {:ok, issued} <- issued_at(dir, rel),
         :ok <- check.(issued) do
      {:ok,
       %{
         sequence: n,
         path: rel,
         issued: issued,
         info: older,
         manifests: differing(older, info, names)
       }}
    end
  end

  defp same_number(n, n, _rel), do: :ok
  defp same_number(got, _n, rel), do: {:error, "#{rel} carries sequence #{got}"}

  # The fixture deps the older batch names a manifest for that differs from
  # the current batch's.
  defp differing(older, info, names) do
    for name <- Enum.sort(names),
        {sha, mdir} = named <- [Trust.manifest_sha(older, name)],
        named != Trust.manifest_sha(info, name),
        into: %{},
        do: {name, %{dir: mdir, sha256: sha}}
  end

  # The issue instant of a stored batch's payload (its signature is
  # verified elsewhere).
  defp issued_at(dir, rel) do
    case File.read(Path.join(dir, rel)) do
      {:ok, bytes} ->
        case fields(bytes) do
          {:ok, _sequence, issued} -> {:ok, issued}
          :error -> {:error, "#{rel} carries no issue instant"}
        end

      {:error, why} ->
        {:error, "#{rel}: #{:file.format_error(why)}"}
    end
  end

  defp fields(bytes) do
    with {:ok, %{"payload" => p}} when is_binary(p) <- JSON.decode(bytes),
         {:ok, payload} <- Base.url_decode64(p, padding: false),
         {:ok, %{"sequence" => seq, "issued" => text}} when is_integer(seq) <-
           JSON.decode(payload),
         {:ok, issued, _} <- DateTime.from_iso8601(text) do
      {:ok, seq, issued}
    else
      _ -> :error
    end
  end

  # What batches/<n>.json says about its age, before any verification:
  # `{:ok, :new}` (issued 25 h or less before the current batch), `{:ok,
  # {:old, bytes}}`, `{:ok, :missing}` (404), or `{:invalid, why}` /
  # `{:unavailable, why}`, which end the search. The candidate the search settles on is verified.
  defp probe(source, n, n_issued, timeout) do
    rel = "batches/#{n}.json"

    case HTTP.get("#{source}/#{rel}", timeout, max_bytes: HTTP.max_bytes()) do
      {:ok, bytes} ->
        case fields(bytes) do
          {:ok, ^n, issued} ->
            if DateTime.diff(n_issued, issued, :second) > @old_after_s,
              do: {:ok, {:old, bytes}},
              else: {:ok, :new}

          {:ok, seq, _} ->
            {:invalid, "#{rel} carries sequence #{seq}"}

          :error ->
            {:invalid, "#{rel} is not a batch"}
        end

      {:error, why} ->
        if not_found?(why),
          do: {:ok, :missing},
          else: {:unavailable, "#{rel}: #{why}"}
    end
  end

  # Sequences are numbered by one, issue instants rise with them, and the
  # portal may have dropped the oldest: missing < old < new. Steps down from
  # `n` (100 at a time, doubling: the portal signs every 15 minutes) to a
  # batch that is not new, then bisects to the newest batch that is not.
  defp search_old(probe, n) do
    st = %{memo: %{}, left: @max_probes, probe: probe}

    with {:ok, lo, hi, st} <- bracket(n, @probe_step, n, st),
         {:ok, lo, st} <- bisect(lo, hi, st) do
      case st.memo[lo] do
        {:old, bytes} ->
          {:ok, lo, bytes}

        _ ->
          {:missing,
           "the portal keeps no batch issued more than 25 h before batch #{n} " <>
             "(batches/#{lo}.json is not there)"}
      end
    end
  end

  defp bracket(n, step, hi, st) do
    m = max(n - step, 0)

    with {:ok, class, st} <- class(m, st) do
      cond do
        class != :new ->
          {:ok, m, hi, st}

        m == 0 ->
          {:missing,
           "every batch back to batches/0.json was issued 25 h or less before batch #{n}"}

        true ->
          bracket(n, step * 2, m, st)
      end
    end
  end

  defp bisect(lo, hi, st) when hi - lo <= 1, do: {:ok, lo, st}

  defp bisect(lo, hi, st) do
    mid = div(lo + hi, 2)

    with {:ok, class, st} <- class(mid, st) do
      if class == :new, do: bisect(lo, mid, st), else: bisect(mid, hi, st)
    end
  end

  defp class(m, %{memo: memo} = st) when is_map_key(memo, m), do: {:ok, kind(memo[m]), st}

  defp class(_m, %{left: 0}),
    do: {:missing, "no batch issued more than 25 h before found within #{@max_probes} probes"}

  defp class(m, st) do
    case st.probe.(m) do
      {:ok, v} -> {:ok, kind(v), %{st | memo: Map.put(st.memo, m, v), left: st.left - 1}}
      {kind, why} when kind in [:invalid, :unavailable] -> {kind, why}
    end
  end

  defp kind({:old, _bytes}), do: :old
  defp kind(class), do: class

  # A kept snapshot's older batches, re-verified as when taken; one that no
  # longer verifies fails the load. A snapshot taken before they were kept
  # has none.
  defp stored_older(dir, meta, info, trust_opts, names) do
    with {:ok, issued} <- issued_at(dir, "batch.json") do
      ctx = %{dir: dir, info: info, trust_opts: trust_opts, names: names}
      previous = fn n -> n == info.sequence - 1 end
      old = fn n -> n < info.sequence end

      with {:ok, p} <-
             older_entry(ctx, meta["previous"], "previous", previous, &previous_check(issued, &1)),
           {:ok, o} <- older_entry(ctx, meta["old"], "old", old, &old_check(issued, &1)) do
        {:ok, %{previous: p, old: o}}
      end
    end
  end

  # `allowed?` says which sequence the entry may name, `check` (given that
  # sequence) what the batch's issue instant must pass.
  defp older_entry(ctx, entry, key, allowed?, check) do
    case entry do
      nil ->
        {:ok,
         {:missing, "the snapshot was taken before snapshots kept older batches; take a new one"}}

      %{"missing" => why} when is_binary(why) ->
        {:ok, {:missing, why}}

      %{"unavailable" => why} when is_binary(why) ->
        {:ok, {:unavailable, why}}

      %{"invalid" => why} when is_binary(why) ->
        {:ok, {:invalid, why}}

      %{"sequence" => n} when is_integer(n) ->
        if allowed?.(n) do
          with {:ok, older} <-
                 older_batch(ctx.dir, n, ctx.info, ctx.trust_opts, ctx.names, check.(n)),
               do: {:ok, {:ok, older}}
        else
          {:error, "snapshot.json names batch #{n} as the #{key} batch of #{ctx.info.sequence}"}
        end

      _ ->
        {:error, "snapshot.json has a malformed #{key} entry: #{inspect(entry)}"}
    end
  end

  defp older_meta({:ok, older}), do: %{"sequence" => older.sequence}
  defp older_meta({kind, why}) when kind in @absent, do: %{Atom.to_string(kind) => why}

  defp meta(snap) do
    %{
      "previous" => older_meta(snap.previous),
      "old" => older_meta(snap.old),
      "format" => 1,
      "source" => snap.source,
      "target" => snap.target,
      "taken_at" => DateTime.to_iso8601(snap.taken_at),
      "sequence" => snap.sequence,
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "deps" =>
        Map.new(snap.deps, fn {name, d} ->
          {name,
           %{
             "version" => d.version,
             "manifest" => d.manifest,
             "sha256" => d.sha256,
             "builds" => d.builds,
             "files" => d.files,
             "file_shas" => d.file_shas
           }}
        end)
    }
  end

  # loading

  defp read_meta(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "snapshot.json")),
         {:ok, %{"format" => 1, "deps" => deps} = meta} when is_map(deps) <- JSON.decode(bytes) do
      {:ok, meta}
    else
      _ -> {:error, "#{dir} is not a complete snapshot (no readable snapshot.json)"}
    end
  end

  defp fresh(meta) do
    now = DateTime.utc_now()

    with text when is_binary(text) <- meta["taken_at"],
         {:ok, at, _} <- DateTime.from_iso8601(text) do
      age = DateTime.diff(now, at, :second)

      cond do
        age > @max_age_s ->
          {:error, "the snapshot was taken at #{text}, older than 24 hours; take a new one"}

        age < -@max_future_s ->
          {:error, "the snapshot was taken at #{text}, in the future"}

        true ->
          {:ok, at}
      end
    else
      _ -> {:error, "snapshot.json names no valid taken_at"}
    end
  end

  defp same_toolchain(%{"elixir" => elixir, "otp" => otp}) do
    if {elixir, otp} == {System.version(), System.otp_release()},
      do: :ok,
      else:
        {:error,
         "the snapshot was taken under Elixir #{elixir} / OTP #{otp}, this is " <>
           "#{System.version()} / #{System.otp_release()}; take a new one"}
  end

  defp same_toolchain(_), do: {:error, "snapshot.json names no Elixir/OTP"}

  defp same_sequence(%{"sequence" => seq}, %{sequence: seq}), do: :ok

  defp same_sequence(meta, info),
    do:
      {:error,
       "snapshot.json names batch #{inspect(meta["sequence"])}, the stored batch #{info.sequence}"}

  defp same_batch(dir, %{sequence: seq}) do
    rel = "batches/#{seq}.json"

    case {File.read(Path.join(dir, "batch.json")), File.read(Path.join(dir, rel))} do
      {{:ok, same}, {:ok, same}} -> :ok
      {{:ok, _}, {:ok, _}} -> {:error, "#{rel} differs from batch.json"}
      {_, {:error, why}} -> {:error, "#{rel}: #{:file.format_error(why)}"}
      {{:error, why}, _} -> {:error, "batch.json: #{:file.format_error(why)}"}
    end
  end

  defp stored_deps(dir, meta, info, stored) do
    Enum.reduce_while(meta["deps"], {:ok, %{}}, fn {name, d}, {:ok, acc} ->
      case stored_dep(dir, name, d, info, stored) do
        {:ok, dep} -> {:cont, {:ok, Map.put(acc, name, dep)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stored_dep(dir, name, %{"file_shas" => shas} = d, info, stored) when is_list(shas) do
    dep = %{
      version: d["version"],
      manifest: d["manifest"],
      sha256: d["sha256"],
      builds: d["builds"],
      files: d["files"],
      file_shas: shas
    }

    with :ok <- stored_manifest(dir, name, dep, info),
         :ok <- listed_files(name, dep, stored) do
      {:ok, dep}
    end
  end

  defp stored_dep(_dir, name, _d, _info, _stored),
    do: {:error, "snapshot.json has a malformed entry for #{name}"}

  defp stored_manifest(dir, name, dep, info) do
    case {dep.manifest, Trust.manifest_sha(info, name)} do
      {nil, nil} ->
        :ok

      {nil, {_sha, mdir}} ->
        {:error,
         "snapshot.json names no manifest for #{name}, but the stored batch names " <>
           "#{mdir}/#{name}.json"}

      {rel, {sha, mdir}} when rel == mdir <> "/" <> name <> ".json" ->
        case File.read(Path.join(dir, rel)) do
          {:ok, bytes} -> manifest_sha(bytes, sha, rel)
          {:error, why} -> {:error, "#{rel}: #{:file.format_error(why)}"}
        end

      {rel, _} ->
        {:error,
         "snapshot.json names #{inspect(rel)} for #{name}, which the stored batch does not"}
    end
  end

  # Every file a dep lists is stored (and so, by `stored_files/1`, hashes to
  # its name), and the count agrees with the list.
  defp listed_files(name, dep, stored) do
    cond do
      dep.files != length(dep.file_shas) ->
        {:error,
         "snapshot.json counts #{inspect(dep.files)} files for #{name} but lists " <>
           "#{length(dep.file_shas)}"}

      dep.manifest == nil and dep.file_shas != [] ->
        {:error, "snapshot.json lists files for #{name}, which has no manifest"}

      missing = Enum.find(dep.file_shas, &(not MapSet.member?(stored, &1))) ->
        {:error, "files/#{missing}, listed for #{name}, is not in the snapshot"}

      true ->
        :ok
    end
  end

  # The names of the stored files, each checked to hash to its name.
  defp stored_files(dir) do
    dir
    |> Path.join("files/*")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn path, {:ok, acc} ->
      name = Path.basename(path)

      case File.read(path) do
        {:ok, bytes} ->
          if sha256(bytes) == name,
            do: {:cont, {:ok, MapSet.put(acc, name)}},
            else: {:halt, {:error, "files/#{name}: the bytes do not hash to their name"}}

        {:error, why} ->
          {:halt, {:error, "files/#{name}: #{:file.format_error(why)}"}}
      end
    end)
  end

  defp random(), do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
