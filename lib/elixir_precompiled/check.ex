# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Check do
  @moduledoc false
  # The shared engine: every candidate becomes a HIT, MISS or FAIL line with
  # a reason; the same list lands in `<build_lib>/.precompiled/report.json`.

  alias ElixirPrecompiled.{CompileEnv, Config, Env, Fetch, FileUtil, Match, Output, Trust}

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

  @spec check(map(), Env.t(), keyword()) :: :nothing_to_do | {:ok, report()}
  def check(config, %Env{} = env, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    {candidates, skipped} = candidates(env.candidates, env.lock, config.except)

    {excepted, installed} = installed(env, config.except)

    if candidates == [] and installed == [] and excepted == [] do
      debug("precompiled: no dependencies to check")
      :nothing_to_do
    else
      config = with_home(config, env)
      debug_skipped(skipped)
      config_fun = Keyword.get(opts, :config_fun, &CompileEnv.lookup/2)

      lines =
        except_lines(excepted, env) ++ lines_for(candidates, installed, config, env, config_fun)

      # Installs kept on a refused or missing batch are one warning, not a
      # FAIL line each: an offline warm build is a correct build. The
      # report still lists them.
      {kept, shown} = Enum.split_with(lines, &Map.get(&1, :kept, false))
      Enum.each(shown, &print/1)
      print_kept(kept)
      ms = System.monotonic_time(:millisecond) - started
      report = summarize(lines, ms)
      # A warm build whose installs the batch still names has nothing to say.
      if shown != [], do: print_summary(summarize(shown, ms), length(shown))
      print_stripped(Enum.count(lines, &Map.get(&1, :stripped, false)))
      # Nothing to say also means nothing to record: keep the last report.
      if lines != [], do: write_report(env.build_lib, report)
      {:ok, report}
    end
  end

  @doc false
  # The home must take writes (trust state, cache). One that cannot (none
  # at all, read-only, or a pre-seeded CI cache) moves to _build for this
  # run; its files/ stay readable as :ro_home.
  @spec with_home(map(), Env.t()) :: map()
  def with_home(config, env) do
    home = config.home

    if is_binary(home) and FileUtil.writable_dir?(home) do
      config
    else
      fallback = Path.join([env.build_lib, ".precompiled", "home"])
      Output.warning("precompiled: cache dir #{inspect(home)} is not writable; using #{fallback}")
      Map.merge(config, %{home: fallback, ro_home: home})
    end
  end

  # Nothing left that needs the batch (only excepted installs): no fetch.
  defp lines_for([], [], _config, _env, _config_fun), do: []

  defp lines_for(candidates, installed, config, env, config_fun) do
    case batch(config) do
      {:ok, batch} ->
        {revoked, replaced} = recheck(installed, batch, env)

        revoked ++ install_lines(candidates ++ replaced, config, batch, env, config_fun)

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
    |> Enum.filter(&Match.candidate?(&1.name, env.lock, []))
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
  # it. Same manifest sha: nothing to do. Another sha: matched again like
  # any candidate, its old bytes removed first so a miss leaves Mix to
  # compile it. Not named, or no readable provenance: removed, so Mix
  # compiles it from source in this same run.
  defp recheck(installed, batch, env) do
    Enum.reduce(installed, {[], []}, fn dep, {revoked, replaced} ->
      {sha, _path} = manifest_ref(batch, Atom.to_string(dep.name))

      case recheck_one(dep, sha, provenance_sha(env.build_lib, dep.name), env) do
        :keep -> {revoked, replaced}
        :replace -> {revoked, replaced ++ [dep]}
        line -> {revoked ++ [line], replaced}
      end
    end)
  end

  defp recheck_one(_dep, sha, sha, _env) when is_binary(sha), do: :keep

  defp recheck_one(dep, sha, recorded, env) when is_binary(sha) and is_binary(recorded),
    do: revoke(dep, env, :replace)

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

  defp revoke_line(dep, status, detail),
    do: %{
      name: Atom.to_string(dep.name),
      version: dep.version,
      status: status,
      detail: detail,
      bytes: 0
    }

  defp provenance_sha(build_lib, dep) do
    with {:ok, bytes} <- File.read(Fetch.provenance_path(build_lib, dep)),
         %{"manifest_sha256" => sha} when is_binary(sha) <- decode_json(bytes) do
      sha
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

  defp install_lines(candidates, config, batch, env, config_fun) do
    candidates
    |> Task.async_stream(&one(&1, config, batch, env, config_fun),
      max_concurrency: 8,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, line} -> line end)
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

  defp batch(config) do
    with {:ok, root} <- Trust.load_root(config),
         {:ok, root} <- Trust.update_root(config, root, &Fetch.get_body/1) do
      Trust.fetch_batch(config, root, &Fetch.get_body/1)
    end
  end

  defp one(
         %{name: name, version: version, lock_entry: lock_entry} = candidate,
         config,
         batch,
         env,
         config_fun
       ) do
    sname = Atom.to_string(name)
    base = %{name: sname, version: version, bytes: 0}

    {sha, path} = manifest_ref(batch, sname)

    try do
      # Mix compiles this dep unless it is installed now: a provenance file
      # left by an earlier install would vouch for Mix's own build.
      _ = File.rm(Fetch.provenance_path(env.build_lib, name))

      result =
        with sha when is_binary(sha) <- sha || {:miss, "not in batch"},
             {:ok, manifest} <- Fetch.manifest(config, sname, sha, path),
             {:ok, entry, _system_key} <-
               Match.select(manifest, %{
                 name: sname,
                 version: version,
                 lock_entry: lock_entry,
                 lock: env.lock,
                 system: env.system || {"host", ""},
                 elixir: System.version(),
                 otp: to_string(:erlang.system_info(:otp_release)),
                 dep_env: Map.get(candidate, :dep_env, "prod"),
                 config: config_fun
               }),
             {:ok, stats} <-
               Fetch.install(config, name, entry, lock_entry, env.build_lib,
                 deps_path: env.deps_path,
                 provenance: %{sha: sha, path: path, sequence: batch.sequence},
                 verify_app: &verify_app(&1, sname, version, config_fun)
               ) do
          {:hit, Map.put(stats, :stripped, stripped?(Path.join(env.build_lib, sname), sname))}
        end

      line_for(base, result)
    rescue
      e ->
        %{
          name: sname,
          version: version,
          bytes: 0,
          status: :fail,
          detail: "candidate crashed: #{Exception.message(e)}"
        }
    catch
      kind, reason when kind in [:exit, :throw] ->
        %{
          name: sname,
          version: version,
          bytes: 0,
          status: :fail,
          detail: "candidate crashed: #{inspect(reason)}"
        }
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

  # Release-stripped beams (no debug_info chunk) still load and run, but
  # Mix cannot consolidate the protocols they define. Judged by the first
  # module the .app lists.
  defp stripped?(dir, name) do
    with {:ok, [{:application, _, props}]} <-
           :file.consult(String.to_charlist(Path.join([dir, "ebin", name <> ".app"]))),
         [first | _] <- Keyword.get(props, :modules, []) do
      beam = Path.join([dir, "ebin", "#{first}.beam"])

      not match?(
        {:ok, {_, [{:debug_info, _}]}},
        :beam_lib.chunks(String.to_charlist(beam), [:debug_info])
      )
    else
      _ -> false
    end
  end

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

  # Rule 5, second half: the manifest said the compile_env matches; the
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

  defp candidates(deps, lock, except) do
    {c, s} = Enum.reduce(deps, {[], []}, &sort_candidate(&1, &2, lock, except))
    {Enum.reverse(c), Enum.reverse(s)}
  end

  defp sort_candidate(dep, {c, s}, lock, except) do
    cond do
      Match.candidate?(dep.name, lock, except) ->
        {[dep | c], s}

      dep.name in except ->
        {c, [{dep.name, "excepted"} | s]}

      Match.tooling?(Atom.to_string(dep.name)) or dep.name in Match.nerves_children(lock) ->
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
      lines: Enum.map(lines, &Map.drop(&1, [:bytes, :stripped, :kept, :why]))
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
