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
  refused), and starts a reference mirror that serves it unchanged. Per
  case: a case that needs something the snapshot lacks
  (`ChainTest.Snapshot.available/2`: an older batch, say) is
  `:not_testable`, "not testable here", decided from snapshot facts alone,
  and nothing runs; it does not fail the run. An older batch the snapshot
  could not fetch makes the case `:not_exercised`, and one the source
  served but that does not verify a `:fail`. Otherwise a mirror over the
  snapshot with the case's transform (two when its args say `mirrors: 2`:
  the second is started first, so the case mirror knows its URL); a fresh,
  empty client home (a private temp dir, removed after the case) and the
  case's `setup` in it (a failed setup fails the case, unbuilt); the
  fixture build (`ChainTest.Build`, `mix compile` for the target, that
  home, the client's source at the case's mirror, the case's
  `client_config` and `client_env` (a `{:home, rel}` path resolved under
  that home), an empty site config); step 3 (`ChainTest.Integrity`)
  against the snapshot's verified
  batch through the reference mirror, never the case's; step 4
  (`ChainTest.Compiled`); what the home and `_build` hold, for the case's
  `after`; then the case's verdict. A case that raises is a `:fail`
  verdict; the other cases still run. The snapshot is
  removed after the run unless it was taken into `--snapshot-dir`. A run
  that selects no case is refused (`setup`, `:not_exercised`).

  Layer 2 (`ChainTest.Conformance.Case.layer2?/1`, a case pinned to a test
  root): when the run selects one, `ChainTest.TestKey.prepare/1` makes
  throwaway keys and a test-signed copy of the snapshot (in a private tmp
  dir, removed after the run), and every layer-2 case runs against that
  copy instead: its mirror serves it, its build and step 3 trust its batch,
  and its `{:test_root, name}` root is that test root's path. The control
  `L2-T0` (selected whenever a layer-2 case is) runs first; unless it
  passes, the client is not shown to take the test root, and every other
  layer-2 case is `:not_exercised`, as they all are when the copy cannot be
  made. A case with a `gate` runs only once that earlier case passed, else
  it is `:not_exercised` too. The verdicts keep the case file's order. A real-root case fails
  when its home or client config shows a test root (a state dir named for
  one, a file naming a test key id, a root path among the test material);
  a layer-2 case fails when its home holds a state dir named for the real
  root.

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

  alias ChainTest.Conformance.{Case, Clock, Setup}
  alias ChainTest.Mirror.Transform
  alias ChainTest.{TestKey, Trust}

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
          mirror: &Mirror.start/2,
          layer2: &TestKey.prepare/2
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

  # A selected case brings its gates along, and a layer-2 one the control.
  defp only(cases, ids) do
    case ids -- Enum.map(cases, & &1.id) do
      [] ->
        wanted = with_gates(MapSet.new(ids), Map.new(cases, &{&1.id, &1}))
        control? = Enum.any?(cases, &(&1.id in wanted and Case.layer2?(&1)))
        {:ok, Enum.filter(cases, &(&1.id in wanted or (control? and Case.control?(&1))))}

      unknown ->
        {:error, "--only names cases the file does not have: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp with_gates(ids, by_id) do
    more =
      for id <- ids, gate = Case.gate(by_id[id]), gate not in ids, into: MapSet.new(), do: gate

    if MapSet.size(more) == 0, do: ids, else: with_gates(MapSet.union(ids, more), by_id)
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
        layer2 =
          if Enum.any?(cases, &Case.layer2?/1), do: s.layer2.(snap, opts.fixture_dir), else: nil

        try do
          run = run_state(snap, ref, site, opts, s, meta)
          run = Map.put(run, :layer2, material(layer2))
          by_id = run_in_order(cases, layer2, run)
          Enum.map(cases, &Map.fetch!(by_id, &1.id))
        after
          with {:ok, l2} <- layer2, do: TestKey.cleanup(l2)
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

  defp material({:ok, l2}), do: l2
  defp material(_layer2), do: nil

  # Real-root cases first, then the layer-2 control, then the other
  # layer-2 cases, each in file order; a case runs only when what it
  # depends on passed (see the moduledoc). The verdicts by id.
  defp run_in_order(cases, layer2, run) do
    {real, test} = Enum.split_with(cases, &(not Case.layer2?(&1)))
    {control, rest} = Enum.split_with(test, &Case.control?/1)

    Enum.reduce(real ++ control ++ rest, %{}, fn c, done ->
      verdict =
        case blocked(c, layer2, done) do
          nil -> run_case(c, run_for(c, layer2, run))
          why -> not_exercised(c, why)
        end

      Map.put(done, c.id, verdict)
    end)
  end

  defp run_for(c, {:ok, l2}, run),
    do: if(Case.layer2?(c), do: %{run | snap: l2.snapshot}, else: run)

  defp run_for(_c, _layer2, run), do: run

  defp blocked(c, layer2, done) do
    control = Case.control_id()

    cond do
      Case.layer2?(c) and match?({:error, _}, layer2) ->
        {:error, why} = layer2
        "the test-key snapshot could not be prepared: #{why}"

      Case.layer2?(c) and not Case.control?(c) and not passed?(done, control) ->
        "the layer-2 control #{control} did not pass (#{class(done, control)}): the client is " <>
          "not shown to take the test root, so no test-key case can say anything"

      (gate = Case.gate(c)) && not passed?(done, gate) ->
        "its gate #{gate} did not pass (#{class(done, gate)}): without that positive " <>
          "control this case says nothing"

      true ->
        nil
    end
  end

  defp passed?(done, id), do: match?(%Result{class: :pass}, done[id])
  defp class(done, id), do: if(r = done[id], do: r.class, else: "not run")

  defp not_exercised(c, why) do
    verdict = %Result{step: :conformance, check: c.id, class: :not_exercised, detail: why}
    CLI.print(verdict)
    verdict
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
      {class, why} when class in [:not_testable, :not_exercised, :fail] ->
        verdict = %Result{step: :conformance, check: c.id, class: class, detail: why}
        CLI.print(verdict)
        verdict
    end
  end

  # The snapshot has everything the case's transform or setup needs.
  defp testable(c, snap) do
    setup = if Map.has_key?(c, :setup), do: Setup.needs(c.setup), else: []

    lacking =
      for name <- Enum.uniq(Transform.needs(c.transform) ++ setup),
          {kind, why} <- [Snapshot.available(snap, name)],
          do: {kind, why}

    # The worst wins: a source that served a bad batch is a finding, one
    # that could not be asked proves nothing, and only an absent batch is
    # merely not testable here.
    by = fn kind -> for {^kind, why} <- lacking, do: why end

    cond do
      by.(:invalid) != [] ->
        {:fail,
         "the snapshot's source served an older batch that does not verify: " <>
           Enum.join(by.(:invalid), "; ")}

      by.(:unavailable) != [] ->
        {:not_exercised,
         "could not fetch what the case needs: " <>
           Enum.join(by.(:unavailable), "; ")}

      lacking != [] ->
        {:not_testable, "not testable here: " <> Enum.join(by.(:missing), "; ")}

      true ->
        :ok
    end
  end

  # `[case_mirror]` or `[case_mirror, second]`; the second is started first,
  # so the case mirror's transform knows where it is.
  defp start_mirrors(c, run) do
    start = fn mirror, second_url ->
      context = %{mirror: mirror, second_url: second_url, snapshot: run.snap}

      run.steps.mirror.(
        run.snap.dir,
        [transform: Transform.fun(c.transform, context)] ++ Transform.mirror_opts(c.transform)
      )
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
      client = test_root(Map.get(c, :client_config), run) || %{}

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

  # A `runs: 2` case first builds cold, served unchanged by the reference
  # mirror, in a home of its own that is removed afterwards; its build is
  # then the warm `_build` the case's own build starts from. A warm build
  # that did not install every expected hit leaves nothing to judge.
  defp build_and_judge(c, run, mirrors, home, context) do
    case warm_build(c, run) do
      :ok ->
        judged_build(c, run, mirrors, home, context)

      {:error, why} ->
        %Result{
          step: :conformance,
          check: c.id,
          class: :fail,
          detail: "the warm build, before the case's own, did not install: #{why}"
        }
    end
  end

  defp warm_build(c, run) do
    if Case.runs(c) == 2, do: cold_build(run), else: :ok
  end

  defp cold_build(%{opts: opts, steps: s, snap: snap} = run) do
    home = case_home()

    try do
      {rows, _build} =
        s.build.(%{
          fixture_dir: opts.fixture_dir,
          target: opts.target,
          source: run.ref.url,
          home: home,
          home_prepared: true,
          client_config: nil,
          client_env: nil,
          trust: snap.info,
          target_config: run.site,
          command: ["compile"]
        })

      case for r <- rows, r.class != :pass, do: "#{r.step}/#{r.check} #{r.class} (#{r.detail})" do
        [] -> :ok
        bad -> {:error, Enum.join(bad, "; ")}
      end
    after
      File.rm_rf(home)
    end
  end

  defp judged_build(c, run, [mirror | _] = mirrors, home, context) do
    %{opts: opts, steps: s, snap: snap} = run
    before = home_view(home, context)

    {rows, {report, requests, second}, tooling, observed} =
      try do
        {build_rows, build} =
          s.build.(%{
            fixture_dir: opts.fixture_dir,
            target: opts.target,
            source: mirror.url,
            home: home,
            home_prepared: true,
            keep_build: Case.runs(c) == 2,
            client_config: client_config(test_root(Map.get(c, :client_config), run), snap),
            client_env: client_env(Map.get(c, :client_env), home),
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

        build_dir = Path.join([opts.fixture_dir, "_build", "#{opts.target}_dev"])
        installed = installed(build_dir)

        observed = %{
          before: before,
          after: home_view(home, context),
          installed: installed,
          installed_files: installed_files(build_dir, installed),
          log: Map.get(build, :log, "")
        }

        second = Enum.flat_map(tl(mirrors), &Mirror.requests/1)
        observed = Map.put(observed, :isolation, isolation(c, run, home, context))

        {build_rows ++ integrity ++ compiled, {build.report, Mirror.requests(mirror), second},
         tooling(opts.fixture_dir, build.build_lib), observed}
      after
        Enum.each(mirrors, &Mirror.stop/1)
      end

    {:ok, _} = Report.write(opts.report_dir, "#{opts.target}-#{c.id}", rows, run.meta)

    {isolation, observed} = Map.pop(observed, :isolation)

    Case.judge(c, %{
      rows: rows,
      report: report,
      requests: requests,
      second_requests: second,
      snapshot: snap,
      hits: run.hits,
      tooling: tooling,
      observed: observed,
      isolation: isolation
    })
  end

  # A `{:test_root, name}` root as that test root's path.
  defp test_root(%{root: {:test_root, name}} = config, %{layer2: %{roots: roots}}),
    do: %{config | root: Map.fetch!(roots, name)}

  defp test_root(%{root: {:test_root, _}}, _run),
    do: raise(ArgumentError, "a test-root case outside a layer-2 run")

  defp test_root(config, _run), do: config

  # What the case's home and config show of a root it must not use: for a
  # real-root case any test root (a state dir named for one, a file outside
  # the cache naming a test key, a root path in the test material), for a
  # layer-2 case the real root's state dir.
  defp isolation(c, %{layer2: nil}, _home, _context) do
    if Case.layer2?(c), do: ["isolation: a layer-2 case ran without test-key material"], else: []
  end

  defp isolation(c, %{layer2: l2}, home, context) do
    if Case.layer2?(c) do
      case Setup.state_dir(home, context.source, Trust.library_root_path()) do
        {:ok, dir} ->
          if File.exists?(dir),
            do: [
              "isolation: the home holds #{Path.relative_to(dir, home)}, the state dir of the " <>
                "real root: the client did not use the test root"
            ],
            else: []

        {:error, why} ->
          ["isolation: cannot name the real root's state dir: #{why}"]
      end
    else
      real_root_isolation(l2, home, context, client_env(Map.get(c, :client_env), home))
    end
  end

  defp real_root_isolation(l2, home, context, env) do
    under? = &(is_binary(&1) and String.starts_with?(&1, l2.dir <> "/"))

    config =
      for {what, value} <- [{"root", context.root}, {"source", context.source}],
          under?.(value),
          do: "isolation: the client config names test root material: #{what} #{value}"

    env =
      for {name, value} <- Enum.sort(env || %{}),
          under?.(value),
          do: "isolation: the build's #{name} names test root material: #{value}"

    dirs =
      for {name, path} <- Enum.sort(l2.roots),
          {:ok, dir} <- [Setup.state_dir(home, context.source, path)],
          File.exists?(dir),
          do:
            "isolation: the home holds #{Path.relative_to(dir, home)}, the state dir of " <>
              "test root #{name}"

    named =
      for entry <- entries(home, "."),
          path = Path.expand(entry, home),
          rel = Path.relative_to(path, home),
          rel != "." and hd(Path.split(rel)) not in ["files", Setup.outside_dir()],
          {:ok, %File.Stat{type: :regular}} <- [File.lstat(path)],
          {:ok, bytes} <- [File.read(path)],
          kid = Enum.find(l2.keyids, &String.contains?(bytes, &1)),
          do:
            "isolation: #{Path.relative_to(path, home)} names test key #{String.slice(kid, 0, 12)}"

    config ++ env ++ dirs ++ named
  end

  # A clock age resolved against the snapshot batch's issue, now, so the
  # case means the same however old the snapshot is.
  defp client_config(config, snap) do
    if Clock.relative?(config) do
      case Snapshot.issued(snap) do
        {:ok, issued} -> Clock.resolve(config, issued, DateTime.utc_now())
        {:error, why} -> raise ArgumentError, "cannot resolve the case's clock age: #{why}"
      end
    else
      config
    end
  end

  # The case's variables, a `{:home, rel}` path resolved under the case home.
  defp client_env(nil, _home), do: nil

  defp client_env(env, home) do
    Map.new(env, fn
      {name, {:home, rel}} -> {name, Path.join(home, rel)}
      {name, path} -> {name, path}
    end)
  end

  # A fresh, private client home for one case.
  defp case_home() do
    rand = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    home = Path.join(Path.expand(System.tmp_dir!()), "chain_conformance_home-" <> rand)
    File.mkdir_p!(home)

    try do
      File.chmod!(home, 0o700)
    rescue
      e ->
        File.rm_rf(home)
        reraise e, __STACKTRACE__
    end

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

    root_versions =
      for path <- Path.wildcard(Path.join(home, "*/root_version"), match_dot: true),
          {:ok, %File.Stat{type: :regular}} <- [File.lstat(path)],
          into: %{},
          do: {Path.relative_to(path, home), read_or_error(path)}

    %{
      states: states,
      root_versions: root_versions,
      cache: fingerprints(home, "files"),
      outside: fingerprints(home, Setup.outside_dir()),
      own: own
    }
  end

  # Every entry under `home/rel` by its `t:ChainTest.Conformance.Case.fingerprint/0`.
  defp fingerprints(home, rel),
    do: Map.new(entries(home, rel), &{&1, fingerprint(Path.join(home, &1))})

  defp fingerprint(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :dir
      {:ok, %File.Stat{type: :regular}} -> file_fingerprint(path)
      {:ok, %File.Stat{type: :symlink}} -> link_fingerprint(path)
      {:ok, %File.Stat{type: type}} -> {:other, type}
      {:error, why} -> {:other, why}
    end
  end

  defp file_fingerprint(path) do
    hash =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:file, Base.encode16(hash, case: :lower)}
  rescue
    e in File.Error -> {:other, e.reason}
  end

  defp link_fingerprint(path) do
    case File.read_link(path) do
      {:ok, to} -> {:link, to}
      {:error, why} -> {:other, why}
    end
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

  # The sha256 of every regular file under an installed dep's `ebin` and
  # `priv`: which cache entries an install used.
  defp installed_files(build_dir, deps) do
    for dep <- deps,
        sub <- ["ebin", "priv"],
        path <- Path.wildcard(Path.join([build_dir, "lib", dep, sub, "**"]), match_dot: true),
        {:file, sha} <- [fingerprint(path)],
        into: MapSet.new(),
        do: sha
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
