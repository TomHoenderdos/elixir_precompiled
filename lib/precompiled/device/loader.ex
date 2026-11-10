# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Loader do
  @moduledoc false
  # Puts an installed app into the running VM and takes it out again (spec
  # section 6). Nothing here runs at boot: only an install or uninstall call
  # reaches it.
  #
  # Serialization. activate/5, deactivate/3 and rollback/1 are safe only
  # when every call runs under the store lock (Store.with_lock/2): the
  # conflict checks, the record of what was loaded and the code path are
  # read and changed without any lock of their own.
  #
  # Code path (6.1). The install's ebin is appended with :code.add_pathz/1,
  # as exactly the string Path.join(install_path, "ebin"), so the store's
  # in-use check sees the same name. The release's own code always wins a
  # lookup.
  #
  # Conflicts (6.2). Nothing is ever replaced: an app that is already
  # present, a module that is loaded, or a module the code path already
  # resolves is refused, both by conflicts/3 and again by activate/5.
  #
  # Loading (6.3). The .app and every beam are read once and checked
  # against the build's file list (sha256 and size). The app is loaded from
  # the parsed bytes ({:application, app, props}) and the modules from the
  # verified binaries, so nothing is re-read from disk after the check.
  # Every priv file in the list is re-hashed in the same step, just before
  # anything loads: a NIF's .so is dlopened from disk by the package's own
  # on_load, so this narrows the window between the check and the dlopen to
  # the activation itself. The
  # modules load with :code.atomic_load/1; the -on_load ones it refuses load
  # afterwards one at a time, in .app order, with :code.load_binary/3.
  # Explicit loading works the same in embedded mode, where nothing
  # autoloads. Apps start :temporary.
  #
  # Uninstall and rollback (6.4). activate/5 records in this VM which ebin
  # and which modules it loaded for an app. deactivate/3 acts only on that
  # record and only on modules still loaded from that ebin, so a .app
  # rewritten on disk can never make it delete or purge firmware code. With
  # no record it does nothing. A failed activate tears down what it did
  # before returning. The record is written before the code path changes,
  # so a crash between the two never leaves an unrecorded path behind.
  #
  # Apps started on the way. Application.ensure_all_started/2 also starts
  # the app's dependencies that were not running, firmware apps included;
  # the record keeps that list. rollback/1, which undoes activations of the
  # same call seconds later, stops those apps again (newest first, only
  # when still running). deactivate/3, an uninstall at any later time,
  # leaves them running: by then something else may use them.
  #
  # A refused uninstall (force: false). Before anything changes, processes
  # outside the app whose stacks run its modules are found, and the call is
  # refused with the app untouched. That look covers only the top frames of
  # each stack (the VM's backtrace depth). A process that runs the app's
  # code deeper down is found later by :code.soft_purge/1, after the app
  # was stopped and unloaded and its modules deleted: that refusal leaves
  # the app stopped, with its old code still in place for those processes,
  # until a forced uninstall.

  alias Precompiled.Device.Env
  alias Precompiled.Device.Source
  alias Precompiled.Match

  @typep activation :: %{
           ebin: Path.t(),
           app?: boolean(),
           modules: [module()],
           started: [atom()],
           env_loaded: [atom()]
         }

  @doc "The config function for an install whose builds record no compile_env."
  @spec no_config(String.t(), [String.t()]) :: :error
  def no_config(_app, _path), do: :error

  @spec conflicts(atom(), String.t(), Path.t()) :: :ok | {:error, term()}
  def conflicts(app, _vsn, ebin) do
    with :ok <- not_present(app),
         {:ok, bin} <- read(app, ebin, "#{app}.app"),
         {:ok, props} <- parse_app(app, bin) do
      Enum.find_value(props[:modules], :ok, &module_conflict(&1, nil))
    end
  end

  defp not_present(app) do
    case :code.lib_dir(app) do
      {:error, :bad_name} -> :ok
      dir -> {:error, {:already_present, app, present_vsn(app, dir)}}
    end
  end

  defp present_vsn(app, dir) do
    with :undefined <- :application.get_key(app, :vsn),
         {:ok, _, vsn} <- Env.split(Path.basename(to_string(dir))) do
      vsn
    else
      {:ok, vsn} -> to_string(vsn)
      _ -> "unknown"
    end
  end

  # nil when mod is free. own_ebin is the ebin activate just appended: the
  # path search finding the module there is not a conflict.
  defp module_conflict(mod, own_ebin) do
    case {:code.is_loaded(mod), :code.which(mod)} do
      {{:file, file}, _} -> {:error, {:module_loaded, mod, to_string(file)}}
      {false, file} when is_list(file) -> path_conflict(mod, to_string(file), own_ebin)
      {false, _} -> nil
    end
  end

  defp path_conflict(mod, file, own_ebin) do
    if Path.dirname(file) == own_ebin, do: nil, else: {:error, {:module_conflict, mod, file}}
  end

  @spec activate(atom(), Path.t(), [map()], (String.t(), [String.t()] -> term()), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def activate(app, path, deferred, config_fun, opts) do
    ebin = Path.join(path, "ebin")

    with {:ok, files} <- files_opt(opts),
         :ok <- not_active(app),
         {:ok, props, beams} <- read_verified(app, ebin, files),
         :ok <- hook(opts, :verified),
         :ok <- add_path(app, ebin, props[:modules], opts) do
      guarded(app, fn ->
        with :ok <- load_app(app, props),
             :ok <- load_env_apps(app, deferred),
             :ok <- deferred_env(app, deferred, config_fun),
             :ok <- load_modules(beams, ebin),
             :ok <- start(app, opts) do
          {:ok, protocol_warnings(props[:modules])}
        end
      end)
    end
  end

  defp files_opt(opts) do
    case opts[:files] do
      files when is_list(files) -> {:ok, files}
      _ -> {:error, {:bad_option, :files}}
    end
  end

  defp not_active(app) do
    case record(app) do
      nil -> :ok
      _ -> {:error, {:already_present, app, present_vsn(app, "")}}
    end
  end

  # Test seam: called once the bytes are read and checked (:verified), and
  # once the record is written, before the code path changes (:recorded).
  defp hook(opts, stage) do
    case opts[:hook] do
      fun when is_function(fun, 1) ->
        _ = fun.(stage)
        :ok

      _ ->
        :ok
    end
  end

  # Everything after the code path changed: any error or raise tears down
  # what this call did.
  defp guarded(app, fun) do
    result =
      try do
        fun.()
      rescue
        e -> {:error, {:internal, Exception.message(e)}}
      catch
        kind, why -> {:error, {:internal, Exception.format_banner(kind, why)}}
      end

    with {:error, _} <- result do
      rec = record(app)
      _ = teardown(app, rec, true)
      _ = rec && stop_started(rec.started)
      _ = rec && unload_env_loaded(rec)
      result
    end
  end

  ## Reading and checking

  defp read_verified(app, ebin, files) do
    index = Map.new(files, &{&1["path"], &1})

    with {:ok, bin} <- read_checked(app, ebin, "#{app}.app", index),
         {:ok, props} <- parse_app(app, bin),
         {:ok, beams} <- read_beams(app, ebin, props[:modules], index),
         :ok <- priv_verified(app, Path.dirname(ebin), files) do
      {:ok, props, beams}
    end
  end

  defp read_beams(app, ebin, modules, index) do
    Enum.reduce_while(modules, {:ok, []}, fn mod, {:ok, acc} ->
      name = "#{mod}.beam"

      case read_checked(app, ebin, name, index) do
        {:ok, bin} ->
          {:cont, {:ok, acc ++ [{mod, String.to_charlist(Path.join(ebin, name)), bin}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp read_checked(app, ebin, name, index) do
    rel = "ebin/" <> name

    with {:ok, entry} <- listed(app, rel, index),
         {:ok, bin} <- read(app, ebin, name),
         :ok <- same_bytes(app, rel, bin, entry) do
      {:ok, bin}
    end
  end

  defp listed(app, rel, index) do
    case index do
      %{^rel => entry} -> {:ok, entry}
      _ -> {:error, {:fetch, app, "not in the file list (#{rel})"}}
    end
  end

  defp read(app, ebin, name) do
    case File.read(Path.join(ebin, name)) do
      {:ok, bin} -> {:ok, bin}
      {:error, why} -> {:error, {:fetch, app, "cannot read ebin/#{name}: #{why}"}}
    end
  end

  defp same_bytes(app, rel, bin, entry) do
    if entry["size"] == byte_size(bin) and is_binary(entry["sha256"]) and
         String.downcase(entry["sha256"]) == sha256(bin),
       do: :ok,
       else: {:error, {:fetch, app, "sha256 mismatch (#{rel})"}}
  end

  defp priv_verified(app, root, files) do
    Enum.find_value(files, :ok, fn
      %{"path" => "priv/" <> _ = rel} = entry -> priv_file(app, root, rel, entry)
      _ -> nil
    end)
  end

  # nil when the file matches its entry.
  defp priv_file(app, root, rel, entry) do
    with {:ok, safe} <- safe_rel(rel),
         {:ok, digest, size} <- hash_file(Path.join(root, safe)),
         true <- entry["size"] == size and is_binary(entry["sha256"]),
         true <- String.downcase(entry["sha256"]) == digest do
      nil
    else
      {:error, why} -> {:error, {:fetch, app, "cannot read #{rel}: #{why}"}}
      _ -> {:error, {:fetch, app, "sha256 mismatch (#{rel})"}}
    end
  end

  defp safe_rel(rel) do
    case Path.safe_relative(rel) do
      {:ok, safe} -> {:ok, safe}
      :error -> {:error, :unsafe_path}
    end
  end

  # Streamed: a .so can be large.
  defp hash_file(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          hash_io(io, :crypto.hash_init(:sha256), 0)
        after
          File.close(io)
        end

      {:error, why} ->
        {:error, why}
    end
  end

  defp hash_io(io, ctx, size) do
    case IO.binread(io, 65_536) do
      :eof -> {:ok, Base.encode16(:crypto.hash_final(ctx), case: :lower), size}
      {:error, why} -> {:error, why}
      bin -> hash_io(io, :crypto.hash_update(ctx, bin), size + byte_size(bin))
    end
  end

  defp sha256(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # The .app is parsed from bytes already checked, never consulted from
  # disk, by the same parser planning used (Source.parse_app/2).
  defp parse_app(app, bin) do
    case Source.parse_app(bin, Atom.to_string(app)) do
      {:ok, props} -> {:ok, props}
      {:fail, why} -> {:error, {:fetch, app, why}}
    end
  end

  ## Activation steps

  defp add_path(app, ebin, modules, opts) do
    dir = String.to_charlist(ebin)

    if dir in :code.get_path() do
      {:error, {:code_path, ebin, :already_present}}
    else
      :ok =
        put_record(app, %{ebin: ebin, app?: false, modules: modules, started: [], env_loaded: []})

      :ok = hook(opts, :recorded)

      if :code.add_pathz(dir) == true do
        :ok
      else
        _ = :persistent_term.erase({__MODULE__, app})
        {:error, {:code_path, ebin, :bad_directory}}
      end
    end
  end

  defp load_app(app, props) do
    case :application.load({:application, app, props}) do
      :ok -> put_record(app, %{record(app) | app?: true})
      {:error, {:already_loaded, _}} -> {:error, {:already_present, app, present_vsn(app, "")}}
      {:error, why} -> {:error, {:app_load_failed, app, why}}
    end
  end

  # A compile_env item may name an app the release ships but has not
  # loaded yet (Rules defers it): its .app defaults are only in the
  # application env once it is loaded. Such an app is loaded here from its
  # own lib/<app>-<vsn>/ebin/<app>.app in the release (which an embedded
  # release need not have on the code path), never started, and the code
  # path is left alone. The record keeps them so a failed activation
  # unloads them again.
  defp load_env_apps(app, deferred) do
    own = Atom.to_string(app)
    lib = Path.join(to_string(:code.root_dir()), "lib")
    names = MapSet.new(for %{"app" => name} <- deferred, name != own, do: name)

    loaded =
      for {name, dir} <- release_dirs(names, lib),
          {:ok, other, props} <- [release_app(name, dir)],
          not List.keymember?(Application.loaded_applications(), other, 0),
          :application.load({:application, other, props}) == :ok,
          do: other

    put_record(app, %{record(app) | env_loaded: loaded})
  end

  # The `<name>-<vsn>` dirs in the release's lib dir of the apps `names`.
  defp release_dirs(names, lib) do
    for entry <- ls(lib),
        [name, vsn] <- [String.split(entry, "-", parts: 2)],
        MapSet.member?(names, name),
        String.match?(vsn, ~r/\A\d/),
        uniq: true,
        do: {name, Path.join(lib, entry)}
  end

  # The atom is made only for a name the release itself ships, whose .app
  # names it.
  defp release_app(name, dir) do
    with {:ok, [{:application, app, props}]} <-
           :file.consult(Path.join([dir, "ebin", name <> ".app"])),
         true <- is_atom(app) and Atom.to_string(app) == name and Keyword.keyword?(props) do
      {:ok, app, props}
    else
      _ -> :error
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  defp deferred_env(app, deferred, config_fun) do
    case Match.compile_env_ok(deferred, config_fun) do
      :ok -> :ok
      {:miss, why} -> {:error, {:no_build, Atom.to_string(app), why}}
    end
  end

  defp load_modules(beams, ebin) do
    with :ok <- free(beams, ebin) do
      case :code.atomic_load(beams) do
        :ok -> :ok
        {:error, errors} -> load_split(beams, errors)
      end
    end
  end

  # Never replace: a module loaded, or found elsewhere on the code path,
  # since conflicts/3 ran.
  defp free(beams, ebin) do
    Enum.find_value(beams, :ok, fn {mod, _, _} -> module_conflict(mod, ebin) end)
  end

  defp load_split(beams, errors) do
    case Enum.find(errors, fn {_mod, what} -> what != :on_load_not_allowed end) do
      {mod, what} ->
        {:error, {:on_load_failed, mod, what}}

      nil ->
        late = for {mod, :on_load_not_allowed} <- errors, do: mod
        {on_load, rest} = Enum.split_with(beams, fn {mod, _, _} -> mod in late end)
        with :ok <- atomic(rest), do: load_each(on_load)
    end
  end

  defp atomic([]), do: :ok

  defp atomic(beams) do
    case :code.atomic_load(beams) do
      :ok -> :ok
      {:error, [{mod, what} | _]} -> {:error, {:on_load_failed, mod, what}}
    end
  end

  defp load_each(beams) do
    Enum.reduce_while(beams, :ok, fn {mod, file, bin}, :ok ->
      case :code.load_binary(mod, file, bin) do
        {:module, ^mod} -> {:cont, :ok}
        {:error, why} -> {:halt, {:error, {:on_load_failed, mod, why}}}
      end
    end)
  end

  defp start(app, opts) do
    if opts[:start] == false do
      :ok
    else
      case Application.ensure_all_started(app, :temporary) do
        {:ok, started} -> put_record(app, %{record(app) | started: started -- [app]})
        {:error, why} -> {:error, {:start_failed, app, why}}
      end
    end
  end

  defp protocol_warnings(modules) do
    for mod <- modules,
        Code.ensure_loaded?(mod) and function_exported?(mod, :__impl__, 1),
        proto <- [mod.__impl__(:protocol)],
        consolidated?(proto) do
      "#{inspect(proto)} impl for #{inspect(mod.__impl__(:for))} is not dispatched: " <>
        "protocols are consolidated in this release"
    end
  end

  defp consolidated?(proto), do: Code.ensure_loaded?(proto) and Protocol.consolidated?(proto)

  ## Deactivation

  @spec deactivate(atom(), Path.t(), boolean()) ::
          :ok | {:error, {:in_use, module(), [pid()]} | {:stop_failed, atom(), term()}}
  def deactivate(app, path, force) do
    ebin = Path.join(path, "ebin")

    case record(app) do
      %{ebin: ^ebin} = rec -> teardown(app, rec, force)
      _ -> :ok
    end
  end

  @spec rollback([{atom(), Path.t()}]) :: :ok
  def rollback(activated) do
    for {app, path} <- Enum.reverse(activated) do
      ebin = Path.join(path, "ebin")

      case record(app) do
        %{ebin: ^ebin, started: started} = rec ->
          with :ok <- teardown(app, rec, true) do
            stop_started(started)
            unload_env_loaded(rec)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  # Newest first, and only what is still running.
  defp stop_started(started) do
    running = for {a, _, _} <- Application.started_applications(), do: a

    for a <- Enum.reverse(started), a in running do
      _ = Application.stop(a)
    end

    :ok
  end

  # The release apps load_env_apps/2 loaded, unless something started one
  # since.
  defp unload_env_loaded(rec) do
    running = for {a, _, _} <- Application.started_applications(), do: a
    for a <- Map.get(rec, :env_loaded, []), a not in running, do: _ = Application.unload(a)
    :ok
  end

  defp teardown(_app, nil, _force), do: :ok

  defp teardown(app, rec, force) do
    mods = Enum.filter(rec.modules, &ours?(&1, rec.ebin))

    with :ok <- refuse_if_running(app, rec, mods, force),
         :ok <- unload_app(app, rec),
         :ok <- purge(mods, force) do
      _ = :code.del_path(String.to_charlist(rec.ebin))
      _ = :persistent_term.erase({__MODULE__, app})
      :ok
    end
  end

  # Only modules this VM runs from the install's ebin: a firmware module of
  # the same name is never touched.
  defp ours?(mod, ebin) do
    case {:code.is_loaded(mod), :code.which(mod)} do
      {{:file, file}, _} -> in_ebin?(file, ebin)
      {false, file} when is_list(file) -> in_ebin?(file, ebin)
      _ -> false
    end
  end

  defp in_ebin?(file, ebin), do: is_list(file) and Path.dirname(to_string(file)) == ebin

  defp refuse_if_running(_app, _rec, _mods, true), do: :ok

  defp refuse_if_running(app, rec, mods, false) do
    set = MapSet.new(mods)

    running =
      for pid <- Process.list(),
          pid != self(),
          not (rec.app? and :application.get_application(pid) == {:ok, app}),
          mod <- [running_module(pid, set)],
          mod,
          do: {mod, pid}

    case running do
      [] -> :ok
      [{mod, _} | _] -> {:error, {:in_use, mod, for({^mod, pid} <- running, do: pid)}}
    end
  end

  defp running_module(pid, set) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        Enum.find_value(frames, false, fn {mod, _, _, _} -> MapSet.member?(set, mod) && mod end)

      nil ->
        false
    end
  end

  defp unload_app(_app, %{app?: false}), do: :ok

  defp unload_app(app, rec) do
    _ = Application.stop(app)

    case :application.unload(app) do
      :ok -> put_record(app, %{rec | app?: false})
      {:error, {:not_loaded, ^app}} -> put_record(app, %{rec | app?: false})
      {:error, why} -> {:error, {:stop_failed, app, why}}
    end
  end

  defp purge(mods, force) do
    Enum.reduce_while(mods, :ok, fn mod, :ok ->
      # A module already deleted by a refused uninstall has old code only.
      _ = :code.is_loaded(mod) && :code.delete(mod)

      cond do
        :code.soft_purge(mod) -> {:cont, :ok}
        force -> {:cont, hard_purge(mod)}
        true -> {:halt, {:error, {:in_use, mod, old_code_pids(mod)}}}
      end
    end)
  end

  defp hard_purge(mod) do
    _ = :code.purge(mod)
    :ok
  end

  defp old_code_pids(mod),
    do: for(pid <- Process.list(), :erlang.check_process_code(pid, mod), do: pid)

  ## The record of what activate loaded, per app, in this VM

  @spec record(atom()) :: activation() | nil
  defp record(app), do: :persistent_term.get({__MODULE__, app}, nil)

  defp put_record(app, rec) do
    :persistent_term.put({__MODULE__, app}, rec)
    :ok
  end
end
