# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Check do
  @moduledoc false
  # The shared engine: every candidate becomes a HIT, MISS or FAIL line with
  # a reason; the same list lands in `<build_lib>/.precompiled/report.json`.

  alias ElixirPrecompiled.{CompileEnv, Config, Env, Fetch, Match, Output, Trust}

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

    if candidates == [] do
      debug("precompiled: no dependencies to check")
      :nothing_to_do
    else
      debug_skipped(skipped)
      config_fun = Keyword.get(opts, :config_fun, &CompileEnv.lookup/2)
      lines = lines_for(candidates, config, env, config_fun)
      Enum.each(lines, &print/1)
      report = summarize(lines, System.monotonic_time(:millisecond) - started)
      print_summary(report, length(lines))
      print_stripped(Enum.count(lines, &Map.get(&1, :stripped, false)))
      write_report(env.build_lib, report)
      {:ok, report}
    end
  end

  defp lines_for(candidates, config, env, config_fun) do
    case batch(config) do
      {:ok, batch} ->
        candidates
        |> Task.async_stream(&one(&1, config, batch, env, config_fun),
          max_concurrency: 8,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.map(fn {:ok, line} -> line end)

      {:error, why} ->
        Enum.map(
          candidates,
          &%{
            name: Atom.to_string(&1.name),
            version: &1.version,
            status: :fail,
            detail: why,
            bytes: 0
          }
        )
    end
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
         %{name: name, version: version, lock_entry: lock_entry},
         config,
         batch,
         env,
         config_fun
       ) do
    sname = Atom.to_string(name)
    base = %{name: sname, version: version, bytes: 0}

    {sha, path} = manifest_ref(batch, sname)

    try do
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
                 config: config_fun
               }),
             {:ok, stats} <-
               Fetch.install(config, name, entry, lock_entry, env.build_lib,
                 deps_path: env.deps_path,
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
      lines: Enum.map(lines, &Map.drop(&1, [:bytes, :stripped]))
    }
  end

  # The report is a convenience artifact, not the run's result: an
  # unwritable _build degrades to a warning rather than failing the step.
  defp write_report(build_lib, report) do
    dir = Path.join(build_lib, ".precompiled")

    json = %{
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

    final = Path.join(dir, "report.json")
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, :json.encode(json)),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, reason} ->
        Output.warning("precompiled: could not write report.json: #{inspect(reason)}")
        :ok
    end
  end
end
