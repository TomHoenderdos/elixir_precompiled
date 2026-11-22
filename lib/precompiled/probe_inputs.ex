# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ProbeInputs do
  @moduledoc false
  # 0.9.0: a build's `probe` compile inputs. The package's closure asked at
  # compile time whether a module or an application is there, and on the
  # builder nothing could supply it, so the answer was "absent". This
  # project's own compile answers the same only when nothing in it can
  # supply it either: then the build is the one Mix would make here. Mix
  # finds a module when a dep compiled before the asker in the same VM
  # defines it (its modules stay loaded), when Mix.install's unpruned code
  # path holds it, or when an archive, the OTP install or an editor's VM
  # (ElixirLS) has it on the code path. So an item holds when:
  #
  #   * `of: "module"`: no dep Mix loads in the project, by app or Hex
  #     package name, is in `definers` (the packages the portal knows define
  #     it; a lock entry Mix leaves out of this env never compiles here); no dep
  #     outside the build's closure defines it in its sources (read below);
  #     and this VM's code path has no `<name>.beam`;
  #   * `of: "app"`: no dep of the project is that application, and this VM
  #     finds no `<name>.app` on its code path or under OTP's or Elixir's lib
  #     dir;
  #   * `of: "otp_app"`: the application is installed nowhere here (no
  #     `<name>.app` under OTP's or Elixir's lib dir or on the code path) and
  #     no dep has its name. The builder's pruned code path never held it,
  #     but Mix.install's would here, and any dep's compile could load it.
  #
  # The deps of the build's closure are the build's releases (the closure
  # rule checks them), and their compile is the build's, since every input
  # of the closure is checked: they are not read.
  #
  # A dep's sources are read as the portal reads a Hex tarball
  # (Compatibility.HexModules): every literal defmodule, defprotocol and
  # defimpl name with its nesting, every -module of an Erlang file, and a
  # leex or yecc file's base name. No atom is created. Only a file that
  # holds the module's last name segment can define it under a literal
  # name, so only those are parsed. Such a file that defines a module under
  # a name it computes (defmodule or defprotocol of anything but a literal,
  # a defimpl whose module could be this one, Module.create/3, a Code
  # compile or eval call, an Erlang compile:forms or code:load_binary) is
  # one this client cannot tell, as is a dep without a readable dir, a
  # symbolic link in its tree, a file it cannot read or parse, or a tree
  # over the caps: a miss. What stays is a dep outside the build's closure
  # that builds the module's name from parts no file holding its last
  # segment shows, in a release the portal does not list as a definer.
  #
  # A dep's answer for a name is kept for the run in `memo` (an ETS table
  # Precompiled.Check makes per run), so each dep is read once per name.

  alias Precompiled.Reason

  @module_name ~r/\A[A-Za-z_][A-Za-z0-9_.@]{0,254}\z/
  @app_name ~r/\A[a-z][a-z0-9_]{0,254}\z/
  @max_definers 64
  @max_files 20_000
  @max_file_bytes 8 * 1024 * 1024
  @max_parse_bytes 64 * 1024 * 1024
  @source_exts [".ex", ".erl", ".xrl", ".yrl"]
  # Dirs of a dep that Mix never compiles as its sources.
  @not_sources ["_build", "deps", "node_modules"]
  @compile_calls ~w(compile_string compile_quoted compile_file eval_string eval_quoted
                    eval_file require_file eval_quoted_with_env)

  @type view :: %{
          names: MapSet.t(String.t()),
          dirs: %{optional(String.t()) => String.t() | nil} | nil,
          memo: :ets.tid() | atom() | nil
        }

  @doc false
  # The project as an item is checked against: `names`, every dep's app and
  # Hex package name and every lock entry's; `dirs`, each dep Mix loads by
  # app name and its source dir (nil when the deps were not read); `memo`,
  # the run's table or nil.
  @spec view(MapSet.t(String.t()), map() | nil, :ets.tid() | atom() | nil) :: view()
  def view(names, dirs, memo), do: %{names: names, dirs: dirs, memo: memo}

  @doc false
  @spec check(term(), map() | nil, String.t(), view() | nil) :: :ok | {:miss, Reason.t()}
  def check(item, closure, package, view) do
    case parse(item) do
      {:module, name, definers} -> module_check(name, definers, closure, package, view)
      {:app, name} -> app_check(name, view)
      {:otp_app, name} -> otp_check(name, view)
      :error -> malformed()
    end
  end

  defp parse(%{"of" => "module", "name" => name, "answer" => "absent", "definers" => d} = item)
       when map_size(item) == 5 and is_list(d) and length(d) <= @max_definers do
    if Regex.match?(@module_name, name) and Enum.all?(d, &app_name?/1),
      do: {:module, name, d},
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
  defp module_check(name, _definers, _closure, _package, %{dirs: nil}), do: unknown(name)

  defp module_check(name, definers, closure, package, view) do
    shown = shown(name)

    cond do
      found = Enum.find(definers, &MapSet.member?(view.names, &1)) ->
        definer(shown, found)

      on_code_path?(name <> ".beam") ->
        definer(shown, "code_path")

      true ->
        outside =
          view.dirs |> Map.keys() |> Enum.reject(&(&1 == package or in_closure?(closure, &1)))

        scan_deps(Enum.sort(outside), name, shown, view)
    end
  end

  defp in_closure?(closure, app) when is_map(closure), do: Map.has_key?(closure, app)
  defp in_closure?(_closure, _app), do: false

  defp scan_deps([], _name, _shown, _view), do: :ok

  defp scan_deps([app | rest], name, shown, view) do
    case memo(view.memo, {Map.get(view.dirs, app), name}, fn ->
           scan(Map.get(view.dirs, app), name)
         end) do
      :clear -> scan_deps(rest, name, shown, view)
      :defines -> definer(shown, app)
      :unknown -> unknown(name)
    end
  end

  defp memo(nil, _key, fun), do: fun.()

  defp memo(table, key, fun) do
    case :ets.lookup(table, key) do
      [{^key, answer}] ->
        answer

      [] ->
        answer = fun.()
        :ets.insert(table, {key, answer})
        answer
    end
  rescue
    ArgumentError -> fun.()
  end

  # Whether the source tree at `dir` defines `name`: :defines, :clear or
  # :unknown.
  defp scan(dir, name) when is_binary(dir) do
    case source_files(dir) do
      {:ok, files} -> scan_files(files, name, needle(name), 0)
      :error -> :unknown
    end
  end

  defp scan(_dir, _name), do: :unknown

  defp scan_files([], _name, _needle, _parsed), do: :clear

  defp scan_files([path | rest], name, needle, parsed) do
    case scan_file(path, name, needle) do
      {:clear, bytes} when parsed + bytes <= @max_parse_bytes ->
        scan_files(rest, name, needle, parsed + bytes)

      {:clear, _bytes} ->
        :unknown

      answer ->
        answer
    end
  end

  # The module's last name segment, as a file that defines it under a
  # literal name must hold it.
  defp needle("Elixir." <> rest), do: rest |> String.split(".") |> List.last()
  defp needle(name), do: name

  defp scan_file(path, name, needle) do
    ext = Path.extname(path)

    if ext in [".xrl", ".yrl"] do
      if Path.basename(path, ext) == name, do: :defines, else: {:clear, 0}
    else
      case File.read(path) do
        {:ok, body} when byte_size(body) <= @max_file_bytes ->
          body_answer(ext, body, name, needle)

        _ ->
          :unknown
      end
    end
  end

  defp body_answer(ext, body, name, needle) do
    cond do
      not String.contains?(body, needle) -> {:clear, 0}
      ext == ".erl" -> erlang_answer(body, name)
      true -> elixir_answer(body, name)
    end
  end

  defp erlang_answer(body, name) do
    cond do
      Regex.match?(~r/^\s*-module\(\s*'?#{Regex.escape(name)}'?\s*\)/m, body) -> :defines
      Regex.match?(~r/\b(compile:forms|code:load_binary)\b/, body) -> :unknown
      true -> {:clear, 0}
    end
  end

  defp elixir_answer(body, name) do
    with {:ok, ast} <- quoted(body),
         {:ok, top} <- aliases(ast, :top),
         {:ok, all} <- aliases(ast, :all) do
      scope = %{top: top, all: Map.merge(all, defined(ast, top), fn _k, a, b -> a ++ b end)}

      case walk(ast, [], name, scope, false) do
        :clear -> {:clear, byte_size(body)}
        answer -> answer
      end
    else
      _ -> :unknown
    end
  end

  # No atom is created: every atom of the source comes back as {:atom, name}.
  defp quoted(body) do
    with true <- String.valid?(body),
         {:ok, ast} <-
           Code.string_to_quoted(body,
             static_atoms_encoder: fn atom, _meta -> {:ok, {:atom, atom}} end,
             existing_atoms_only: true,
             columns: false,
             emit_warnings: false
           ) do
      {:ok, ast}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # :defines as soon as a definition can be `name`, :unknown as soon as one
  # whose name this client cannot work out could be; :clear otherwise.
  # Elixir names a module defined inside another by nesting it under that
  # one, and a top-level one through the aliases in scope; `scope` holds
  # every alias the file makes (`:top` outside every module, `:all`
  # anywhere, with every module the file defines as its own alias), so the
  # names worked out here are a superset of Elixir's. A definition inside a
  # `quote` is named where the macro expands: computed.
  defp walk({{:atom, kind}, _, [name_ast | rest]}, outers, name, scope, quoted?)
       when kind in ["defmodule", "defprotocol"] do
    case module_names(name_ast, outers, scope, quoted?) do
      :unknown -> :unknown
      names -> if name in names, do: :defines, else: walk(rest, names, name, scope, quoted?)
    end
  end

  defp walk({{:atom, "defimpl"}, _, [proto_ast | rest]}, outers, name, scope, quoted?) do
    case impl_answer(proto_ast, rest, outers, name, scope) do
      :clear -> walk(rest, outers, name, scope, quoted?)
      other -> other
    end
  end

  defp walk({{:atom, "quote"}, _, args}, outers, name, scope, _quoted?),
    do: walk(args, outers, name, scope, true)

  defp walk(
         {{:., _, [{:__aliases__, _, [{:atom, "Module"}]}, {:atom, "create"}]}, _, _},
         _,
         _,
         _,
         _
       ),
       do: :unknown

  defp walk({{:., _, [{:__aliases__, _, [{:atom, "Code"}]}, {:atom, fun}]}, _, _}, _, _, _, _)
       when fun in @compile_calls,
       do: :unknown

  defp walk({a, _meta, args}, outers, name, scope, quoted?),
    do:
      both(walk(a, outers, name, scope, quoted?), fn ->
        walk(args, outers, name, scope, quoted?)
      end)

  defp walk({l, r}, outers, name, scope, quoted?),
    do:
      both(walk(l, outers, name, scope, quoted?), fn -> walk(r, outers, name, scope, quoted?) end)

  defp walk(list, outers, name, scope, quoted?) when is_list(list) do
    Enum.reduce_while(list, :clear, fn node, :clear ->
      case walk(node, outers, name, scope, quoted?) do
        :clear -> {:cont, :clear}
        answer -> {:halt, answer}
      end
    end)
  end

  defp walk(_other, _outers, _name, _scope, _quoted?), do: :clear

  defp both(:clear, next), do: next.()
  defp both(answer, _next), do: answer

  # The names a defmodule or defprotocol can give: nested under each name
  # its enclosing module can have, or, at the top level, the literal name
  # and every expansion through a top-level alias of its first segment. A
  # name that is no literal alias, a definition inside a quote, or an alias
  # this client could not read is :unknown.
  defp module_names(_ast, _outers, _scope, true), do: :unknown

  defp module_names(ast, outers, scope, false) do
    case segments(ast) do
      {:absolute, joined} ->
        [joined]

      {:relative, [head | _] = segs} when outers == [] ->
        expand(head, segs, scope.top)

      {:relative, segs} ->
        Enum.uniq(for o <- outers, do: o <> "." <> Enum.join(segs, "."))

      {:atom, atom} ->
        [atom]

      :error ->
        :unknown
    end
  end

  # An alias as `{:absolute, "Elixir.A.B"}`, `{:relative, ["A", "B"]}` or a
  # literal atom `{:atom, name}`; anything else :error.
  defp segments({:__aliases__, _, parts}) do
    names = for {:atom, p} <- parts, do: p

    cond do
      names == [] or length(names) != length(parts) -> :error
      hd(names) == "Elixir" -> {:absolute, Enum.join(names, ".")}
      true -> {:relative, names}
    end
  end

  defp segments({:atom, name}) when is_binary(name), do: {:atom, name}
  defp segments(_ast), do: :error

  # `Elixir.<segs>` and every alias of `head` in `aliases` with the rest of
  # `segs`; :unknown when an alias in scope could not be read.
  defp expand(head, segs, aliases) do
    rest = tl(segs)

    case {Map.get(aliases, :any), Map.get(aliases, head, [])} do
      {[_ | _], _} ->
        :unknown

      {_, targets} ->
        if :unknown in targets,
          do: :unknown,
          else:
            Enum.uniq([
              "Elixir." <> Enum.join(segs, ".")
              | for(t <- targets, do: Enum.join([t | rest], "."))
            ])
    end
  end

  # An implementation is `Protocol.For`, both expanded through the file's
  # aliases: `name` exactly, or not. A protocol whose name cannot be worked
  # out could be anything; a `for:` that cannot is some module under the
  # protocol.
  defp impl_answer(proto_ast, rest, outers, name, scope) do
    case names_anywhere(proto_ast, scope.all) do
      :unknown ->
        :unknown

      protos ->
        fors =
          case rest |> Enum.filter(&is_list/1) |> Enum.flat_map(&for_option/1) do
            [] when outers != [] -> outers
            [] -> :unknown
            given -> given |> Enum.map(&names_anywhere(&1, scope.all)) |> flat_or_unknown()
          end

        impl_names(protos, fors, name)
    end
  end

  defp impl_names(protos, :unknown, name) do
    if Enum.any?(protos, &String.starts_with?(name, &1 <> ".")), do: :unknown, else: :clear
  end

  defp impl_names(protos, fors, name) do
    impls = for p <- protos, f <- fors, do: p <> "." <> String.replace_prefix(f, "Elixir.", "")
    if name in impls, do: :defines, else: :clear
  end

  defp flat_or_unknown(lists),
    do: if(:unknown in lists, do: :unknown, else: lists |> List.flatten() |> Enum.uniq())

  # An alias used anywhere in the file: its literal name and every
  # expansion through any alias the file makes.
  defp names_anywhere(ast, aliases) do
    case segments(ast) do
      {:absolute, joined} -> [joined]
      {:atom, atom} -> [atom]
      {:relative, [head | _] = segs} -> expand(head, segs, aliases)
      :error -> :unknown
    end
  end

  defp for_option(kw) do
    Enum.flat_map(kw, fn
      {key, value} when key in [:for, {:atom, "for"}] -> List.wrap(value)
      _ -> []
    end)
  end

  # The aliases the file makes, `%{first_segment => [target | :unknown]}`,
  # with `:any` for one whose name cannot be read: `:top` those outside
  # every module, `:all` every one. `alias A.B`, `alias A.B, as: C` and
  # `alias A.{B, C}`.
  defp aliases(ast, which) do
    {:ok, collect_aliases(ast, which, %{})}
  end

  defp collect_aliases({{:atom, kind}, _, _}, :top, acc)
       when kind in ["defmodule", "defprotocol", "defimpl"],
       do: acc

  defp collect_aliases({{:atom, "alias"}, _, [target | opts]}, which, acc) do
    acc =
      Enum.reduce(alias_pairs(target, opts), acc, fn {key, t}, acc ->
        Map.update(acc, key, [t], &[t | &1])
      end)

    collect_aliases(opts, which, acc)
  end

  defp collect_aliases({a, _meta, args}, which, acc),
    do: collect_aliases(args, which, collect_aliases(a, which, acc))

  defp collect_aliases({l, r}, which, acc),
    do: collect_aliases(r, which, collect_aliases(l, which, acc))

  defp collect_aliases(list, which, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_aliases(&1, which, &2))

  defp collect_aliases(_other, _which, acc), do: acc

  defp alias_pairs({{:., _, [base, multi]}, _, children}, _opts)
       when multi in [:{}, {:atom, "{}"}] do
    case alias_target(base) do
      {:absolute_or_relative, base} ->
        Enum.flat_map(children, fn child ->
          case segments(child) do
            {:relative, segs} -> [{List.last(segs), Enum.join([base | segs], ".")}]
            _ -> [{:any, :unknown}]
          end
        end)

      :error ->
        [{:any, :unknown}]
    end
  end

  defp alias_pairs(target, opts) do
    as = opts |> List.flatten() |> Enum.find_value(&as_option/1)

    case {alias_target(target), as} do
      {{:absolute_or_relative, full}, nil} -> [{full |> String.split(".") |> List.last(), full}]
      {{:absolute_or_relative, full}, {:ok, key}} -> [{key, full}]
      {_, {:ok, key}} -> [{key, :unknown}]
      _ -> [{:any, :unknown}]
    end
  end

  defp as_option({key, value}) when key in [:as, {:atom, "as"}] do
    case segments(value) do
      {:relative, [key]} -> {:ok, key}
      _ -> {:ok, :any}
    end
  end

  defp as_option(_other), do: nil

  # An alias directive's target as Elixir names it, without the aliases in
  # scope (`alias A.B` after `alias X.A` is X.A.B): over-approximated by the
  # expansion of its first segment as well, through `expand/3` at use.
  defp alias_target(ast) do
    case segments(ast) do
      {:absolute, joined} -> {:absolute_or_relative, joined}
      {:relative, segs} -> {:absolute_or_relative, "Elixir." <> Enum.join(segs, ".")}
      _ -> :error
    end
  end

  # Every module the file defines, by the alias of its last segment Elixir
  # makes in the enclosing module: each name it can have, as
  # `module_names/4` works them out, or :unknown.
  defp defined(ast, top), do: defined(ast, [], %{top: top}, false, %{})

  defp defined({{:atom, kind}, _, [name_ast | rest]}, outers, scope, quoted?, acc)
       when kind in ["defmodule", "defprotocol"] do
    case {segments(name_ast), module_names(name_ast, outers, scope, quoted?)} do
      {{:relative, segs}, :unknown} ->
        Map.update(acc, List.last(segs), [:unknown], &[:unknown | &1])

      {{:relative, segs}, names} ->
        acc = Map.update(acc, List.last(segs), names, &(names ++ &1))
        defined(rest, names, scope, quoted?, acc)

      {_, names} when is_list(names) ->
        defined(rest, names, scope, quoted?, acc)

      _ ->
        acc
    end
  end

  defp defined({{:atom, "quote"}, _, args}, outers, scope, _quoted?, acc),
    do: defined(args, outers, scope, true, acc)

  defp defined({a, _meta, args}, outers, scope, quoted?, acc),
    do: defined(args, outers, scope, quoted?, defined(a, outers, scope, quoted?, acc))

  defp defined({l, r}, outers, scope, quoted?, acc),
    do: defined(r, outers, scope, quoted?, defined(l, outers, scope, quoted?, acc))

  defp defined(list, outers, scope, quoted?, acc) when is_list(list),
    do: Enum.reduce(list, acc, &defined(&1, outers, scope, quoted?, &2))

  defp defined(_other, _outers, _scope, _quoted?, acc), do: acc

  # Every source file of the tree at `dir`, walked without following a
  # link: hidden entries and the dirs Mix never compiles as sources are
  # skipped; a link, an unreadable dir or more than @max_files sources is
  # :error.
  defp source_files(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> walk_dir([dir], [], 0)
      _ -> :error
    end
  end

  defp walk_dir([], acc, _count), do: {:ok, Enum.sort(acc)}

  defp walk_dir([dir | rest], acc, count) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @not_sources))
        |> Enum.reduce_while({rest, acc, count}, &entry(Path.join(dir, &1), &2))
        |> case do
          {rest, acc, count} -> walk_dir(rest, acc, count)
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp entry(path, {dirs, files, count}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:cont, {[path | dirs], files, count}}

      {:ok, %File.Stat{type: :regular}} ->
        cond do
          Path.extname(path) not in @source_exts -> {:cont, {dirs, files, count}}
          count >= @max_files -> {:halt, :error}
          true -> {:cont, {dirs, [path | files], count + 1}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:halt, :error}

      {:ok, _other} ->
        {:cont, {dirs, files, count}}

      _ ->
        {:halt, :error}
    end
  end

  # --- applications ----------------------------------------------------------

  defp app_check(name, nil), do: unknown(name)

  defp app_check(name, view) do
    cond do
      MapSet.member?(view.names, name) -> definer(name, name)
      on_code_path?(name <> ".app") or shipped?(name) -> definer(name, "code_path")
      true -> :ok
    end
  end

  defp otp_check(name, view) do
    names = if view, do: view.names, else: MapSet.new()

    if MapSet.member?(names, name) or shipped?(name) or on_code_path?(name <> ".app"),
      do: {:miss, Reason.new(:probe_otp_app, [name])},
      else: :ok
  end

  defp on_code_path?(file), do: :code.where_is_file(String.to_charlist(file)) != :non_existing

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
