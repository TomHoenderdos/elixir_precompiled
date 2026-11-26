# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ProbeInputs do
  @moduledoc false
  # 0.10.0: a build's `probe` compile inputs. The package's closure asked at
  # compile time whether a module or an application is there, and on the
  # builder nothing could supply it, so the answer was "absent". This
  # project's own compile answers the same only when nothing in it can
  # supply it either: then the build is the one Mix would make here.
  #
  # Where a project can supply a module. Mix evaluates every dep's mix.exs
  # before any dep compiles, so what a mix.exs defines is loaded when the
  # asker compiles. A regular project prunes the code path to the compiling
  # app's own closure, so a dep outside it is visible only through what its
  # compile or its mix.exs loaded; Mix.install does not prune, so every dep
  # compiled earlier is on the path with all its modules. An archive, the
  # OTP install or an editor's VM (ElixirLS) may have the module on the
  # code path. The client over-approximates: any dep Mix loads here, of
  # either kind of project, counts with its whole module set.
  #
  # So an item holds when:
  #
  #   * `of: "module"`: no dep Mix loads in this env and target, by app or
  #     Hex package name, is in `definers` (the packages the portal knows
  #     define it; every lock entry when the deps did not load); the module
  #     is in no dep's exact module list, for every dep Mix loads outside
  #     the build's closure; and this VM's code path holds no
  #     `<name>.beam` and its VM has no such module loaded. A dep's exact
  #     module list is the one of its served build that matches this
  #     project (Precompiled.Check.module_provider/4): where a build
  #     matches, this project's own compile of the dep is that build, so
  #     its modules are the build's ebin and the modules its compile
  #     defined in memory (`build.defined_modules`, from the builder's
  #     trace). That build's own probe items are checked against this
  #     same view (Check.module_provider/4; a cycle or a chain deeper than
  #     eight is unknown). An inert dep (no manager, `compile: false`,
  #     `app: false` or no .app: Env.inert_deps) lists the beams in its
  #     ebin dirs. Any other dep Mix does not load from Hex as locked (a
  #     path or git dep, or one switched to it, 0.9.1's source rule), a
  #     release with no matching build, or a build
  #     without the list is one this client cannot tell: a miss;
  #   * `of: "module"` with `declared` (round 3): the declared-optional-
  #     dependency rule (declared_check/3): no dep is a definer, the code
  #     path and this VM lack it, every dep is a Hex one, no inert dep's
  #     ebin holds it; no other list needed;
  #   * `of: "app"`: no dep is that application, and this VM finds no
  #     `<name>.app` on its code path, under OTP's or Elixir's lib dir, or
  #     loaded;
  #   * `of: "otp_app"`: the application is installed nowhere here (no
  #     `<name>.app` under OTP's or Elixir's lib dir or on the code path, or
  #     loaded) and no dep has its name. The builder's pruned code path
  #     never held it, but Mix.install's would here, and any dep's compile
  #     could load it.
  #
  # The deps of the build's closure are the build's releases (the closure
  # rule checks them), and their compile is the build's, since every input
  # of the closure is checked: they are not read. The package itself is the
  # build. Without a view of the project (no deps read, or on a device)
  # every item is a miss.

  alias Precompiled.Reason

  @module_name ~r/\A[A-Za-z_][A-Za-z0-9_.@]{0,254}\z/
  @app_name ~r/\A[a-z][a-z0-9_]{0,254}\z/
  @max_definers 64
  @max_declared 8

  @type view :: %{
          names: MapSet.t(String.t()),
          deps: [String.t()] | nil,
          non_hex: [String.t()] | nil,
          modules_of: (String.t() -> {:ok, MapSet.t(String.t())} | :unknown),
          inert: [String.t()]
        }

  @doc false
  # The project as an item is checked against: `names`, every dep's app and
  # Hex package name; `deps`, the apps of the deps Mix loads (nil when they
  # were not read); `non_hex`, those that are no Hex dep (nil when unknown);
  # `modules_of`, a dep's exact module list (`{:ok, set}`) or `:unknown`;
  # `inert`, the inert deps (Env.inert_deps), whose lists are their beams.
  @spec view(
          MapSet.t(String.t()),
          [String.t()] | nil,
          [String.t()] | nil,
          function(),
          [String.t()]
        ) :: view()
  def view(names, deps, non_hex, modules_of, inert \\ []),
    do: %{names: names, deps: deps, non_hex: non_hex, modules_of: modules_of, inert: inert}

  @doc false
  @spec check(term(), map() | nil, String.t(), view() | nil) :: :ok | {:miss, Reason.t()}
  def check(item, closure, package, view) do
    case parse(item) do
      {:module, name, definers} -> module_check(name, definers, closure, package, view)
      {:declared, name, definers} -> declared_check(name, definers, view)
      {:app, name} -> app_check(name, view)
      {:otp_app, name} -> otp_check(name, view)
      :error -> malformed()
    end
  end

  @doc false
  # A served build's exact module list: its ebin's beams and the modules
  # its compile defined in memory. Without that list, :unknown.
  @spec module_set(map()) :: {:ok, MapSet.t(String.t())} | :unknown
  def module_set(%{"ebin" => ebin, "build" => %{"defined_modules" => defined}})
      when is_list(ebin) and is_list(defined) do
    beams =
      for %{"path" => "ebin/" <> file} <- ebin,
          Path.extname(file) == ".beam",
          do: Path.basename(file, ".beam")

    if Enum.all?(defined, &is_binary/1),
      do: {:ok, MapSet.new(beams ++ defined)},
      else: :unknown
  end

  def module_set(_entry), do: :unknown

  defp parse(%{"of" => "module", "name" => name, "answer" => "absent", "definers" => d} = item)
       when map_size(item) == 5 and is_list(d) and length(d) <= @max_definers do
    if Regex.match?(@module_name, name) and Enum.all?(d, &app_name?/1),
      do: {:module, name, d},
      else: :error
  end

  # Round 3: a module item whose declared packages (each a definer) decide
  # it, the declared-optional-dependency rule.
  defp parse(
         %{
           "of" => "module",
           "name" => name,
           "answer" => "absent",
           "definers" => d,
           "declared" => declared
         } = item
       )
       when map_size(item) == 6 and is_list(d) and length(d) <= @max_definers and
              is_list(declared) and declared != [] and length(declared) <= @max_declared do
    if Regex.match?(@module_name, name) and Enum.all?(d, &app_name?/1) and
         Enum.all?(declared, &(&1 in d)),
       do: {:declared, name, d},
       else: :error
  end

  defp parse(%{"of" => of, "name" => name, "answer" => "absent"} = item)
       when of in ["app", "otp_app"] and map_size(item) == 4 do
    cond do
      not app_name?(name) -> :error
      of == "app" -> {:app, name}
      true -> {:otp_app, name}
    end
  end

  defp parse(_item), do: :error

  defp app_name?(name), do: is_binary(name) and Regex.match?(@app_name, name)

  # --- a module -----------------------------------------------------------

  defp module_check(name, _definers, _closure, _package, nil), do: unknown(name)

  defp module_check(name, definers, closure, package, view) do
    shown = shown(name)

    cond do
      found = Enum.find(definers, &MapSet.member?(view.names, &1)) ->
        definer(shown, found)

      on_code_path?(name <> ".beam") or loaded?(name) ->
        definer(shown, "code_path")

      not is_list(view.deps) or view.non_hex != [] ->
        unknown(name)

      true ->
        view.deps
        |> Enum.reject(&(&1 == package or in_closure?(closure, &1)))
        |> Enum.sort()
        |> listed(name, shown, view)
    end
  end

  # The declared-optional-dependency rule (S10 round 3). The portal
  # recorded the module as one only its declared packages define in their
  # own namespace (the review gate, worker and portal), and `definers` holds
  # those packages and every package the module index of every Hex release
  # (its last and latest stable) and our builds' lists show defining it.
  # The project supplies it only if one of those is a dep, or the code path
  # or this VM has it: no other dep's module list is needed. A dep that is
  # no Hex dep (an inert one aside) is in no index: a miss; an inert dep's
  # beams on disk are read here (re-review R4). The residual: a module
  # defined by a macro or at compile time outside any tarball parse or
  # build list, by a dep other than the declared ones, from files no index
  # reads among them (an inert dep's sources, which a Hex dep's compile may
  # load: `Code.require_file/2`).
  defp declared_check(name, _definers, nil), do: unknown(name)

  defp declared_check(name, definers, view) do
    shown = shown(name)

    cond do
      found = Enum.find(definers, &MapSet.member?(view.names, &1)) -> definer(shown, found)
      on_code_path?(name <> ".beam") or loaded?(name) -> definer(shown, "code_path")
      not is_list(view.deps) or view.non_hex != [] -> unknown(name)
      found = inert_definer(name, view) -> definer(shown, found)
      true -> :ok
    end
  end

  # Re-review R4: an inert dep's beams on disk, which no index reads.
  defp inert_definer(name, view) do
    Enum.find(Map.get(view, :inert, []), fn app ->
      case view.modules_of.(app) do
        {:ok, modules} -> MapSet.member?(modules, name)
        _ -> false
      end
    end)
  end

  defp in_closure?(closure, app) when is_map(closure), do: Map.has_key?(closure, app)
  defp in_closure?(_closure, _app), do: false

  defp listed([], _name, _shown, _view), do: :ok

  defp listed([app | rest], name, shown, view) do
    case view.modules_of.(app) do
      {:ok, modules} ->
        if MapSet.member?(modules, name),
          do: definer(shown, app),
          else: listed(rest, name, shown, view)

      _unknown ->
        unknown(name)
    end
  end

  # --- applications ----------------------------------------------------------

  defp app_check(name, nil), do: unknown(name)

  defp app_check(name, view) do
    cond do
      MapSet.member?(view.names, name) -> definer(name, name)
      installed?(name) -> definer(name, "code_path")
      true -> :ok
    end
  end

  defp otp_check(name, nil), do: unknown(name)

  defp otp_check(name, view) do
    if MapSet.member?(view.names, name) or installed?(name),
      do: {:miss, Reason.new(:probe_otp_app, [name])},
      else: :ok
  end

  defp installed?(name), do: on_code_path?(name <> ".app") or shipped?(name) or app_loaded?(name)

  defp on_code_path?(file), do: :code.where_is_file(String.to_charlist(file)) != :non_existing

  # Loaded in this VM now, on the code path or not: the project's own
  # mix.exs and config are evaluated before any dep compiles, and what they
  # define is loaded when one does. A name no atom has yet is no module.
  defp loaded?(name) do
    :erlang.module_loaded(String.to_existing_atom(name))
  rescue
    ArgumentError -> false
  end

  defp app_loaded?(name) do
    atom = String.to_existing_atom(name)
    Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == atom))
  rescue
    ArgumentError -> false
  end

  # An application whose .app is under OTP's or Elixir's own lib directory,
  # pruned from the code path or not.
  defp shipped?(name) do
    Enum.any?(shipped_roots(), fn root ->
      [root, "{#{name},#{name}-*}", "ebin", name <> ".app"] |> Path.join() |> Path.wildcard() !=
        []
    end)
  end

  defp shipped_roots() do
    otp = [List.to_string(:code.lib_dir())]

    case :code.lib_dir(:elixir) do
      dir when is_list(dir) -> [Path.dirname(List.to_string(dir)) | otp]
      _ -> otp
    end
  end

  # --- reasons ----------------------------------------------------------------

  defp shown("Elixir." <> rest), do: rest
  defp shown(name), do: name

  defp definer(shown, by), do: {:miss, Reason.new(:probe_definer, [shown, by])}
  defp unknown(name), do: {:miss, Reason.new(:probe_unknown, [shown(name)])}
  defp malformed(), do: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}
end
