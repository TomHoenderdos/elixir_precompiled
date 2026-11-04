# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ElixirPrecompiled.InstallTest do
    # Igniter.Test works on an in-memory project: nothing is fetched and
    # no Hex home (real or private) is read or written.
    use ExUnit.Case, async: true
    import Igniter.Test

    @alias_entries ~s(["deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"])

    # The file's text with the formatter's line breaks inside lists undone,
    # so a list reads the same however long it is.
    defp content(igniter, path) do
      igniter.rewrite
      |> Rewrite.source!(path)
      |> Rewrite.Source.get(:content)
      |> String.replace(~r/\[\s+/, "[")
      |> String.replace(~r/,\s+/, ", ")
      |> String.replace(~r/,?\s+\]/, "]")
    end

    defp order(text, needles),
      do: Enum.map(needles, fn n -> text |> :binary.match(n) |> elem(0) end)

    defp count(text, needle), do: length(:binary.matches(text, needle))

    defp install(igniter, argv \\ []),
      do: Igniter.compose_task(igniter, "elixir_precompiled.install", argv)

    defp project_with(aliases, dep \\ ~s({:elixir_precompiled, "~> 0.1"})) do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", deps: deps(), aliases: #{aliases}]
        end

        defp deps, do: [#{dep}]
      end
      """

      test_project(files: %{"mix.exs" => mix_exs})
    end

    test "a new project gets the dep option, the source and the alias" do
      igniter =
        test_project()
        |> Igniter.Project.Deps.add_dep({:elixir_precompiled, "~> 0.1"})
        |> install(["--source", "https://example.test/api/precompiled"])
        |> apply_igniter!()

      mix_exs = content(igniter, "mix.exs")
      assert mix_exs =~ ~s({:elixir_precompiled, "~> 0.1", runtime: false})
      assert mix_exs =~ @alias_entries

      assert content(igniter, "config/config.exs") =~
               ~s(source: "https://example.test/api/precompiled")
    end

    test "without --source the public portal is configured" do
      igniter = project_with("[]") |> install() |> apply_igniter!()

      assert content(igniter, "config/config.exs") =~
               ~s(source: "https://compatibility.nerves-project.org/api/precompiled")
    end

    test "an existing deps.loadpaths alias keeps its own steps after ours" do
      igniter =
        project_with(~s(["deps.loadpaths": ["my.step", "deps.loadpaths"]]))
        |> install()
        |> apply_igniter!()

      text = content(igniter, "mix.exs")

      [compile, install, mine, loadpaths] =
        order(text, [
          ~s("deps.compile elixir_precompiled"),
          ~s("precompiled.install"),
          ~s("my.step"),
          ~s("deps.loadpaths"])
        ])

      assert compile < install and install < mine and mine < loadpaths
      assert count(text, ~s("deps.loadpaths")) == 2
    end

    test "running it twice changes nothing" do
      igniter = project_with("[]") |> install() |> apply_igniter!()
      once = content(igniter, "mix.exs")
      config = content(igniter, "config/config.exs")

      igniter
      |> install(["--source", "https://other.example.test/p"])
      |> assert_unchanged()

      assert count(once, ~s("precompiled.install")) == 1
      assert count(once, ~s("deps.compile elixir_precompiled")) == 1
      assert config =~ "compatibility.nerves-project.org"
    end

    test "an already set-up alias with other steps is left as it is" do
      igniter =
        project_with(
          ~s(["deps.loadpaths": ["deps.compile elixir_precompiled", "precompiled.install", "my.step", "deps.loadpaths"]])
        )
        |> install()
        |> apply_igniter!()

      text = content(igniter, "mix.exs")
      assert count(text, ~s("precompiled.install")) == 1
      assert count(text, ~s("deps.compile elixir_precompiled")) == 1
    end

    test "the dep keeps its own options and gains runtime: false" do
      for {dep, want} <- [
            {~s({:elixir_precompiled, "~> 0.1", only: :dev}),
             ~s({:elixir_precompiled, "~> 0.1", only: :dev, runtime: false})},
            {~s({:elixir_precompiled, github: "o/r"}),
             ~s({:elixir_precompiled, github: "o/r", runtime: false})},
            {~s({:elixir_precompiled, "~> 0.1", runtime: true}),
             ~s({:elixir_precompiled, "~> 0.1", runtime: false})}
          ] do
        igniter = project_with("[]", dep) |> install() |> apply_igniter!()
        assert content(igniter, "mix.exs") =~ want, dep
      end
    end
  end
end
