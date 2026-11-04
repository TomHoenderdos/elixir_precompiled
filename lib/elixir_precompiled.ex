# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled do
  @moduledoc """
  Install signed, verified precompiled dependency builds instead of
  compiling them.

  Opt in with `config :elixir_precompiled, source: url`. In a Mix project
  the `mix precompiled.install` task, reached through the project's
  `deps.loadpaths` alias, calls `run/1` before Mix compiles the
  dependencies (the Nerves `nerves.init` hook calls it the same way);
  `install/2` wraps `Mix.install/2`. Every candidate dependency prints HIT,
  MISS or FAIL with a reason, and the same list lands in
  `_build/<target>_<env>/lib/.precompiled/report.json`.
  """

  alias ElixirPrecompiled.{Check, Config, Env, Fetch, Install}

  # A process told to stop (supervisor shutdown, a linked :normal or
  # {:shutdown, _} exit) must stop, not turn into a source compile.
  defguardp stop?(reason)
            when reason in [:normal, :shutdown] or
                   (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :shutdown)

  @doc """
  The build-time step: check every dependency Mix is about to compile and
  install the matching builds. `:disabled` without a source, and on the host
  target unless `allow_host: true` (what `mix precompiled.install` passes);
  `host?: true | false` forces either.
  """
  @spec run(keyword()) :: :disabled | :nothing_to_do | {:ok, Check.report()}
  def run(opts \\ []) do
    do_run(opts)
  rescue
    e -> internal_error(Exception.message(e))
  catch
    :exit, reason when stop?(reason) -> exit(reason)
    kind, reason -> internal_error(Exception.format_banner(kind, reason))
  end

  defp do_run(opts) do
    config = Config.load()

    cond do
      config == nil ->
        off(opts)

      host_disabled?(opts) ->
        :disabled

      true ->
        once(opts, fn ->
          Check.check(
            config,
            Keyword.get_lazy(opts, :env, &Env.MixProject.load/0),
            Keyword.take(opts, [:config_fun])
          )
        end)
    end
  end

  # Off means compile from source: builds an earlier run installed are
  # removed, so Mix compiles them in this same run. Only when a project is
  # there to look at; a script without one has nothing installed.
  defp off(opts) do
    if Keyword.has_key?(opts, :env) or Mix.Project.get() != nil do
      _ = Check.remove_installed(Keyword.get_lazy(opts, :env, &Env.MixProject.load/0))
    end

    :disabled
  end

  # `host?:` (the old option) wins; `allow_host: true` is what the Mix task
  # passes, so a plain project on the host target gets pure_elixir builds;
  # nerves.init's bare run() keeps skipping the host target.
  defp host_disabled?(opts) do
    cond do
      Keyword.has_key?(opts, :host?) -> Keyword.fetch!(opts, :host?)
      Keyword.get(opts, :allow_host, false) -> false
      true -> Mix.target() == :host
    end
  end

  # The fork's nerves.init hook and the alias can both call in one VM;
  # the second call returns the first one's result without a request, but
  # only while the build lib still looks as the first run left it: `mix do
  # clean --deps + compile` deletes _build between the two, and the second
  # call must install again.
  defp once(opts, fun) do
    if Keyword.has_key?(opts, :env) do
      fun.()
    else
      key = {__MODULE__, :ran, Mix.Project.build_path()}

      case :persistent_term.get(key, :none) do
        {result, proof} -> if proof(result) == proof, do: result, else: remember(key, fun)
        :none -> remember(key, fun)
      end
    end
  end

  defp proof(result), do: memo_proof(result, Path.join(Mix.Project.build_path(), "lib"))

  defp remember(key, fun) do
    result = fun.()
    :persistent_term.put(key, {result, proof(result)})
    result
  end

  @doc false
  # What a memoised result depends on: the deps' build dirs (by name) and,
  # for every dep the run installed, its provenance file and its app file.
  @spec memo_proof(term(), Path.t()) :: {[String.t()] | :none, [boolean()]}
  def memo_proof(result, build_lib) do
    hits =
      case result do
        {:ok, %{lines: lines}} ->
          for %{status: :hit, name: name} <- lines do
            File.regular?(Fetch.provenance_path(build_lib, name)) and
              File.regular?(Path.join([build_lib, to_string(name), "ebin", "#{name}.app"]))
          end

        _ ->
          []
      end

    dirs =
      case File.ls(build_lib) do
        {:ok, names} -> Enum.sort(names)
        {:error, _} -> :none
      end

    {dirs, hits}
  end

  # The build must go on: whatever went wrong here, Mix compiles the deps.
  defp internal_error(why) do
    ElixirPrecompiled.Output.warning(
      "precompiled: internal error, compiling from source (#{why})"
    )

    :disabled
  end

  @doc """
  `Mix.install/2` with precompiled builds: resolves `deps`, installs every
  matching build into the install project, then calls `Mix.install/2`,
  which compiles only the rest. Takes `Mix.install/2`'s options plus
  `:source`, `:except`, `:root` and `:home` (see `ElixirPrecompiled.Config`);
  without a source, configured or given, it is a plain `Mix.install/2`.

  Needs Mix on the device (`:mix` in `extra_applications`), a writable
  `MIX_INSTALL_DIR`, and Hex.
  """
  @spec install([term()], keyword()) :: :ok
  def install(deps, opts \\ []) when is_list(deps) and is_list(opts) do
    {ours, mix_opts} = Keyword.split(opts, [:source, :except, :root, :home])
    Install.run(deps, mix_opts, Config.load(ours))
  end
end
