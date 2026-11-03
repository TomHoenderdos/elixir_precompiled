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
       names. A different one from a later batch is `:rerun`, from the same
       batch a `:disagreement`.
    2. The manifest is downloaded from `<source>/<dir>/<name>.json` and its
       bytes must hash to the verified sha. When they do not, a fresh batch
       is checked: if it names another manifest for the dep, production
       moved (`:rerun`); otherwise the source served bytes the batch does
       not vouch for (`:disagreement`).
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
       `ebin/` or `priv/` (a `priv` symlink to the dep's sources is what the
       client makes for a build with no `priv` files). Any difference is a
       `:disagreement` naming the file.

  Never compared with the release image or the device: those rewrite and
  strip what was installed.
  """

  alias ChainTest.{HTTP, Result, Trust}

  @timeout_ms 60_000
  @shown_problems 5

  @type files :: %{String.t() => [%{path: String.t(), sha256: String.t()}]}

  @doc """
  Runs step 3. `trust` is step 1's info; `nil` leaves every hit not
  exercised. Optional: `:lock_path` (default the fixture's `mix.lock`, three
  levels above `build_lib`), `:system` (`{name, version}`, default
  `nerves_system_<target>` at its locked version), `:elixir`, `:otp`
  (default this VM's), `:timeout_ms`, `:recheck` (a zero-arity function
  returning a fresh verified batch info, default `ChainTest.Trust.check/1`
  against `source`).

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
           recheck: Map.get(input, :recheck, fn -> elem(Trust.check(%{source: source}), 1) end)
         }}

      {:error, why} ->
        {:error, "fixture lock #{lock_path} unreadable: #{why}"}
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
             :ok <- provenance(ctx.build_lib, name, sha, dir, trust.sequence),
             {:ok, bytes} <- fetch(ctx, name, dir),
             :ok <- manifest_hash(bytes, sha, name, ctx),
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

      {class, detail} ->
        {result(check, class, "#{name} #{version}: #{detail}", ms), nil}
    end
  end

  defp batch_ref(trust, name) do
    case Trust.manifest_sha(trust, name) do
      {sha, dir} ->
        {:ok, sha, dir}

      nil ->
        {:disagreement,
         "the client reports a hit, but the verified batch #{trust.sequence} names no manifest"}
    end
  end

  defp provenance(build_lib, name, sha, dir, sequence) do
    path = Path.join([build_lib, name, ".mix", "elixir_precompiled.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"manifest_sha256" => recorded} = p} when is_binary(recorded) <-
           JSON.decode(bytes) do
      cond do
        recorded == sha and p["manifest_path"] == dir ->
          :ok

        p["batch_sequence"] != sequence ->
          {:rerun,
           "provenance names manifest #{recorded} from batch #{inspect(p["batch_sequence"])}, " <>
             "step 1 verified batch #{sequence}: production moved; run again"}

        true ->
          {:disagreement,
           "provenance names manifest #{recorded} under #{inspect(p["manifest_path"])}, " <>
             "the verified batch #{sequence} names #{sha} under #{dir}"}
      end
    else
      _ -> {:disagreement, "the client reports a hit, but #{path} is missing or unreadable"}
    end
  end

  defp fetch(ctx, name, dir) do
    url = "#{ctx.source}/#{dir}/#{name}.json"

    case HTTP.get(url, ctx.timeout_ms) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, why} -> {:not_exercised, "manifest unavailable: #{why}"}
    end
  end

  defp manifest_hash(bytes, sha, name, ctx) do
    got = sha256(bytes)

    if got == sha do
      :ok
    else
      fresh = ctx.recheck.()

      case fresh && Trust.manifest_sha(fresh, name) do
        {other, _} when other != sha ->
          {:rerun,
           "the manifest moved: batch #{fresh.sequence} names #{other}, step 1's names #{sha}; " <>
             "run again"}

        _ ->
          {:disagreement,
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
          case Enum.find(builds, &(problems(&1, dir) == [])) do
            nil -> "the installed files match no build in it"
            b -> "the installed files are #{describe(b)}"
          end

        {:disagreement,
         "the manifest has no build of #{version} the harness finds eligible for " <>
           "#{system_name(ctx.system)}, Elixir #{ctx.elixir}, OTP #{ctx.otp}; #{installed}"}

      _ ->
        selected = Enum.min_by(eligible, &rank(&1, ctx))

        case problems(selected, dir) do
          [] ->
            {:ok, selected, describe(selected)}

          problems ->
            case Enum.find(builds -- [selected], &(problems(&1, dir) == [])) do
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
  defp problems(build, dir) do
    listed = entry_files(build)
    paths = Enum.map(listed, & &1["path"])
    priv_listed? = Enum.any?(paths, &(is_binary(&1) and String.starts_with?(&1, "priv/")))

    listed_problems = Enum.flat_map(listed, &file_problem(&1, dir))
    {installed, layout} = installed(dir, priv_listed?)

    extra =
      for p <- installed -- paths, do: "#{p}: in _build, not listed in the manifest"

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
            else: ["#{path}: sha256 #{got} in _build, #{inspect(sha)} in the manifest"]

        {:ok, %{type: type}} ->
          ["#{path}: a #{type} in _build, not a regular file"]

        {:error, _} ->
          ["#{path}: listed in the manifest, missing from _build"]
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
  defp installed(dir, priv_listed?) do
    ebin = walk(dir, "ebin")

    case File.lstat(Path.join(dir, "priv")) do
      {:ok, %{type: :directory}} ->
        {ebin ++ walk(dir, "priv"), []}

      {:ok, %{type: :symlink}} when not priv_listed? ->
        {ebin, []}

      {:ok, %{type: type}} ->
        {ebin, ["priv: a #{type} in _build, the manifest lists priv files"]}

      {:error, _} ->
        {ebin, []}
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
