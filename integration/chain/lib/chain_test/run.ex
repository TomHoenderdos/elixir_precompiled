# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Run do
  @moduledoc """
  The whole chain test, in order: preflight, trust (step 1), build (2),
  integrity (3), compiled here (4), deploy (5), on the device (6), then the
  report.

  A failing preflight stops the run before anything is built (`run/aborted`,
  not exercised). Steps 2 to 4 run whatever step 1 found, so a client that
  installs from a batch the harness rejects is caught. Step 6 runs only when
  step 5 left the device on the uploaded firmware; it probes every hit the
  client reports.

  Two checks belong to the run rather than to one step:

    * `build/sequence` - the client's batch sequence (from its state file)
      usually differs from step 1's: batches come every 15 to 30 minutes and
      a build takes minutes. When it differs, the harness fetches
      `batches/<client sequence>.json` itself and runs the same trust checks
      on it (reported as `trust/client_batch:<check>`). If it verifies and
      names that sequence, the check passes and step 3 runs against that
      batch. Only when it is unavailable (an HTTP error status, a transport
      error, a timeout) and step 1 verified a batch is the check, with the
      client batch's rows and step 3's batch-mismatch disagreements,
      `:rerun`. A client batch the harness fetched and rejects (signature,
      threshold, format, dates, another sequence) fails the check and its
      rows, and the client verdict below becomes a `:disagreement` when the
      client installed anything from it.
    * `trust/client_verdict` - the harness's own verdict on the batch the
      client used against the client's: a batch the harness rejects but the
      client installed from, or one the harness verified but the client
      refused, is a `:disagreement`.

  Reports go to `opts.report_dir` (outside the repository by default) as
  `<target>-<timestamp>.md` and `.json`.
  """

  alias ChainTest.{
    Build,
    CLI,
    Cmd,
    Compiled,
    Deploy,
    Device,
    Integrity,
    Lock,
    Preflight,
    Report,
    Result,
    Trust
  }

  @project_app "chain_fixture"
  @repo_root Path.expand("../../../..", __DIR__)

  @type steps :: %{optional(atom()) => function()}

  @doc "Parses `argv`, runs the chain test, writes the report; returns the exit code."
  @spec main([String.t()]) :: 0 | 1
  def main(argv), do: argv |> CLI.parse!() |> main_with(%{})

  @doc """
  `main/1` with parsed options and, for tests, step functions replacing the
  real ones (`:preflight`, `:trust`, `:build`, `:integrity`, `:compiled`,
  `:deploy`, `:device`, `:versions`).
  """
  @spec main_with(CLI.opts(), steps()) :: 0 | 1
  def main_with(opts, steps) do
    {results, meta} = run(opts, steps)
    {:ok, %{md: md}} = Report.write(opts.report_dir, opts.target, results, meta)
    IO.puts("report: #{md}")
    Result.exit_code(results)
  end

  @doc "Runs every step; returns the results and the report's meta."
  @spec run(CLI.opts(), steps()) :: {[Result.t()], map()}
  def run(opts, steps \\ %{}) do
    s = Map.merge(default_steps(), steps)
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    lock = lock_info(opts)
    versions = s.versions.(opts)

    meta = %{
      batch_sequence_step1: nil,
      batch_sequence_step2: nil,
      root_version: nil,
      client_commit: versions[:client_commit],
      nerves_commit: versions[:nerves_commit] || lock.nerves_commit,
      elixir: System.version(),
      otp: System.otp_release(),
      system_version: system_text(lock.system),
      started_at: started_at,
      known_gaps: Report.known_gaps()
    }

    pre = emit(s.preflight.(opts))

    if Result.exit_code(pre) == 1 do
      aborted =
        result(:run, "aborted", :not_exercised, "preflight failed; nothing built or deployed")

      {pre ++ emit([aborted]), meta}
    else
      chain(opts, s, lock, pre, meta)
    end
  end

  defp chain(opts, s, lock, pre, meta) do
    {trust_results, step1} = s.trust.(%{source: opts.source})
    emit(trust_results)

    {build_results, build} =
      s.build.(%{
        fixture_dir: opts.fixture_dir,
        target: opts.target,
        source: opts.source,
        trust: step1,
        target_config: opts.target_config
      })

    %{sequence: seq, used: used, results: client_batch, harness: harness} =
      reconcile(s, opts, step1, trust_results, build.sequence)

    build_results = replace_sequence(build_results, seq)
    emit(client_batch)
    emit(build_results)
    verdict = emit([client_verdict(harness, build.report)])

    integrity =
      s.integrity.(%{
        build_lib: build.build_lib,
        report: build.report,
        trust: used,
        source: opts.source
      })

    integrity =
      if match?(%Result{class: :rerun}, seq), do: rerun_mismatches(integrity), else: integrity

    emit(integrity)

    compiled =
      emit(
        s.compiled.(%{
          build_lib: build.build_lib,
          report: build.report,
          allowlist: Compiled.allowlist(@project_app)
        })
      )

    {deploy, %{expected_uuid: uuid}} =
      s.deploy.(%{
        device: opts.device,
        known_hosts: opts.known_hosts,
        fw_path: build.fw_path,
        target: opts.target
      })

    emit(deploy)

    {apps, unprobeable} = probe_apps(build.report)

    device =
      if landed?(deploy) do
        unprobeable ++
          s.device.(%{
            device: opts.device,
            known_hosts: opts.known_hosts,
            apps: apps,
            release_dir: Path.join(Path.dirname(build.build_lib), "rel/#{@project_app}"),
            expected_uuid: uuid,
            system: lock.system
          })
      else
        [
          result(
            :device,
            "probe",
            :not_exercised,
            "the device is not running the uploaded firmware"
          )
        ]
      end

    emit(device)

    results =
      pre ++
        trust_results ++
        client_batch ++
        verdict ++ build_results ++ integrity ++ compiled ++ deploy ++ device

    meta = %{
      meta
      | batch_sequence_step1: step1 && step1.sequence,
        batch_sequence_step2: build.sequence,
        root_version: step1 && step1.root_version
    }

    {results, meta}
  end

  defp default_steps() do
    %{
      preflight: &Preflight.run/1,
      trust: &Trust.check/1,
      build: &Build.run/1,
      integrity: &Integrity.run/1,
      compiled: &Compiled.run/1,
      deploy: &Deploy.run/1,
      device: &Device.run/1,
      versions: &versions/1
    }
  end

  defp emit(results) do
    Enum.each(results, &CLI.print/1)
    results
  end

  # Every hit the client reports is probed, not only the expected ones; a
  # name that is not an app name cannot be, which is a failure.
  defp probe_apps(report) do
    hits =
      for %{"status" => "hit", "name" => n} <- Map.get(report || %{}, "lines", []),
          is_binary(n),
          uniq: true,
          do: n

    {apps, bad} = Enum.split_with(hits, &Device.app_name?/1)

    {apps,
     Enum.map(bad, fn n ->
       result(
         :device,
         "app:#{inspect(n)}",
         :fail,
         "the client reports a hit #{inspect(n)}, " <>
           "which is not an app name the probe can load"
       )
     end)}
  end

  defp landed?(deploy),
    do: Enum.any?(deploy, &match?(%Result{check: "active_uuid", class: :pass}, &1))

  # batch sequence

  defp reconcile(_s, _opts, step1, step1_results, nil),
    do: %{sequence: nil, used: step1, results: [], harness: verdict(step1, step1_results)}

  defp reconcile(_s, _opts, %{sequence: sequence} = step1, step1_results, client)
       when sequence == client,
       do: %{sequence: nil, used: step1, results: [], harness: verdict(step1, step1_results)}

  defp reconcile(s, opts, step1, _step1_results, client) do
    path = "batches/#{client}.json"
    {results, info} = s.trust.(%{source: opts.source, batch_path: path})
    tagged = client_batch_results(results)
    named = info != nil and info.sequence == client

    unavailable? =
      Enum.any?(results, &match?(%Result{check: "batch_signature", cause: :unavailable}, &1))

    case verdict(info, results) do
      {:accepted, _} when named ->
        client_batch_accepted(step1, client, path, info, tagged)

      # Only a batch the harness could not fetch means production moved
      # out from under it; one it fetched and rejects is the client
      # installing from a bad batch.
      {:rejected, why} when unavailable? and step1 != nil ->
        client_batch_unavailable(step1, client, path, why, tagged)

      other ->
        client_batch_rejected(step1, client, path, info, other, tagged)
    end
  end

  defp client_batch_accepted(step1, client, path, info, tagged) do
    %{
      sequence:
        result(
          :build,
          "sequence",
          :pass,
          "the client used batch #{client} (#{step1_text(step1)}); the harness verified " <>
            "#{path} itself and checks step 3 against it"
        ),
      used: info,
      results: tagged,
      harness: {:accepted, "batch #{client}"}
    }
  end

  defp client_batch_unavailable(step1, client, path, why, tagged) do
    %{
      sequence:
        result(
          :build,
          "sequence",
          :rerun,
          "step 1 verified batch #{step1.sequence}, the client used #{client}, and " <>
            "#{path} is unavailable: #{why}; run again"
        ),
      used: step1,
      results: Enum.map(tagged, &rerun_row/1),
      harness: :unknown
    }
  end

  defp client_batch_rejected(step1, client, path, info, verdict, tagged) do
    why =
      case verdict do
        {:accepted, _} -> "#{path} names sequence #{info.sequence}, not #{client}"
        {:rejected, why} -> why
      end

    %{
      sequence:
        result(
          :build,
          "sequence",
          :fail,
          "the client used batch #{client} (#{step1_text(step1)}), which the harness " <>
            "rejects: #{why}"
        ),
      used: step1,
      results: tagged,
      harness: {:rejected, "#{path}: #{why}"}
    }
  end

  defp step1_text(nil), do: "step 1 verified none"
  defp step1_text(step1), do: "step 1 verified batch #{step1.sequence}"

  # Production moved past step 1's batch to one the harness could not verify:
  # the client batch's checks say why, but it is a rerun, not a failure.
  defp rerun_row(%Result{class: :pass} = r), do: r
  defp rerun_row(%Result{} = r), do: %{r | class: :rerun}

  # Under a rerun Integrity checked step 1's batch, not the client's; a
  # disagreement from that mismatch alone is part of the rerun. One about the
  # installed files stays a disagreement.
  defp rerun_mismatches(results) do
    Enum.map(results, fn r ->
      if Integrity.batch_mismatch?(r),
        do: %{
          r
          | class: :rerun,
            detail: "checked against step 1's batch, not the client's: " <> r.detail
        },
        else: r
    end)
  end

  # The batch checks of the client's batch, under their own names.
  defp client_batch_results(results) do
    for %Result{check: "batch_" <> _} = r <- results, do: %{r | check: "client_batch:" <> r.check}
  end

  # The harness's verdict on a batch: every trust check passed (a served
  # root other than the pinned one is only a miss).
  defp verdict(nil, results), do: {:rejected, first_problem(results)}

  defp verdict(_info, results) do
    case Enum.reject(results, &(&1.class == :pass or &1.check == "served_root")) do
      [] -> {:accepted, "batch"}
      _ -> {:rejected, first_problem(results)}
    end
  end

  defp first_problem(results) do
    case Enum.find(results, &(&1.class not in [:pass, :miss])) do
      nil -> "no batch"
      r -> "#{r.check}: #{r.detail}"
    end
  end

  defp replace_sequence(build_results, nil), do: build_results

  defp replace_sequence(build_results, seq) do
    if Enum.any?(build_results, &(&1.check == "sequence")),
      do: Enum.map(build_results, &if(&1.check == "sequence", do: seq, else: &1)),
      else: build_results ++ [seq]
  end

  # client verdict

  defp client_verdict(harness, report) do
    lines =
      case report do
        %{"lines" => lines} when is_list(lines) -> Enum.filter(lines, &is_map/1)
        _ -> nil
      end

    if lines == nil do
      result(:trust, "client_verdict", :not_exercised, "the client wrote no report")
    else
      hits = for %{"status" => "hit", "name" => n} <- lines, do: n
      # A revoked build is refused under a good batch by design; Build
      # reports it as :refused already.
      refused =
        for %{"detail" => d} = l <- lines,
            Build.refusal?(d),
            not String.starts_with?(d, "revoked:"),
            do: "#{l["name"]}: #{d}"

      judge(harness, hits, refused)
    end
  end

  defp judge(:unknown, _hits, _refused) do
    result(
      :trust,
      "client_verdict",
      :rerun,
      "the harness could not verify the batch the client used; run again"
    )
  end

  defp judge({:accepted, what}, _hits, [first | _] = refused) do
    result(
      :trust,
      "client_verdict",
      :disagreement,
      "the harness verified #{what}, but the client refused #{length(refused)}: #{first}"
    )
  end

  defp judge({:rejected, why}, [_ | _] = hits, _refused) do
    result(
      :trust,
      "client_verdict",
      :disagreement,
      "the harness rejects the batch (#{why}), but the client installed " <>
        "#{length(hits)} from it: #{Enum.join(hits, ", ")}"
    )
  end

  defp judge({:accepted, what}, hits, []) do
    result(
      :trust,
      "client_verdict",
      :pass,
      "the harness and the client both accept #{what}; #{length(hits)} installed"
    )
  end

  defp judge({:rejected, why}, [], refused) do
    result(
      :trust,
      "client_verdict",
      :pass,
      "the harness rejects the batch (#{why}) and the client installed nothing " <>
        "(#{length(refused)} refused)"
    )
  end

  # versions and the fixture lock

  @doc false
  @spec versions(CLI.opts()) :: map()
  def versions(_opts) do
    nerves =
      case System.get_env("CHAIN_NERVES_PATH") do
        nil -> nil
        path -> with sha when is_binary(sha) <- git_head(path), do: sha <> " (CHAIN_NERVES_PATH)"
      end

    %{client_commit: git_head(@repo_root), nerves_commit: nerves}
  end

  defp git_head(dir) do
    case Cmd.run("git", ["-C", dir, "rev-parse", "HEAD"], timeout_ms: 10_000) do
      {0, out} ->
        sha = String.trim(out)

        case Cmd.run("git", ["-C", dir, "status", "--porcelain"], timeout_ms: 10_000) do
          {0, ""} -> sha
          {0, _} -> sha <> "-dirty"
          _ -> sha
        end

      _ ->
        nil
    end
  end

  defp lock_info(opts) do
    lock =
      case Lock.read(Path.join(opts.fixture_dir, "mix.lock")) do
        {:ok, lock} -> lock
        {:error, _} -> %{}
      end

    %{system: Lock.system(lock, opts.target), nerves_commit: Lock.git_ref(lock, "nerves")}
  end

  defp system_text({name, vsn}), do: "#{name} #{vsn}"
  defp system_text(nil), do: nil

  defp result(step, check, class, detail),
    do: %Result{step: step, check: check, class: class, detail: detail}
end
