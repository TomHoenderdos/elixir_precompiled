# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Status do
  @moduledoc false
  # What is installed in a _build: every dep dir with the provenance file
  # an install writes. The provenance files are the record; report.json is
  # only the last run that had something to say.
  #
  # Removal is by the same rule, checked again right before each removal,
  # by lstat at every step: the build lib, the dep dir, its .mix and the
  # provenance file must each be what they look like (a plain dir, a plain
  # file), never a link. A dep Mix compiled has no provenance file (or a
  # stale one under Mix's own newer compile manifest) and its dir is never
  # removed; a link is removed as a link, never followed, so nothing
  # outside `<build_lib>/<dep>` goes.

  alias ElixirPrecompiled.Fetch

  @spec installed(Path.t()) :: [map()]
  def installed(build_lib) do
    for name <- install_names(build_lib) do
      dir = Path.join(build_lib, name)
      doc = decode(Fetch.provenance_path(build_lib, name))

      %{
        name: name,
        version: app_vsn(dir, name),
        manifest: str(doc["manifest_sha256"]),
        sequence: int(doc["batch_sequence"]),
        source: str(doc["source"])
      }
    end
  end

  @spec format(map()) :: String.t()
  def format(dep) do
    manifest =
      if dep.manifest,
        do: binary_part(dep.manifest, 0, min(12, byte_size(dep.manifest))),
        else: "?"

    "#{String.pad_trailing("#{dep.name} #{dep.version || "?"}", 32)}  batch #{dep.sequence || "?"}  " <>
      "manifest #{manifest}  #{dep.source || ""}"
  end

  @doc false
  # Every install in the build lib removed (see remove/2), and the stale
  # provenance file of every dep Mix rebuilt since. Only lstat and the
  # provenance files are read, no dep is loaded: a project that never
  # opted in pays one directory listing.
  @spec sweep(Path.t()) :: %{removed: [String.t()], failed: [{String.t(), String.t()}]}
  def sweep(build_lib) do
    results = for name <- dep_names(build_lib), do: {name, remove(build_lib, name)}

    %{
      removed: for({name, :ok} <- results, do: name),
      failed: for({name, {:error, why}} <- results, do: {name, why})
    }
  end

  @doc false
  # Removes `<build_lib>/<name>` only when it is an install (see above).
  # A dep Mix compiled after an install (one of Mix's own compile
  # manifests as new as the provenance file or newer) is Mix's build: only
  # the provenance file, now stale, goes (`:stale_provenance`). Anything
  # else is left as it is (`:not_installed`).
  #
  # File.rm_rf/1 acts on a path just checked by lstat; Erlang has no
  # O_NOFOLLOW, so a swap to a link in between (by someone who can already
  # write this _build) is removed as a link, never followed.
  @spec remove(Path.t(), String.t()) ::
          :ok | :stale_provenance | :not_installed | {:error, String.t()}
  def remove(build_lib, name) do
    case kind(build_lib, name) do
      :install ->
        case File.rm_rf(Path.join(build_lib, name)) do
          {:ok, _} -> :ok
          {:error, reason, file} -> {:error, "#{file}: #{:file.format_error(reason)}"}
        end

      :mix_build ->
        _ = File.rm(Fetch.provenance_path(build_lib, name))
        :stale_provenance

      :none ->
        :not_installed
    end
  end

  defp install_names(build_lib),
    do: Enum.filter(dep_names(build_lib), &(kind(build_lib, &1) == :install))

  defp dep_names(build_lib) do
    with true <- plain?(build_lib, :directory),
         {:ok, names} <- File.ls(build_lib) do
      names |> Enum.filter(&one_component?/1) |> Enum.sort()
    else
      _ -> []
    end
  end

  # Mix's own compile manifests; an install writes none of them (only
  # compile.elixir_scm, compile.fetch and the provenance file).
  @mix_manifests ~w(compile.elixir compile.erlang compile.leex compile.yecc compile.rebar3 compile.make)

  defp kind(build_lib, name) do
    dir = Path.join(build_lib, name)
    mix = Path.join(dir, ".mix")

    with true <- one_component?(name),
         true <- plain?(build_lib, :directory) and plain?(dir, :directory),
         true <- plain?(mix, :directory),
         {:ok, %File.Stat{type: :regular, mtime: at}} <-
           File.lstat(Fetch.provenance_path(build_lib, name), time: :posix) do
      if Enum.any?(@mix_manifests, &newer?(Path.join(mix, &1), at)),
        do: :mix_build,
        else: :install
    else
      _ -> :none
    end
  end

  defp newer?(path, at),
    do: match?({:ok, %File.Stat{mtime: m}} when m >= at, File.lstat(path, time: :posix))

  # A single plain path component: never ".", "..", empty or with a
  # separator, so the removal stays inside the build lib.
  defp one_component?(name),
    do:
      is_binary(name) and name not in ["", ".", ".."] and not String.starts_with?(name, ".") and
        Path.basename(name) == name and not String.contains?(name, ["/", "\\", <<0>>])

  defp plain?(path, type), do: match?({:ok, %File.Stat{type: ^type}}, File.lstat(path))

  defp decode(path) do
    with true <- plain?(path, :regular),
         {:ok, bytes} <- File.read(path),
         %{} = doc <- :json.decode(bytes) do
      doc
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp app_vsn(dir, name) do
    path = Path.join([dir, "ebin", name <> ".app"])

    with true <- plain?(Path.join(dir, "ebin"), :directory) and plain?(path, :regular),
         {:ok, [{:application, _, props}]} when is_list(props) <-
           :file.consult(String.to_charlist(path)),
         vsn when is_list(vsn) <- props[:vsn] do
      to_string(vsn)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp str(s) when is_binary(s), do: s
  defp str(_), do: nil
  defp int(n) when is_integer(n), do: n
  defp int(_), do: nil
end
