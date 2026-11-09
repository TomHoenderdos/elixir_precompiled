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
  one unit: anything that fails leaves the code path and the loaded apps
  as they were. Nothing is compiled, nothing unsigned is loaded, and
  nothing already present is replaced.

  It is available by default. Nothing runs on its own: only someone with a
  shell on the device calls it. The files stay in the store across reboots
  as a cache, but nothing is loaded at boot.

  ## Options

  | Option | Default | Meaning |
  | --- | --- | --- |
  | `:source` | `config :elixir_precompiled, :device, source:`, else the official API | The API root (`https://...`, or `http://` on loopback only), or `file://DIR` for a bundle. The default is `https://compatibility.nerves-project.org/api/precompiled`, checked against the root this library ships. Any other source must be configured or passed. |
  | `:root` | the shipped `priv/precompiled/root.json` | A trust anchor that overrides the shipped one, as on the host. |
  | `:content`, `:cacerts_path`, `:deadline_seconds` | as on the host | Same meaning as the host config keys. |
  | `:dir` | `/data/precompiled` | The store. Its trust state lives in `DIR/.trust`, so a call with another `:dir` keeps its own sequence floors. |
  | `:start` | `true` | Start the installed apps (`:temporary`) after loading them. |
  | `:closure` | `true` | Install absent runtime dependencies. `false` refuses with `{:needs, [...]}` instead. |
  | `:max_closure`, `:max_bytes` | 25, 64 MB | Bounds on the apps of one call and on the store's size. |
  | `:dry_run` | `false` | Select and plan, verify the trust chain, fetch the manifests and `.app` files only, and write nothing outside `DIR/.trust`. Returns the plan. |
  | `:report` | none | With `dry_run: true`, write the device facts and the plan as JSON to this path (for `mix precompiled.bundle --device-report`). |
  | `:quiet` | `false` | Print nothing. |
  | `:env` | read from the device | For tests: the device facts (`ElixirPrecompiled.Device.Env`) to use. |
  | `:clock_synchronized?` | `NervesTime.synchronized?/0` when loaded | For tests: a 0-arity function that says whether the clock is set. |
  | `:lock_retries` | 60 | For tests: how often to retry a store another call holds. |

  `config :elixir_precompiled, :device, enabled: false` in the firmware
  turns the whole API off (`{:error, :disabled}`); `allow: [app]` limits
  it to those apps, closure members included. The same config may set
  `source`, `dir`, `max_bytes` and `cacerts_path`.

  An online call needs a synchronized clock: on an unsynchronized one it
  refuses before any request. A `file://` bundle with a signed
  `offline.json` needs no clock and no network at all; one without it is
  bounded by its batch's own expiry.

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
      * `{:enospc, path}`, `{:unsafe_store, why}`;
      * `{:fetch, pkg, why}`, a file that did not verify;
      * `{:elf, why}`, a native library built for another CPU;
      * `{:on_load_failed, mod, reason}`;
      * `{:start_failed, app, reason}`;
      * `{:in_use, mod, pids}`, `{:in_use_by, [app]}`, `{:not_installed, app}`;
      * `{:report, path, why}`, the dry run's report could not be written;
      * `:busy`, another call holds the store;
      * `:disabled`;
      * `{:internal, message}`.

  `install/2` never raises on the network or on bad input.

  The store's lock serializes calls on this node. An installed app whose
  `start/2` itself calls `install/2` waits out the retries and gets
  `{:error, :busy}`.
  """

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
         {:ok, opts} <- normalize_opts(opts),
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
  The apps in the store, each with whether it is loaded in this VM.
  Prints one line per app unless `quiet: true`.
  """
  @spec list(keyword()) :: [Precompiled.Installed.t()]
  def list(opts \\ []) do
    case normalize_opts(opts) do
      {:ok, opts} ->
        items = opts[:dir] |> Store.list() |> Enum.map(&installed/1)
        for i <- items, do: say(opts, list_line(i))
        items

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Unloads an installed app: stops it, unloads it, purges its modules and
  takes its directory off the code path. Its files stay in the store as a
  cache unless `remove: true`.

  Refuses `{:in_use_by, apps}` while other installed apps that are loaded
  need it, unless `cascade: true` (which unloads them first). Refuses
  `{:in_use, mod, pids}` while other processes run its code, unless
  `force: true`.
  """
  @spec uninstall(atom(), keyword()) :: :ok | {:error, term()}
  def uninstall(app, opts \\ []) do
    with :ok <- app_request(app),
         {:ok, opts} <- normalize_opts(opts) do
      dir = Path.expand(opts[:dir])
      Store.with_lock(fn -> locked_uninstall(app, dir, opts, [app]) end, opts[:lock_retries])
    end
  rescue
    e -> {:error, {:internal, Exception.message(e)}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {:internal, inspect({kind, reason})}}
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

  defp device_config() do
    case Application.get_env(:elixir_precompiled, :device, []) do
      kw when is_list(kw) -> kw
      _ -> []
    end
  end

  defp normalize_opts(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:bad_option, opts}},
         nil <- Enum.find(@not_options, &Keyword.has_key?(opts, &1)) do
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

  defp normalize_opts(other), do: {:error, {:bad_option, other}}

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

  # A bundle needs no clock: Trust decides (an online batch's expiry needs
  # a sane clock, an offline document none).
  defp clock(%{bundle: true}, _opts), do: :ok

  defp clock(_config, opts) do
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
         {:ok, batch} <- Source.batch(config) do
      config = Source.with_batch(config, batch)
      ctx = ctx(env, config, entries, active, memo, opts)

      plan_opts = [
        manifest: Source.manifest_fun(config, batch),
        closure: opts[:closure],
        max_closure: opts[:max_closure],
        allow: opts[:allow]
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
      app_spec: Source.app_spec_fun(config, memo: memo, budget: 4 * opts[:max_closure]),
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

    with {:ok, victims} <-
           Store.room(config.dir, plan.bytes, opts[:max_bytes], state.active, []),
         :ok <- noexec(plan.installs, state),
         {:ok, staged} <- stage_all(plan.installs, state),
         :ok <- verify_staged(staged, state),
         :ok <- Store.evict(config.dir, victims),
         {:ok, committed} <- commit_all(staged, state),
         {:ok, installed} <- activate_all(committed, state) do
      for i <- installed, do: Store.touch(config.dir, i.app, i.version)
      ms = System.monotonic_time(:millisecond) - t0
      say(opts, Output.summary(length(installed), plan.bytes, ms))
      {:ok, installed}
    end
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
    Enum.any?(install.build["priv"] || [], fn f ->
      name = Path.basename(f["path"])

      String.ends_with?(name, ".so") or String.contains?(name, ".so.") or
        Bitwise.band(f["mode"], 0o111) != 0
    end)
  end

  defp stage_all(installs, state) do
    Enum.reduce_while(installs, {:ok, []}, fn i, {:ok, acc} ->
      case stage(i, state) do
        {:ok, staging} -> {:cont, {:ok, acc ++ [{i, staging}]}}
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
      {:fail, why} -> {:error, {:fetch, name, why}}
    end
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

  defp verify_staged(staged, state) do
    Enum.find_value(staged, :ok, fn {install, staging} ->
      with :ok <- elf(install, staging, state.env.cpu),
           :ok <- conflicts(install, staging) do
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

  defp commit_all(staged, state) do
    Enum.reduce_while(staged, {:ok, []}, fn {install, staging}, {:ok, acc} ->
      prov = provenance(install, state.batch)

      case Store.commit(
             staging,
             state.config.dir,
             install.app,
             install.version,
             prov,
             state.active
           ) do
        {:ok, path} -> {:cont, {:ok, acc ++ [{install, path}]}}
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
  # recorded does nothing).
  defp activate_all(committed, state) do
    result =
      Enum.reduce_while(committed, {:ok, [], []}, fn {install, path}, {:ok, done, out} ->
        done = done ++ [{install.app, path}]

        case guarded(fn -> activate(install, path, state) end) do
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

  defp activate(install, path, state) do
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
      say(state.opts, Output.line(name_vsn(install), "OK", path))

      {:ok,
       %Precompiled.Installed{
         app: install.app,
         version: install.version,
         target: install.target,
         path: path,
         role: install.role,
         bytes: install.bytes,
         from_cache?: false,
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
          app in (Application.spec(e.app, :applications) || []),
          uniq: true,
          do: e.app

    cond do
      users == [] -> :ok
      opts[:cascade] != true -> {:error, {:in_use_by, Enum.sort(users)}}
      true -> cascade(users -- seen, dir, opts, seen ++ users)
    end
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
