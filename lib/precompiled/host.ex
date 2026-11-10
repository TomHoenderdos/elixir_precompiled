# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Host do
  @moduledoc """
  Install signed, verified precompiled dependency builds instead of
  compiling them.

  Opt in with `config :precompiled, source: url`. In a Mix project
  the `mix precompiled.deps` task, reached through the project's
  `deps.loadpaths` alias, calls `run/1` before Mix compiles the
  dependencies (the Nerves `nerves.init` hook calls it the same way);
  `install/2` wraps `Mix.install/2`. Every candidate dependency prints HIT,
  MISS or FAIL with a reason, and the same list lands in
  `_build/<target>_<env>/lib/.precompiled/report.json`.
  """

  alias Precompiled.{Check, Config, Env, Fetch, Install}

  @typedoc """
  What a run did: counts of hits, misses and failures, the bytes
  installed, the time taken and one printed line per candidate.
  """
  @type report :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          fails: non_neg_integer(),
          bytes: non_neg_integer(),
          seconds: float(),
          lines: [term()]
        }

  # A process told to stop (supervisor shutdown, a linked :normal or
  # {:shutdown, _} exit) must stop, not turn into a source compile.
  defguardp stop?(reason)
            when reason in [:normal, :shutdown] or
                   (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :shutdown)

  @doc """
  The build-time step: check every dependency Mix is about to compile and
  install the matching builds. `:disabled` without a source, and on the host
  target unless `allow_host: true` (what `mix precompiled.deps` passes);
  `host?: true | false` forces either.
  """
  @spec run(keyword()) :: :disabled | :nothing_to_do | {:ok, report()}
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
      skipped_task?(opts, Mix.Tasks.Precompiled.Deps.top_level_task()) ->
        :disabled

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
  # The build lib is walked as it is; no dep is loaded.
  defp off(opts) do
    cond do
      Keyword.has_key?(opts, :env) -> _ = Check.remove_installed(Keyword.fetch!(opts, :env))
      Mix.Project.get() != nil -> _ = Check.remove_installed(build_lib())
      true -> :ok
    end

    :disabled
  end

  defp build_lib(), do: Path.join(Mix.Project.build_path(), "lib")

  @doc false
  # A Mix-project run (no :env: the fork's nerves.init hook, or the task)
  # under a top-level task that never compiles deps or only inspects or
  # undoes installs (precompiled.*) does nothing, as the task itself
  # already decides for its own call.
  @spec skipped_task?(keyword(), String.t()) :: boolean()
  def skipped_task?(opts, task),
    do: not Keyword.has_key?(opts, :env) and Mix.Tasks.Precompiled.Deps.skip?(task)

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

  defp proof(result), do: memo_proof(result, build_lib())

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
    Precompiled.Output.warning("precompiled: internal error, compiling from source (#{why})")

    :disabled
  end

  @doc """
  `Mix.install/2` with precompiled builds: resolves `deps`, installs every
  matching build into the install project, then calls `Mix.install/2`,
  which compiles only the rest. Takes `Mix.install/2`'s options plus
  `:source`, `:except`, `:root` and `:home` (see `Precompiled.Config`);
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
