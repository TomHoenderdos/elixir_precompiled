# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Env.MixProject do
  @moduledoc false
  # Build time, inside a Mix project: the deps Mix is about to compile, the
  # project's lock and build dir, and the Nerves system from the build plan
  # when nerves is loaded.

  alias ElixirPrecompiled.Env

  # nerves is not a dependency; its build plan is read only when the module
  # is there, so the compiler must not warn about the remote call.
  @compile {:no_warn_undefined, [Nerves]}

  # Mix.Dep.load_and_cache/0 and Mix.Dep.Lock.read/0 raise only when the
  # project itself is broken, in which case Mix is about to fail the same
  # way; no try here.
  @spec load() :: Env.t()
  def load() do
    lock = Mix.Dep.Lock.read()

    %Env{
      system: system(),
      candidates: candidates_from(Mix.Dep.load_and_cache(), lock),
      lock: lock,
      build_lib: Path.join(Mix.Project.build_path(), "lib"),
      deps_path: Mix.Project.deps_path()
    }
  end

  @doc false
  # Dependencies Mix would compile now: status :compile or no app file, Hex
  # SCM, and locked. Each dep's own :env option (defaulting to :prod, as Mix
  # itself does) names the env Mix compiles it with.
  @spec candidates_from([Mix.Dep.t()], map()) :: [Env.candidate()]
  def candidates_from(deps, lock) do
    pairs =
      for %Mix.Dep{app: app, status: status, scm: Hex.SCM, opts: opts} <- deps,
          match?(:compile, status) or match?({:noappfile, _}, status),
          do: {app, Atom.to_string(Keyword.get(opts, :env, :prod))}

    Env.hex_candidates(lock, Enum.map(pairs, &elem(&1, 0)), Map.new(pairs))
  end

  # Nerves.build_plan/0 raises only when the project itself is broken; it
  # already ran, unguarded, one line earlier in nerves.init's export_env/0.
  defp system() do
    if Code.ensure_loaded?(Nerves), do: system_from_plan(Nerves.build_plan()), else: nil
  end

  @doc false
  # The v1 system package the plan builds against. Read as a plain map so
  # the struct need not exist here.
  @spec system_from_plan(term()) :: {String.t(), String.t()} | nil
  def system_from_plan(%{actions: actions, packages: packages}) do
    with {_, opts} <- Enum.find(actions, &match?({Nerves.BuildAction.NervesV1System, _}, &1)),
         %{app: app, version: version} <- Enum.find(packages, &(&1.app == opts[:app])) do
      {Atom.to_string(app), version}
    else
      _ -> nil
    end
  end

  def system_from_plan(_), do: nil
end
