# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Integrity do
  @moduledoc """
  Step 3: every file the client installed in `_build` has the sha256 named in
  a manifest whose bytes hash to what step 1's verified batch names.

  For each hit in the client's report:

    1. The dep's provenance file (`.mix/elixir_precompiled.json`, written by
       the client's install) must name the manifest the verified batch
       names. A different one is `:rerun` only when a fresh batch the
       harness verifies itself, newer than step 1's, names exactly the
       recorded manifest; the file's own batch number counts for nothing.
       Anything else is a `:disagreement`.
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

  alias ChainTest.{HTTP, Result, Trust}

  @timeout_ms 60_000
  @shown_problems 5

  @type files :: %{String.t() => [%{path: String.t(), sha256: String.t()}]}

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
  verified batch info, default `ChainTest.Trust.check/1` against `source`;
  called at most once per run).

  Returns the results and, per dep whose files all matched, the manifest's
  `[%{path, sha256}]`.
  """
  @spec run(map()) :: {[Result.t()], files()}
  def run(%{build_lib: build_lib, report: report, trust: trust, source: source} = input) do
    hits = for %{"status" => "hit", "name" => n} = l <- lines(report), do: {n, l["version"]}

    cond do
      hits == [] ->
        {[result("integrity", :not_exercised, "the client report has no hits to check")], %{}}

      trust == nil ->
        why = "step 1 could not trust a batch, so no manifest sha to check against"
        {Enum.map(hits, fn {n, _} -> result("integrity:#{n}", :not_exercised, why) end), %{}}

      true ->
        case context(input, build_lib, String.trim_trailing(source, "/")) do
          {:ok, ctx} ->
            checked = Enum.map(hits, fn {n, v} -> check(n, v, trust, ctx) end)
            results = Enum.map(checked, &elem(&1, 0))
            files = for {_, {n, f}} <- checked, into: %{}, do: {n, f}
            {results, files}

          {:error, why} ->
            {Enum.map(hits, fn {n, _} -> result("integrity:#{n}", :not_exercised, why) end), %{}}
        end
    end
  end

  defp lines(%{"lines" => lines}) when is_list(lines), do: Enum.filter(lines, &is_map/1)
  defp lines(_), do: []

  defp context(input, build_lib, source) do
    lock_path = Map.get(input, :lock_path, Path.expand("../../../mix.lock", build_lib))

    case read_lock(lock_path) do
      {:ok, lock} ->
        target =
          build_lib |> Path.dirname() |> Path.basename() |> String.replace_suffix("_dev", "")

        {:ok,
         %{
           build_lib: build_lib,
           source: source,
           lock: lock,
           system: Map.get_lazy(input, :system, fn -> system(lock, target) end),
           elixir: Map.get(input, :elixir, System.version()),
           otp: Map.get(input, :otp, System.otp_release()),
           timeout_ms: Map.get(input, :timeout_ms, @timeout_ms),
           deps_path: Map.get(input, :deps_path, Path.join(Path.dirname(lock_path), "deps")),
           recheck:
             once(Map.get(input, :recheck, fn -> elem(Trust.check(%{source: source}), 1) end))
         }}

      {:error, why} ->
        {:error, "fixture lock #{lock_path} unreadable: #{why}"}
    end
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

  # Read as Mix reads it (mix.lock quotes its keys). String keys, so names
  # from a manifest never become atoms.
  defp read_lock(path) do
    quoted =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path, emit_warnings: false)

    case Code.eval_quoted(quoted, [], file: path, emit_warnings: false) do
      {lock, _} when is_map(lock) -> {:ok, Map.new(lock, fn {k, v} -> {to_string(k), v} end)}
      _ -> {:error, "not a map"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp system(lock, target) do
    name = "nerves_system_#{target}"

    case lock[name] do
      {:hex, _, vsn, _, _, _, _, _} -> {name, vsn}
      _ -> {"host", ""}
    end
  end

  # one hit

  defp check(name, version, trust, ctx) do
    check = "integrity:#{name}"

    {outcome, ms} =
      Result.timed(fn ->
        with {:ok, sha, dir} <- batch_ref(trust, name),
             :ok <- provenance(name, sha, dir, trust, ctx),
             {:ok, bytes} <- fetch(ctx, name, dir),
             :ok <- manifest_hash(bytes, sha, name, trust, ctx),
             {:ok, manifest} <- normalize(bytes),
             {:ok, entry, desc} <- select(manifest, name, version, ctx) do
          {:pass, entry, desc}
        end
      end)

    case outcome do
      {:pass, entry, desc} ->
        listed = entry_files(entry)

        {result(check, :pass, "#{name} #{version}: #{length(listed)} files match #{desc}", ms),
         {name, Enum.map(listed, &%{path: &1["path"], sha256: &1["sha256"]})}}

      {:batch_mismatch, detail} ->
        r = result(check, :disagreement, "#{name} #{version}: #{detail}", ms)
        {%{r | cause: :batch_mismatch}, nil}

      {class, detail} ->
        {result(check, class, "#{name} #{version}: #{detail}", ms), nil}
    end
  end

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

  defp provenance(name, sha, dir, trust, ctx) do
    path = Path.join([ctx.build_lib, name, ".mix", "elixir_precompiled.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"manifest_sha256" => recorded} = p} when is_binary(recorded) <-
           JSON.decode(bytes) do
      recorded_dir = p["manifest_path"]

      if recorded == sha and recorded_dir == dir do
        :ok
      else
        # The provenance file is the client's word; only a fresh batch the
        # harness verified itself can make a different manifest a rerun.
        fresh = ctx.recheck.()

        if newer?(fresh, trust) and Trust.manifest_sha(fresh, name) == {recorded, recorded_dir} do
          {:rerun,
           "the client installed from manifest #{recorded}, which batch #{fresh.sequence} " <>
             "names; step 1 verified batch #{trust.sequence}: production moved; run again"}
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
    builds = manifest |> get_in(["versions", version, "builds"]) |> List.wrap()
    builds = Enum.filter(builds, &is_map/1)
    lock_entry = ctx.lock[name]
    eligible = Enum.filter(builds, &eligible?(&1, lock_entry, ctx))

    case eligible do
      [] ->
        installed =
          case Enum.find(builds, &(problems(&1, dir, name, ctx) == [])) do
            nil -> "the installed files match no build in it"
            b -> "the installed files are #{describe(b)}"
          end

        {:disagreement,
         "the manifest has no build of #{version} the harness finds eligible for " <>
           "#{system_name(ctx.system)}, Elixir #{ctx.elixir}, OTP #{ctx.otp}; #{installed}"}

      _ ->
        selected = Enum.min_by(eligible, &rank(&1, ctx))

        case problems(selected, dir, name, ctx) do
          [] ->
            {:ok, selected, describe(selected)}

          problems ->
            case Enum.find(builds -- [selected], &(problems(&1, dir, name, ctx) == [])) do
              nil ->
                shown = Enum.take(problems, @shown_problems)
                more = length(problems) - length(shown)

                {:disagreement,
                 "#{length(problems)} files differ from #{describe(selected)}: " <>
                   Enum.join(shown, "; ") <> if(more > 0, do: "; #{more} more", else: "")}

              other ->
                {:disagreement,
                 "the installed files are #{describe(other)}, but the harness selects " <>
                   "#{describe(selected)} (the harness does not repeat the client's " <>
                   "compile_env rule)"}
            end
        end
    end
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
