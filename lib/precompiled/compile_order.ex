# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CompileOrder do
  @moduledoc false
  # The order `mix deps.compile` compiles this project's deps in, and which
  # apps are loaded when a given dep compiles. The order is the list
  # Mix.Dep.load_and_cache/0 returns: Mix.Dep.Converger.converge/4 ends in
  # topological_sort/1 (:digraph_utils.topsort/1), and
  # Mix.Tasks.Deps.Compile.compile/2 walks it with Enum.each after
  # filtering. It is taken as given and never re-sorted: among unrelated
  # deps, topsort follows digraph's vertex table, not names or declaration
  # order. A partitioned compile (MIX_OS_DEPS_COMPILE_PARTITION_COUNT above
  # 1) runs in several OS processes and has no single order.
  #
  # compile.app loads a Mix dep's .app right after writing it, compile.all
  # loads a Mix dep's whole tree before compiling it (Mix.AppLoader), and a
  # loaded app stays loaded. A rebar3, make or custom-compiled dep compiles
  # in an OS process and loads nothing here. An app this project does not
  # depend on never compiles here, so it is never loaded, unless it ships
  # with OTP or Elixir: an earlier dep may load one of those all the same.
  #
  # The deps are read as plain maps, never as %Mix.Dep{}: this module is
  # reached from the device layer, which must not reference Mix.

  @type t ::
          %{apps: [String.t()], mix: MapSet.t(), trees: %{String.t() => MapSet.t()}}
          | {:ambiguous, String.t()}

  @spec from_deps([Mix.Dep.t()], String.t() | nil) :: t()
  def from_deps(deps, partition_count) do
    if partitioned?(partition_count) do
      {:ambiguous, "MIX_OS_DEPS_COMPILE_PARTITION_COUNT"}
    else
      deps = Enum.reject(deps, &(Keyword.get(&1.opts, :from_umbrella) == true))
      apps = Enum.map(deps, &name(&1.app))
      children = Map.new(deps, &{name(&1.app), Enum.map(&1.deps, fn d -> name(d.app) end)})

      %{
        apps: apps,
        mix: for(d <- deps, mix_compiled?(d), into: MapSet.new(), do: name(d.app)),
        trees: Map.new(apps, &{&1, tree(children[&1], children, MapSet.new())})
      }
    end
  end

  @spec apps(t()) :: [String.t()]
  def apps(%{apps: apps}), do: apps
  def apps(_ambiguous), do: []

  # Whether `app`'s .app is loaded when `reader` compiles: it is in the
  # reader's tree (compile.all loads it), or a Mix-compiled dep before the
  # reader has it as itself or in its tree. :unknown when the order cannot
  # say.
  @spec loaded_before?(t() | nil, String.t(), String.t()) :: boolean() | :unknown
  def loaded_before?(%{apps: apps, mix: mix, trees: trees}, app, reader) do
    with true <- MapSet.member?(mix, reader),
         i when is_integer(i) <- Enum.find_index(apps, &(&1 == reader)) do
      cond do
        app in apps ->
          MapSet.member?(trees[reader], app) or
            apps
            |> Enum.take(i)
            |> Enum.any?(
              &(MapSet.member?(mix, &1) and (&1 == app or MapSet.member?(trees[&1], app)))
            )

        shipped?(app) ->
          :unknown

        true ->
          false
      end
    else
      _ -> :unknown
    end
  end

  def loaded_before?(_order, _app, _reader), do: :unknown

  defp mix_compiled?(%{manager: :mix, opts: opts}), do: is_nil(opts[:compile])
  defp mix_compiled?(_dep), do: false

  defp tree(nil, _children, seen), do: seen

  defp tree(apps, children, seen) do
    Enum.reduce(apps, seen, fn app, seen ->
      if MapSet.member?(seen, app),
        do: seen,
        else: tree(children[app], children, MapSet.put(seen, app))
    end)
  end

  # An app whose .app file is under OTP's or Elixir's own lib directory.
  # The name comes from a manifest: only a plain app name is looked up.
  defp shipped?(app) do
    String.match?(app, ~r/\A[a-z][a-z0-9_]{0,254}\z/) and found_shipped?(app)
  end

  defp found_shipped?(app) do
    case :code.where_is_file(String.to_charlist(app <> ".app")) do
      :non_existing ->
        false

      path ->
        path = List.to_string(path)
        Enum.any?(shipped_roots(), &String.starts_with?(path, &1 <> "/"))
    end
  end

  defp shipped_roots() do
    elixir = :code.lib_dir(:elixir)
    otp = [List.to_string(:code.lib_dir())]
    if is_list(elixir), do: [Path.dirname(List.to_string(elixir)) | otp], else: otp
  end

  defp partitioned?(nil), do: false
  defp partitioned?(""), do: false

  defp partitioned?(count) do
    case Integer.parse(count) do
      {n, ""} -> n > 1
      _ -> true
    end
  end

  defp name(app), do: Atom.to_string(app)
end
