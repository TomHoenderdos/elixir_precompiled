# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ForeignPriv do
  @moduledoc false
  # Foreign priv builds (0.8.0): a build whose compile wrote Kino.JS asset
  # archives into kino's build `priv`, the one pattern the portal's judge
  # reviewed (rule `kino_js_v1`, kino 0.19.1). Its `foreign_priv` entries name
  # each archive by its path below kino's build dir,
  # `priv/assets/<d>/<h>.tar.gz`, where `<d>` is the writer's module `M`
  # without `Elixir.` and with every `.` replaced by `_`.
  #
  # This client knows one target, kino, and one rule. A build under a rule it
  # does not know misses (`foreign_priv_rule_unknown`); entries it cannot
  # place exactly as Kino.JS would are a malformed entry (V1-V4, checked
  # before anything is fetched). Mix-free: Check runs it in a release too.

  alias Precompiled.{Fetch, Reason}

  @target :kino
  @rules ["kino_js_v1"]
  # The portal's own shape check (its ingest's regex): `<h>` is Kino.JS's
  # name hash, 26 characters of unpadded lower-case base32.
  @path ~r/\Apriv\/assets\/([A-Z][A-Za-z0-9_]*)\/([a-z2-7]{26})\.tar\.gz\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  @modes [0o644, 0o100644]
  @max_entries 64
  @max_bytes 10 * 1024 * 1024

  @doc "The one app whose priv a foreign build writes into."
  @spec target() :: atom()
  def target(), do: @target

  @doc "The rules this client knows."
  @spec rules() :: [String.t()]
  def rules(), do: @rules

  @spec max_entries() :: pos_integer()
  def max_entries(), do: @max_entries

  @spec max_bytes() :: pos_integer()
  def max_bytes(), do: @max_bytes

  @doc "A build's foreign entries, `[]` for a build without any."
  @spec entries(map()) :: [map()]
  def entries(%{"foreign_priv" => [_ | _] = list}), do: list
  def entries(_build), do: []

  @doc """
  Whether a build carries no foreign entries: its `foreign_priv` is absent,
  nil or `[]`. Only such a build may be installed as a regular one.
  """
  @spec none?(map()) :: boolean()
  def none?(build), do: Map.get(build, "foreign_priv") in [nil, []]

  @doc "The directory Kino.JS packs `module`'s assets in, nil for an Erlang module."
  @spec dir_name(String.t()) :: String.t() | nil
  def dir_name("Elixir." <> name) when name != "", do: String.replace(name, ".", "_")
  def dir_name(_module), do: nil

  @doc """
  `<d>` as it is compared: case-folded, since on a file system that folds
  case (macOS's default, Windows) two names that differ only in case are
  one directory.
  """
  @spec fold(String.t()) :: String.t()
  def fold(d), do: String.downcase(d)

  @doc "An entry's `<d>`."
  @spec dir(map()) :: String.t()
  def dir(%{"path" => path}), do: path |> Path.split() |> Enum.at(2)

  @doc """
  A foreign-list build without entries passes only as kino's own build
  (the portal's 0b: `build.foreign_priv_target` is kino, the package is
  kino). Any other would install without the archives its compile writes.
  """
  @spec own_reason(map(), String.t()) :: :ok | {:miss, Reason.t()}
  def own_reason(build, name) do
    target = Atom.to_string(@target)

    if name == target and get_in(build, ["build", "foreign_priv_target"]) == target,
      do: :ok,
      else: malformed()
  end

  @doc "A foreign-list build with entries passes only for a package other than kino."
  @spec writer_reason(String.t()) :: :ok | {:miss, Reason.t()}
  def writer_reason(name), do: if(name == Atom.to_string(@target), do: malformed(), else: :ok)

  @doc "The build's rule is one this client knows."
  @spec rule_reason(map()) :: :ok | {:miss, Reason.t()}
  def rule_reason(build) do
    rule = get_in(build, ["build", "foreign_priv_rule"])

    if rule in @rules,
      do: :ok,
      else: {:miss, Reason.new(:foreign_priv_rule_unknown, ["kino", to_string(rule)])}
  end

  @doc """
  V1 to V4 (before any fetch): every entry for kino, at an archive path
  `Fetch.safe_path?/1` takes, mode 0644, in a directory of one of the
  build's own beams (its `ebin` list, which `Fetch.modules_ok/2` ties to
  its `.app` at install), one entry per directory (case-folded, `fold/1`),
  at most 64, 10 MiB in all.
  """
  @spec entries_reason(map()) :: :ok | {:miss, Reason.t()}
  def entries_reason(build) do
    entries = build["foreign_priv"]
    dirs = build |> modules() |> MapSet.new(&dir_name/1)

    ok? =
      is_list(entries) and length(entries) <= @max_entries and
        Enum.all?(entries, &entry_ok?(&1, dirs)) and
        entries |> Enum.map(& &1["size"]) |> Enum.sum() <= @max_bytes and
        length(Enum.uniq_by(entries, &fold(dir(&1)))) == length(entries)

    if ok?, do: :ok, else: malformed()
  end

  @doc """
  A build that carries no foreign entries passes; one that does misses as
  a malformed entry. For a list where no foreign build may be: the regular
  and host-native ones, which Phase A installs without placing anything.
  """
  @spec none_reason(map()) :: :ok | {:miss, Reason.t()}
  def none_reason(build), do: if(none?(build), do: :ok, else: malformed())

  @doc """
  Whether the entries an install recorded in its provenance (`foreign`)
  are archives this client would place: V1, V2 and V4 as for a manifest
  entry. V3 was checked when they were placed, against the build's beams.
  """
  @spec recorded?(term()) :: boolean()
  def recorded?(entries) do
    is_list(entries) and entries != [] and length(entries) <= @max_entries and
      Enum.all?(entries, &entry_ok?(&1, :any)) and
      entries |> Enum.map(& &1["size"]) |> Enum.sum() <= @max_bytes and
      length(Enum.uniq_by(entries, &fold(dir(&1)))) == length(entries)
  end

  defp malformed(), do: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}

  defp entry_ok?(
         %{"app" => "kino", "path" => path, "sha256" => sha, "size" => size, "mode" => mode},
         dirs
       )
       when is_binary(path) and is_binary(sha) and is_integer(size) and size >= 0 do
    Regex.match?(@path, path) and Fetch.safe_path?(path) and mode in @modes and
      Regex.match?(@sha, sha) and (dirs == :any or MapSet.member?(dirs, dir(%{"path" => path})))
  end

  defp entry_ok?(_entry, _dirs), do: false

  defp modules(build) do
    for %{"path" => "ebin/" <> file} <- List.wrap(build["ebin"]),
        String.ends_with?(file, ".beam"),
        do: Path.rootname(file)
  end
end
