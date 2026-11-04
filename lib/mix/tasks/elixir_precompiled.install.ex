# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ElixirPrecompiled.Install do
    @shortdoc "Sets a project up to install signed precompiled dependency builds"
    @moduledoc """
    Run through `mix igniter.install elixir_precompiled`. Makes the
    `elixir_precompiled` dependency `runtime: false`, adds
    `config :elixir_precompiled, source: ...` to `config/config.exs`
    (`--source URL`, default the public Nerves compatibility portal) and puts
    `"deps.compile elixir_precompiled", "precompiled.install"` at the front of
    the project's `deps.loadpaths` alias, before any steps already there.
    Running it again changes nothing. Not for umbrellas: add the alias to
    the umbrella root by hand (see `mix help precompiled.install`).
    """
    use Igniter.Mix.Task

    @source "https://compatibility.nerves-project.org/api/precompiled"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :elixir_precompiled,
        example: "mix igniter.install elixir_precompiled",
        schema: [source: :string],
        defaults: [source: @source]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      source = igniter.args.options[:source]

      # The two add_alias calls compose. With no alias the first writes the
      # whole list and the second finds its entry present. With an alias of
      # the user's (nerves_bootstrap's, say) the first prepends
      # "precompiled.install" and the second "deps.compile elixir_precompiled"
      # before it. Neither adds an entry already in the list.
      igniter
      |> runtime_false()
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :elixir_precompiled,
        [:source],
        source
      )
      |> Igniter.Project.TaskAliases.add_alias(
        :"deps.loadpaths",
        ["deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"],
        if_exists: {:prepend, "precompiled.install"}
      )
      |> Igniter.Project.TaskAliases.add_alias(
        :"deps.loadpaths",
        "deps.compile elixir_precompiled",
        if_exists: {:prepend, "deps.compile elixir_precompiled"}
      )
      |> Igniter.add_notice("""
      elixir_precompiled: dependencies with a matching signed build are now
      installed instead of compiled. `mix precompiled.status` lists them;
      ELIXIR_PRECOMPILED=0 turns it off (and removes them).
      """)
    end

    # Igniter.Project.Deps.set_dep_option/4 writes `:runtime => false` into
    # a `{name, "~> x"}` tuple (invalid Elixir), so that one shape gets its
    # options list here; every other shape goes through set_dep_option/4.
    defp runtime_false(igniter) do
      igniter
      |> Igniter.update_elixir_file("mix.exs", fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Module.move_to_module_using(zipper, Mix.Project),
             {:ok, zipper} <- Igniter.Code.Function.move_to_defp(zipper, :deps, 0),
             true <- Igniter.Code.List.list?(zipper),
             {:ok, zipper} <- Igniter.Code.List.move_to_list_item(zipper, &our_dep?/1),
             {:ok, version} <- Igniter.Code.Tuple.tuple_elem(zipper, 1),
             true <- Igniter.Code.String.string?(version),
             :error <- Igniter.Code.Tuple.tuple_elem(zipper, 2) do
          {:{}, _, [_, _, opts]} = Sourceror.parse_string!(~s({:x, "", runtime: false}))
          Igniter.Code.Tuple.append_elem(zipper, opts)
        else
          _ -> {:ok, zipper}
        end
      end)
      |> Igniter.Project.Deps.set_dep_option(:elixir_precompiled, :runtime, false)
    end

    defp our_dep?(zipper) do
      with true <- Igniter.Code.Tuple.tuple?(zipper),
           {:ok, name} <- Igniter.Code.Tuple.tuple_elem(zipper, 0) do
        Igniter.Code.Common.nodes_equal?(name, :elixir_precompiled)
      else
        _ -> false
      end
    end
  end
else
  defmodule Mix.Tasks.ElixirPrecompiled.Install do
    @shortdoc "Sets a project up to install signed precompiled dependency builds"
    @moduledoc false
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      mix elixir_precompiled.install runs through Igniter: `mix igniter.install elixir_precompiled`.
      Without Igniter, add this to the project in mix.exs (the umbrella root in an umbrella):

          aliases: ["deps.loadpaths": ["deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"]]

      and `config :elixir_precompiled, source: "https://compatibility.nerves-project.org/api/precompiled"`
      to config/config.exs (or set ELIXIR_PRECOMPILED_SOURCE).
      """)
    end
  end
end
