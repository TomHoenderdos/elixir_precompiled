# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Check do
  @moduledoc false
  # The shared engine: every candidate becomes a HIT, MISS or FAIL line with
  # a reason; the same list lands in `<build_lib>/.precompiled/report.json`.

  alias Precompiled.{CompileEnv, Config, Env, Fetch, FileUtil, Match, Output, Trust}

  @type line :: %{
          name: String.t(),
          version: String.t(),
          status: :hit | :miss | :fail,
          detail: String.t()
        }
  @type report :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          fails: non_neg_integer(),
          bytes: non_neg_integer(),
          seconds: float(),
          lines: [line()]
        }

  # opts:
  # - `:config_fun`: how a compile_env key is looked up (default
  #   `CompileEnv.lookup/2`);
  # - `:toolchain`: `{elixir, otp}` in place of the running ones. Test only:
  #   it lets a test change the toolchain under an unchanged batch.
  @spec check(map(), Env.t(), keyword()) :: :nothing_to_do | {:ok, report()}
  def check(config, %Env{} = env, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    {candidates, skipped} = candidates(env.candidates, env.lock, config.except, env.tooling)

    {excepted, installed} = installed(env, config.except)

    if candidates == [] and installed == [] and excepted == [] do
      debug("precompiled: no dependencies to check")
      :nothing_to_do
    else
      # Origins that fail to connect are not asked again this run.
      dead = Fetch.new_dead_origins()

      try do
        config =
          config
          |> with_home(env)
          |> with_deadline()
          |> with_toolchain(opts)
          |> Map.put(:dead_origins, dead)

        run_check(config, env, opts, %{
          started: started,
          candidates: candidates,
          skipped: skipped,
          excepted: excepted,
          installed: installed
        })
      after
        :ets.delete(dead)
      end
    end
  end

  defp run_check(config, env, opts, %{
         started: started,
         candidates: candidates,
         skipped: skipped,
         excepted: excepted,
         installed: installed
       }) do
    # Temp files a killed run left behind; an hour back, so a run sharing
    # this home mid-write keeps its own.
    Fetch.sweep_tmp(config, System.os_time(:second) - 3600)
    debug_skipped(skipped)
    config_fun = Keyword.get(opts, :config_fun, &CompileEnv.lookup/2)

    lines =
      except_lines(excepted, env) ++ lines_for(candidates, installed, config, env, config_fun)

    # Installs kept on a refused or missing batch are one warning, not a
    # FAIL line each: an offline warm build is a correct build. The
    # report still lists them.
    {kept, shown} = Enum.split_with(lines, &Map.get(&1, :kept, false))
    {noted, kept} = Enum.split_with(kept, &Map.get(&1, :note, false))
    Enum.each(shown, &print/1)
    print_kept(kept)
    Enum.each(noted, &print_note/1)
    ms = System.monotonic_time(:millisecond) - started
    report = summarize(lines, ms)
    # A warm build whose installs the batch still names has nothing to say.
    if shown != [], do: print_summary(summarize(shown, ms), length(shown))
    print_stripped(Enum.count(lines, &Map.get(&1, :stripped, false)))
    # Nothing to say also means nothing to record: keep the last report.
    if lines != [], do: write_report(env.build_lib, report)
    {:ok, report}
  end

  @doc false
  # Off means compile from source: every build an earlier run installed
  # goes, so Mix compiles it in this same run. Only a dir that carries the
  # provenance file an install writes is removed, checked by lstat right
  # before (Precompiled.Status.remove/2), so a dep Mix built stays.
  # The build lib is walked, no dep is loaded: this runs for every project
  # that has the library and is not opted in. A dir that will not go is
  # one line naming it; Mix then compiles what is left over it.
  @spec remove_installed(Env.t() | Path.t()) :: non_neg_integer()
  def remove_installed(%Env{build_lib: build_lib}), do: remove_installed(build_lib)

  def remove_installed(build_lib) when is_binary(build_lib) do
    %{removed: removed, failed: failed} = Precompiled.Status.sweep(build_lib)

    for {dep, why} <- failed,
        do: Output.warning("precompiled: could not remove the installed #{dep}: #{why}")

    n = length(removed)

    if n > 0 do
      Output.warning(
        "precompiled: disabled; removed #{n} installed #{if n == 1, do: "build", else: "builds"}, " <>
          "Mix compiles #{if n == 1, do: "it", else: "them"} from source"
      )
    end

    n
  end

  def remove_installed(_), do: 0

  @doc false
  # The home must take writes (trust state, cache). One that cannot (none
  # at all, read-only, or a pre-seeded CI cache) moves to _build for this
  # run.
  @spec with_home(map(), Env.t()) :: map()
  def with_home(config, env) do
    case Config.run_home(config.home, env.build_lib) do
      {:ok, _} ->
        config

      {:fallback, fallback} ->
        Output.warning(
          "precompiled: cache dir #{inspect(config.home)} is not writable; using #{fallback}"
        )

        %{config | home: fallback}
    end
  end

  # The Elixir and OTP builds are matched against; `:toolchain` in opts
  # stands in for the running ones (tests).
  defp with_toolchain(config, opts) do
    Map.put(
      config,
      :toolchain,
      Keyword.get(opts, :toolchain) ||
        {System.version(), to_string(:erlang.system_info(:otp_release))}
    )
  end

  @doc false
  # The whole run, every request in it, ends at :deadline_at; whatever is
  # still waiting then compiles from source.
  @spec with_deadline(map()) :: map()
  def with_deadline(config) do
    Map.put_new_lazy(config, :deadline_at, fn ->
      System.monotonic_time(:millisecond) + Map.get(config, :deadline_ms, 300_000)
    end)
  end

  # Nothing left that needs the batch (only excepted installs): no fetch.
  defp lines_for([], [], _config, _env, _config_fun), do: []

  defp lines_for(candidates, installed, config, env, config_fun) do
    case fetch_batch(config) do
      {:ok, batch} ->
        # Files may come from the project's own :content origins; by-sha
        # manifest paths are used only where the signed batch says they exist.
        config =
          config
          |> Map.put(:content, Map.get(config, :content_override) || batch.content)
          |> Map.put(:by_sha, is_list(batch.content))

        {revoked, replaced} = recheck(installed, batch, env)

        lines = revoked ++ install_lines(candidates ++ replaced, config, batch, env, config_fun)
        # Once a day, the cache back under its bound. Only after a run with
        # a verified batch: a refused one changes nothing on disk (R14). A
        # project with nothing to check never gets here, so it never gc's
        # a shared home; the next project that checks something does.
        Precompiled.Cache.maybe_gc(config)
        lines

      {:error, why} ->
        # No fresh batch, no verdict: installed builds stay as they are,
        # and their line says so rather than reading as a source compile.
        Enum.map(candidates, &revoke_line(&1, :fail, why)) ++
          Enum.map(installed, &kept_line(&1, why))
    end
  end

  # Installed builds Mix will not compile this run, as candidates (with
  # their lock entry and env), split into those now in `:except` and the
  # rest. A tooling or no longer Hex-locked dep is not this library's to
  # recheck.
  defp installed(env, except) do
    Env.hex_candidates(env.lock, env.installed, env.installed_envs)
    |> Enum.filter(&Match.candidate?(&1.name, env.lock, [], env.tooling))
    |> Enum.split_with(&(&1.name in except))
  end

  # `:except` means compile from source: an install made before the dep was
  # excepted is removed, batch or no batch, so Mix compiles it this run.
  defp except_lines(excepted, env) do
    for dep <- excepted do
      case remove(env.build_lib, Atom.to_string(dep.name)) do
        :ok -> revoke_line(dep, :miss, "excepted: compiled from source")
        {:error, why} -> revoke_line(dep, :fail, why)
      end
    end
  end

  # R16: an installed build is only as good as the batch that still names
  # it and the project it sits in. Named (same manifest sha or another):
  # matched again like any candidate on every run, preferring the
  # installed files, kept only when the selected build is exactly what is
  # on disk and its .app passes today's config, and removed when nothing
  # matches; a changed toolchain, lock, compile_env or target under an
  # unchanged batch is caught that way. An unchanged sha reads the manifest
  # from the cache, so this costs no request. Not named, or no readable
  # provenance: removed, so Mix compiles it from source in this same run.
  defp recheck(installed, batch, env) do
    Enum.reduce(installed, {[], []}, fn dep, {revoked, replaced} ->
      {sha, _path} = manifest_ref(batch, Atom.to_string(dep.name))

      case recheck_one(
             dep,
             sha,
             provenance_field(env.build_lib, dep.name, "manifest_sha256"),
             env
           ) do
        {:replace, dep} -> {revoked, replaced ++ [dep]}
        line -> {revoked ++ [line], replaced}
      end
    end)
  end

  # The recorded files hash only says which build to prefer; whether the
  # disk holds it is read from the disk (`Fetch.installed_as?/3`).
  defp recheck_one(dep, sha, recorded, env) when is_binary(sha) and is_binary(recorded),
    do:
      {:replace,
       Map.merge(dep, %{
         installed_hash: provenance_field(env.build_lib, dep.name, "files_sha256"),
         installed_sha: recorded
       })}

  defp recheck_one(dep, sha, nil, env) when is_binary(sha),
    do: revoke(dep, env, revoke_line(dep, :miss, "revoked: provenance unreadable"))

  defp recheck_one(dep, _sha, _recorded, env),
    do: revoke(dep, env, revoke_line(dep, :miss, "revoked: no longer in the current batch"))

  # Removes the installed build; `outcome` once it is gone, a FAIL line
  # naming the file that would not go otherwise.
  defp revoke(dep, env, outcome) do
    case remove(env.build_lib, Atom.to_string(dep.name)) do
      :ok -> outcome
      {:error, why} -> revoke_line(dep, :fail, why)
    end
  end

  defp kept_line(dep, why),
    do:
      Map.merge(revoke_line(dep, :fail, why <> " (installed build kept)"), %{kept: true, why: why})

  defp print_kept([]), do: :ok

  defp print_kept([%{why: why} | _] = kept) do
    n = length(kept)

    Output.warning(
      "precompiled: no fresh batch (#{why}); #{n} installed #{if n == 1, do: "build", else: "builds"} " <>
        "kept, not rechecked"
    )
  end

  # An installed build whose manifest is unchanged but could not be read
  # (not cached, and the network could not deliver it): one line of its
  # own, kept as it is, like an install kept on a missing batch.
  defp print_note(%{why: why} = l),
    do: Output.warning(line(%{l | detail: "#{why}; installed build kept, not rechecked"}, "KEPT"))

  defp revoke_line(dep, status, detail),
    do: %{
      name: Atom.to_string(dep.name),
      version: dep.version,
      status: status,
      detail: detail,
      bytes: 0
    }

  defp provenance_field(build_lib, dep, key) do
    with {:ok, bytes} <- File.read(Fetch.provenance_path(build_lib, dep)),
         %{^key => value} when is_binary(value) <- decode_json(bytes) do
      value
    else
      _ -> nil
    end
  end

  defp decode_json(bytes) do
    :json.decode(bytes)
  rescue
    _ -> nil
  end

  defp remove(build_lib, sname) do
    case File.rm_rf(Path.join(build_lib, sname)) do
      {:ok, _} -> :ok
      {:error, reason, file} -> {:error, "revoke failed: #{file}: #{:file.format_error(reason)}"}
    end
  end

  # Unlinked workers under a supervisor of this run: a worker that dies
  # outright (killed, or a crash one/5 cannot catch) is one FAIL line for
  # its dep, never an exit that takes the caller and the build with it.
  defp install_lines(candidates, config, batch, env, config_fun) do
    {:ok, sup} = Task.Supervisor.start_link()

    try do
      sup
      |> Task.Supervisor.async_stream_nolink(
        candidates,
        &one(&1, config, batch, env, config_fun),
        max_concurrency: 8,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.zip(candidates)
      |> Enum.map(fn
        {{:ok, line}, _dep} -> line
        {{:exit, reason}, dep} -> worker_died(dep, reason, env)
      end)
      |> Enum.reject(&is_nil/1)
    after
      Supervisor.stop(sup)
    end
  end

  # Nothing of a dead worker's install may stay behind: no staging dir and
  # no build dir carrying Mix's marker, so Mix compiles the dep.
  defp worker_died(dep, reason, env) do
    sname = Atom.to_string(dep.name)
    for dir <- Fetch.staging_dirs(env.build_lib, dep.name, :own), do: File.rm_rf(dir)
    _ = File.rm_rf(Path.join(env.build_lib, sname))

    %{
      name: sname,
      version: dep.version,
      bytes: 0,
      status: :fail,
      detail: "candidate crashed: #{inspect(reason)}"
    }
  end

  defp debug(msg), do: if(Config.debug?(), do: Output.info(msg))

  defp debug_skipped(skipped) do
    if Config.debug?() do
      Enum.each(skipped, fn {name, why} ->
        Output.info(line(%{name: name, version: "", detail: why}, "skip"))
      end)
    end
  end

  defp print_summary(report, total) do
    Output.info(
      "precompiled: #{report.hits} hit, #{report.misses} miss, #{report.fails} fail of #{total} deps, " <>
        "#{mb(report.bytes)} MB, #{Float.round(report.seconds, 1)} s"
    )
  end

  defp print_stripped(0), do: :ok

  defp print_stripped(n) do
    Output.info(
      "precompiled: #{n} hits carry stripped beams; protocols they define are not " <>
        "consolidated and Dialyzer has no types for them"
    )
  end

  # One conditional batch request on a warm run. The root is fetched only
  # when its check is due (hourly) or when the batch stops verifying under
  # the root in use (a rotation since the last check); never offline. Root
  # and batch together get :metadata_timeout_ms of the run's deadline.
  @doc false
  @spec fetch_batch(map()) :: {:ok, Trust.batch()} | {:error, String.t()}
  def fetch_batch(config) do
    meta =
      Map.update!(
        config,
        :deadline_at,
        &min(
          &1,
          System.monotonic_time(:millisecond) + Map.get(config, :metadata_timeout_ms, 15_000)
        )
      )

    offline? = Map.get(meta, :offline, false)
    fetch = &Fetch.get_conditional(meta, &1, &2)

    with {:ok, root, refreshed?} <- root_in_use(meta, offline?) do
      checked? = refreshed? or (not offline? and Trust.root_check_due?(meta))
      root = if checked? and not refreshed?, do: refresh_root(meta, root), else: root

      meta
      |> Trust.fetch_batch_cached(root, fetch)
      |> case do
        {:error, "batch signature invalid"} when not checked? and not offline? ->
          Trust.fetch_batch_cached(meta, refresh_root(meta, root), fetch)

        other ->
          other
      end
      |> source_down(config)
    end
  end

  # A cached batch stood in for an unreachable source: its manifests and
  # files are not asked of the source again this run.
  defp source_down({:ok, %{source_unreachable: true}} = result, config) do
    Fetch.source_unreachable(config)
    result
  end

  defp source_down(result, _config), do: result

  # The root in use. When it has expired (an offline bundle can adopt an
  # expired root into the same trust state), the TUF way: chain from it to
  # the served root first, and only then judge expiry, so an expired root
  # is never a dead end while the source serves a newer one.
  defp root_in_use(meta, offline?) do
    case Trust.load_root(meta) do
      {:ok, root} ->
        {:ok, root, false}

      {:error, _} = error when not offline? ->
        with {:ok, expired} <- Trust.load_root(meta, offline: true),
             _ = refresh_root(meta, expired),
             {:ok, root} <- Trust.load_root(meta) do
          {:ok, root, true}
        else
          _ -> error
        end

      error ->
        error
    end
  end

  defp refresh_root(config, root) do
    {:ok, root} =
      Trust.update_root(config, root, &Fetch.get_body(&1, Fetch.metadata_opts(config)))

    root
  end

  defp one(candidate, config, batch, env, config_fun) do
    %{name: name, version: version} = candidate
    sname = Atom.to_string(name)
    base = %{name: sname, version: version, bytes: 0}
    replacing? = Map.has_key?(candidate, :installed_hash)
    installed_sha = Map.get(candidate, :installed_sha)

    try do
      {sha, path} = manifest_ref(batch, sname)

      # A fresh candidate: Mix compiles it unless it is installed now, so a
      # provenance file left by an earlier install must not vouch for
      # Mix's own build.
      if not replacing?, do: _ = File.rm(Fetch.provenance_path(env.build_lib, name))

      result =
        with sha when is_binary(sha) <- sha || {:miss, "not in batch"},
             {:ok, manifest} <- Fetch.manifest(config, sname, sha, path),
             reads = scan_reads(config, env, sname, candidate.lock_entry),
             :ok <- scan_in_time(reads),
             {:ok, entry, _system_key} <-
               Match.select(manifest, ctx(candidate, env, config, config_fun, reads)) do
          provenance = %{
            sha: sha,
            path: path,
            sequence: batch.sequence,
            files_sha256: Match.files_hash(entry),
            source: Map.get(config, :source)
          }

          place(candidate, entry, provenance, config, env, config_fun)
        end

      result =
        result
        |> unreachable(replacing? and sha == installed_sha)
        |> verify_kept(candidate, env, config_fun)

      if replacing? and not stays?(result), do: _ = remove(env.build_lib, sname)
      line_for(base, result)
    rescue
      e ->
        if replacing?, do: _ = remove(env.build_lib, sname)
        crashed(base, Exception.message(e))
    catch
      kind, reason when kind in [:exit, :throw] ->
        if replacing?, do: _ = remove(env.build_lib, sname)
        crashed(base, inspect(reason))
    end
  end

  # An unchanged manifest the network could not deliver says nothing
  # against the installed build: kept, with a note. For anything else it is
  # a miss.
  defp unreachable({:unreachable, why}, true), do: {:kept_unchecked, why}
  defp unreachable({:unreachable, why}, false), do: {:miss, why}
  defp unreachable(result, _), do: result

  # A scan the run deadline cut short is like a manifest the network could
  # not deliver: it says nothing about the build either way.
  defp scan_in_time({:unscannable, "run deadline passed" = why}),
    do: {:unreachable, "source not scannable: " <> why}

  defp scan_in_time(_reads), do: :ok

  # Kept without a recheck, the installed .app is still read against
  # today's config, as keep/4 reads it for a rechecked build.
  defp verify_kept({:kept_unchecked, _} = kept, candidate, env, config_fun) do
    sname = Atom.to_string(candidate.name)
    app = Path.join([env.build_lib, sname, "ebin", sname <> ".app"])

    case verify_app(app, sname, candidate.version, config_fun) do
      :ok -> kept
      fail -> fail
    end
  end

  defp verify_kept(result, _candidate, _env, _config_fun), do: result

  # A replaced install that neither stayed nor hit is removed: Mix compiles
  # it.
  defp stays?(:kept), do: true
  defp stays?({:hit, _}), do: true
  defp stays?({:kept_unchecked, _}), do: true
  defp stays?(_), do: false

  defp crashed(base, why),
    do: Map.merge(base, %{status: :fail, detail: "candidate crashed: #{why}"})

  defp ctx(candidate, env, config, config_fun, reads) do
    {elixir, otp} = config.toolchain

    method =
      case Map.get(env, :build_methods, %{}) do
        {:unknown, why} -> %{unknown: why}
        methods -> Map.get(methods, candidate.name, %{})
      end

    %{
      name: Atom.to_string(candidate.name),
      version: candidate.version,
      lock_entry: candidate.lock_entry,
      lock: env.lock,
      system: env.system || {"host", ""},
      elixir: elixir,
      otp: otp,
      dep_env: Map.get(candidate, :dep_env, "prod"),
      config: config_fun,
      prefer: Map.get(candidate, :installed_hash),
      mix_target: Map.get(env, :mix_target, "host"),
      reads: reads,
      manager: Map.get(method, :manager),
      overrides: Map.get(method, :overrides, []),
      build_method_unknown: Map.get(method, :unknown)
    }
  end

  # What the dep's own sources read at compile time (SourceScan), from the
  # sources deps.get fetched; scanned only when a manifest is in hand, once
  # per package checksum, within the run deadline. No sources on disk: nil,
  # no rule. That fails open safely: Mix compiles a dep only from
  # deps/<dep>, so a project without it has not fetched its deps and its
  # build stops at Mix's own "dependency is not available" before
  # anything installed here is compiled into it.
  defp scan_reads(config, env, sname, {:hex, _, _, _, _, _, _, outer}) do
    dir = Path.join(env.deps_path, sname)

    if File.dir?(dir),
      do:
        Precompiled.SourceScan.cached(
          config.home,
          dir,
          outer,
          Map.get(config, :deadline_at)
        )
  end

  defp scan_reads(_config, _env, _sname, _lock_entry), do: nil

  # The selected build may be the one installed: then only its provenance
  # moves, once the disk is checked to hold exactly its files and its .app
  # is checked against today's config. Anything else installs as usual.
  # Under an unchanged manifest the disk is not re-hashed (the build was
  # checked when it was placed); the rules and the .app still are.
  defp place(%{installed_hash: hash} = candidate, entry, provenance, config, env, config_fun)
       when is_binary(hash) do
    same_manifest? = provenance.sha == Map.get(candidate, :installed_sha)

    # The hash equality only picks the build to compare against: whether
    # the disk holds it is installed_as?'s call, or, under an unchanged
    # manifest, the check made when it was placed. verify_app (in keep/4)
    # runs either way.
    if provenance.files_sha256 == hash and
         (same_manifest? or Fetch.installed_as?(env.build_lib, candidate.name, entry)),
       do: keep(candidate, provenance, env, config_fun),
       else: install(candidate, entry, provenance, config, env, config_fun)
  end

  defp place(candidate, entry, provenance, config, env, config_fun),
    do: install(candidate, entry, provenance, config, env, config_fun)

  defp keep(candidate, provenance, env, config_fun) do
    sname = Atom.to_string(candidate.name)
    app = Path.join([env.build_lib, sname, "ebin", sname <> ".app"])

    with :ok <- verify_app(app, sname, candidate.version, config_fun),
         :ok <- Fetch.write_provenance_file(env.build_lib, candidate.name, provenance) do
      :kept
    else
      {:error, reason} -> {:fail, "provenance write failed: #{inspect(reason)}"}
      fail -> fail
    end
  end

  defp install(candidate, entry, provenance, config, env, config_fun) do
    sname = Atom.to_string(candidate.name)

    with {:ok, stats} <-
           Fetch.install(config, candidate.name, entry, candidate.lock_entry, env.build_lib,
             deps_path: env.deps_path,
             provenance: provenance,
             verify_app: &verify_app(&1, sname, candidate.version, config_fun)
           ) do
      {:hit, Map.put(stats, :stripped, stripped?(Path.join(env.build_lib, sname), sname))}
    end
  end

  # A batch that carries the v2 map names the format-2 document; otherwise
  # the format-1 one, which Manifest translates.
  defp manifest_ref(%{manifests_v2: v2} = batch, name) when is_map(v2) do
    case v2[name] do
      nil -> {batch.manifests[name], "manifests"}
      sha -> {sha, "v2/manifests"}
    end
  end

  defp manifest_ref(batch, name), do: {batch.manifests[name], "manifests"}

  @doc false
  # Release-stripped beams (no debug_info chunk) still load and run, but
  # Mix cannot consolidate the protocols they define. Judged by the first
  # module the .app lists. The beam is read here and handed to beam_lib as
  # bytes: given a file name, beam_lib turns it into an atom on some error
  # paths, which raises for a name over 255 characters.
  @spec stripped?(Path.t(), String.t()) :: boolean()
  def stripped?(dir, name) do
    with {:ok, [{:application, _, props}]} <-
           :file.consult(String.to_charlist(Path.join([dir, "ebin", name <> ".app"]))),
         [first | _] <- Keyword.get(props, :modules, []),
         {:ok, bytes} <- File.read(Path.join([dir, "ebin", "#{first}.beam"])) do
      not match?({:ok, {_, [{:debug_info, _}]}}, :beam_lib.chunks(bytes, [:debug_info]))
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp line_for(_base, :kept), do: nil

  defp line_for(base, {:kept_unchecked, why}),
    do:
      Map.merge(base, %{
        status: :fail,
        detail: why <> " (installed build kept)",
        kept: true,
        note: true,
        why: why
      })

  defp line_for(base, {:hit, %{bytes: bytes, files: files, cached: cached} = stats}) do
    %{base | bytes: bytes}
    |> Map.merge(%{
      stripped: stats.stripped,
      status: :hit,
      detail: "#{mb(bytes)} MB#{if cached == files, do: ", cached", else: ""}"
    })
  end

  defp line_for(base, {:miss, why}), do: Map.merge(base, %{status: :miss, detail: why})
  defp line_for(base, {:fail, why}), do: Map.merge(base, %{status: :fail, detail: why})

  # Rule 7, second half: the manifest said the compile_env matches; the
  # downloaded .app is the authority. A manifest that lies still cannot
  # plant a mismatched build.
  defp verify_app(app_path, name, version, config_fun) do
    with :ok <- app_identity(app_path, name, version) do
      case Match.compile_env_from_app(app_path) do
        nil -> {:fail, "staged .app unreadable"}
        items -> Match.compile_env_ok(items, config_fun) |> as_fail()
      end
    end
  end

  # The .app must be the locked package's: same application, same version.
  defp app_identity(app_path, name, version) do
    case :file.consult(String.to_charlist(app_path)) do
      {:ok, [{:application, app, props}]} when is_atom(app) and is_list(props) ->
        vsn = if is_list(props[:vsn]), do: to_string(props[:vsn]), else: "nil"

        if Atom.to_string(app) == name and vsn == version,
          do: :ok,
          else: {:fail, "downloaded .app names #{app} #{vsn}"}

      _ ->
        {:fail, "staged .app unreadable"}
    end
  end

  defp as_fail(:ok), do: :ok
  defp as_fail({:miss, why}), do: {:fail, "downloaded .app: " <> why}

  defp candidates(deps, lock, except, tooling) do
    {c, s} = Enum.reduce(deps, {[], []}, &sort_candidate(&1, &2, lock, except, tooling))
    {Enum.reverse(c), Enum.reverse(s)}
  end

  defp sort_candidate(dep, {c, s}, lock, except, tooling) do
    cond do
      Match.candidate?(dep.name, lock, except, tooling) ->
        {[dep | c], s}

      dep.name in except ->
        {c, [{dep.name, "excepted"} | s]}

      Match.tooling?(Atom.to_string(dep.name)) or dep.name in (tooling || []) or
          dep.name in Match.nerves_children(lock) ->
        {c, [{dep.name, "tooling"} | s]}

      true ->
        {c, [{dep.name, "not a hex dep"} | s]}
    end
  end

  defp print(%{status: :hit} = l), do: Output.success(line(l, "HIT "))
  defp print(%{status: :miss} = l), do: Output.warning(line(l, "MISS"))
  defp print(%{status: :fail} = l), do: Output.error(line(l, "FAIL"))

  defp line(%{name: n, version: v, detail: d}, tag),
    do: "precompiled: #{n} #{v}#{pad(n, v)}  #{tag}  #{d}"

  defp pad(n, v), do: String.duplicate(" ", max(0, 34 - String.length("precompiled: #{n} #{v}")))
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp summarize(lines, ms) do
    count = fn s -> Enum.count(lines, &(&1.status == s)) end

    %{
      hits: count.(:hit),
      misses: count.(:miss),
      fails: count.(:fail),
      bytes: Enum.sum(Enum.map(lines, & &1.bytes)),
      seconds: ms / 1000,
      lines: Enum.map(lines, &Map.drop(&1, [:bytes, :stripped, :kept, :why, :note]))
    }
  end

  # The report is a convenience artifact, not the run's result: an
  # unwritable _build degrades to a warning rather than failing the step.
  defp write_report(build_lib, report) do
    dir = Path.join(build_lib, ".precompiled")

    json = %{
      "format" => 1,
      "hits" => report.hits,
      "misses" => report.misses,
      "fails" => report.fails,
      "bytes" => report.bytes,
      "seconds" => report.seconds,
      "lines" =>
        Enum.map(
          report.lines,
          &%{
            "name" => &1.name,
            "version" => &1.version,
            "status" => Atom.to_string(&1.status),
            "detail" => &1.detail
          }
        )
    }

    case FileUtil.write_atomic(Path.join(dir, "report.json"), :json.encode(json)) do
      :ok ->
        :ok

      {:error, reason} ->
        Output.warning("precompiled: could not write report.json: #{inspect(reason)}")
        :ok
    end
  end
end
