# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled do
  @moduledoc """
  Installs signed precompiled libraries into a running Nerves device, with
  no Mix, no Hex and no compiler.

      Precompiled.install(:recon)
      Precompiled.install({:circuits_gpio, "2.3.1"})
      Precompiled.install([:recon, {:circuits_gpio, "~> 2.3"}])
      Precompiled.install(:recon, dry_run: true)
      Precompiled.install(:recon, source: "file:///media/usb/precompiled")
      Precompiled.list()
      Precompiled.uninstall(:recon)

  A call selects the build that matches the device (its Nerves system and
  version, OTP, Elixir, CPU and the apps it already has, by name and exact
  version), verifies every byte through the signed root, batch, manifest
  and file hashes, stages the files under the store directory, and loads
  and starts them. Absent runtime dependencies are installed with it, as
  one unit for the running VM: anything that fails leaves the code path
  and the loaded apps as they were. The store is a cache and may change
  before a later step fails: least recently used entries can be evicted
  for room, and builds that verified and were committed stay in it,
  unloaded, for a later call. Nothing is compiled, nothing unsigned is
  loaded, and nothing already present is replaced.

  It is available by default. Nothing runs on its own: only someone with a
  shell on the device calls it. The files stay in the store across reboots
  as a cache, but nothing is loaded at boot.

  ## Cache

  Installed builds stay in `dir` across reboots, but nothing is loaded at
  boot. Installing the same build again loads it from there without
  downloading, after checking every cached file against the signed hashes
  of the current batch. The cache is bounded by `max_bytes` and evicts the
  least recently used builds that are not loaded. `Precompiled.clean/0`
  empties it.

  ## Options

  | Option | Default | Meaning |
  | --- | --- | --- |
  | `:source` | `config :elixir_precompiled, :device, source:`, else the official API | The API root (`https://...`, or `http://` on loopback only), or `file://DIR` for a bundle. The default is `https://compatibility.nerves-project.org/api/precompiled`, checked against the root this library ships. Any other source must be configured or passed. |
  | `:content`, `:deadline_seconds` | as on the host | Same meaning as the host config keys. |
  | `:cacerts_path` | none | A PEM CA bundle to verify an `https` source with (a path). |
  | `:dir` | `/data/precompiled` | The store. Its trust state lives in `DIR/.trust`: a call with another `:dir` gets its own trust state (root chain and sequence floors), starting again from the shipped root. |
  | `:start` | `true` | Start the installed apps (`:temporary`) after loading them. |
  | `:closure` | `true` | Install absent runtime dependencies. `false` refuses with `{:needs, [...]}` instead. |
  | `:max_closure`, `:max_bytes` | 25, 64 MB | Bounds on the apps of one call and on the store's size. |
  | `:dry_run` | `false` | Select and plan, verify the trust chain, fetch the manifests and `.app` files only. Returns the plan. It writes no entry, staging dir or eviction: only the trust state in `DIR/.trust`, and the store dir and its marker when they do not exist yet. |
  | `:report` | none | With `dry_run: true`, write the device facts and the plan as JSON to this path (for `mix precompiled.bundle --device-report`). |
  | `:quiet` | `false` | Print nothing. |
  | `:lock_retries` | 60 | For tests: how often to retry a store another call holds. |

  Another trust anchor than the shipped `priv/precompiled/root.json` is
  set in the firmware's config only (`config :elixir_precompiled,
  :device, root: path`), never per call.

  The device facts, the clock check and the trust anchor have test seams
  (`:env`, `:clock_synchronized?`, `:root`). A call may pass them only while this library's
  application env has `test_seams: true`, as its own test suite sets;
  otherwise they are refused as unknown options, and the firmware's
  `:device` config never sets them.

  `config :elixir_precompiled, :device, enabled: false` in the firmware
  disables `install/2` (`{:error, :disabled}`); `list/1`, `uninstall/2`
  and `clean/1` keep working, so what is installed can still be removed.
  `allow: [app]` limits installs to those apps, closure members included.
  Both are read from the firmware's config only: a call can neither pass,
  widen nor clear them. The same config may set the defaults of `source`,
  `content`, `root`, `cacerts_path`, `deadline_seconds`, `dir`,
  `max_bytes`, `max_closure`, `start`, `closure` and `quiet`; any other key
  there is ignored.

  An online call needs a synchronized clock: on an unsynchronized one it
  refuses before any request. A `file://` bundle with a signed
  `offline.json` needs no clock and no network at all; one without it is
  bounded by its batch's own expiry and needs a synchronized clock too,
  checked once its batch is read.

  ## Return values

    * `{:ok, [%Precompiled.Installed{}]}`, the apps this call installed
      (empty when everything was already there);
    * with `dry_run: true`, `{:ok, %Precompiled.Plan{}}`;
    * `{:error, reason}`, where `reason` is one of:
      * `{:bad_request, term}`, `{:bad_option, key}`, `{:bad_source, s}`;
      * `{:clock_unsynchronized, now}`;
      * `{:missing_app, app}`, a network app the firmware leaves out;
      * `{:batch, why}`, the trust chain refused (`why` is the client's
        batch refusal text);
      * `{:no_build, pkg, why}`, the first failed rule of the build that
        got furthest;
      * `{:needs, [{app, vsn}]}`, with `closure: false`;
      * `{:not_allowed, app}`;
      * `{:already_present, app, vsn}`;
      * `{:module_loaded | :module_conflict, mod, path}`;
      * `{:noexec, mount}`;
      * `{:conflict, app, [vsn]}`, two versions of one app in one call;
      * `{:too_big, needed, free}`, `{:too_many, n, max}`;
      * `{:enospc, path}`, a full disk while staging or committing;
      * `{:unsafe_store, why}`;
      * `{:rename, posix}`, `{:bad_staging, path}`, or a posix atom such
        as `:eacces`, when the store refuses a commit;
      * `{:fetch, pkg, why}`, a file that did not verify;
      * `{:elf, why}`, a native library built for another CPU;
      * `{:on_load_failed, mod, reason}`;
      * `{:start_failed, app, reason}`;
      * `{:in_use, mod, pids}`, `{:in_use_by, [app]}`, `{:not_installed, app}`;
      * from `uninstall/2`: `{:stop_failed, app, why}`, the app would not
        stop or unload, and `{:in_use, app}`, with `remove: true`, when
        its files are still in use;
      * `{:report, path, why}`, the dry run's report could not be written;
      * `:busy`, another call holds the store;
      * `:disabled`;
      * `{:internal, message}`.

  `install/2` never raises on the network or on bad input.

  The store's lock serializes calls on this node. An installed app whose
  `start/2` itself calls `install/2` waits out the retries and gets
  `{:error, :busy}`.
  """

  alias ElixirPrecompiled.Check
  alias ElixirPrecompiled.CompileEnv
  alias ElixirPrecompiled.Device.Elf
  alias ElixirPrecompiled.Device.Env
  alias ElixirPrecompiled.Device.Loader
  alias ElixirPrecompiled.Device.Output
  alias ElixirPrecompiled.Device.Plan
  alias ElixirPrecompiled.Device.Source
  alias ElixirPrecompiled.Device.Store
  alias ElixirPrecompiled.Fetch
  alias ElixirPrecompiled.Match

  @defaults [
    start: true,
    closure: true,
    max_closure: 25,
    max_bytes: 64 * 1_048_576,
    dry_run: false,
    quiet: false,
    lock_retries: 60
  ]
  @not_options [:persist, :deps_identity]
  @common_keys [:dir, :quiet, :lock_retries]
  @install_keys @common_keys ++
                  [
                    :source,
                    :content,
                    :cacerts_path,
                    :deadline_seconds,
                    :start,
                    :closure,
                    :max_closure,
                    :max_bytes,
                    :dry_run,
                    :report
                  ]
  # Test seams: they replace the device facts and the clock check, so a
  # call may pass them only while `:test_seams` is set in this library's
  # application env (its own test suite, the qemu test). Otherwise they
  # are unknown options.
  # :root swaps the trust anchor: per call only as a seam, otherwise the
  # firmware's :device config sets it.
  @seam_keys [:env, :clock_synchronized?, :root]
  @uninstall_keys @common_keys ++ [:force, :cascade, :remove]
  @network_apps [:ssl, :inets, :public_key]

  @type request :: atom() | {atom(), String.t()}

  @doc """
  Installs, loads and starts `request` and its absent runtime
  dependencies. See the module documentation for the options and reasons.
  """
  @spec install(request() | [request()], keyword()) ::
          {:ok, [Precompiled.Installed.t()]} | {:ok, Precompiled.Plan.t()} | {:error, term()}
  def install(request, opts \\ []) do
    with {:ok, requests} <- normalize(request),
         :ok <- enabled(),
         {:ok, opts} <- normalize_opts(opts, install_keys()),
         {:ok, config} <- Source.config(opts),
         :ok <- network_apps(config),
         :ok <- clock(config, opts) do
      Store.with_lock(fn -> locked_install(requests, config, opts) end, opts[:lock_retries])
    end
    |> said(opts)
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {:internal, inspect({kind, reason})}}
  end

  @doc """
  The apps in the store, each with whether it is loaded in this VM (`[]`
  when there is no store yet), or `{:error, reason}`: a bad option, an
  unsafe store, `{:internal, message}`. Prints one line per app unless
  `quiet: true`.
  """
  @spec list(keyword()) :: [Precompiled.Installed.t()] | {:error, term()}
  def list(opts \\ []) do
    with {:ok, opts} <- common_opts(opts),
         :ok <- Store.check_root(opts[:dir]) do
      items = opts[:dir] |> Store.list() |> Enum.map(&installed/1)
      for i <- items, do: say(opts, list_line(i))
      items
    else
      {:error, reason} -> said({:error, reason}, opts)
      :absent -> []
    end
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {:internal, inspect({kind, reason})}}
  end

  @doc """
  Unloads an installed app: stops it, unloads it, purges its modules and
  takes its directory off the code path. Its files stay in the store as a
  cache unless `remove: true`.

  Refuses `{:in_use_by, apps}` while other installed apps that are loaded
  need it, unless `cascade: true` (which unloads them first). Refuses
  `{:in_use, mod, pids}` while other processes run its code, unless
  `force: true`.

  "In use" means code: processes running the app's modules, as
  `:code.soft_purge/1` sees them. Data is not detected: an open NIF
  resource or a reference into the app (a GPIO handle from
  `Circuits.GPIO.open/2`, say) held by a shell or another process does not
  stop the uninstall. Close such handles (`Circuits.GPIO.close/1`) before
  uninstalling.
  """
  @spec uninstall(atom(), keyword()) :: :ok | {:error, term()}
  def uninstall(app, opts \\ []) do
    with :ok <- app_request(app),
         {:ok, opts} <- normalize_opts(opts, @uninstall_keys) do
      dir = Path.expand(opts[:dir])

      Store.with_lock(
        fn ->
          case Store.check_root(dir) do
            :ok -> locked_uninstall(app, dir, opts, [app])
            :absent -> {:error, {:not_installed, app}}
            error -> error
          end
        end,
        opts[:lock_retries]
      )
    end
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {:internal, inspect({kind, reason})}}
  end

  @doc """
  Empties the cache: removes every store entry that is not loaded in this
  VM. Keeps `.trust` and whatever this VM is running from. Runs under the
  store's lock. Prints one summary line unless `quiet: true`.
  """
  @spec clean(keyword()) ::
          {:ok, %{removed: [atom()], bytes: non_neg_integer(), kept: [atom()]}} | {:error, term()}
  def clean(opts \\ []) do
    with {:ok, opts} <- common_opts(opts) do
      dir = Path.expand(opts[:dir])

      Store.with_lock(
        fn ->
          case Store.check_root(dir) do
            :ok -> locked_clean(dir, opts)
            :absent -> {:ok, %{removed: [], bytes: 0, kept: []}}
            error -> error
          end
        end,
        opts[:lock_retries]
      )
    end
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {:internal, inspect({kind, reason})}}
  end

  defp locked_clean(dir, opts) do
    active = active(Store.list(dir))
    result = Store.clean(dir, active)
    say(opts, clean_line(result))
    {:ok, result}
  end

  defp clean_line(%{removed: removed, bytes: bytes, kept: []}),
    do: "precompiled: cache cleaned, #{length(removed)} removed (#{Output.kb(bytes)})"

  defp clean_line(%{removed: removed, bytes: bytes, kept: kept}) do
    "precompiled: cache cleaned, #{length(removed)} removed (#{Output.kb(bytes)}), " <>
      "kept loaded: #{Enum.join(kept, ", ")}"
  end

  ## Requests and options

  defp normalize(requests) when is_list(requests) and requests != [] do
    Enum.reduce_while(requests, {:ok, []}, fn r, {:ok, acc} ->
      case normalize_one(r) do
        {:ok, one} -> {:cont, {:ok, acc ++ [one]}}
        _ -> {:halt, {:error, {:bad_request, requests}}}
      end
    end)
  end

  defp normalize(request) do
    with {:ok, one} <- normalize_one(request), do: {:ok, [one]}
  end

  defp normalize_one({app, req} = r) when is_binary(req) do
    if app_request(app) == :ok and requirement?(req),
      do: {:ok, {app, req}},
      else: {:error, {:bad_request, r}}
  end

  defp normalize_one(app) do
    with :ok <- app_request(app), do: {:ok, {app, nil}}
  end

  defp app_request(app) when is_atom(app) and app not in [nil, true, false], do: :ok
  defp app_request(other), do: {:error, {:bad_request, other}}

  defp requirement?(req),
    do: match?({:ok, _}, Version.parse(req)) or match?({:ok, _}, Version.parse_requirement(req))

  defp enabled() do
    if Keyword.get(device_config(), :enabled) == false, do: {:error, :disabled}, else: :ok
  end

  defp device_config(), do: Source.device_config()

  defp install_keys() do
    if Application.get_env(:elixir_precompiled, :test_seams) == true,
      do: @install_keys ++ @seam_keys,
      else: @install_keys
  end

  # Only the keys `known` documents: a misspelt one (dry_rn: true) is
  # refused rather than ignored, and :allow and :enabled are the
  # firmware's config alone.
  defp normalize_opts(opts, known) when is_list(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:bad_option, opts}},
         nil <- Enum.find(@not_options, &Keyword.has_key?(opts, &1)),
         nil <- Enum.find(Keyword.keys(opts), &(&1 not in known)) do
      merged =
        @defaults
        |> Keyword.merge(dir: Source.default_dir())
        |> Keyword.merge(device_config())
        |> Keyword.merge(opts)

      with :ok <- valid_opts(merged), do: {:ok, merged}
    else
      key when is_atom(key) -> {:error, {:bad_option, key}}
      error -> error
    end
  end

  defp normalize_opts(other, _known), do: {:error, {:bad_option, other}}

  # list/1 and clean/1 take only @common_keys, but accept the same opts
  # list as install/2 or uninstall/2 without refusing it: a true unknown
  # key (a typo) is still refused, everything else is just unused.
  defp common_opts(opts) do
    with {:ok, opts} <- normalize_opts(opts, install_keys() ++ @uninstall_keys) do
      {:ok, Keyword.take(opts, @common_keys)}
    end
  end

  @required [:dir, :start, :closure, :dry_run, :quiet, :max_closure, :max_bytes, :lock_retries]
  @optional [:report, :clock_synchronized?, :allow, :env]

  defp valid_opts(opts) do
    bad =
      Enum.find(@required, &(not ok?(&1, opts[&1]))) ||
        Enum.find(@optional, &(Keyword.has_key?(opts, &1) and not ok?(&1, opts[&1])))

    if bad, do: {:error, {:bad_option, bad}}, else: :ok
  end

  defp ok?(key, v) when key in [:start, :closure, :dry_run, :quiet], do: is_boolean(v)
  defp ok?(:dir, v), do: is_binary(v)
  defp ok?(:max_closure, v), do: is_integer(v) and v > 0
  defp ok?(key, v) when key in [:max_bytes, :lock_retries], do: is_integer(v) and v >= 0
  defp ok?(:report, v), do: is_binary(v)
  defp ok?(:clock_synchronized?, v), do: is_function(v, 0)
  defp ok?(:allow, v), do: is_nil(v) or (is_list(v) and Enum.all?(v, &is_atom/1))
  defp ok?(:env, v), do: is_struct(v, Env)

  ## The checks before the lock

  defp network_apps(%{bundle: true}), do: :ok
  defp network_apps(_config), do: missing_app(@network_apps)

  @doc false
  # The first of `apps` this release does not ship.
  @spec missing_app([atom()]) :: :ok | {:error, {:missing_app, atom()}}
  def missing_app(apps) do
    case Enum.find(apps, &match?({:error, _}, :code.lib_dir(&1))) do
      nil -> :ok
      app -> {:error, {:missing_app, app}}
    end
  end

  # A bundle is gated once its batch is read (bundle_clock/2): only a
  # signed offline.json is free of the clock.
  defp clock(%{bundle: true}, _opts), do: :ok

  defp clock(_config, opts), do: clock_set(opts)

  defp bundle_clock(%{offline: true}, _opts), do: :ok
  defp bundle_clock(_batch, opts), do: clock_set(opts)

  defp clock_set(opts) do
    synchronized? = Keyword.get(opts, :clock_synchronized?, &nerves_time_synced?/0)

    if synchronized?.() == true do
      :ok
    else
      say(opts, "precompiled: clock not synchronized; set the clock or wait for NTP, then retry")
      {:error, {:clock_unsynchronized, DateTime.utc_now()}}
    end
  end

  # NervesTime is not a dependency of this library: called through apply/3
  # only when it is loaded. Without it the clock is taken as set.
  defp nerves_time_synced?() do
    if Code.ensure_loaded?(NervesTime),
      do: apply(NervesTime, :synchronized?, []) == true,
      else: true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  ## Install, under the store's lock

  defp locked_install(requests, config, opts) do
    # The run's network deadline counts from here, not from before a wait
    # for the lock.
    config = config |> Map.delete(:deadline_at) |> Check.with_deadline()

    with :ok <- Store.ensure_root(config.dir) do
      if not opts[:dry_run], do: Store.sweep(config.dir)
      env = Keyword.get_lazy(opts, :env, &Env.load/0)
      say(opts, Output.env_line(env))
      memo = :ets.new(__MODULE__, [:set, :private])

      try do
        plan_and_install(requests, env, config, opts, memo)
      after
        # Every staging dir this call made: a committed one was renamed
        # away, anything left is removed, whatever ended the call.
        for {{:staging, path}, _} <- :ets.tab2list(memo), do: File.rm_rf(path)
        :ets.delete(memo)
      end
    end
  end

  defp plan_and_install(requests, env, config, opts, memo) do
    entries = Store.list(config.dir)
    active = active(entries)

    with :ok <- not_present(requests, env, active),
         {:ok, batch} <- Source.batch(config),
         :ok <- if(config.bundle, do: bundle_clock(batch, opts), else: :ok) do
      config = Source.with_batch(config, batch)
      ctx = ctx(env, config, entries, active, memo, opts)

      plan_opts = [
        manifest: Source.manifest_fun(config, batch),
        closure: opts[:closure],
        max_closure: opts[:max_closure],
        allow: Keyword.get(device_config(), :allow)
      ]

      with {:ok, plan} <- Plan.build(requests, ctx, plan_opts) do
        for i <- plan.installs, do: say(opts, plan_line(i))
        for w <- plan.warnings, do: say(opts, Output.line("", "WARN", w))
        state = %{env: env, config: config, batch: batch, active: active, opts: opts, memo: memo}
        if opts[:dry_run], do: dry_run(plan, env, opts), else: apply_plan(plan, state)
      end
    end
  end

  # A requested app the device has, and that this library did not load,
  # is refused before anything is fetched.
  defp not_present(requests, env, active) do
    Enum.find_value(requests, :ok, fn {app, _req} ->
      case {active[app], env.present[app]} do
        {nil, %{vsn: vsn}} -> {:error, {:already_present, app, vsn}}
        _ -> nil
      end
    end)
  end

  defp ctx(env, config, entries, active, memo, opts) do
    %{
      env: env,
      app_spec:
        Source.app_spec_fun(config,
          memo: memo,
          budget: 4 * opts[:max_closure],
          entries: entries
        ),
      installed: Map.new(entries, &{&1.app, &1.provenance["files_sha256"]}),
      active: active,
      config: &CompileEnv.lookup/2,
      pin: nil
    }
  end

  # Store entries loaded in this VM from that entry: app => version.
  defp active(entries), do: Map.new(for e <- entries, loaded?(e), do: {e.app, e.version})

  defp loaded?(entry) do
    List.keymember?(Application.loaded_applications(), entry.app, 0) and
      :code.lib_dir(entry.app) == String.to_charlist(entry.path)
  end

  ## Dry run

  defp dry_run(plan, env, opts) do
    case opts[:report] do
      nil -> {:ok, plan}
      path -> with :ok <- write_report(path, plan, env), do: {:ok, plan}
    end
  end

  defp write_report(path, plan, env) do
    report = %{
      "format" => 1,
      "env" => %{
        "system" => system_json(env.system),
        "platform" => env.platform || :null,
        "arch" => env.arch || :null,
        "otp" => env.otp,
        "elixir" => env.elixir,
        "cpu" => env.cpu,
        "present" => Map.new(env.present, fn {app, info} -> {Atom.to_string(app), info.vsn} end)
      },
      "plan" => %{
        "installs" => Enum.map(plan.installs, &install_json/1),
        "present" => Enum.map(plan.present, fn {app, vsn} -> [Atom.to_string(app), vsn] end),
        "warnings" => plan.warnings,
        "bytes" => plan.bytes
      }
    }

    case File.write(path, :json.encode(report)) do
      :ok -> :ok
      {:error, why} -> {:error, {:report, path, why}}
    end
  end

  defp system_json({name, vsn}), do: %{"name" => name, "version" => vsn}
  defp system_json(nil), do: :null

  defp install_json(i) do
    %{
      "app" => Atom.to_string(i.app),
      "version" => i.version,
      "target" => i.target,
      "role" => Atom.to_string(i.role),
      "bytes" => i.bytes,
      "manifest_sha256" => i.manifest.sha
    }
  end

  ## Stage, verify, commit, activate

  defp apply_plan(%{installs: []}, _state), do: {:ok, []}

  defp apply_plan(plan, state) do
    t0 = System.monotonic_time(:millisecond)
    %{config: config, opts: opts} = state
    checked = check_cache(plan.installs, config.dir)
    plan_bytes = Enum.sum(for {install, :miss} <- checked, do: install.bytes)
    keep = for {install, {:hit, _path}} <- checked, do: install.app

    with {:ok, victims} <-
           Store.room(config.dir, plan_bytes, opts[:max_bytes], state.active, keep),
         :ok <- noexec(plan.installs, state),
         # Room first: on a nearly full /data a stale cache must go before
         # the download, or staging hits ENOSPC. Only unloaded, unused
         # entries are victims, so this never touches what runs.
         :ok <- Store.evict(config.dir, victims),
         {:ok, placed} <- place_all(checked, state),
         :ok <- verify_placed(placed, state),
         {:ok, committed} <- commit_all(placed, state),
         {:ok, installed} <- activate_all(committed, state) do
      for i <- installed, do: Store.touch(config.dir, i.app, i.version)
      ms = System.monotonic_time(:millisecond) - t0
      say(opts, summary_line(installed, ms))
      {:ok, installed}
    end
  end

  # Only a miss downloaded anything: the summary counts those bytes, and
  # names how many of the rest came from the cache instead.
  defp summary_line(installed, ms) do
    {hits, misses} = Enum.split_with(installed, & &1.from_cache?)
    miss_bytes = Enum.sum(for i <- misses, do: i.bytes)
    line = Output.summary(length(installed), miss_bytes, ms)
    if hits == [], do: line, else: "#{line} (#{length(hits)} from cache)"
  end

  # Whether each planned install already has an exact, verified copy on
  # disk. Checked once, before room is computed, so a hit never counts
  # toward the bytes a miss needs and is never itself a candidate for
  # eviction (`keep`, below).
  defp check_cache(installs, dir) do
    for i <- installs, do: {i, Store.cached(dir, i.app, i.version, i.build)}
  end

  defp noexec(installs, state) do
    if Enum.any?(installs, &native?/1) do
      case Store.noexec(state.config.dir, state.env.mounts) do
        nil -> :ok
        mount -> {:error, {:noexec, mount}}
      end
    else
      :ok
    end
  end

  defp native?(install) do
    # A malformed entry is not native here; staging refuses it later as a
    # fetch error ("unsafe path or mode").
    Enum.any?(install.build["priv"] || [], fn f ->
      name = if is_map(f) and is_binary(f["path"]), do: Path.basename(f["path"]), else: ""

      String.ends_with?(name, ".so") or String.contains?(name, ".so.") or
        (is_map(f) and is_integer(f["mode"]) and Bitwise.band(f["mode"], 0o111) != 0)
    end)
  end

  # {:cached, path} for a hit (nothing downloaded), {:staged, path} for a
  # miss staged under .staging. Either way `path` has a readable `ebin`
  # (and `priv`) to run the checks below against.
  defp place_all(checked, state) do
    Enum.reduce_while(checked, {:ok, []}, fn
      {install, {:hit, path}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [{install, {:cached, path}}]}}

      {install, :miss}, {:ok, acc} ->
        case stage(install, state) do
          {:ok, staging} -> {:cont, {:ok, acc ++ [{install, {:staged, staging}}]}}
          error -> {:halt, error}
        end
    end)
  end

  defp stage(install, %{config: config, memo: memo}) do
    staging = Store.staging(config.dir, install.app, install.version)
    :ets.insert(memo, {{:staging, staging}, true})
    name = Atom.to_string(install.app)
    verify_app = &verify_app(&1, name, install.version)

    case Fetch.stage_verified(config, install.app, install.build, staging, verify_app: verify_app) do
      {:ok, _stats} -> {:ok, staging}
      {:fail, why} -> {:error, stage_reason(name, why, staging)}
    end
  rescue
    e in File.Error -> {:error, stage_reason(Atom.to_string(install.app), e, config.dir)}
  end

  @doc false
  # A full disk while staging is {:enospc, path}, as on commit; anything
  # else is the fetch failure it was.
  @spec stage_reason(String.t(), String.t() | Exception.t(), Path.t()) :: term()
  def stage_reason(_name, %File.Error{reason: :enospc}, path), do: {:enospc, path}
  def stage_reason(name, %File.Error{} = e, _path), do: {:fetch, name, Exception.message(e)}

  def stage_reason(name, why, path) when is_binary(why) do
    if String.contains?(why, "no space left on device"),
      do: {:enospc, path},
      else: {:fetch, name, why}
  end

  # The staged .app must be the planned app at the planned version.
  defp verify_app(path, name, version) do
    with {:ok, bytes} <- File.read(path),
         {:ok, props} <- Source.parse_app(bytes, name),
         true <- to_string(props[:vsn]) == version do
      :ok
    else
      {:fail, _} = fail -> fail
      _ -> {:fail, "staged .app is not #{name} #{version}"}
    end
  end

  defp verify_placed(placed, state) do
    Enum.find_value(placed, :ok, fn {install, {_kind, path}} ->
      with :ok <- elf(install, path, state.env.cpu),
           :ok <- conflicts(install, path) do
        nil
      end
    end)
  end

  defp conflicts(install, staging) do
    case Loader.conflicts(install.app, install.version, Path.join(staging, "ebin")) do
      :ok -> :ok
      {:error, why} -> {:error, reason(why)}
    end
  end

  defp elf(install, staging, cpu) do
    Enum.find_value(install.build["priv"] || [], :ok, fn %{"path" => path} ->
      case Elf.check(path, head(Path.join(staging, path)), cpu) do
        :ok -> nil
        {:fail, why} -> {:error, {:elf, why}}
      end
    end)
  end

  defp head(path) do
    case File.open(path, [:read, :binary, :raw], &IO.binread(&1, 64)) do
      {:ok, bytes} when is_binary(bytes) -> bytes
      _ -> ""
    end
  end

  # A cached hit is already the store's own entry; only a staged (just
  # downloaded) install still needs committing.
  defp commit_all(placed, state) do
    Enum.reduce_while(placed, {:ok, []}, fn
      {install, {:cached, path}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [{install, path, true}]}}

      {install, {:staged, staging}}, {:ok, acc} ->
        prov = provenance(install, state.batch)

        case Store.commit(
               staging,
               state.config.dir,
               install.app,
               install.version,
               prov,
               state.active
             ) do
          {:ok, path} -> {:cont, {:ok, acc ++ [{install, path, false}]}}
          error -> {:halt, error}
        end
    end)
  end

  # An offline document's sequence is its own counter, never a batch's:
  # the provenance says which vouched for the build.
  defp provenance(install, batch) do
    base = %{
      "files_sha256" => Match.files_hash(install.build),
      "files" => (install.build["ebin"] || []) ++ (install.build["priv"] || []),
      "manifest_sha256" => install.manifest.sha,
      "manifest_path" => install.manifest.path,
      "target" => install.target,
      "role" => Atom.to_string(install.role)
    }

    if batch[:offline],
      do: Map.merge(base, %{"trust" => "offline", "offline_sequence" => batch.sequence}),
      else: Map.merge(base, %{"trust" => "batch", "batch_sequence" => batch.sequence})
  end

  # Each app goes on the rollback list before its activation starts, so a
  # half-done one is torn down with the rest (a deactivate with nothing
  # recorded does nothing). A rolled-back hit is only unloaded: its store
  # entry, verified before this call, is left as it was.
  defp activate_all(committed, state) do
    result =
      Enum.reduce_while(committed, {:ok, [], []}, fn {install, path, from_cache?},
                                                     {:ok, done, out} ->
        done = done ++ [{install.app, path}]

        case guarded(fn -> activate(install, path, from_cache?, state) end) do
          {:ok, item} -> {:cont, {:ok, done, out ++ [item]}}
          {:error, why} -> {:halt, {:error, done, reason(why)}}
        end
      end)

    case result do
      {:ok, _done, installed} ->
        {:ok, installed}

      {:error, done, why} ->
        Loader.rollback(done)
        {:error, why}
    end
  end

  defp guarded(fun) do
    fun.()
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  catch
    kind, why -> {:error, {:internal, Exception.format_banner(kind, why)}}
  end

  defp activate(install, path, from_cache?, state) do
    # The priv files too: the loader re-hashes each one (a NIF's .so) just
    # before anything loads.
    files = (install.build["ebin"] || []) ++ (install.build["priv"] || [])

    with {:ok, app_items} <- app_compile_env(install, path),
         {:ok, warnings} <-
           Loader.activate(
             install.app,
             path,
             install.deferred_env ++ app_items,
             &CompileEnv.lookup/2,
             files: files,
             start: state.opts[:start]
           ) do
      for w <- warnings, do: say(state.opts, Output.line(name_vsn(install), "WARN", w))
      detail = if from_cache?, do: "#{path} (cached)", else: path
      say(state.opts, Output.line(name_vsn(install), "OK", detail))

      {:ok,
       %Precompiled.Installed{
         app: install.app,
         version: install.version,
         target: install.target,
         path: path,
         role: install.role,
         bytes: install.bytes,
         from_cache?: from_cache?,
         loaded?: true,
         batch_sequence: if(state.batch[:offline], do: nil, else: state.batch.sequence)
       }}
    end
  end

  # The compile_env the .app itself records, as the host checks it after
  # the download: read from bytes checked against the build, for the app
  # itself and for apps already loaded (the others were judged from the
  # manifest while planning).
  defp app_compile_env(install, path) do
    name = Atom.to_string(install.app)
    rel = "ebin/#{name}.app"
    entry = Enum.find(install.build["ebin"] || [], &(&1["path"] == rel))
    loaded = for {app, _, _} <- Application.loaded_applications(), do: Atom.to_string(app)

    with %{"sha256" => sha, "size" => size} <- entry,
         {:ok, bytes} <- File.read(Path.join(path, rel)),
         true <- byte_size(bytes) == size and sha256(bytes) == sha,
         {:ok, props} <- Source.parse_app(bytes, name) do
      {:ok,
       for(%{"app" => a} = i <- Match.compile_env_items(props), a == name or a in loaded, do: i)}
    else
      _ -> {:error, {:fetch, name, "sha256 mismatch (#{rel})"}}
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc false
  # The loader's reasons, as the reasons the module documentation lists.
  @spec reason(term()) :: term()
  def reason({:app_load_failed, app, why}), do: {:start_failed, app, {:load, why}}
  def reason({:fetch, app, why}) when is_atom(app), do: {:fetch, Atom.to_string(app), why}

  def reason({:code_path, ebin, why}),
    do: {:internal, "code path #{ebin}: #{inspect(why)}"}

  def reason({:bad_option, :files}), do: {:internal, "no file list for the loader"}
  def reason(other), do: other

  ## Uninstall, under the store's lock

  defp locked_uninstall(app, dir, opts, seen) do
    entries = Store.list(dir)
    mine = Enum.filter(entries, &(&1.app == app))

    if mine == [] do
      {:error, {:not_installed, app}}
    else
      with :ok <- dependants(app, entries, dir, opts, seen),
           :ok <- deactivate(app, mine, opts) do
        remove(app, dir, opts)
      end
    end
  end

  # Other installs, loaded here, whose loaded .app (verified bytes, in
  # memory) needs `app`.
  defp dependants(app, entries, dir, opts, seen) do
    users =
      for e <- entries,
          e.app != app,
          loaded?(e),
          app in needed_apps(e.app),
          uniq: true,
          do: e.app

    cond do
      users == [] -> :ok
      opts[:cascade] != true -> {:error, {:in_use_by, Enum.sort(users)}}
      true -> cascade(users -- seen, dir, opts, seen ++ users)
    end
  end

  # Every app another loaded app's .app names, as the planner reads it:
  # applications, included and optional applications.
  defp needed_apps(app) do
    for key <- [:applications, :included_applications, :optional_applications],
        dep <- Application.spec(app, key) || [],
        do: dep
  end

  defp cascade(users, dir, opts, seen) do
    Enum.find_value(users, :ok, fn user ->
      case locked_uninstall(user, dir, opts, seen) do
        :ok -> nil
        error -> error
      end
    end)
  end

  # Every cached version is offered to the loader, which acts only on the
  # one it activated in this VM.
  defp deactivate(app, mine, opts) do
    Enum.find_value(mine, :ok, fn e ->
      case Loader.deactivate(app, e.path, opts[:force] == true) do
        :ok ->
          nil

        {:error, {:in_use, _mod, _pids}} = error ->
          say(opts, Output.line("#{app} #{e.version}", "NO", in_use_note(app)))
          error

        error ->
          error
      end
    end)
  end

  defp in_use_note(app) do
    if List.keymember?(Application.loaded_applications(), app, 0),
      do: "in use by other processes, unchanged; retry with force: true",
      else: "stopped, still in use; retry with force: true"
  end

  defp remove(app, dir, opts) do
    if opts[:remove] == true, do: Store.remove(dir, app), else: :ok
  end

  ## Lines

  defp installed(e) do
    prov = e.provenance

    %Precompiled.Installed{
      app: e.app,
      version: e.version,
      target: prov["target"],
      path: e.path,
      role: role(prov["role"]),
      bytes: e.bytes,
      from_cache?: false,
      loaded?: loaded?(e),
      batch_sequence: if(is_integer(prov["batch_sequence"]), do: prov["batch_sequence"])
    }
  end

  defp role("requested"), do: :requested
  defp role("dependency"), do: :dependency
  defp role(_), do: nil

  defp list_line(i) do
    trust = if i.batch_sequence, do: "batch #{i.batch_sequence}", else: "offline"
    state = if i.loaded?, do: "loaded", else: "cached"
    Output.line("#{i.app} #{i.version}", "OK", "#{Output.kb(i.bytes)}, #{trust}, #{state}")
  end

  defp plan_line(i),
    do: Output.line(name_vsn(i), "PLAN", "#{i.target}, #{Output.kb(i.bytes)}")

  defp name_vsn(i), do: "#{i.app} #{i.version}"

  # The call's options may be anything here: quiet when they, or the
  # :device config, say so.
  defp said({:error, reason} = error, opts) do
    quiet? =
      (is_list(opts) and Keyword.keyword?(opts) and opts[:quiet] == true) or
        Keyword.get(device_config(), :quiet) == true

    case reason do
      {:no_build, pkg, why} when is_binary(pkg) and is_binary(why) ->
        Output.put(Output.line(pkg, "NO", why), quiet?)

      _ ->
        Output.put("precompiled: " <> inspect(reason), quiet?)
    end

    error
  end

  defp said(result, _opts), do: result

  defp say(opts, line), do: Output.put(line, opts[:quiet] == true)
end
