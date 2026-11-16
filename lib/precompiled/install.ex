# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Install do
  @moduledoc false
  # Mix.install/2 with the precompiled step in front of it. Mix offers no
  # hook between its deps.get and deps.loadpaths, and its install project
  # has no aliases, so this reproduces the start of its sequence: resolve
  # the deps into the project Mix.install/2 will use, place the hits in its
  # _build with Mix's "already compiled" markers, then call Mix.install/2.
  # Mix finds the project, skips deps.get because _build exists, and
  # deps.loadpaths compiles only what carries no marker.

  alias Precompiled.{Check, Config, Env, Output}

  @mix_install_app :mix_install

  # A process told to stop (supervisor shutdown, a linked :normal or
  # {:shutdown, _} exit) must stop, not turn into a source compile.
  defguardp stop?(reason)
            when reason in [:normal, :shutdown] or
                   (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :shutdown)

  @spec run([term()], keyword(), map() | nil, keyword()) :: :ok
  def run(deps, mix_opts, config, test_opts \\ []) do
    installer = Keyword.get(test_opts, :installer, &Mix.install/2)
    ensure_mix!(Code.ensure_loaded?(Mix))
    Mix.start()

    cond do
      config == nil ->
        Output.warning(
          if Config.disabled?(),
            do: "precompiled: disabled by PRECOMPILED, installing without precompiled builds",
            else: "precompiled: source refused, installing without precompiled builds"
        )

        # A second call in one VM finds its deps loaded: nothing to undo.
        if not Keyword.get_lazy(test_opts, :installed?, &Mix.installed?/0),
          do: remove_installed(deps, mix_opts)

        installer.(deps, mix_opts)

      # Mix allows a second call with the same deps and does nothing; so do we.
      Keyword.get_lazy(test_opts, :installed?, &Mix.installed?/0) ->
        installer.(deps, mix_opts)

      true ->
        install_precompiled(deps, mix_opts, config, installer, test_opts)
    end
  end

  defp install_precompiled(deps, mix_opts, config, installer, test_opts) do
    # Mix.install/2 refuses inside a Mix project; refuse before any work.
    if Keyword.get_lazy(test_opts, :in_project?, fn -> Mix.Project.get() != nil end) do
      Mix.raise("Precompiled.Host.install/2 cannot be used inside a Mix project")
    end

    # Before any config is applied: a call Mix.install/2 refuses changes nothing.
    validate!(mix_opts)
    {forced?, mix_opts} = take_force(mix_opts)
    dir = project_dir(deps, mix_opts)
    if forced?, do: File.rm_rf!(dir)

    unreadable = apply_config(dir, deps, mix_opts)
    # Mix.install/2's config: may hold the opt-in (`precompiled: [host_native: true]`).
    config = Config.with_host_native(config)

    {methods, present, order} =
      resolve(dir, deps, mix_opts, Keyword.get(test_opts, :load, &Mix.Dep.load_and_cache/0))

    with {:unknown, why} <- methods do
      Output.warning(
        "precompiled: deps did not load (#{why}); every dependency compiles from source"
      )
    end

    check =
      Keyword.get(test_opts, :check, fn env, config ->
        Check.check(config, env, Keyword.take(test_opts, [:config_fun, :native_host]))
      end)

    # Mix.install/2 runs whatever happened here; it compiles what is missing.
    try do
      env = Env.MixInstall.load(dir, deps, methods, present, order)
      _ = run_check(check, %{env | config_unreadable: unreadable}, config)
    rescue
      e -> internal_error(Exception.message(e))
    catch
      :exit, reason when stop?(reason) -> exit(reason)
      kind, reason -> internal_error(Exception.format_banner(kind, reason))
    end

    # Only now, so a forced install that failed above is still forced on retry.
    if forced?, do: System.delete_env("MIX_INSTALL_FORCE")
    installer.(deps, mix_opts)
  end

  # Off means off here too: builds an earlier install placed in this
  # install project go, so Mix.install/2 compiles them. Never in the way
  # of the install itself.
  defp remove_installed(deps, mix_opts) do
    # The build lib Env.MixInstall reads, walked as it is: no lock is read.
    lib = Path.join([project_dir(deps, mix_opts), "_build", Atom.to_string(Mix.env()), "lib"])
    _ = Check.remove_installed(lib)
    :ok
  rescue
    _ -> :ok
  end

  # The :check seam takes the env, or the env and the config.
  defp run_check(check, env, _config) when is_function(check, 1), do: check.(env)
  defp run_check(check, env, config), do: check.(env, config)

  defp internal_error(why),
    do: Output.warning("precompiled: internal error, compiling from source (#{why})")

  @doc false
  @spec ensure_mix!(boolean()) :: :ok
  def ensure_mix!(true), do: :ok

  def ensure_mix!(false) do
    raise RuntimeError,
          "Precompiled.Host.install/2 needs Mix on this device: " <>
            "add :mix to extra_applications in mix.exs and rebuild the firmware"
  end

  # The compile-time config Mix.install/2 compiles its deps with, applied
  # now so the check reads what the compiles will: Mix.install/2 puts the
  # system_env, then config: (Application.put_all_env/2, persistent, each
  # key replacing the app's), then reads config_path: as loadconfig does
  # (Config.Reader with Mix.env/0 and Mix.target/0, imports included) and
  # puts it the same way, so the file's keys replace config:'s. The file is
  # evaluated inside the install project dir, as Mix.install/2 evaluates it,
  # so a relative read or File.cwd!/0 in it sees that dir; its own path is
  # expanded against the caller's cwd first, as Mix.install/2 expands it.
  # It does the same again when it runs; doing it first changes nothing it
  # then does.
  # Elixir 1.17 to 1.20 all apply them in that order before deps.get. nil,
  # or why config_path: could not be read: Mix.install/2 then fails on it
  # too, and the check (Check) misses every build that read config.
  defp apply_config(dir, deps, mix_opts) do
    System.put_env(Keyword.get(mix_opts, :system_env, []))
    Application.put_all_env(Keyword.get(mix_opts, :config, []), persistent: true)

    case Keyword.get(mix_opts, :config_path) do
      nil -> nil
      path -> read_config(dir, path, normalize_deps(deps))
    end
  end

  defp read_config(dir, path, deps) do
    file = dep_file(path, deps, :config_path, "config/config.exs")
    File.mkdir_p!(dir)

    config =
      File.cd!(dir, fn ->
        Elixir.Config.Reader.read!(file, env: Mix.env(), target: Mix.target())
      end)

    Application.put_all_env(config, persistent: true)
    nil
  rescue
    e -> unreadable(path, Exception.message(e))
  catch
    :exit, reason when stop?(reason) -> exit(reason)
    kind, reason -> unreadable(path, Exception.format_banner(kind, reason))
  end

  defp unreadable(path, why) do
    Output.warning(
      "precompiled: config_path #{inspect(path)} could not be read (#{why}); " <>
        "every dependency that reads compile-time config compiles from source"
    )

    "config_path unreadable"
  end

  # Mix.install/2's own checks, in its order, before it does anything: the
  # :elixir requirement, then Keyword.validate!/2 with the options this
  # Elixir's Mix.install/2 takes (:compilers from 1.19,
  # :stop_unused_applications from 1.20).
  @install_opts [
    config: [],
    config_path: nil,
    consolidate_protocols: true,
    elixir: nil,
    force: false,
    lockfile: nil,
    runtime_config: [],
    start_applications: true,
    system_env: [],
    verbose: false
  ]

  defp validate!(mix_opts) do
    requirement = mix_opts[:elixir]
    version = System.version()

    if !!requirement and not Version.match?(version, requirement) do
      Mix.raise(
        "Mix.install/2 declared it supports only Elixir #{requirement} " <>
          "but you're running on Elixir #{version}"
      )
    end

    _ = Keyword.validate!(mix_opts, install_opts(Version.parse!(version)))
    :ok
  end

  @doc false
  @spec install_opts(Version.t()) :: keyword()
  def install_opts(%Version{major: major, minor: minor}) do
    @install_opts
    |> then(&if({major, minor} >= {1, 19}, do: [{:compilers, [:elixir]} | &1], else: &1))
    |> then(
      &if({major, minor} >= {1, 20}, do: [{:stop_unused_applications, true} | &1], else: &1)
    )
  end

  # Mix.install/2 deletes the install dir when forced, which would delete the
  # placed hits; honour force here and strip it before Mix runs (the env var
  # is cleared just before Mix.install/2 is called).
  defp take_force(mix_opts) do
    forced? =
      System.get_env("MIX_INSTALL_FORCE") in ["1", "true"] or Keyword.get(mix_opts, :force, false)

    {forced?, Keyword.delete(mix_opts, :force)}
  end

  @doc false
  # Mix.install/2's own formula: the id is the md5 of {deps, config,
  # system_env, consolidate_protocols?} after dep normalisation; the dir is
  # MIX_INSTALL_DIR (or <mix cache>/installs) / <version dir> / id. Elixir
  # 1.19 renamed both parts: ex-<elixir>-erl-<erts> and the md5 in url-safe
  # base64, where 1.17 and 1.18 use elixir-<elixir>-erts-<erts> and lower
  # hex. test/integration/install_test.exs compares this with
  # Mix.install_project_dir/0 after a real Mix.install/2, so a Mix that
  # changes the formula fails loudly there.
  @spec project_dir([term()], keyword()) :: Path.t()
  def project_dir(deps, mix_opts) do
    md5 =
      {normalize_deps(deps), Keyword.get(mix_opts, :config, []),
       Keyword.get(mix_opts, :system_env, []),
       Keyword.get(mix_opts, :consolidate_protocols, true)}
      |> :erlang.term_to_binary()
      |> :erlang.md5()

    {elixir, erts} = {System.version(), :erlang.system_info(:version)}
    %Version{major: major, minor: minor} = Version.parse!(elixir)

    # By minor, so a 1.19 release candidate counts as 1.19.
    {version_dir, id} =
      if {major, minor} >= {1, 19},
        do: {"ex-#{elixir}-erl-#{erts}", Base.url_encode64(md5, padding: false)},
        else: {"elixir-#{elixir}-erts-#{erts}", Base.encode16(md5, case: :lower)}

    root = System.get_env("MIX_INSTALL_DIR") || Path.join(Mix.Utils.mix_cache(), "installs")
    Path.join([root, version_dir, id])
  end

  @doc false
  @spec normalize_deps([term()]) :: [term()]
  def normalize_deps(deps) do
    Enum.map(deps, fn
      dep when is_atom(dep) ->
        {dep, ">= 0.0.0"}

      {app, opts} when is_atom(app) and is_list(opts) ->
        {app, expand_path(opts)}

      {app, req, opts} when is_atom(app) and is_binary(req) and is_list(opts) ->
        {app, req, expand_path(opts)}

      other ->
        other
    end)
  end

  defp expand_path(opts) do
    if Keyword.has_key?(opts, :path), do: Keyword.update!(opts, :path, &Path.expand/1), else: opts
  end

  @doc false
  # What Mix.install/2 does first: the lockfile: merge and deps.get in its
  # install project, with the project config it would push. Running them
  # early is idempotent; the lock they write is what Env.MixInstall reads,
  # and Mix.install/2 then finds the merge done (merge_lockfile/3). Then the
  # deps Mix loads there, read once for three things: how Mix builds each
  # Hex dep (build_methods/4), each dep's children (present_deps/1), and the
  # order deps.compile walks them in (CompileOrder.from_deps/2). Mix.install/2
  # loads and compiles that same list right after, in the same project, from
  # the same lock, env and target: its deps.loadpaths runs deps.compile over
  # Mix.Dep.load_and_cache/0, as in a Mix project. `load` stands in for
  # Mix.Dep.load_and_cache/0 in tests.
  @spec resolve(Path.t(), [term()], keyword(), (-> [Mix.Dep.t()])) ::
          {Env.build_methods(), Env.present_deps() | nil, Env.compile_order() | nil}
  def resolve(dir, deps, mix_opts, load \\ &Mix.Dep.load_and_cache/0) do
    System.put_env(Keyword.get(mix_opts, :system_env, []))
    File.mkdir_p!(dir)

    in_install_project(dir, deps, mix_opts, fn ->
      merge_lockfile(dir, normalize_deps(deps), Keyword.get(mix_opts, :lockfile))
      Mix.Task.rerun("deps.get")
      load_deps(load)
    end)
  end

  # Mix.install/2's lockfile: step, as Elixir 1.17 to 1.20 write it: the
  # external lock merged over the install project's, then deps.get, and the
  # external lock's md5 in merge.lock.md5 so a run with the same lock skips
  # both. Done here, before the tree is read, the tree checked is the one
  # Mix.install/2 compiles: a sibling the external lock pins to a version
  # that no longer brings in an optional dep changes another package's
  # closure without making Mix recompile that package. Mix.install/2 then
  # finds the same md5 and merges nothing.
  defp merge_lockfile(_dir, _deps, nil), do: :ok

  defp merge_lockfile(dir, deps, lockfile) do
    external = dep_file(lockfile, deps, :lockfile, "mix.lock")
    md5_path = Path.join(dir, "merge.lock.md5")

    old_md5 =
      case File.read(md5_path) do
        {:ok, data} -> Base.decode64!(data)
        _ -> nil
      end

    new_md5 = external |> File.read!() |> :erlang.md5()

    if old_md5 != new_md5 do
      lock_path = Path.join(dir, "mix.lock")
      merged = Map.merge(Mix.Dep.Lock.read(lock_path), Mix.Dep.Lock.read(external))
      Mix.Dep.Lock.write(merged, file: lock_path)
      File.write!(md5_path, Base.encode64(new_md5))
    end

    :ok
  end

  # Mix.install/2's expand_path/4 for :lockfile and :config_path: a path,
  # or the name of a path dependency whose file at `relative` is meant.
  defp dep_file(path, _deps, _key, _relative) when is_binary(path), do: Path.expand(path)

  defp dep_file(app, deps, key, relative) when is_atom(app) do
    app_dir =
      case List.keyfind(deps, app, 0) do
        {_, _, opts} when is_list(opts) -> opts[:path]
        {_, opts} when is_list(opts) -> opts[:path]
        _ -> Mix.raise("unknown dependency #{inspect(app)} given to #{inspect(key)}")
      end

    if !app_dir do
      Mix.raise("#{inspect(app)} given to #{inspect(key)} must be a path dependency")
    end

    Path.join(app_dir, relative)
  end

  @doc false
  # Per Hex dep of the install project in `dir`, the manager Mix resolves
  # and the build options its declaration sets, read from the deps Mix
  # loads there: transitive declarations (a package's own mix.exs setting
  # :manager on a child) and inherited managers included. When Mix cannot
  # load them, {:unknown, why}: rule 9 then misses every candidate, as a
  # guess from the deps list alone could miss an override and hit wrongly.
  # `load` stands in for Mix.Dep.load_and_cache/0 in tests.
  @spec build_methods(Path.t(), [term()], keyword(), (-> [Mix.Dep.t()])) ::
          Env.build_methods()
  def build_methods(dir, deps, mix_opts \\ [], load \\ &Mix.Dep.load_and_cache/0),
    do: dir |> in_install_project(deps, mix_opts, fn -> load_deps(load) end) |> elem(0)

  # Never cached past this call: Mix.install/2 loads its own deps. Deps that
  # do not load leave all three unknown: every candidate misses on rule 9.
  # The partition count is read after resolve/4 put the system_env: Mix.install/2
  # partitions its deps.compile by it as a Mix project does.
  defp load_deps(load) do
    Mix.Dep.clear_cached()
    deps = load.()

    {Env.MixProject.build_methods_from(deps), present_deps(deps),
     compile_order(deps, System.get_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT"))}
  rescue
    e -> {{:unknown, Exception.message(e)}, nil, nil}
  catch
    :exit, reason when stop?(reason) -> exit(reason)
    kind, reason -> {{:unknown, Exception.format_banner(kind, reason)}, nil, nil}
  after
    Mix.Dep.clear_cached()
  end

  # Each dep's children as Mix loaded them, as Env.MixProject reads them in
  # a Mix project. Anything but the shape Mix gives (a Mix that changed
  # its dep struct) leaves the tree unknown, nil: Match then falls back to
  # the lock, and builds_closure is not read.
  defp present_deps(deps) do
    tree = Env.MixProject.present_deps_from(deps)

    if Enum.all?(tree, fn {app, children} ->
         is_atom(app) and is_list(children) and Enum.all?(children, &is_atom/1)
       end),
       do: tree
  rescue
    _ -> nil
  end

  # As present_deps/1: deps in a shape the order cannot be read from leave
  # it unknown, nil.
  defp compile_order(deps, partition_count) do
    Precompiled.CompileOrder.from_deps(deps, partition_count)
  rescue
    _ -> nil
  end

  defp in_install_project(dir, deps, mix_opts, fun) do
    config = [
      version: "1.0.0",
      build_per_environment: true,
      build_path: "_build",
      lockfile: "mix.lock",
      deps_path: "deps",
      app: @mix_install_app,
      erlc_paths: [],
      elixirc_paths: [],
      prune_code_paths: false,
      deps: normalize_deps(deps),
      consolidate_protocols: Keyword.get(mix_opts, :consolidate_protocols, true),
      compilers: Keyword.get(mix_opts, :compilers, [:elixir])
    ]

    # Pushed under a named module, as Mix.install/2 does: in_project/4 without
    # a mix.exs pushes a nil project, which deps.get rejects. The name is
    # deliberately not Mix.InstallProject, so Mix's {:cached_deps, module}
    # cache is not shared with the real install that follows.
    File.cd!(dir, fn ->
      :ok = Mix.ProjectStack.push(Precompiled.InstallProject, config, "nofile")

      try do
        fun.()
      after
        Mix.ProjectStack.pop()
        Mix.Task.clear()
      end
    end)
  end
end

defmodule Precompiled.InstallProject do
  @moduledoc false
  # The project module Install.resolve/3 pushes for its deps.get.
end
