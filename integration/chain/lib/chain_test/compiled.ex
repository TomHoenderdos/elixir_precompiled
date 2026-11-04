# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Compiled do
  @moduledoc """
  Step 4: only misses, the project itself and Nerves' own tooling were
  compiled here.

  Judged from `_build`, never from build output: a dependency was compiled
  here when `<build_lib>/<dep>/.mix/compile.elixir` exists (Mix's manifest
  for an Elixir dep), or, for a rebar or make dep, when Mix's
  `.mix/compile.elixir_scm` marker exists without the client's provenance
  file `.mix/elixir_precompiled.json`. A precompiled install carries the
  marker and the provenance file and no compile manifest.

  Checks:

    * `compiled:<dep>` per hit in the report, and per dep `_build` shows
      the client installed (its provenance file) though the report does not
      call it a hit: `:fail` when the dep was
      compiled here after all, `:disagreement` when `_build` has no such
      dep, `:pass` otherwise.
    * `compiled_here` - every dep compiled here, `:pass` when each is on
      the allowlist or a miss or fail in the report, `:fail` naming the
      rest.
    * `reported_miss:<dep>` per dep the report calls a miss or fail (not a
      hit): `:pass` when `.mix/compile.elixir` exists, or, for a dep without
      Elixir sources in `deps/<dep>/lib`, when the marker exists without the
      client's provenance file; `:disagreement` otherwise; `:not_exercised`
      when `_build` has no such dep.
  """

  alias ChainTest.{Integrity, Result}

  @tooling ~w(nerves nerves_system_* nerves_toolchain_* elixir_precompiled interactive_cmd
              nerves_discovery tablet)

  @doc """
  The tooling allowlist plus the project's own app and `project_deps`, the
  project's own path deps (compiled here as part of it; the client never
  considers them).
  """
  @spec allowlist(String.t(), [String.t()]) :: [String.t()]
  def allowlist(project_app, project_deps \\ []),
    do: @tooling ++ [project_app | project_deps]

  @doc "`allowlist/2` with the fixture's literal path deps (`ChainTest.Preflight.path_deps/1`)."
  @spec fixture_allowlist(Path.t(), String.t()) :: [String.t()]
  def fixture_allowlist(fixture_dir, project_app),
    do: allowlist(project_app, Map.keys(ChainTest.Preflight.path_deps(fixture_dir)))

  @doc "Whether `name` matches an allowlist entry (a trailing `*` is a prefix)."
  @spec allowed?(String.t(), [String.t()]) :: boolean()
  def allowed?(name, allowlist) do
    Enum.any?(allowlist, fn pattern ->
      case String.split_at(pattern, -1) do
        {prefix, "*"} -> String.starts_with?(name, prefix)
        _ -> name == pattern
      end
    end)
  end

  @doc "Runs step 4."
  @spec run(%{
          required(:build_lib) => Path.t(),
          required(:report) => map(),
          required(:allowlist) => [String.t()],
          optional(:deps_path) => Path.t()
        }) :: [Result.t()]
  def run(%{build_lib: build_lib, report: report, allowlist: allowlist} = input) do
    deps_path = Map.get(input, :deps_path, Path.expand("../../../deps", build_lib))
    lines = Enum.filter(Map.get(report, "lines", []), &is_map/1)
    reported = for %{"status" => "hit", "name" => n} <- lines, do: n
    hits = Enum.uniq(reported ++ Integrity.installed(build_lib))

    reported_misses =
      for %{"status" => s, "name" => n} <- lines, s in ["miss", "fail"], is_binary(n), do: n

    deps = deps(build_lib)
    compiled = deps |> Enum.filter(&compiled?(build_lib, &1)) |> Enum.sort()

    # A compiled hit already fails its own check; the summary covers the rest.
    Enum.map(hits, &hit_result(build_lib, &1, deps)) ++
      Enum.map(Enum.uniq(reported_misses) -- hits, &miss_result(build_lib, deps_path, &1, deps)) ++
      [summary(compiled -- hits, reported_misses, allowlist)]
  end

  @doc "Whether `dep` was compiled here, per the rule in the moduledoc."
  @spec compiled?(Path.t(), String.t()) :: boolean()
  def compiled?(build_lib, dep) do
    mix = Path.join([build_lib, dep, ".mix"])

    File.exists?(Path.join(mix, "compile.elixir")) or
      (File.exists?(Path.join(mix, "compile.elixir_scm")) and
         not File.exists?(Path.join(mix, "elixir_precompiled.json")))
  end

  defp deps(build_lib) do
    case File.ls(build_lib) do
      {:ok, names} ->
        Enum.filter(
          names,
          &(not String.starts_with?(&1, ".") and File.dir?(Path.join(build_lib, &1)))
        )

      {:error, _} ->
        []
    end
  end

  defp hit_result(build_lib, dep, deps) do
    check = "compiled:#{dep}"
    mix = Path.join([build_lib, dep, ".mix"])

    cond do
      dep not in deps ->
        result(check, :disagreement, "the report calls #{dep} a hit, but _build has no #{dep}")

      File.exists?(Path.join(mix, "compile.elixir")) ->
        result(
          check,
          :fail,
          "the report calls #{dep} a hit, but #{Path.join(mix, "compile.elixir")} exists: " <>
            "Mix compiled it here"
        )

      compiled?(build_lib, dep) ->
        result(
          check,
          :fail,
          "the report calls #{dep} a hit, but it has Mix's marker without " <>
            "#{Path.join(mix, "elixir_precompiled.json")}: Mix compiled it here"
        )

      true ->
        result(check, :pass, "#{dep} installed precompiled, not compiled here")
    end
  end

  # Mix writes .mix/compile.elixir whenever it compiles a dep with Elixir
  # sources; a reported miss without one was put in _build by something else.
  defp miss_result(build_lib, deps_path, dep, deps) do
    check = "reported_miss:#{dep}"
    mix = Path.join([build_lib, dep, ".mix"])
    manifest = Path.join(mix, "compile.elixir")
    lib = Path.join([deps_path, dep, "lib"])

    cond do
      dep not in deps ->
        result(
          check,
          :not_exercised,
          "the report calls #{dep} a miss, but _build has no #{dep}; " <>
            "the build may have stopped before it"
        )

      File.exists?(manifest) ->
        result(check, :pass, "#{dep} compiled here by Mix, as the client reports")

      Path.wildcard(Path.join([lib, "**", "*.ex"])) != [] ->
        result(
          check,
          :disagreement,
          "the report calls #{dep} a miss and #{lib} has Elixir sources, but #{manifest} " <>
            "is missing: Mix did not compile it, so its files came from somewhere else"
        )

      compiled?(build_lib, dep) ->
        result(check, :pass, "#{dep} has no Elixir sources; compiled here by its own tool")

      true ->
        result(
          check,
          :disagreement,
          "the report calls #{dep} a miss, but _build/#{dep} has neither Mix's compile " <>
            "manifest nor its marker: nothing compiled it here"
        )
    end
  end

  defp summary(compiled, reported_misses, allowlist) do
    {tooling, rest} = Enum.split_with(compiled, &allowed?(&1, allowlist))
    {misses, unexplained} = Enum.split_with(rest, &(&1 in reported_misses))

    detail =
      "compiled here: tooling and project [#{Enum.join(tooling, ", ")}]; " <>
        "reported misses [#{Enum.join(misses, ", ")}]"

    case unexplained do
      [] ->
        result("compiled_here", :pass, detail)

      _ ->
        result(
          "compiled_here",
          :fail,
          "compiled here but neither tooling nor a reported miss: " <>
            "[#{Enum.join(unexplained, ", ")}]; " <> detail
        )
    end
  end

  defp result(check, class, detail),
    do: %Result{step: :compiled, check: check, class: class, detail: detail}
end
