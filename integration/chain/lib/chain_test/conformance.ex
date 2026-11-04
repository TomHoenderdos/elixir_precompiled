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
  (`ChainTest.Snapshot`; good for 24 hours), or loads the one a
  `--snapshot-dir` already holds (`ChainTest.Snapshot.obtain/1`: re-verified,
  under 24 hours old, same source, target and fixture lock, else the run is
  refused), and starts a reference mirror
  that serves it unchanged. Per case: a case that needs an older batch the
  snapshot lacks (`ChainTest.Snapshot.older/2`) is `:not_exercised`, "not
  testable here", and nothing runs; otherwise a mirror over the snapshot
  with the case's transform (two when its args say `mirrors: 2`: the second
  is started first, so the case mirror knows its URL); a fresh, empty client
  home (a private temp dir, removed after the case) and the case's
  `setup` in it (a failed setup fails the case, unbuilt); the fixture build
  (`ChainTest.Build`, `mix compile` for the target, that home, the client's
  source at the case's mirror, the case's `client_config`, an empty site
  config); step 3 (`ChainTest.Integrity`) against the snapshot's verified
  batch through the reference mirror, never the case's; step 4
  (`ChainTest.Compiled`); what the home and `_build` hold, for the case's
  `after`; then the case's verdict. A case that raises is a `:fail`
  verdict; the other cases still run. The snapshot is
  removed after the run unless it was taken into `--snapshot-dir`. A run
  that selects no case is refused (`setup`, `:not_exercised`).

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

  alias ChainTest.Conformance.{Case, Setup}
  alias ChainTest.Mirror.Transform
  alias ChainTest.Trust

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
    supported_target!(target)
    only = only!(opts[:only])

    %{
      target: target,
      source: String.trim_trailing(opts[:source] || CLI.default_source(), "/"),
      cases: Path.expand(opts[:cases] || Path.join(CLI.root(), "conformance/cases.exs")),
      only: only,
      snapshot_dir: opts[:snapshot_dir] && Path.expand(opts[:snapshot_dir]),
      report_dir: Path.expand(opts[:report_dir] || default_report_dir()),
      fixture_dir: Path.join(CLI.root(), "fixture")
    }
  end

  defp supported_target!(target) do
    unless target in Preflight.targets(),
      do: Mix.raise("unsupported target #{target}; supported: rpi4, rpi0_2\n" <> @usage)
  end

  defp only!(nil), do: nil

  defp only!(only) do
    case String.split(only, ",", trim: true) do
      [] -> Mix.raise("--only names no case\n" <> @usage)
      ids -> ids
    end
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
          snapshot: &Snapshot.obtain/1,
          build: &Build.run/1,
          integrity: &Integrity.run/1,
          compiled: &Compiled.run/1,
          mirror: &Mirror.start/2
        },
        steps
      )

    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    versions = Run.versions(%{})

    with {:ok, cases} <- Case.load(opts.cases),
         {:ok, cases} <- only(cases, opts.only),
         :ok <- selected(cases),
         {:ok, snap} <-
           s.snapshot.(%{
             source: opts.source,
             fixture_dir: opts.fixture_dir,
             target: opts.target,
             dir: opts.snapshot_dir
           }) do
      IO.puts("snapshot: #{snap.dir} (batch #{snap.sequence})")
      meta = meta(opts, snap, started_at, versions)

      try do
        {run_cases(cases, snap, opts, s, meta), meta}
      after
        # A snapshot this run took for itself is not kept; one in a
        # caller-given --snapshot-dir is.
        if opts.snapshot_dir == nil, do: File.rm_rf(snap.dir)
      end
    else
      {:error, why} -> {[setup(why)], meta(opts, nil, started_at, versions)}
    end
  end

  defp setup(why) do
    setup = %Result{step: :conformance, check: "setup", class: :not_exercised, detail: why}
    CLI.print(setup)
    setup
  end

  # A run of no case proves nothing: it must not exit 0.
  defp selected([_ | _]), do: :ok
  defp selected(_), do: {:error, "no case selected"}

  defp only(cases, nil), do: {:ok, cases}
  defp only(_cases, []), do: {:error, "--only names no case"}

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

    case s.mirror.(snap.dir, []) do
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

  # The mirrors are not linked to this process: they are always stopped here.
  defp run_case(c, run) do
    with :ok <- testable(c, run.snap),
         {:ok, mirrors} <- start_mirrors(c, run) do
      try do
        judge_case(c, run, mirrors)
      rescue
        e -> crashed(c, Exception.format(:error, e, __STACKTRACE__))
      catch
        kind, reason -> crashed(c, Exception.format(kind, reason, __STACKTRACE__))
      after
        Enum.each(mirrors, &Mirror.stop/1)
      end
    else
      {:not_exercised, why} ->
        verdict = %Result{step: :conformance, check: c.id, class: :not_exercised, detail: why}
        CLI.print(verdict)
        verdict
    end
  end

  # Every older batch the case's transform or setup needs is in the snapshot.
  defp testable(c, snap) do
    setup = if Map.has_key?(c, :setup), do: Setup.needs(c.setup), else: []

    missing =
      for name <- Enum.uniq(Transform.needs(c.transform) ++ setup),
          {:missing, why} <- [Snapshot.older(snap, name)],
          do: "the #{name} batch: #{why}"

    case missing do
      [] -> :ok
      _ -> {:not_exercised, "not testable here: " <> Enum.join(missing, "; ")}
    end
  end

  # `[case_mirror]` or `[case_mirror, second]`; the second is started first,
  # so the case mirror's transform knows where it is.
  defp start_mirrors(c, run) do
    start = fn mirror, second_url ->
      context = %{mirror: mirror, second_url: second_url, snapshot: run.snap}
      run.steps.mirror.(run.snap.dir, transform: Transform.fun(c.transform, context))
    end

    result =
      case Transform.mirrors(c.transform) do
        1 ->
          with {:ok, m} <- start.(1, nil), do: {:ok, [m]}

        2 ->
          with {:ok, second} <- start.(2, nil) do
            case start.(1, second.url) do
              {:ok, m} ->
                {:ok, [m, second]}

              error ->
                Mirror.stop(second)
                error
            end
          end
      end

    case result do
      {:ok, mirrors} -> {:ok, mirrors}
      {:error, why} -> {:not_exercised, "cannot start the case's mirror: #{inspect(why)}"}
    end
  end

  # A case that raised is a failure of that case; the other cases and the
  # summary report still run.
  defp crashed(c, why) do
    lines = why |> String.split("\n", trim: true) |> Enum.take(6) |> Enum.join(" | ")

    verdict = %Result{
      step: :conformance,
      check: c.id,
      class: :fail,
      detail: "the case crashed: " <> lines
    }

    CLI.print(verdict)
    verdict
  end

  defp judge_case(c, run, [mirror | _] = mirrors) do
    home = case_home()

    try do
      client = Map.get(c, :client_config) || %{}

      context = %{
        source: Map.get(client, :source, mirror.url),
        root: Map.get(client, :root, Trust.library_root_path()),
        mirrors: Enum.map(mirrors, & &1.url)
      }

      case setup(c, home, Map.put(run.snap, :case, context)) do
        :ok ->
          verdict = build_and_judge(c, run, mirrors, home, context)
          CLI.print(verdict)
          verdict

        {:error, why} ->
          verdict = %Result{
            step: :conformance,
            check: c.id,
            class: :fail,
            detail: "the case's setup failed, nothing was built: #{why}"
          }

          CLI.print(verdict)
          verdict
      end
    after
      File.rm_rf(home)
    end
  end

  defp setup(%{setup: setup}, home, snap), do: Setup.run(setup, home, snap)
  defp setup(_c, _home, _snap), do: :ok

  defp build_and_judge(c, run, [mirror | _] = mirrors, home, context) do
    %{opts: opts, steps: s, snap: snap} = run
    before = home_view(home, context)

    {rows, report, requests, tooling, observed} =
      try do
        {build_rows, build} =
          s.build.(%{
            fixture_dir: opts.fixture_dir,
            target: opts.target,
            source: mirror.url,
            home: home,
            home_prepared: true,
            client_config: Map.get(c, :client_config),
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

        observed = %{
          before: before,
          after: home_view(home, context),
          installed: installed(Path.join([opts.fixture_dir, "_build", "#{opts.target}_dev"]))
        }

        {build_rows ++ integrity ++ compiled, build.report, Mirror.requests(mirror),
         tooling(opts.fixture_dir, build.build_lib), observed}
      after
        Enum.each(mirrors, &Mirror.stop/1)
      end

    {:ok, _} = Report.write(opts.report_dir, "#{opts.target}-#{c.id}", rows, run.meta)

    Case.judge(c, %{
      rows: rows,
      report: report,
      requests: requests,
      snapshot: snap,
      hits: run.hits,
      tooling: tooling,
      observed: observed
    })
  end

  # A fresh, private client home for one case.
  defp case_home() do
    rand = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    home = Path.join(Path.expand(System.tmp_dir!()), "chain_conformance_home-" <> rand)
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    home
  end

  # The client state files and cache entries in `home` (see
  # `ChainTest.Conformance.Case.observed/0`), never following a symlink.
  defp home_view(home, context) do
    states =
      for path <- Path.wildcard(Path.join(home, "*/state"), match_dot: true),
          {:ok, %File.Stat{type: :regular}} <- [File.lstat(path)],
          into: %{},
          do: {Path.relative_to(path, home), read_or_error(path)}

    own =
      case Setup.state_dir(home, context.source, context.root) do
        {:ok, dir} -> {:ok, Path.relative_to(Path.join(dir, "state"), home)}
        {:error, why} -> {:error, why}
      end

    %{states: states, cache: MapSet.new(entries(home, "files")), own: own}
  end

  defp read_or_error(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, why} -> "(unreadable: #{:file.format_error(why)})"
    end
  end

  # Every path under `home/rel` (rel included when it exists), relative to
  # `home`; a symlink is listed, not followed.
  defp entries(home, rel) do
    path = Path.join(home, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        children =
          case File.ls(path) do
            {:ok, names} -> Enum.flat_map(Enum.sort(names), &entries(home, Path.join(rel, &1)))
            {:error, _} -> []
          end

        [rel | children]

      {:ok, _} ->
        [rel]

      {:error, _} ->
        []
    end
  end

  # The deps with a provenance file in the target's `_build` dir, by name;
  # one outside `lib/<dep>/.mix/` by its path.
  defp installed(build_dir) do
    build_lib = Path.join(build_dir, "lib")

    build_dir
    |> Path.join("**/.mix/elixir_precompiled.json")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn path ->
      case Path.split(Path.relative_to(path, build_lib)) do
        [dep, ".mix", "elixir_precompiled.json"] -> dep
        _ -> Path.relative_to(path, build_dir)
      end
    end)
    |> Enum.sort()
  end

  # The deps nerves pulls in, which the client leaves to nerves_bootstrap.
  defp tooling(fixture_dir, build_lib) do
    case Lock.read(Path.join(fixture_dir, "mix.lock")) do
      {:ok, lock} -> Lock.nerves_children(lock, build_lib)
      {:error, _} -> []
    end
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
