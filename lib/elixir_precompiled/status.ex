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
  # file), never a link. A dep Mix compiled has no provenance file and is
  # never touched; a link is removed as a link, never followed, so nothing
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

  @spec clean(Path.t()) :: non_neg_integer()
  def clean(build_lib) do
    Enum.count(install_names(build_lib), &(remove(build_lib, &1) == :ok))
  end

  @doc false
  # Removes `<build_lib>/<name>` only when it is an install (see above);
  # `:not_installed` leaves it as it is.
  @spec remove(Path.t(), String.t()) :: :ok | :not_installed | {:error, String.t()}
  def remove(build_lib, name) do
    if install?(build_lib, name) do
      case File.rm_rf(Path.join(build_lib, name)) do
        {:ok, _} -> :ok
        {:error, reason, file} -> {:error, "#{file}: #{:file.format_error(reason)}"}
      end
    else
      :not_installed
    end
  end

  defp install_names(build_lib) do
    with true <- plain?(build_lib, :directory),
         {:ok, names} <- File.ls(build_lib) do
      names |> Enum.filter(&install?(build_lib, &1)) |> Enum.sort()
    else
      _ -> []
    end
  end

  defp install?(build_lib, name) do
    dir = Path.join(build_lib, name)

    one_component?(name) and plain?(build_lib, :directory) and plain?(dir, :directory) and
      plain?(Path.join(dir, ".mix"), :directory) and
      plain?(Fetch.provenance_path(build_lib, name), :regular)
  end

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
