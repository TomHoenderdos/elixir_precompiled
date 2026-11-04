# SPDX-FileCopyrightText: None
#
# SPDX-License-Identifier: CC0-1.0
checks = [
  {Credo.Check.Design.AliasUsage, false},
  {Credo.Check.Refactor.Apply, false},
  {Credo.Check.Refactor.MapInto, false},
  {Credo.Check.Warning.LazyLogging, false},
  {Credo.Check.Readability.LargeNumbers, only_greater_than: 86400},
  {Credo.Check.Readability.ParenthesesOnZeroArityDefs, parens: true},
  {Credo.Check.Readability.Specs, tags: []},
  {Credo.Check.Readability.StrictModuleLayout, tags: []},
  {Credo.Check.Refactor.Nesting, max_nesting: 5},

  # Report TODO comments, but don't fail the check
  {Credo.Check.Design.TagTODO, exit_status: 0}
]

# Credo merges only the config named "default" with its built-in checks;
# any other named config runs exactly the checks it lists. The chain config
# starts from credo's own default set, so both configs run the same checks.
credo_default_checks =
  Mix.Project.deps_paths()
  |> Map.fetch!(:credo)
  |> Path.join(".credo.exs")
  |> Code.eval_file()
  |> elem(0)
  |> Map.fetch!(:configs)
  |> Enum.find(&(&1.name == "default"))
  |> get_in([:checks, :enabled])

%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "scripts/"], excluded: ["test/fixtures/"]},
      strict: true,
      checks: checks
    },
    # The chain test harness and its fixture, separate Mix projects
    # (integration/chain/README.md), checked by the library's credo.
    %{
      name: "chain",
      files: %{
        included: [
          "integration/chain/lib/",
          "integration/chain/test/",
          "integration/chain/fixture/lib/",
          "integration/chain/fixture/test/"
        ],
        excluded: []
      },
      strict: true,
      checks: Keyword.merge(credo_default_checks, checks)
    }
  ]
}
