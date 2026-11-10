# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Store do
  @moduledoc false
  # The install store on a device (spec section 5 and Q5: a cache, never
  # loaded at boot). Layout under the store dir, by default
  # /data/precompiled:
  #
  #   .precompiled-store       marker: sweep, clean and eviction act only
  #                            in a directory that carries it
  #   .trust/                  trust state, never counted, never removed
  #   .staging/<app>-<vsn>.<os pid>-<unique>/   in-flight installs
  #   <app>-<vsn>/{ebin,priv,.precompiled.json} cache entries
  #
  # An entry's name is one `:code.lib_dir/1` resolves. Nothing here adds a
  # code path or loads anything: an entry is inert bytes until a later call
  # re-verifies it (cached/4) and the loader activates it.
  #
  # Crash safety. An install is staged, its provenance written and synced,
  # and the staging dir renamed into place. An entry being replaced is first
  # renamed aside into .staging/.replaced.*, the new one renamed in, and
  # the old one deleted. A removal renames the entry into .staging/.discard.*
  # before deleting it, so an entry never disappears file by file. A crash
  # between the two renames of a replace leaves no entry; sweep/1, run at
  # the start of every call, renames the old one back. The entry files
  # themselves are not fsync'd: a crash can leave a renamed entry whose
  # bytes never reached the disk (f2fs). That is safe because nothing trusts
  # an entry without cached/4, which re-hashes every file against a
  # manifest a batch verified in the same call, and removes the entry on
  # any mismatch. Staging is never read as a cache.
  #
  # In use. Eviction, clean, remove, a replacing commit and a failed
  # cached/4 never remove an entry whose app the caller names as active, or
  # whose ebin is on the code path, or that a loaded module was loaded from.
  #
  # Ownership. ensure_root/1 creates a missing store dir with mode 0700 and
  # writes its marker. For any store dir, new or existing, it enforces only
  # this: not a symlink, not writable by group or others, and owned by this
  # VM's uid (an existing 0755 dir passes). The window between a `.so`'s
  # hash check and its dlopen is then open only to code that already runs
  # as that uid. On Windows (win32) the mode and owner checks are skipped:
  # its file modes and uids do not carry that meaning; the symlink and
  # marker checks still apply.
  #
  # One VM per store. Calls that change the store run under with_lock/2,
  # which serializes this node's callers only. The lock is reentrant for
  # one pid; an installed app whose start/2 calls install again waits out
  # the retries and gets {:error, :busy}. No Mix, no Hex.

  alias Precompiled.Fetch
  alias Precompiled.Match

  require Logger

  @marker ".precompiled-store"
  @provenance ".precompiled.json"
  @staging ".staging"
  @trust ".trust"
  @replaced ".replaced."
  @discard ".discard."
  @probe ".probe."
  @lost_found "lost+found"
  @tops MapSet.new([@provenance, "ebin", "priv"])
  @stale_after 3600
  @max_provenance 4 * 1024 * 1024
  @lock {Precompiled, :install}
  @app_re ~r/\A[a-z][a-z0-9_]*\z/
  @vsn_re ~r/\A\d[0-9A-Za-z.+\-]*\z/
  @entry_re ~r/\A[a-z][a-z0-9_]*-\d[0-9A-Za-z.+\-]*\z/

  @type entry_info :: %{
          app: atom(),
          version: String.t(),
          path: Path.t(),
          provenance: map(),
          bytes: non_neg_integer()
        }

  ## The root

  @doc false
  @spec ensure_root(Path.t()) :: :ok | {:error, {:unsafe_store, term()}}
  def ensure_root(dir) do
    dir = root(dir)

    with :ok <- create(dir),
         :ok <- safe_dir(dir) do
      marker(dir)
    end
  end

  @doc false
  # ensure_root/1 without creating anything: :absent when there is no
  # store yet, else the same ownership, mode and marker checks.
  @spec check_root(Path.t()) :: :ok | :absent | {:error, {:unsafe_store, term()}}
  def check_root(dir) do
    dir = root(dir)

    case File.lstat(dir) do
      {:error, :enoent} -> :absent
      _ -> with :ok <- safe_dir(dir), do: marked(dir)
    end
  end

  defp create(dir) do
    with {:error, :enoent} <- File.lstat(dir),
         :ok <- File.mkdir_p(Path.dirname(dir)),
         :ok <- mkdir_private(dir) do
      :ok
    else
      {:ok, _} -> :ok
      {:error, reason} -> unsafe({:create, reason})
    end
  end

  defp mkdir_private(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp safe_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory} = stat} -> owner_and_mode(dir, stat)
      {:ok, %File.Stat{type: :symlink}} -> unsafe(:symlink)
      {:ok, _} -> unsafe(:not_a_directory)
      {:error, reason} -> unsafe({:stat, reason})
    end
  end

  defp owner_and_mode(dir, %File.Stat{mode: mode, uid: uid}) do
    cond do
      match?({:win32, _}, :os.type()) -> :ok
      Bitwise.band(mode, 0o022) != 0 -> unsafe(:writable_by_others)
      true -> owned(dir, uid)
    end
  end

  defp owned(dir, uid) do
    case euid(dir) do
      {:ok, ^uid} -> :ok
      {:ok, _} -> unsafe(:not_owner)
      {:error, reason} -> unsafe({:unwritable, reason})
    end
  end

  # This VM's effective uid, read off a file it creates: no os command and
  # no /proc, so it works on any unix.
  defp euid(dir) do
    probe = Path.join(dir, @probe <> unique())

    case File.write(probe, "", [:exclusive]) do
      :ok ->
        stat = File.lstat(probe)
        File.rm(probe)
        with {:ok, %File.Stat{uid: uid}} <- stat, do: {:ok, uid}

      error ->
        error
    end
  end

  defp marker(dir) do
    path = Path.join(dir, @marker)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> write_marker(path)
      _ -> unsafe(:marker)
    end
  end

  defp write_marker(path) do
    case write_file(path, "precompiled install store\n") do
      :ok -> :ok
      {:error, reason} -> unsafe({:marker, reason})
    end
  end

  defp unsafe(why), do: {:error, {:unsafe_store, why}}

  defp store?(dir) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir)) and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(dir, @marker)))
  end

  defp marked(dir), do: if(store?(dir), do: :ok, else: unsafe(:no_marker))

  ## Staging and commit

  @doc false
  # A fresh, empty directory for one install: never one that existed
  # before, so nothing a crashed or concurrent install left can be in it.
  @spec staging(Path.t(), atom(), String.t()) :: Path.t()
  def staging(dir, app, vsn) do
    {:ok, name} = entry_name(app, vsn)
    parent = Path.join(root(dir), @staging)
    File.mkdir_p!(parent)
    path = Path.join(parent, name <> "." <> unique())
    File.mkdir!(path)
    path
  end

  @doc false
  # opts[:hook] is called with :staged, :provenance, :moved_old and
  # :renamed as each step completes (tests kill the caller there).
  @spec commit(Path.t(), Path.t(), atom(), String.t(), map(), map(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def commit(staging, dir, app, vsn, provenance, active, opts \\ []) do
    dir = root(dir)
    hook = Keyword.get(opts, :hook, fn _ -> :ok end)

    with {:ok, name} <- entry_name(app, vsn),
         :ok <- marked(dir),
         {:ok, staging} <- own_staging(dir, staging),
         :ok <- replaceable(dir, name, app, vsn, active) do
      install(staging, dir, name, provenance, hook)
    end
  end

  defp own_staging(dir, staging) do
    path = root(staging)

    if Path.dirname(path) == Path.join(dir, @staging) and
         not String.starts_with?(Path.basename(path), ".") and
         match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)),
       do: {:ok, path},
       else: {:error, {:bad_staging, staging}}
  end

  defp replaceable(dir, name, app, vsn, active) do
    if Map.has_key?(active, app) or in_use?(Path.join(dir, name), in_use()),
      do: {:error, {:already_present, app, vsn}},
      else: :ok
  end

  defp install(staging, dir, name, provenance, hook) do
    dest = Path.join(dir, name)
    prov = Map.put_new(provenance, "last_used", System.os_time(:second))
    hook.(:staged)

    with :ok <- write_file(Path.join(staging, @provenance), :json.encode(prov)),
         _ <- hook.(:provenance),
         {:ok, aside} <- move_aside(dir, dest, name),
         _ <- hook.(:moved_old),
         :ok <- rename_in(staging, dest, aside),
         _ <- hook.(:renamed) do
      if aside, do: File.rm_rf(aside)
      {:ok, dest}
    end
  end

  defp move_aside(dir, dest, name) do
    aside = Path.join([dir, @staging, @replaced <> unique() <> "." <> name])

    case File.lstat(dest) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, _} -> rename(dest, aside, aside)
      {:error, reason} -> {:error, {:rename, reason}}
    end
  end

  defp rename_in(staging, dest, aside) do
    case File.rename(staging, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        if aside, do: restore(aside, dest)
        {:error, {:rename, reason}}
    end
  end

  # Puts the old entry back after the new one failed to go in. A failure
  # here leaves no entry until the next call's sweep restores it: logged.
  defp restore(aside, dest) do
    case File.rename(aside, dest) do
      :ok ->
        :ok

      {:error, why} ->
        Logger.error(
          "precompiled: could not restore #{dest} from #{aside} (#{inspect(why)}); " <>
            "the next call puts it back"
        )
    end
  end

  defp rename(from, to, result) do
    case File.rename(from, to) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:rename, reason}}
    end
  end

  @doc false
  # Writes and fsyncs `path`. ENOSPC names the path.
  @spec write_file(Path.t(), iodata()) :: :ok | {:error, term()}
  def write_file(path, bytes) do
    result =
      case :file.open(path, [:write, :raw, :binary]) do
        {:ok, fd} -> write_sync_close(fd, bytes)
        error -> error
      end

    case result do
      {:error, :enospc} -> {:error, {:enospc, path}}
      other -> other
    end
  end

  defp write_sync_close(fd, bytes) do
    with :ok <- :file.write(fd, bytes),
         :ok <- :file.sync(fd) do
      :file.close(fd)
    else
      error ->
        :file.close(fd)
        error
    end
  end

  ## Reuse

  @doc false
  # A hit only when the provenance names this build and the disk holds
  # exactly its files, each with its signed sha256, size and mode. Anything
  # else removes the entry (unless it is in use) and is a miss.
  @spec cached(Path.t(), atom(), String.t(), map()) :: {:hit, Path.t()} | :miss
  def cached(dir, app, vsn, entry) do
    dir = root(dir)

    with {:ok, name} <- entry_name(app, vsn),
         path = Path.join(dir, name),
         {:ok, _} <- File.lstat(path) do
      if verified?(path, app, entry) do
        {:hit, path}
      else
        drop_unless_in_use(dir, path)
        :miss
      end
    else
      _ -> :miss
    end
  end

  defp verified?(path, app, entry) do
    hash = Match.files_hash(entry)

    is_binary(hash) and match?({:ok, %{"files_sha256" => ^hash}}, read_provenance(path)) and
      only_tops?(path) and Fetch.installed_at?(path, app, entry)
  end

  defp only_tops?(path) do
    case File.ls(path) do
      {:ok, names} -> Enum.all?(names, &MapSet.member?(@tops, &1))
      _ -> false
    end
  end

  defp drop_unless_in_use(dir, path) do
    if store?(dir) and not in_use?(path, in_use()), do: discard(dir, path)
  end

  @doc false
  # Best effort: a failure only makes the entry look older to eviction.
  @spec touch(Path.t(), atom(), String.t()) :: :ok
  def touch(dir, app, vsn) do
    dir = root(dir)

    with {:ok, name} <- entry_name(app, vsn),
         path = Path.join(dir, name),
         {:ok, prov} <- read_provenance(path) do
      prov = Map.put(prov, "last_used", System.os_time(:second))
      replace_file(dir, Path.join(path, @provenance), :json.encode(prov))
    end

    :ok
  end

  # Written in .staging and renamed over the target, so a crash never leaves
  # a torn provenance, nor a stray file inside the entry.
  defp replace_file(dir, target, bytes) do
    staging = Path.join(dir, @staging)
    tmp = Path.join(staging, @discard <> unique())

    with :ok <- File.mkdir_p(staging),
         :ok <- write_file(tmp, bytes),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  ## Listing and size

  @doc false
  @spec list(Path.t()) :: [entry_info()]
  def list(dir) do
    for %{provenance: prov} = e <- entries(root(dir)),
        is_map(prov),
        do: %{app: app(e), version: e.version, path: e.path, provenance: prov, bytes: e.bytes}
  end

  # Every directory named like an entry, with its provenance (nil when it
  # has none readable). The app stays the string from the name: after a
  # reboot no atom exists yet for a cached app this VM has not named, and
  # the entry is still a valid cache entry.
  defp entries(dir) do
    for name <- Enum.sort(ls(dir)),
        entry_dir_name?(name),
        path = Path.join(dir, name),
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)) do
      {app, vsn} = app_vsn(name)

      prov =
        case read_provenance(path) do
          {:ok, prov} -> prov
          :error -> nil
        end

      %{name: name, app: app, version: vsn, path: path, provenance: prov, bytes: bytes(path)}
    end
  end

  # Only for a name entry_dir_name?/1 accepted: the app ([a-z][a-z0-9_]*)
  # has no "-", so the version starts after the first one.
  defp app_vsn(name) do
    [app, vsn] = String.split(name, "-", parts: 2)
    {app, vsn}
  end

  # The atom for an entry's app, made only here, at the public boundary
  # (list/1, clean/2), and only for an entry with a readable provenance
  # whose name passed @entry_re. That is bounded: only this VM's uid can
  # create an entry (ensure_root/1 refuses a store others can write), the
  # store is size-capped, and sweep/1 removes entries without provenance.
  defp app(%{app: app}), do: String.to_atom(app)

  defp named?(app, atoms), do: Enum.any?(atoms, &(Atom.to_string(&1) == app))

  @doc false
  # Everything under the store but .trust and the marker.
  @spec used_bytes(Path.t()) :: non_neg_integer()
  def used_bytes(dir) do
    dir = root(dir)

    dir
    |> ls()
    |> Enum.reject(&(&1 in [@trust, @marker]))
    |> Enum.reduce(0, &(&2 + bytes(Path.join(dir, &1))))
  end

  defp bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path |> ls() |> Enum.reduce(0, &(&2 + bytes(Path.join(path, &1))))

      {:ok, %File.Stat{size: size}} ->
        size

      _ ->
        0
    end
  end

  ## Eviction and cleaning

  @doc false
  # Makes plan_bytes free under max_bytes,
  # evicting least recently used entries first. Never evicts an `active`
  # app, one of `keep` (the plan's own reuses), or an entry in use.
  @spec make_room(Path.t(), non_neg_integer(), non_neg_integer(), map(), [atom()]) ::
          :ok | {:error, {:too_big, non_neg_integer(), non_neg_integer()}}
  def make_room(dir, plan_bytes, max_bytes, active, keep) do
    with {:ok, victims} <- room(dir, plan_bytes, max_bytes, active, keep) do
      evict(dir, victims)
    end
  end

  @doc false
  # make_room/5 without the eviction: the entries it would evict, least
  # recently used first, so a caller can evict them only once everything
  # else it needs has verified (evict/2).
  @spec room(Path.t(), non_neg_integer(), non_neg_integer(), map(), [atom()]) ::
          {:ok, [Path.t()]} | {:error, {:too_big, non_neg_integer(), non_neg_integer()}}
  def room(dir, plan_bytes, max_bytes, active, keep) do
    dir = root(dir)
    # Staging is renamed into place, never copied: the plan's bytes exist
    # once. An entry the plan replaces is already gone by now (cached/4
    # removes a stale one) or refuses the commit (in use).
    needed = plan_bytes
    free = max_bytes - used_bytes(dir)
    in_use = in_use()

    candidates =
      if store?(dir) do
        dir
        |> entries()
        |> Enum.reject(&(kept?(&1, active, in_use) or named?(&1.app, keep)))
        |> Enum.sort_by(&{last_used(&1), &1.name})
      else
        []
      end

    victims(candidates, free, needed, [])
  end

  defp victims(_candidates, free, needed, acc) when free >= needed, do: {:ok, Enum.reverse(acc)}
  defp victims([], free, needed, _acc), do: {:error, {:too_big, needed, max(free, 0)}}

  defp victims([e | rest], free, needed, acc),
    do: victims(rest, free + e.bytes, needed, [e.path | acc])

  @doc false
  # Discards each entry room/5 chose, unless it has come into use since.
  @spec evict(Path.t(), [Path.t()]) :: :ok
  def evict(dir, paths) do
    dir = root(dir)
    in_use = in_use()

    if store?(dir) do
      for path <- paths,
          Path.dirname(path) == dir,
          not in_use?(path, in_use),
          do: discard(dir, path)
    end

    :ok
  end

  defp last_used(%{provenance: %{"last_used" => t}}) when is_integer(t), do: t
  defp last_used(_), do: 0

  defp kept?(%{app: app, path: path}, active, in_use),
    do: named?(app, Map.keys(active)) or in_use?(path, in_use)

  @doc false
  # Removes every entry that is not active or in use, and .staging. .trust
  # stays.
  @spec clean(Path.t(), map()) :: %{
          removed: [atom()],
          bytes: non_neg_integer(),
          kept: [atom()]
        }
  def clean(dir, active) do
    dir = root(dir)

    if store?(dir) do
      in_use = in_use()
      {kept, gone} = dir |> entries() |> Enum.split_with(&kept?(&1, active, in_use))
      staging = Path.join(dir, @staging)
      freed = bytes(staging) + Enum.reduce(gone, 0, &(&1.bytes + &2))
      Enum.each(gone, &discard(dir, &1.path))
      File.rm_rf(staging)
      %{removed: apps(gone), bytes: freed, kept: apps(kept)}
    else
      %{removed: [], bytes: 0, kept: []}
    end
  end

  defp apps(entries),
    do: Enum.sort(for(%{provenance: %{}} = e <- entries, uniq: true, do: app(e)))

  @doc false
  # Removes every cached version of `app`; refuses, removing nothing, when
  # one of them is in use.
  @spec remove(Path.t(), atom()) :: :ok | {:error, {:in_use, atom()}}
  def remove(dir, app) do
    dir = root(dir)
    in_use = in_use()
    name = Atom.to_string(app)
    mine = if store?(dir), do: Enum.filter(entries(dir), &(&1.app == name)), else: []

    if Enum.any?(mine, &in_use?(&1.path, in_use)) do
      {:error, {:in_use, app}}
    else
      Enum.each(mine, &discard(dir, &1.path))
    end
  end

  @doc false
  # Run at the start of every call, under the lock: puts back an entry a
  # crashed replace moved aside, removes what a crashed removal left,
  # staging dirs older than an hour, every entry dir without a readable
  # provenance, and every other top-level name but .trust, .staging, the
  # marker, lost+found and a fresh ownership probe. A valid entry is never
  # touched. Never raises.
  @spec sweep(Path.t()) :: :ok
  def sweep(dir) do
    dir = root(dir)

    if store?(dir) do
      sweep_staging(dir)
      sweep_entries(dir)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp sweep_staging(dir) do
    staging = Path.join(dir, @staging)
    cutoff = System.os_time(:second) - @stale_after
    for name <- ls(staging), do: sweep_staged(dir, Path.join(staging, name), name, cutoff)
  end

  defp sweep_staged(dir, path, @replaced <> rest, _cutoff) do
    with [_unique, name] <- String.split(rest, ".", parts: 2),
         true <- entry_dir_name?(name),
         dest = Path.join(dir, name),
         {:error, :enoent} <- File.lstat(dest),
         :ok <- File.rename(path, dest) do
      :ok
    else
      _ -> File.rm_rf(path)
    end
  end

  defp sweep_staged(_dir, path, @discard <> _, _cutoff), do: File.rm_rf(path)

  defp sweep_staged(_dir, path, _name, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} when m < cutoff -> File.rm_rf(path)
      _ -> :ok
    end
  end

  # Anything at the top level but .trust, .staging, the marker and entry
  # directories is junk that would otherwise count against the cap forever:
  # a file or symlink named like an entry included. Two names are not junk:
  # lost+found, when the store dir is a filesystem of its own, and the
  # ownership probe of a check_root/1 running outside the lock (list/1,
  # uninstall/2), which removes it itself; one older than an hour is a
  # crashed check's and goes.
  defp sweep_entries(dir) do
    in_use = in_use()
    cutoff = System.os_time(:second) - @stale_after

    for name <- ls(dir), name not in [@trust, @staging, @marker, @lost_found] do
      path = Path.join(dir, name)

      case {name, entry_dir_name?(name), File.lstat(path, time: :posix)} do
        {@probe <> _, _, {:ok, %File.Stat{mtime: m}}} when m >= cutoff -> :ok
        {_, true, {:ok, %File.Stat{type: :directory}}} -> sweep_entry(dir, path, in_use)
        {_, _, {:ok, _}} -> discard(dir, path)
        _ -> :ok
      end
    end
  end

  defp sweep_entry(dir, path, in_use) do
    if read_provenance(path) == :error and not in_use?(path, in_use), do: discard(dir, path)
  end

  ## Mounts and the lock

  @doc false
  # The mountpoint holding `dir` (its real path, longest whole-component
  # prefix) when that mount is noexec, else nil.
  @spec noexec(Path.t(), [{String.t(), [String.t()]}]) :: String.t() | nil
  def noexec(dir, mounts) do
    real = realpath(Path.expand(dir))

    mounts
    |> Enum.filter(fn {mountpoint, _} -> under?(real, mountpoint) end)
    |> Enum.max_by(fn {mountpoint, _} -> byte_size(mountpoint) end, fn -> nil end)
    |> case do
      {mountpoint, options} -> if "noexec" in options, do: mountpoint
      nil -> nil
    end
  end

  defp under?(_path, "/"), do: true

  defp under?(path, mountpoint),
    do: path == mountpoint or String.starts_with?(path, mountpoint <> "/")

  @doc false
  # The store dir every function here works on: its parent resolved to a
  # real path, its own last component kept, so the same store reached
  # through a link (/data -> /root) is one store, while a store dir that is
  # itself a symlink is still seen, and refused, as one.
  @spec root(Path.t()) :: Path.t()
  def root(dir) do
    dir = Path.expand(dir)
    Path.join(realpath(Path.dirname(dir)), Path.basename(dir))
  end

  @doc false
  # Resolves symlinks one component at a time; a missing component and
  # everything after it are kept as written.
  @spec realpath(Path.t()) :: Path.t()
  def realpath(path), do: resolve(Path.split(path), "/", 0)

  defp resolve([], acc, _n), do: acc
  defp resolve(parts, acc, n) when n > 40, do: Path.join([acc | parts])
  defp resolve(["/" | rest], _acc, n), do: resolve(rest, "/", n)

  defp resolve([part | rest], acc, n) do
    next = Path.join(acc, part)

    case :file.read_link_all(String.to_charlist(next)) do
      {:ok, target} ->
        resolve(Path.split(Path.expand(to_string(target), acc)) ++ rest, "/", n + 1)

      {:error, _} ->
        resolve(rest, next, n)
    end
  end

  @doc false
  # One install at a time on this node. The requester is the caller's pid:
  # with a shared requester :global would let every caller in at once.
  @spec with_lock((-> term()), non_neg_integer() | :infinity) :: term() | {:error, :busy}
  def with_lock(fun, retries \\ 120) do
    case :global.trans({@lock, self()}, fun, [node()], retries) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  ## Helpers

  defp entry_name(app, vsn) when is_atom(app) and is_binary(vsn) do
    app_name = Atom.to_string(app)

    cond do
      not Regex.match?(@app_re, app_name) ->
        {:error, {:bad_app, app}}

      not Regex.match?(@vsn_re, vsn) or String.contains?(vsn, "..") ->
        {:error, {:bad_version, vsn}}

      true ->
        {:ok, app_name <> "-" <> vsn}
    end
  end

  defp entry_name(app, vsn), do: {:error, {:bad_version, {app, vsn}}}

  defp entry_dir_name?(name),
    do: Regex.match?(@entry_re, name) and not String.contains?(name, "..")

  defp read_provenance(path) do
    file = Path.join(path, @provenance)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_provenance <-
           File.lstat(file),
         {:ok, bytes} <- File.read(file),
         %{} = prov <- decode(bytes) do
      {:ok, prov}
    else
      _ -> :error
    end
  end

  defp decode(bytes) do
    :json.decode(bytes)
  rescue
    _ -> nil
  end

  # The ebin dirs code runs from: the code path, and where each loaded
  # module was loaded from.
  #
  # Real paths on both sides: an install made through /data/precompiled
  # (/data a link to /root on Nerves) is in use when looked at as
  # /root/precompiled, and the other way round.
  defp in_use() do
    paths = for p <- :code.get_path(), do: Path.expand(to_string(p))

    loaded =
      for {_mod, file} <- :code.all_loaded(),
          is_list(file),
          do: Path.dirname(Path.expand(to_string(file)))

    (paths ++ loaded)
    |> Enum.uniq()
    |> MapSet.new(&realpath/1)
  end

  # The entry side resolved too: an entry whose ebin is a symlink is in use
  # when the dir it points to runs.
  defp in_use?(path, in_use), do: MapSet.member?(in_use, realpath(Path.join(path, "ebin")))

  defp discard(dir, path) do
    staging = Path.join(dir, @staging)
    aside = Path.join(staging, @discard <> unique())

    with :ok <- File.mkdir_p(staging),
         :ok <- File.rename(path, aside) do
      File.rm_rf(aside)
    else
      _ -> File.rm_rf(path)
    end

    :ok
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end

  defp unique(), do: "#{System.pid()}-#{System.unique_integer([:positive])}"
end
