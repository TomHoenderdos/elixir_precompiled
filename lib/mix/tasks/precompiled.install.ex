# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Precompiled.Install do
    @shortdoc "Sets a project up to install signed precompiled dependency builds"
    @moduledoc """
    Run through `mix igniter.install precompiled`. Makes the
    `precompiled` dependency `runtime: false`, adds
    `config :precompiled, source: ...` to `config/config.exs`
    (`--source URL`, default the public Nerves compatibility portal) and puts
    `"deps.compile precompiled", "precompiled.deps"` at the front of
    the project's `deps.loadpaths` alias, before any steps already there.
    Running it again changes nothing. Not for umbrellas: add the alias to
    the umbrella root by hand (see `mix help precompiled.deps`).

    `--device` is for a Nerves firmware that should be able to install on
    the device itself (`Precompiled.install/1`, see the "On a device"
    guide). It does three things:

      * removes `runtime: false` from the dependency, so the library ships
        in the firmware;
      * adds `{:castore, "~> 1.0"}` unless the project already depends on
        `castore`. The check looks at the dependencies only: a firmware
        that sets `cacerts_path:` under `config :precompiled,
        :device` still gets `castore` added, and can drop it again;
      * adds `:inets`, `:ssl` and `:public_key` to `extra_applications`:
        they are optional applications of this library, and an online
        install needs them.

    Nothing else is written for the device: it is on by default and uses
    the official signed source.
    """
    use Igniter.Mix.Task

    @source "https://compatibility.nerves-project.org/api/precompiled"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :precompiled,
        example: "mix igniter.install precompiled",
        schema: [source: :string, device: :boolean],
        defaults: [source: @source]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      source = igniter.args.options[:source]
      device? = igniter.args.options[:device]

      # The two add_alias calls compose. With no alias the first writes the
      # whole list and the second finds its entry present. With an alias of
      # the user's (nerves_bootstrap's, say) the first prepends
      # "precompiled.deps" and the second "deps.compile precompiled"
      # before it. Neither adds an entry already in the list.
      igniter
      |> keep_runtime(device?)
      |> add_castore(device?)
      |> add_network_apps(device?)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :precompiled,
        [:source],
        source
      )
      |> Igniter.Project.TaskAliases.add_alias(
        :"deps.loadpaths",
        ["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"],
        if_exists: {:prepend, "precompiled.deps"}
      )
      |> Igniter.Project.TaskAliases.add_alias(
        :"deps.loadpaths",
        "deps.compile precompiled",
        if_exists: {:prepend, "deps.compile precompiled"}
      )
      |> Igniter.add_notice("""
      precompiled: dependencies with a matching signed build are now
      installed instead of compiled. `mix precompiled.status` lists them;
      PRECOMPILED=0 turns it off (and removes them).
      """)
      |> add_device_notice(device?)
    end

    # Without --device the dependency only runs at build time, as it does
    # today. With --device it stays at runtime: the library ships in the
    # firmware so a shell on the device can call `Precompiled.install/1`.
    # `runtime: true` is the default, so --device only takes an existing
    # `runtime: false` away, by editing the tuple in place: set_dep_option/4
    # would hit the one-liner `defp deps, do: [...]` bug below.
    defp keep_runtime(igniter, true) do
      Igniter.update_elixir_file(igniter, "mix.exs", fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Module.move_to_module_using(zipper, Mix.Project),
             {:ok, zipper} <- Igniter.Code.Function.move_to_defp(zipper, :deps, 0),
             {:ok, dep} <- Igniter.Code.List.move_to_list_item(zipper, &our_dep?/1),
             {:ok, opts} <- Igniter.Code.Tuple.tuple_elem(dep, 2),
             {:ok, value} <- Igniter.Code.Keyword.get_key(opts, :runtime),
             true <- Igniter.Code.Common.nodes_equal?(value, false) do
          drop_runtime(dep, opts)
        else
          _ -> {:ok, zipper}
        end
      end)
    end

    defp keep_runtime(igniter, _device?), do: runtime_false(igniter)

    # The only option: back to the plain 2-tuple. Otherwise just that key.
    defp drop_runtime(dep, opts) do
      opts = Igniter.Code.Common.maybe_move_to_single_child_block(opts)

      case opts.node do
        [_only] ->
          {:ok, name} = Igniter.Code.Tuple.tuple_elem(dep, 0)
          {:ok, version} = Igniter.Code.Tuple.tuple_elem(dep, 1)
          code = "{#{Sourceror.to_string(name.node)}, #{Sourceror.to_string(version.node)}}"
          {:ok, Igniter.Code.Common.replace_code(dep, code)}

        _ ->
          Igniter.Code.Keyword.remove_keyword_key(opts, :runtime)
      end
    end

    # A firmware that installs online needs the network apps in its
    # release; they are optional applications of this library, so a
    # firmware without them would refuse with {:missing_app, :inets}.
    defp add_network_apps(igniter, true) do
      Igniter.Project.MixProject.update(igniter, :application, [:extra_applications], fn
        nil ->
          {:ok, {:code, [:inets, :ssl, :public_key]}}

        zipper ->
          Enum.reduce_while([:inets, :ssl, :public_key], {:ok, zipper}, fn app, {:ok, z} ->
            case Igniter.Code.List.append_new_to_list(z, app) do
              {:ok, z} -> {:cont, {:ok, z}}
              :error -> {:halt, :error}
            end
          end)
      end)
    end

    defp add_network_apps(igniter, _device?), do: igniter

    # A Nerves system's CA store may be empty, so a device install needs its
    # own certificates. Only the deps are checked: a `cacerts_path:` in the
    # device config is not looked for (see the moduledoc).
    defp add_castore(igniter, true) do
      if Igniter.Project.Deps.has_dep?(igniter, :castore) do
        igniter
      else
        Igniter.Project.Deps.add_dep(igniter, {:castore, "~> 1.0"})
      end
    end

    defp add_castore(igniter, _device?), do: igniter

    defp add_device_notice(igniter, true) do
      Igniter.add_notice(igniter, """
      On the device: Precompiled.install(:recon). See the "On a device" guide.
      """)
    end

    defp add_device_notice(igniter, _device?), do: igniter

    # Igniter.Project.Deps.set_dep_option/4 writes `:runtime => false` into
    # a `{name, "~> x"}` tuple (invalid Elixir) when `deps` is defined as a
    # one-liner, `defp deps, do: [...]`; the standard `defp deps do [...]
    # end` block form is unaffected. So that one shape gets its options
    # list here; every other shape goes through set_dep_option/4.
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
      |> Igniter.Project.Deps.set_dep_option(:precompiled, :runtime, false)
    end

    defp our_dep?(zipper) do
      with true <- Igniter.Code.Tuple.tuple?(zipper),
           {:ok, name} <- Igniter.Code.Tuple.tuple_elem(zipper, 0) do
        Igniter.Code.Common.nodes_equal?(name, :precompiled)
      else
        _ -> false
      end
    end
  end
else
  defmodule Mix.Tasks.Precompiled.Install do
    @shortdoc "Sets a project up to install signed precompiled dependency builds"
    @moduledoc false
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      mix precompiled.install runs through Igniter: `mix igniter.install precompiled`.
      Without Igniter, add this to the project in mix.exs (the umbrella root in an umbrella):

          aliases: ["deps.loadpaths": ["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"]]

      and `config :precompiled, source: "https://compatibility.nerves-project.org/api/precompiled"`
      to config/config.exs (or set PRECOMPILED_SOURCE).
      """)
    end
  end
end
