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
            else: "precompiled: no source configured, installing without precompiled builds"
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

    {forced?, mix_opts} = take_force(mix_opts)
    dir = project_dir(deps, mix_opts)
    if forced?, do: File.rm_rf!(dir)
    resolve(dir, deps, mix_opts)

    check =
      Keyword.get(test_opts, :check, fn ->
        Check.check(
          config,
          Env.MixInstall.load(dir, deps),
          Keyword.take(test_opts, [:config_fun])
        )
      end)

    # Mix.install/2 runs whatever happened here; it compiles what is missing.
    try do
      _ = check.()
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

  # What Mix.install/2 does first: deps.get in its install project, with the
  # project config it would push. Running it early is idempotent; the lock it
  # writes is what Env.MixInstall reads.
  defp resolve(dir, deps, mix_opts) do
    System.put_env(Keyword.get(mix_opts, :system_env, []))
    File.mkdir_p!(dir)

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
        Mix.Task.rerun("deps.get")
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
