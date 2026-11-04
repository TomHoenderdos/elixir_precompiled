# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance do
  @moduledoc """
  `mix chain_conformance`: the client against a loopback mirror of the
  portal, one case at a time.

  A run loads the case file (`ChainTest.Conformance.Case`; a bad file stops
  the run before any download), takes a fresh snapshot
  (`ChainTest.Snapshot`; good for 24 hours) and starts a reference mirror
  that serves it unchanged. Per case: a mirror over the snapshot with the
  case's transform; the fixture build (`ChainTest.Build`, `mix compile` for
  the target, a fresh client home, the client's source at the case's
  mirror, an empty site config); step 3 (`ChainTest.Integrity`) against the
  snapshot's verified batch through the reference mirror, never the case's;
  step 4 (`ChainTest.Compiled`); then the case's verdict.

  Reports go to `report_dir`: per case `<target>-<id>-<stamp>.{md,json}`
  with every result as it came (their classes are what the case expects,
  not the run's verdict), and `<target>-conformance-<stamp>.{md,json}` with
  one verdict per case. The exit code is the verdicts'.
  """

  alias ChainTest.{
    Build,
    CLI,
    Compiled,
    Integrity,
    Lock,
    Mirror,
    Preflight,
    Report,
    Result,
    Run,
    Snapshot
  }

  alias ChainTest.Conformance.Case
  alias ChainTest.Mirror.Transform

  @project_app "chain_fixture"
  @switches [
    target: :string,
    source: :string,
    cases: :string,
    only: :string,
    snapshot_dir: :string,
    report_dir: :string
  ]
  @usage "usage: mix chain_conformance [--target rpi4|rpi0_2] [--cases PATH] [--only ID,ID] " <>
           "[--source URL] [--snapshot-dir DIR] [--report-dir DIR]"

  @type opts :: %{
          target: String.t(),
          source: String.t(),
          cases: Path.t(),
          only: [String.t()] | nil,
          snapshot_dir: Path.t() | nil,
          report_dir: Path.t(),
          fixture_dir: Path.t()
        }
  @type steps :: %{optional(atom()) => function()}

  @doc "Parses `argv`; raises `Mix.Error` with the usage line."
  @spec parse!([String.t()]) :: opts()
  def parse!(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("unexpected arguments\n" <> @usage)

    target = opts[:target] || "rpi4"

    unless target in Preflight.targets(),
      do: Mix.raise("unsupported target #{target}; supported: rpi4, rpi0_2\n" <> @usage)

    %{
      target: target,
      source: String.trim_trailing(opts[:source] || CLI.default_source(), "/"),
      cases: Path.expand(opts[:cases] || Path.join(CLI.root(), "conformance/cases.exs")),
      only: opts[:only] && String.split(opts[:only], ",", trim: true),
      snapshot_dir: opts[:snapshot_dir] && Path.expand(opts[:snapshot_dir]),
      report_dir: Path.expand(opts[:report_dir] || default_report_dir()),
      fixture_dir: Path.join(CLI.root(), "fixture")
    }
  end

  @doc "Parses `argv`, runs every case, writes the verdict report; returns the exit code."
  @spec main([String.t()]) :: 0 | 1
  def main(argv) do
    opts = parse!(argv)
    {verdicts, meta} = run(opts)
    {:ok, %{md: md}} = Report.write(opts.report_dir, "#{opts.target}-conformance", verdicts, meta)
    IO.puts("report: #{md}")
    Result.exit_code(verdicts)
  end

  @doc "Runs the cases (see the moduledoc); returns the verdicts and the report's meta."
  @spec run(opts(), steps()) :: {[Result.t()], map()}
  def run(opts, steps \\ %{}) do
    s =
      Map.merge(
        %{
          snapshot: &Snapshot.take/1,
          build: &Build.run/1,
          integrity: &Integrity.run/1,
          compiled: &Compiled.run/1
        },
        steps
      )

    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    versions = Run.versions(%{})

    with {:ok, cases} <- Case.load(opts.cases),
         {:ok, cases} <- only(cases, opts.only),
         {:ok, snap} <-
           s.snapshot.(%{
             source: opts.source,
             fixture_dir: opts.fixture_dir,
             target: opts.target,
             dir: opts.snapshot_dir
           }) do
      IO.puts("snapshot: #{snap.dir} (batch #{snap.sequence})")
      meta = meta(opts, snap, started_at, versions)
      {run_cases(cases, snap, opts, s, meta), meta}
    else
      {:error, why} -> {[setup(why)], meta(opts, nil, started_at, versions)}
    end
  end

  defp setup(why) do
    setup = %Result{step: :conformance, check: "setup", class: :not_exercised, detail: why}
    CLI.print(setup)
    setup
  end

  defp only(cases, nil), do: {:ok, cases}

  defp only(cases, ids) do
    case ids -- Enum.map(cases, & &1.id) do
      [] ->
        {:ok, Enum.filter(cases, &(&1.id in ids))}

      unknown ->
        {:error, "--only names cases the file does not have: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp run_cases(cases, snap, opts, s, meta) do
    File.mkdir_p!(opts.report_dir)
    site = Path.join(opts.report_dir, "fixture-site.exs")

    File.write!(
      site,
      "# A conformance build only compiles: no network or ssh config.\nimport Config\n"
    )

    case Mirror.start(snap.dir) do
      {:ok, ref} ->
        try do
          run = run_state(snap, ref, site, opts, s, meta)
          Enum.map(cases, &run_case(&1, run))
        after
          Mirror.stop(ref)
        end

      {:error, why} ->
        [setup("cannot serve the snapshot #{snap.dir}: #{inspect(why)}")]
    end
  end

  defp run_state(snap, ref, site, opts, s, meta) do
    %{
      snap: snap,
      ref: ref,
      site: site,
      hits: Build.expected(opts.fixture_dir).hits,
      opts: opts,
      steps: s,
      meta: meta
    }
  end

  # The mirror is not linked to this process: it is always stopped here.
  defp run_case(c, run) do
    case Mirror.start(run.snap.dir, transform: Transform.fun(c.transform)) do
      {:ok, mirror} ->
        judge_case(c, run, mirror)

      {:error, why} ->
        verdict = %Result{
          step: :conformance,
          check: c.id,
          class: :not_exercised,
          detail: "cannot start the case's mirror: #{inspect(why)}"
        }

        CLI.print(verdict)
        verdict
    end
  end

  defp judge_case(c, run, mirror) do
    %{opts: opts, steps: s, snap: snap} = run

    {rows, report, requests} =
      try do
        {build_rows, build} =
          s.build.(%{
            fixture_dir: opts.fixture_dir,
            target: opts.target,
            source: mirror.url,
            trust: snap.info,
            target_config: run.site,
            command: ["compile"]
          })

        integrity =
          s.integrity.(%{
            build_lib: build.build_lib,
            report: build.report,
            trust: snap.info,
            source: run.ref.url,
            recheck: fn -> nil end
          })

        compiled =
          s.compiled.(%{
            build_lib: build.build_lib,
            report: build.report,
            allowlist: Compiled.allowlist(@project_app)
          })

        {build_rows ++ integrity ++ compiled, build.report, Mirror.requests(mirror)}
      after
        Mirror.stop(mirror)
      end

    {:ok, _} = Report.write(opts.report_dir, "#{opts.target}-#{c.id}", rows, run.meta)

    verdict =
      Case.judge(c, %{
        rows: rows,
        report: report,
        requests: requests,
        snapshot: snap,
        hits: run.hits
      })

    CLI.print(verdict)
    verdict
  end

  @doc false
  @spec meta(opts() | map(), Snapshot.t() | nil, DateTime.t(), map()) :: map()
  def meta(opts, snap, started_at, versions) do
    lock =
      case Lock.read(Path.join(opts.fixture_dir, "mix.lock")) do
        {:ok, lock} -> lock
        {:error, _} -> %{}
      end

    %{
      batch_sequence_step1: snap && snap.sequence,
      batch_sequence_step2: nil,
      root_version: snap && snap.info.root_version,
      client_commit: versions[:client_commit],
      nerves_commit: versions[:nerves_commit] || Lock.git_ref(lock, "nerves"),
      elixir: System.version(),
      otp: System.otp_release(),
      system_version:
        case Lock.system(lock, opts.target) do
          {name, vsn} -> "#{name} #{vsn}"
          nil -> nil
        end,
      started_at: started_at,
      known_gaps: Report.known_gaps()
    }
  end

  defp default_report_dir() do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(Path.expand(System.tmp_dir!()), "chain_conformance-" <> stamp)
  end
end
