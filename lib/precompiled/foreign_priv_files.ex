# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ForeignPrivFiles do
  @moduledoc """
  The files a foreign priv build places into kino's build `priv` (0.8.0):
  staged and verified like an install's own, then put exactly where
  Kino.JS's own compile of the writer puts them, `priv/assets/<d>/<h>.tar.gz`
  under `<build_lib>/kino`, and checked there on every run.

  Nothing under kino's build dir is ever deleted but `priv/assets/<d>` for a
  `<d>` about to be placed, as Kino.JS's own `File.rm_rf!/1` does. Only
  `priv` and `priv/assets` may be created. A kino replace carries over the
  `priv/assets/<d>` its new entry does not ship (`carry/3`); a kino removal
  makes Mix recompile the deps whose modules own the archives left there
  (`mark_owners/1`). Mix-free: Check runs it in a release too.
  """

  alias Precompiled.{Fetch, ForeignPriv, Status}

  @target "kino"

  @doc """
  Whether kino's build dir can take archives: `:settled` when
  `<build_lib>/kino` is a real directory and its `priv` and `priv/assets`
  are each a real directory or absent; `:linked` when either is a link (a
  kino whose `priv` Mix links to its sources); `:missing` otherwise.
  """
  @spec target_state(Path.t()) :: :settled | :linked | :missing
  def target_state(build_lib) do
    dir = Path.join(build_lib, @target)

    case {lstat_type(dir), lstat_type(Path.join(dir, "priv")),
          lstat_type(Path.join(dir, "priv/assets"))} do
      {:directory, :symlink, _} ->
        :linked

      {:directory, :directory, :symlink} ->
        :linked

      {:directory, priv, assets}
      when priv in [:directory, :none] and assets in [:directory, :none] ->
        :settled

      _ ->
        :missing
    end
  end

  @doc """
  Fetches and verifies (size, sha256) each entry's file into a staging dir
  of its own under `<build_lib>/.precompiled`, as `foreign/<d>/<h>.tar.gz`,
  mode 0644: the same filesystem as kino's build dir. On a failure the
  staging dir is removed.
  """
  @spec stage(map(), atom(), [map()], Path.t()) :: {:ok, Path.t()} | {:fail, String.t()}
  def stage(config, writer, entries, build_lib) do
    staging =
      Path.join([
        build_lib,
        ".precompiled",
        "#{writer}.#{System.pid()}-#{System.unique_integer([:positive])}"
      ])

    try do
      File.mkdir_p!(staging)

      entries
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        target =
          Path.join([staging, "foreign", ForeignPriv.dir(entry), Path.basename(entry["path"])])

        case Fetch.fetch_verified(config, entry) do
          {:ok, bytes, _cached?} ->
            File.mkdir_p!(Path.dirname(target))
            File.write!(target, bytes, [:exclusive])
            File.chmod!(target, 0o644)
            {:cont, :ok}

          {:fail, _} = fail ->
            {:halt, fail}
        end
      end)
      |> case do
        :ok -> {:ok, staging}
        fail -> cleanup(staging, fail)
      end
    rescue
      e -> cleanup(staging, {:fail, "install failed: #{Exception.message(e)}"})
    end
  end

  @doc """
  Puts each staged `<d>` into kino's `priv/assets`, sorted by `<d>`, as
  Kino.JS does: `File.rm_rf/1` of `priv/assets/<d>` (a link goes as a
  link), then the staged `<d>` renamed into place. kino's build dir must be
  a real directory, its `priv` and `priv/assets` real directories or
  absent; only those two are created. The staging dir is removed either way.
  """
  @spec place(Path.t(), Path.t(), [map()]) :: :ok | {:fail, String.t()}
  def place(build_lib, staging, entries) do
    kino = Path.join(build_lib, @target)
    priv = Path.join(kino, "priv")
    assets = Path.join(priv, "assets")

    result =
      with :ok <- dir_or_absent(kino, :required, "kino's build dir"),
           :ok <- dir_or_absent(priv, :may_create, "kino's priv"),
           :ok <- dir_or_absent(assets, :may_create, "kino's priv/assets") do
        for entry <- Enum.sort_by(entries, &ForeignPriv.dir/1) do
          d = ForeignPriv.dir(entry)
          {:ok, _} = File.rm_rf(Path.join(assets, d))
          File.rename!(Path.join([staging, "foreign", d]), Path.join(assets, d))
        end

        :ok
      end

    _ = File.rm_rf(staging)
    result
  rescue
    e ->
      _ = File.rm_rf(staging)
      {:fail, "install failed: #{Exception.message(e)}"}
  end

  @doc """
  Whether each entry's `priv/assets/<d>` under kino's build dir is a real
  directory holding exactly its archive: a regular file of the entry's
  size and sha256, mode 0644.
  """
  @spec on_disk?(Path.t(), [map()]) :: boolean()
  def on_disk?(build_lib, entries) do
    assets = Path.join([build_lib, @target, "priv/assets"])

    Enum.all?(entries, fn %{"path" => path, "size" => size, "sha256" => sha} = entry ->
      dir = Path.join(assets, ForeignPriv.dir(entry))
      name = Path.basename(path)
      file = Path.join(dir, name)

      with :directory <- lstat_type(dir),
           {:ok, [^name]} <- File.ls(dir),
           {:ok, %File.Stat{type: :regular, size: ^size, mode: mode}} <- File.lstat(file),
           0o644 <- Bitwise.band(mode, 0o777),
           {:ok, bytes} <- File.read(file) do
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha
      else
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  @doc """
  The real `priv/assets/<d>` directories under kino dir `dir` that `entry`
  ships no file in; none unless `priv` and `priv/assets` are real
  directories.
  """
  @spec unshipped(Path.t(), map()) :: [String.t()]
  def unshipped(dir, entry) do
    shipped =
      for %{"path" => "priv/assets/" <> rest} <- entry["priv"] || [],
          into: MapSet.new(),
          do: rest |> String.split("/") |> hd()

    assets = Path.join(dir, "priv/assets")

    with :directory <- lstat_type(Path.join(dir, "priv")),
         :directory <- lstat_type(assets),
         {:ok, names} <- File.ls(assets) do
      names
      |> Enum.reject(&MapSet.member?(shipped, &1))
      |> Enum.filter(&(lstat_type(Path.join(assets, &1)) == :directory))
      |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc """
  Before a kino replace (`Fetch.install/6`): moves each real
  `dest/priv/assets/<d>` the new entry does not ship into
  `staging/priv/assets/<d>`, so the replace keeps the archives of other
  deps and of the project. `:mark_owners` when `staging/priv` is not a real
  directory (a link Mix makes to the sources): nothing is moved, and the
  caller marks the owners instead.
  """
  @spec carry(Path.t(), Path.t(), map()) :: :ok | :mark_owners
  def carry(dest, staging, entry) do
    case {unshipped(dest, entry), lstat_type(Path.join(staging, "priv"))} do
      {[], _} ->
        :ok

      {dirs, type} when type in [:directory, :none] ->
        File.mkdir_p!(Path.join(staging, "priv/assets"))

        for d <- dirs,
            do:
              File.rename!(
                Path.join([dest, "priv/assets", d]),
                Path.join([staging, "priv/assets", d])
              )

        :ok

      {_dirs, _link} ->
        :mark_owners
    end
  end

  @doc """
  Before kino's build dir goes: every dep in `build_lib` whose `.app` lists
  a module that owns a `priv/assets/<d>` in it (or a `<d>` of `also`,
  archives about to go with it from elsewhere), and that is not a client
  install, has Mix's `.mix/compile.elixir_scm` removed, Mix's own "fetched"
  mark, so Mix recompiles it after kino. A client install is left to the
  next run's check of its archives.
  """
  @spec mark_owners(Path.t(), [String.t()]) :: :ok
  def mark_owners(build_lib, also \\ []) do
    dirs = MapSet.new(ls(Path.join([build_lib, @target, "priv/assets"])) ++ also)

    with true <- MapSet.size(dirs) > 0,
         {:ok, apps} <- File.ls(build_lib) do
      owners =
        for app <- apps,
            app not in [@target, ".precompiled"],
            d <- app_dirs(build_lib, app),
            MapSet.member?(dirs, d),
            uniq: true,
            do: app

      for app <- owners,
          not Status.installed?(build_lib, app),
          do: File.rm(Path.join([build_lib, app, ".mix", "compile.elixir_scm"]))
    end

    :ok
  end

  @doc """
  `{app, dirs}` for every dep dir of `build_lib` but `except` (and the
  staging dir): `dirs`, the `priv/assets/<d>` its `.app`'s modules own.
  """
  @spec owned_dirs(Path.t(), String.t()) :: [{String.t(), [String.t()]}]
  def owned_dirs(build_lib, except) do
    case File.ls(build_lib) do
      {:ok, apps} ->
        for app <- Enum.sort(apps),
            app not in [except, ".precompiled"],
            do: {app, app_dirs(build_lib, app)}

      _ ->
        []
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end

  defp app_dirs(build_lib, app) do
    path = Path.join([build_lib, app, "ebin", app <> ".app"])

    with {:ok, [{:application, _, props}]} when is_list(props) <-
           :file.consult(String.to_charlist(path)),
         modules when is_list(modules) <- props[:modules] do
      for m <- modules, is_atom(m), d = ForeignPriv.dir_name(Atom.to_string(m)), d != nil, do: d
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp dir_or_absent(path, mode, what) do
    case {lstat_type(path), mode} do
      {:directory, _} -> :ok
      {:none, :may_create} -> mkdir(path, what)
      _ -> {:fail, "#{what} is not a directory"}
    end
  end

  defp mkdir(path, what) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, reason} -> {:fail, "#{what}: #{:file.format_error(reason)}"}
    end
  end

  defp lstat_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, _} -> :none
    end
  end

  defp cleanup(staging, fail) do
    _ = File.rm_rf(staging)
    fail
  end
end
