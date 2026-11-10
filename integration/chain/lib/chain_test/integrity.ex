# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Integrity do
  @moduledoc """
  Step 3: every file the client installed in `_build` has the sha256 named in
  a manifest whose bytes hash to what step 1's verified batch names.

  For each hit in the client's report, and for each dep `_build` shows the
  client installed (a `.mix/precompiled.json` provenance file) that
  the report does not call a hit (which is itself an `unreported:<dep>`
  `:disagreement`, and is checked at its locked version):

    1. The dep's provenance file (`.mix/precompiled.json`, written by
       the client's install) must name the manifest the verified batch
       names. A different one is checked against a fresh batch the harness
       verifies itself, newer than step 1's, that names exactly the
       recorded manifest: steps 2 to 4 run against that manifest and the
       result is `:rerun` when the files match, a `:disagreement` when they
       do not; the file's own batch number counts for nothing. Anything
       else is a `:disagreement`.
    2. The manifest is downloaded from `<source>/<dir>/<name>.json` and its
       bytes must hash to the verified sha. When they do not, it is
       `:rerun` only when a fresh verified batch newer than step 1's names
       exactly the served bytes; otherwise the source served bytes no
       verified batch vouches for (`:disagreement`).
    3. The report does not name the build a hit used, so the harness selects
       it as the client does: the builds of the locked version for
       `pure_elixir` or this target's system at the locked version, the
       running Elixir minor at or above the build's patch, the same OTP
       major, `dep_env` prod, the lock's package checksum, and the build's
       dep lock agreeing with the project's; then the client's ranking
       (closest Elixir patch, `pure_elixir` first, newest run). The
       client's `compile_env` rule is not repeated (it needs the fixture's
       config); if the installed files are some other build of the
       manifest, that is a `:disagreement` that names both builds, never a
       silent pass.
    4. Every file the selected build lists must be in `<build_lib>/<dep>/`
       as a regular file with that sha256, and nothing else may be in its
       `ebin/` or `priv/`. A `priv` symlink is accepted only for a build
       with no `priv` files and only to the fixture's `deps/<dep>/priv`,
       as the client links it. Any difference is a
       `:disagreement` naming the file.

  Never compared with the release image or the device: those rewrite and
  strip what was installed.
  """

  alias ChainTest.{HTTP, Lock, Result, Trust}

  @timeout_ms 60_000
  @shown_problems 5

  @doc """
  Whether `result` is a `:disagreement` caused only by the checked batch not
  naming what the client installed from (provenance, manifest bytes, or no
  manifest at all), rather than by the installed files. Carried in the
  result's `cause`, set by those three checks alone; never read from the
  detail, which quotes untrusted file names.
  """
  @spec batch_mismatch?(Result.t()) :: boolean()
  def batch_mismatch?(%Result{class: :disagreement, cause: :batch_mismatch}), do: true
  def batch_mismatch?(_), do: false

  @doc """
  Runs step 3. `trust` is step 1's info; `nil` leaves every hit not
  exercised. Optional: `:lock_path` (default the fixture's `mix.lock`, three
  levels above `build_lib`), `:system` (`{name, version}`, default
  `nerves_system_<target>` at its locked version), `:elixir`, `:otp`
  (default this VM's), `:deps_path` (default `deps` next to the lock),
  `:timeout_ms`, `:recheck` (a zero-arity function returning a fresh
  batch info the harness accepts, or `nil`; default
  `ChainTest.Trust.verified/1` against `source`, with `:trust_opts` merged
  into its config; called at most once per run).
  """
  @spec run(map()) :: [Result.t()]
  def run(%{build_lib: build_lib, report: report, trust: trust, source: source} = input) do
    hits = for %{"status" => "hit", "name" => n} = l <- lines(report), do: {n, l["version"]}
    reported = Enum.map(hits, &elem(&1, 0))
    unreported = installed(build_lib) -- reported

    flagged =
      for n <- unreported do
        result(
          "unreported:#{n}",
          :disagreement,
          "#{Path.join([build_lib, n, ".mix", "precompiled.json"])} says the client " <>
            "installed #{n}, but the client report does not call it a hit"
        )
      end

    deps = hits ++ Enum.map(unreported, &{&1, :locked})

    checked =
      cond do
        deps == [] ->
          [result("integrity", :not_exercised, "the client report has no hits to check")]

        trust == nil ->
          why = "step 1 could not trust a batch, so no manifest sha to check against"
          Enum.map(deps, fn {n, _} -> result("integrity:#{n}", :not_exercised, why) end)

        true ->
          case context(input, build_lib, String.trim_trailing(source, "/")) do
            {:ok, ctx} ->
              Enum.map(deps, fn {n, v} -> check(n, version(v, n, ctx), trust, ctx) end)

            {:error, why} ->
              Enum.map(deps, fn {n, _} -> result("integrity:#{n}", :not_exercised, why) end)
          end
      end

    checked ++ flagged
  end

  @doc "The deps in `build_lib` with the client's provenance file, sorted."
  @spec installed(Path.t()) :: [String.t()]
  def installed(build_lib) do
    build_lib
    |> Path.join("*/.mix/precompiled.json")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&(&1 |> Path.dirname() |> Path.dirname() |> Path.basename()))
    |> Enum.sort()
  end

  @typedoc """
  What build selection needs: the lock, the target's system
  (`{"host", ""}` selects `pure_elixir` builds only), Elixir and OTP.
  """
  @type selection :: %{
          lock: ChainTest.Lock.t(),
          system: {String.t(), String.t()},
          elixir: String.t(),
          otp: String.t()
        }

  @doc "Manifest bytes as a format-2 document (format 1 translated as the client does)."
  @spec normalize_manifest(binary()) :: {:ok, map()} | {:error, String.t()}
  def normalize_manifest(bytes) do
    case normalize(bytes) do
      {:ok, doc} -> {:ok, doc}
      {_class, _why} -> {:error, "not a format-1 or format-2 manifest"}
    end
  end

  @doc """
  The builds of `version` in `doc` the client could select for `selection`,
  best first by the client's ranking. The client's `compile_env` rule is not
  repeated (see the moduledoc).
  """
  @spec eligible_builds(map(), String.t(), String.t(), selection()) :: [map()]
  def eligible_builds(doc, name, version, selection) do
    doc
    |> version_builds(version)
    |> Enum.filter(&eligible?(&1, selection.lock[name], selection))
    |> Enum.sort_by(&rank(&1, selection))
  end

  defp version_builds(doc, version) do
    with %{} = versions <- doc["versions"],
         %{"builds" => builds} when is_list(builds) <- versions[version] do
      Enum.filter(builds, &is_map/1)
    else
      _ -> []
    end
  end

  defp version(:locked, name, ctx), do: Lock.hex_version(ctx.lock, name)

  defp version(vsn, _name, _ctx), do: vsn

  defp lines(%{"lines" => lines}) when is_list(lines), do: Enum.filter(lines, &is_map/1)
  defp lines(_), do: []

  defp context(input, build_lib, source) do
    lock_path = Map.get(input, :lock_path, Path.expand("../../../mix.lock", build_lib))

    case Lock.read(lock_path) do
      {:ok, lock} ->
        target =
          build_lib |> Path.dirname() |> Path.basename() |> String.replace_suffix("_dev", "")

        {:ok,
         %{
           build_lib: build_lib,
           source: source,
           lock: lock,
           system:
             Map.get_lazy(input, :system, fn -> Lock.system(lock, target) || {"host", ""} end),
           elixir: Map.get(input, :elixir, System.version()),
           otp: Map.get(input, :otp, System.otp_release()),
           timeout_ms: Map.get(input, :timeout_ms, @timeout_ms),
           deps_path: Map.get(input, :deps_path, Path.join(Path.dirname(lock_path), "deps")),
           recheck: once(Map.get_lazy(input, :recheck, fn -> default_recheck(input, source) end))
         }}

      {:error, why} ->
        {:error, "fixture lock #{lock_path} unreadable: #{why}"}
    end
  end

  # The full Trust verdict: an expired, stale or over-lifetime fresh batch
  # is no batch at all, so it can never make a rerun.
  defp default_recheck(input, source) do
    cfg = Map.merge(Map.get(input, :trust_opts, %{}), %{source: source})
    fn -> Trust.verified(cfg) end
  end

  # A fresh batch is fetched at most once per run, and only when needed.
  defp once(fun) do
    key = {__MODULE__, :recheck, make_ref()}

    fn ->
      case Process.get(key, :unset) do
        :unset -> tap(fun.(), &Process.put(key, &1))
        fresh -> fresh
      end
    end
  end

  # one hit

  defp check(name, version, trust, ctx) do
    check = "integrity:#{name}"

    {outcome, ms} =
      Result.timed(fn ->
        with {:ok, sha, dir} <- batch_ref(trust, name),
             {:ok, ref} <- provenance(name, sha, dir, trust, ctx) do
          name |> against(version, ref, ctx) |> under_rerun(ref.rerun)
        end
      end)

    case outcome do
      {:pass, entry, desc, nil} ->
        listed = entry_files(entry)
        result(check, :pass, "#{name} #{version}: #{length(listed)} files match #{desc}", ms)

      {:pass, entry, desc, rerun} ->
        listed = entry_files(entry)

        result(
          check,
          :rerun,
          "#{name} #{version}: #{rerun}; #{length(listed)} files match #{desc}",
          ms
        )

      {:batch_mismatch, detail} ->
        r = result(check, :disagreement, "#{name} #{version}: #{detail}", ms)
        %{r | cause: :batch_mismatch}

      {class, detail} ->
        result(check, class, "#{name} #{version}: #{detail}", ms)
    end
  end

  # Steps 2 to 4 against the manifest `ref` names.
  defp against(name, version, ref, ctx) do
    with {:ok, bytes} <- fetch(ctx, name, ref.dir),
         :ok <- manifest_hash(bytes, ref.sha, name, ref.batch, ctx),
         {:ok, manifest} <- normalize(bytes),
         {:ok, entry, desc} <- select(manifest, name, version, ctx) do
      {:pass, entry, desc, ref.rerun}
    end
  end

  # A hit checked against a fresh batch's manifest that does not come out
  # as a rerun keeps its class, but says it was checked under one.
  defp under_rerun({class, detail}, rerun)
       when is_binary(rerun) and class in [:not_exercised, :disagreement, :batch_mismatch],
       do: {class, "#{detail}; checked under a rerun: #{rerun}"}

  defp under_rerun(outcome, _rerun), do: outcome

  defp batch_ref(trust, name) do
    case Trust.manifest_sha(trust, name) do
      {sha, dir} ->
        {:ok, sha, dir}

      nil ->
        {:batch_mismatch,
         "the client reports a hit, but the verified batch #{trust.sequence} names no " <>
           "manifest for it"}
    end
  end

  # {:ok, ref}: the manifest to check the installed files against: step 1's,
  # or, when a fresh newer verified batch names the one the client recorded,
  # that one, with the rerun reason.
  defp provenance(name, sha, dir, trust, ctx) do
    path = Path.join([ctx.build_lib, name, ".mix", "precompiled.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"manifest_sha256" => recorded} = p} when is_binary(recorded) <-
           JSON.decode(bytes) do
      recorded_dir = p["manifest_path"]

      if recorded == sha and recorded_dir == dir do
        {:ok, %{sha: sha, dir: dir, batch: trust, rerun: nil}}
      else
        # The provenance file is the client's word; only a fresh batch the
        # harness verified itself can make a different manifest a rerun.
        fresh = ctx.recheck.()

        if newer?(fresh, trust) and Trust.manifest_sha(fresh, name) == {recorded, recorded_dir} do
          {:ok,
           %{
             sha: recorded,
             dir: recorded_dir,
             batch: fresh,
             rerun:
               "the client installed from manifest #{recorded}, which batch " <>
                 "#{fresh.sequence} names; step 1 verified batch #{trust.sequence}: " <>
                 "production moved; run again"
           }}
        else
          {:batch_mismatch,
           "provenance names manifest #{inspect(recorded)} under #{inspect(recorded_dir)}, " <>
             "the verified batch #{trust.sequence} names #{sha} under #{dir}, and no newer " <>
             "verified batch names the recorded one"}
        end
      end
    else
      _ -> {:disagreement, "the client reports a hit, but #{path} is missing or unreadable"}
    end
  end

  defp newer?(%{sequence: fresh}, %{sequence: step1}) when is_integer(fresh), do: fresh > step1
  defp newer?(_, _), do: false

  defp fetch(ctx, name, dir) do
    url = "#{ctx.source}/#{dir}/#{name}.json"

    case HTTP.get(url, ctx.timeout_ms) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, why} -> {:not_exercised, "manifest unavailable: #{why}"}
    end
  end

  defp manifest_hash(bytes, sha, name, trust, ctx) do
    got = sha256(bytes)

    if got == sha do
      :ok
    else
      fresh = ctx.recheck.()

      # A rerun only when a newer verified batch vouches for exactly the
      # bytes served; anything else is bytes no verified batch names.
      if newer?(fresh, trust) and match?({^got, _}, Trust.manifest_sha(fresh, name)) do
        {:rerun,
         "the manifest moved: batch #{fresh.sequence} names #{got}, step 1's batch " <>
           "#{trust.sequence} names #{sha}; run again"}
      else
        {:batch_mismatch,
         "the source served manifest bytes hashing to #{got}, the verified batch names #{sha}"}
      end
    end
  end

  # Format 2 as is; format 1 (versions => target => entry) translated as the
  # client does, with dep_env "prod".
  defp normalize(bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"format" => 2, "versions" => versions} = doc} when is_map(versions) ->
        {:ok, doc}

      {:ok, %{"versions" => versions} = doc}
      when is_map(versions) and not is_map_key(doc, "format") ->
        {:ok, %{"format" => 2, "versions" => Map.new(versions, &format1_version/1)}}

      _ ->
        {:disagreement, "the client accepted a manifest the harness cannot read"}
    end
  end

  defp format1_version({vsn, entries}) when is_map(entries) do
    builds =
      for {target, entry} <- entries, is_map(entry) do
        build = if is_map(entry["build"]), do: entry["build"], else: %{}

        entry
        |> Map.put("target", target)
        |> Map.put("build", Map.put_new(build, "dep_env", "prod"))
      end

    {vsn, %{"builds" => builds}}
  end

  defp format1_version({vsn, _}), do: {vsn, %{"builds" => []}}

  # selection

  defp select(manifest, name, version, ctx) do
    dir = Path.join(ctx.build_lib, name)
    builds = version_builds(manifest, version)

    case eligible_builds(manifest, name, version, ctx) do
      [] -> none_eligible(builds, dir, name, version, ctx)
      [selected | _] -> check_selected(selected, builds, dir, name, ctx)
    end
  end

  defp none_eligible(builds, dir, name, version, ctx) do
    installed =
      case Enum.find(builds, &(problems(&1, dir, name, ctx) == [])) do
        nil -> "the installed files match no build in it"
        b -> "the installed files are #{describe(b)}"
      end

    {:disagreement,
     "the manifest has no build of #{version} the harness finds eligible for " <>
       "#{system_name(ctx.system)}, Elixir #{ctx.elixir}, OTP #{ctx.otp}; #{installed}"}
  end

  defp check_selected(selected, builds, dir, name, ctx) do
    case problems(selected, dir, name, ctx) do
      [] ->
        {:ok, selected, describe(selected)}

      problems ->
        case Enum.find(builds -- [selected], &(problems(&1, dir, name, ctx) == [])) do
          nil -> files_differ(selected, problems)
          other -> other_build(selected, other)
        end
    end
  end

  defp files_differ(selected, problems) do
    shown = Enum.take(problems, @shown_problems)
    more = length(problems) - length(shown)

    {:disagreement,
     "#{length(problems)} files differ from #{describe(selected)}: " <>
       Enum.join(shown, "; ") <> if(more > 0, do: "; #{more} more", else: "")}
  end

  defp other_build(selected, other) do
    {:disagreement,
     "the installed files are #{describe(other)}, but the harness selects " <>
       "#{describe(selected)} (the harness does not repeat the client's " <>
       "compile_env rule)"}
  end

  defp system_name({"host", _}), do: "pure_elixir"
  defp system_name({name, vsn}), do: "#{name} #{vsn}"

  defp describe(build) do
    run_id = get_in(build, ["build", "run_id"])
    "build #{build["target"]} run #{run_id || "(no run id)"}"
  end

  defp eligible?(build, {:hex, _, _, _, _, declared, _, outer}, ctx) do
    b = if is_map(build["build"]), do: build["build"], else: %{}

    target_ok?(build["target"], b["system_version"], ctx.system) and
      elixir_ok?(b["elixir"], ctx.elixir) and b["otp"] == ctx.otp and b["dep_env"] == "prod" and
      b["package_checksum"] == outer and is_map(b["deps"]) and deps_ok?(b["deps"], ctx.lock) and
      declared_ok?(declared, b["deps"], ctx.lock)
  end

  defp eligible?(_build, _lock_entry, _ctx), do: false

  defp target_ok?("pure_elixir", _, _), do: true
  defp target_ok?(t, built, {t, project}), do: built == project
  defp target_ok?(_, _, _), do: false

  defp elixir_ok?(built, running) when is_binary(built) do
    with {:ok, b} <- Version.parse(built),
         {:ok, r} <- Version.parse(running) do
      b.major > 0 and {b.major, b.minor} == {r.major, r.minor} and Version.compare(r, b) != :lt
    else
      _ -> false
    end
  end

  defp elixir_ok?(_, _), do: false

  defp deps_ok?(deps, lock) do
    Enum.all?(deps, fn
      {name, %{"version" => v, "checksum" => c}} ->
        match?({:hex, _, ^v, _, _, _, _, ^c}, lock[name])

      _ ->
        false
    end)
  end

  defp declared_ok?(declared, built, lock) when is_list(declared) do
    Enum.all?(declared, fn {name, _req, _opts} ->
      name = to_string(name)
      not Map.has_key?(lock, name) or Map.has_key?(built, name)
    end)
  end

  defp declared_ok?(_, _, _), do: true

  # The client's ranking: closest Elixir patch at or below the running one,
  # pure_elixir before a system build, then the newest run id.
  defp rank(build, ctx) do
    {:ok, built} = Version.parse(build["build"]["elixir"])
    {:ok, running} = Version.parse(ctx.elixir)
    pure = if build["target"] == "pure_elixir", do: 0, else: 1
    {running.patch - built.patch, pure, inverted(build["build"]["run_id"])}
  end

  defp inverted(id) when is_binary(id), do: for(<<c <- id>>, do: -c) ++ [1]
  defp inverted(_), do: [2]

  # file comparison

  defp entry_files(entry) do
    Enum.filter(List.wrap(entry["ebin"]) ++ List.wrap(entry["priv"]), &is_map/1)
  end

  # Every difference between `build`'s file list and `<dep>/{ebin,priv}`.
  defp problems(build, dir, name, ctx) do
    listed = entry_files(build)
    paths = Enum.map(listed, & &1["path"])
    priv_listed? = Enum.any?(paths, &(is_binary(&1) and String.starts_with?(&1, "priv/")))

    listed_problems = Enum.flat_map(listed, &file_problem(&1, dir))
    {installed, layout} = installed(dir, priv_listed?, Path.join([ctx.deps_path, name, "priv"]))

    extra =
      for p <- installed -- paths, do: "#{inspect(p)}: in _build, not listed in the manifest"

    layout ++ listed_problems ++ extra
  end

  defp file_problem(%{"path" => path, "sha256" => sha}, dir) when is_binary(path) do
    if safe_path?(path) do
      full = Path.join(dir, path)

      case File.lstat(full) do
        {:ok, %{type: :regular}} ->
          got = sha256(File.read!(full))

          if got == sha,
            do: [],
            else: ["#{inspect(path)}: sha256 #{got} in _build, #{inspect(sha)} in the manifest"]

        {:ok, %{type: type}} ->
          ["#{inspect(path)}: a #{type} in _build, not a regular file"]

        {:error, _} ->
          ["#{inspect(path)}: listed in the manifest, missing from _build"]
      end
    else
      ["#{inspect(path)}: unsafe path in the manifest"]
    end
  end

  defp file_problem(entry, _dir), do: ["malformed manifest file entry #{inspect(entry)}"]

  defp safe_path?(path) do
    String.valid?(path) and not String.contains?(path, [<<0>>, "\\"]) and
      (String.starts_with?(path, "ebin/") or String.starts_with?(path, "priv/")) and
      Path.type(path) == :relative and ".." not in Path.split(path)
  end

  # {paths of every non-directory under ebin/ and priv/, layout problems}.
  # The only priv symlink the client makes (link_sources) points at the
  # dep's own `deps/<dep>/priv`, for a build that lists no priv files.
  defp installed(dir, priv_listed?, own_priv) do
    ebin = walk(dir, "ebin")
    priv = Path.join(dir, "priv")

    case File.lstat(priv) do
      {:ok, %{type: :directory}} ->
        {ebin ++ walk(dir, "priv"), []}

      {:ok, %{type: :symlink}} when not priv_listed? ->
        case priv_link(priv, own_priv) do
          :ok -> {ebin, []}
          {:error, why} -> {ebin, ["priv: a symlink in _build, #{why}"]}
        end

      {:ok, %{type: type}} ->
        {ebin, ["priv: a #{type} in _build, the manifest lists priv files"]}

      {:error, _} ->
        {ebin, []}
    end
  end

  # The link must resolve, symlink by symlink as the kernel does, to the
  # fixture's own `deps/<dep>/priv`, itself a real directory reached
  # through no symlink below the fixture root. Comparing expanded text is
  # not enough: a planted directory symlink or `..` in the link path, or a
  # `deps/<dep>/priv` that is itself a link, opens somewhere else.
  defp priv_link(priv, own_priv) do
    deps = Path.dirname(Path.dirname(own_priv))
    root = Path.dirname(deps)

    with {:root, {:ok, real_root}} <- {:root, realpath(root)},
         expected =
           Path.join([
             real_root,
             Path.basename(deps),
             Path.basename(Path.dirname(own_priv)),
             "priv"
           ]),
         {:own, {:ok, %{type: :directory}}} <- {:own, File.lstat(expected)},
         {:own, {:ok, ^expected}} <- {:own, realpath(expected)},
         {:link, {:ok, ^expected}} <- {:link, realpath(priv)} do
      :ok
    else
      {:root, {:error, why}} -> {:error, "the fixture root #{root} does not resolve: #{why}"}
      {:own, _} -> {:error, "#{own_priv} is not a real directory under the fixture root"}
      {:link, {:ok, real}} -> {:error, "resolves to #{real}, not to #{own_priv}"}
      {:link, {:error, why}} -> {:error, "does not resolve: #{why}"}
    end
  end

  @max_links 40

  # The real path of `path`: every symlink followed, component by
  # component, with a relative target resolved against the link's parent.
  # `{:error, reason}` on a missing component, an unreadable link or more
  # than 40 links. Never raises.
  defp realpath(path) do
    case if(Path.type(path) == :absolute, do: {:ok, "/"}, else: File.cwd()) do
      {:ok, base} -> resolve("/", Path.split(Path.join(base, path)), 0)
      {:error, why} -> {:error, "cwd: #{:file.format_error(why)}"}
    end
  end

  defp resolve(acc, [], _links), do: {:ok, acc}
  defp resolve(_acc, ["/" | rest], links), do: resolve("/", rest, links)
  defp resolve(acc, ["." | rest], links), do: resolve(acc, rest, links)
  defp resolve(acc, [".." | rest], links), do: resolve(Path.dirname(acc), rest, links)

  defp resolve(_acc, _rest, links) when links > @max_links,
    do: {:error, "more than #{@max_links} symlinks"}

  defp resolve(acc, [name | rest], links) do
    next = Path.join(acc, name)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(next) do
          {:ok, target} -> resolve(acc, Path.split(target) ++ rest, links + 1)
          {:error, why} -> {:error, "#{next}: #{:file.format_error(why)}"}
        end

      {:ok, _} ->
        resolve(next, rest, links)

      {:error, why} ->
        {:error, "#{next}: #{:file.format_error(why)}"}
    end
  end

  defp walk(dir, rel) do
    full = Path.join(dir, rel)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        case File.ls(full) do
          {:ok, names} -> Enum.flat_map(names, &walk(dir, Path.join(rel, &1)))
          {:error, _} -> [rel]
        end

      {:ok, _} ->
        [rel]

      {:error, _} ->
        []
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp result(check, class, detail, ms \\ 0),
    do: %Result{step: :integrity, check: check, class: class, detail: detail, ms: ms}
end
