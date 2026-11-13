# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Rebar3Config do
  @moduledoc false
  # The user's global rebar3 config, which rebar3 merges into every compile
  # Mix runs it for, a rebar3-managed dependency's included
  # (rebar3:init_config/0 merges it under the project's rebar.config, and
  # `mix deps.compile` runs `rebar3 bare compile` with REBAR_PROFILE=prod).
  # Its `erl_opts`, `overrides`, hooks, plugins and the like change what a
  # local compile produces, and no build records them, so a config that
  # sets any of them makes every rebar3-managed candidate miss.
  #
  # rebar3 reads `<dir>/.config/rebar3/rebar.config`, where `<dir>` is
  # REBAR_GLOBAL_CONFIG_DIR, else HOME. REBAR_CONFIG names a project config,
  # not the global one, and Mix overrides it with its own file anyway.
  # A `rebar.config.script` beside the file is evaluated by rebar3 and could
  # set anything, so it is a miss. A file rebar3 cannot read is ignored by
  # rebar3; here it is a miss all the same, as nothing tells the two
  # parsers agree.

  alias Precompiled.Reason

  # Keys only providers other than `bare compile` read (publishing, docs,
  # tests, releases, shells, analysis), plus project_plugins, which Mix
  # skips with REBAR_SKIP_PROJECT_PLUGINS.
  @inert ~w(hex rebar_packages_cdn alias shell dialyzer ct_opts eunit_opts
            cover_enabled cover_opts cover_excl_mods cover_excl_apps
            cover_export_enabled cover_print_enabled relx edoc_opts ex_doc
            xref_checks xref_queries xref_ignores xref_extra_paths dist_node
            escript_main_app escript_name escript_incl_apps escript_emu_args
            escript_shebang escript_comment project_plugins)a

  # The profiles a dependency's compile applies: default, prod (Mix sets
  # REBAR_PROFILE=prod) and global (the one rebar3 installs global plugins
  # under).
  @compile_profiles [:default, :prod, :global]

  @type getenv :: (String.t() -> String.t() | nil)

  @doc false
  @spec path(getenv()) :: Path.t() | nil
  def path(getenv) do
    case getenv.("REBAR_GLOBAL_CONFIG_DIR") || getenv.("HOME") do
      dir when is_binary(dir) and dir != "" ->
        Path.join([dir, ".config", "rebar3", "rebar.config"])

      _ ->
        nil
    end
  end

  @doc false
  # :ok when the global rebar3 config changes nothing a dependency's
  # compile produces, else a miss naming the file and the first key that
  # can (never its value).
  @spec check(getenv()) :: :ok | {:miss, Reason.t()}
  def check(getenv) do
    with file when is_binary(file) <- path(getenv),
         true <- File.regular?(file) do
      if File.exists?(file <> ".script"),
        do: miss(file, "script", "has a .script beside it"),
        else: judge(file, consult(file))
    else
      _ -> :ok
    end
  end

  defp consult(file) do
    case :file.consult(String.to_charlist(file)) do
      {:ok, terms} -> if Enum.all?(terms, &pair?/1), do: {:ok, terms}, else: :error
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp pair?({_key, _value}), do: true
  defp pair?(_), do: false

  defp judge(file, :error), do: miss(file, "unreadable", "could not be read")

  defp judge(file, {:ok, terms}) do
    case Enum.find_value(terms, &offending/1) do
      nil -> :ok
      key -> miss(file, key, "sets #{key}")
    end
  end

  defp offending({key, _}) when key in @inert, do: nil
  defp offending({_key, []}), do: nil

  defp offending({:profiles, profiles}) when is_list(profiles) do
    Enum.find_value(profiles, fn
      {name, opts} when name in @compile_profiles and is_list(opts) ->
        if Enum.all?(opts, &pair?/1) do
          with key when is_binary(key) <- Enum.find_value(opts, &offending/1),
               do: "profiles.#{name}.#{key}"
        else
          "profiles.#{name}"
        end

      {name, _opts} when is_atom(name) and name not in @compile_profiles ->
        nil

      _ ->
        "profiles"
    end)
  end

  defp offending({key, _}) when is_atom(key), do: Atom.to_string(key)
  defp offending({_key, _}), do: "?"

  defp miss(file, arg, what),
    do: {:miss, Reason.new(:rebar3_global_config, [arg], "global rebar3 config #{file} #{what}")}
end
