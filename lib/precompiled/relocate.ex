# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Relocate do
  @moduledoc false
  # 0.9.0: relocated builds. A build whose beams bake the portal builder's
  # deps or build path (`build.relocation` of a relocated entry) is installed
  # with each occurrence rewritten to this project's own paths, as this
  # project's own compile would have written it: a literal re-encoded with
  # term_to_binary(term, [{:minor_version, 2}, :deterministic]) (the
  # compiler's beam_dict:my_term_to_binary/1), an atom or a line-table file
  # name rewritten in place, an attribute rewritten and the whole Attr chunk
  # encoded again, the module's md5 taken again as the running OTP takes it
  # (beam_lib:md5/1: OTP 29 adds Recs and DbgB to OTP 28's chunks), each
  # fun's old_uniq its first 27 bits, and a default vsn (the old md5) the
  # new one. The portal's builder proved the same rewrite against compiles
  # at two other roots. The record's three roots must be the builder's own
  # layout (pinned_problem/2), every build slot in it followed by Mix's own
  # layout under a build path, and every served beam's CInf source must lie
  # in the package's dir under the record's deps path. A record may name no
  # file: a package held only for a dependency, nothing of its own to
  # rewrite, still held to the envelope and these checks. It refuses what a
  # compile at these paths would have written differently (two literals,
  # atoms or file names that become one, an atom over 255 code points), an
  # occurrence the record and the beam disagree on, and any builder path
  # left in any chunk but CInf, Dbgi and Docs. Runs in the user's own VM, so
  # a literal is encoded as the user's compiler would encode it.
  #
  # An occurrence: %{"chunk", "index", "term", "kind", "parts"}, as the
  # portal records it (Compatibility.Relocation): the chunk (LitT, AtU8,
  # Attr, Line), the literal's index (from 0), the atom's (from 1) or the
  # file name's (from 0), the path to the value inside the term (element
  # indices; a map value's index among its keys in term order), the kind
  # (binary, charlist, atom) and the value as text and slot names in turn:
  # ["", "deps", "/fine/c_include"] is <deps>/fine/c_include.

  @slots ["deps", "build"]
  @metadata ~w(CInf Dbgi Docs)
  @rewritten ~w(LitT AtU8 Attr Line)
  @max_term_bytes 4 * 1024 * 1024
  @max_occurrences 10_000
  @literal_opts [{:minor_version, 2}, :deterministic]
  @md5_limit Bitwise.bsl(1, 128)

  @type slots :: %{String.t() => String.t()}
  @type occurrence :: %{String.t() => term()}
  @type outcome :: :same | {:ok, [occurrence()]} | {:refuse, String.t()}

  @doc "The slot names: `deps` and `build`."
  @spec slots() :: [String.t()]
  def slots(), do: @slots

  @doc """
  `beam` with each of `occurrences` rewritten from the slots `from` to the
  slots `to`, its md5, funs and default `vsn` taken again (see the
  moduledoc).
  """
  @spec relocate(binary(), [occurrence()], slots(), slots()) ::
          {:ok, binary()} | {:refuse, String.t()}
  def relocate(beam, occurrences, from, to) when is_list(occurrences) do
    with :ok <- valid_slots(from),
         :ok <- valid_slots(to),
         {:ok, chunks} <- chunks(beam),
         {:ok, moved} <- relocate_chunks(chunks, occurrences, from, to),
         :ok <- nothing_left(moved, from, to) do
      {:ok, form(moved)}
    end
  rescue
    _ -> {:refuse, "unreadable beam"}
  end

  def relocate(_beam, _occurrences, _from, _to), do: {:refuse, "no occurrences"}

  @doc """
  The occurrences of `slots` in `beam` (see the moduledoc), unproven: what
  `prove/4` starts from, and how the worker finds a build's holder modules
  before its second build. `{:refuse, why}` where a slot sits where no
  rewrite reaches it.
  """
  @spec occurrences(binary(), slots()) :: {:ok, [occurrence()]} | {:refuse, String.t()}
  def occurrences(beam, slots) do
    with :ok <- valid_slots(slots),
         {:ok, chunks} <- chunks(beam),
         do: scan(chunks, slots)
  rescue
    _ -> {:refuse, "unreadable beam"}
  end

  @record_keys ["build", "deps", "files", "second", "third"]
  @kinds ["binary", "charlist", "atom"]
  @max_files 10_000

  # Match's last rule for a relocated build (0.9.0): nil when this project
  # can take it, else the miss. OTP 28 or later (OTP 27 compresses the
  # literal table, which this rewrite never reads), a record of the entry's
  # own beams, well formed, at the builder's own three roots
  # (pinned_problem/2), and this project's own slots (`ctx.relocate`,
  # `user_slots/2`: real, printable ASCII, spelled as on disk) inside the
  # envelope of those roots (envelope_reason/2).
  @spec reason(map(), map()) :: Precompiled.Reason.t() | nil
  def reason(build, ctx) do
    record = build["relocation"]
    ebin = for %{"path" => path} when is_binary(path) <- build["ebin"] || [], do: path

    cond do
      otp_major(ctx.otp) < 28 ->
        Precompiled.Reason.new(:relocated_otp, [])

      problem =
          record_problem(record, ebin, closure_apps(build, Map.get(ctx, :name))) ||
            pinned_problem(record) ->
        Precompiled.Reason.new(:relocation_refused, [], "relocated build: #{problem}")

      true ->
        slots_reason(record, Map.get(ctx, :relocate))
    end
  end

  defp slots_reason(record, {:ok, slots}), do: envelope_reason(record, slots)
  defp slots_reason(_record, {:error, code, args}), do: Precompiled.Reason.new(code, args)
  defp slots_reason(_record, _none), do: Precompiled.Reason.new(:relocated_paths, [])

  defp otp_major(otp) do
    case Integer.parse(to_string(otp)) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Why a relocation record is not one this client can apply, or nil: the
  # builder's `deps` and `build` paths, `second` and `third` the same for
  # its other two builds (each pair absolute, printable ASCII, distinct,
  # neither inside the other), and `files`, a list of distinct beams of the
  # entry's own `ebin`, each with at least one well-formed occurrence, every
  # `build` slot in it followed by Mix's own layout under a build path (the
  # client re-review's R5 and R9): nothing, `/consolidated/...`, or
  # `/lib/<app>/` and then `ebin`, `priv`, `include` or `.mix`, `<app>` one
  # of `apps` (the build's closure, closure_apps/2) when given. `files`
  # is empty for a dependent that passed only because a dependency was
  # held: nothing in its own beams to rewrite, but the envelope and the
  # source check still hold it. The same check as the portal's at ingest
  # (Compatibility.Relocation).
  @spec record_problem(term(), [String.t()], [String.t()] | nil) :: String.t() | nil
  def record_problem(record, ebin, apps \\ nil)

  def record_problem(%{"deps" => deps, "build" => build, "files" => files} = record, ebin, apps)
      when is_list(files) and is_list(ebin) and (is_list(apps) or is_nil(apps)) do
    cond do
      record |> Map.keys() |> Enum.sort() != @record_keys ->
        "unknown keys"

      problem =
          roots_problem(%{"deps" => deps, "build" => build}, record["second"], record["third"]) ->
        problem

      length(files) > @max_files ->
        "too many files"

      length(Enum.uniq_by(files, &file_path/1)) != length(files) ->
        "a file twice"

      true ->
        Enum.find_value(files, &file_problem(&1, ebin, apps))
    end
  end

  def record_problem(_record, _ebin, _apps), do: "not a relocation record"

  # The build's closure apps, as Mix names their dirs under a build path:
  # the package's own and its entry's `build.deps` keys.
  defp closure_apps(entry, app) do
    locked =
      case entry["build"] do
        %{"deps" => %{} = deps} -> Map.keys(deps)
        _ -> []
      end

    Enum.uniq(if(is_nil(app), do: locked, else: [to_string(app) | locked]))
  end

  defp roots_problem(first, second, third) do
    roots = [first, second, third]

    cond do
      Enum.any?(roots, &match?({:refuse, _}, valid_slots(&1))) ->
        "bad paths"

      not Enum.all?(Enum.flat_map(roots, &Map.values/1), &printable?/1) ->
        "a path not printable ASCII"

      true ->
        nil
    end
  end

  # The builder's three roots (the client re-review's R1), as
  # Compatibility.Relocation lays them out on the portal: the first its
  # host compile's, the second under /home/ncc-relocate (outside the
  # container's HOME), the third under /Users, both of run token n. Copied
  # here, so a record whose roots are not these (a portal that widened
  # them, a wrong record) is refused whatever the portal checked. The
  # layout is frozen: another one needs another record version.
  @first %{"deps" => "/work/proj/deps", "build" => "/work/proj/_build/host"}
  @home "/home/ncc-relocate"
  @users "/Users"
  @second_cache ".cache/mix/installs/elixir-1.20.5-erts-16.4.0.2"
  @second_dirs ["nix/store/src/code/projects", "x_y@z~0.d", "app"]
  @second_deps "deps"
  @second_build "out.d/host-1"
  @third_dirs [
    "Library/Mobile Documents",
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "0123456789",
    "abcdefghijklmnopqrstuvwxyz",
    "Long Relocation.Path-0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
    "x",
    "Y",
    "z-0",
    "Projects",
    "The Relocated.Project-2"
  ]
  @third_deps "Deps vendored_d"
  @third_build "Build-3/Host 4"

  @doc false
  # The record's three roots for run token `n`, under `prefix` ("" outside
  # tests): what pinned_problem/2 holds a record to.
  @spec pinned_record(non_neg_integer(), String.t()) :: map()
  def pinned_record(n, prefix \\ "") when is_integer(n) and n >= 0 and is_binary(prefix) do
    second = Path.join([prefix <> @home, @second_cache, "ncc-relocate-#{n}" | @second_dirs])
    third = Path.join([prefix <> @users, "Ncc-Relocate #{n}" | @third_dirs])

    %{
      "deps" => prefix <> @first["deps"],
      "build" => prefix <> @first["build"],
      "second" => %{
        "deps" => Path.join(second, @second_deps),
        "build" => Path.join(second, @second_build)
      },
      "third" => %{
        "deps" => Path.join(third, @third_deps),
        "build" => Path.join(third, @third_build)
      }
    }
  end

  # Why a record's three roots are not the builder's (pinned_record/2 for
  # the run token its second root names), or nil: the portal's
  # Compatibility.Relocation.pinned_problem/1, under `prefix`.
  @spec pinned_problem(term(), term()) :: String.t() | nil
  def pinned_problem(record, prefix \\ relocation_prefix())

  def pinned_problem(%{"second" => %{"deps" => deps}} = record, prefix)
      when is_binary(deps) and is_binary(prefix) do
    with [_, digits] <- Regex.run(~r"/ncc-relocate-([0-9]{1,20})/", deps),
         true <-
           Map.take(record, ["deps", "build", "second", "third"]) ==
             pinned_record(String.to_integer(digits), prefix) do
      nil
    else
      _ -> "the record's roots are not the builder's"
    end
  end

  def pinned_problem(_record, _prefix), do: "the record's roots are not the builder's"

  # The client re-review's R8: a test-only seam. Only when this library is
  # compiled in its own test env does `config :precompiled,
  # relocation_prefix: dir` put the three roots under `dir`, so a unit test
  # can compile at them (no record at the real roots matches then). Built
  # as a dependency, as every user builds it, the prefix is "" and no
  # config can change it.
  if Mix.env() == :test do
    defp relocation_prefix(), do: Application.get_env(:precompiled, :relocation_prefix, "")
  else
    defp relocation_prefix(), do: ""
  end

  defp file_path(%{"path" => path}), do: path
  defp file_path(file), do: file

  defp file_problem(
         %{"path" => "ebin/" <> name = path, "occurrences" => [_ | _] = occs},
         ebin,
         apps
       ) do
    cond do
      Path.basename(name) != name or Path.extname(name) != ".beam" -> "not a beam: #{path}"
      path not in ebin -> "not a file of the build: #{path}"
      length(occs) > @max_occurrences -> "too many occurrences"
      not Enum.all?(occs, &occurrence?/1) -> "a malformed occurrence in #{path}"
      tail = tails_problem(occs, apps) -> "#{tail} in #{path}"
      true -> nil
    end
  end

  defp file_problem(_file, _ebin, _apps), do: "a malformed file entry"

  # The client re-review's R5 and R9: nothing but Mix's own layout under a
  # build path ties the build root to the beams, so the text after a
  # `build` slot must be that layout (mix_layout?/2).
  defp tails_problem(occs, apps) do
    Enum.find_value(occs, fn %{"parts" => parts} ->
      parts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(&tail_problem(&1, apps))
    end)
  end

  defp tail_problem(["build", tail], apps) do
    if not mix_layout?(tail, apps), do: "a build path followed by #{inspect(tail, limit: 3)}"
  end

  defp tail_problem(_pair, _apps), do: nil

  @app_dirs ~w(ebin priv include .mix)

  # Nothing, `/consolidated/...`, or `/lib/<app>/<dir>` and below, `<dir>`
  # one of an app's own dirs and `<app>` one of `apps` when given.
  defp mix_layout?("", _apps), do: true
  defp mix_layout?("/consolidated/" <> _, _apps), do: true

  defp mix_layout?("/lib/" <> rest, apps) do
    case String.split(rest, "/", parts: 3) do
      [app, dir | _] when dir in @app_dirs and app not in ["", ".", ".."] ->
        apps == nil or app in apps

      _ ->
        false
    end
  end

  defp mix_layout?(_tail, _apps), do: false

  defp occurrence?(
         %{"chunk" => chunk, "index" => i, "term" => term, "kind" => kind, "parts" => parts} =
           occ
       )
       when map_size(occ) == 5 and chunk in @rewritten and is_integer(i) and i >= 0 and
              is_list(term) and kind in @kinds and is_list(parts) do
    Enum.all?(term, &(is_integer(&1) and &1 >= 0)) and template?(parts)
  end

  defp occurrence?(_occ), do: false

  defp template?([_text, _slot | _] = parts) do
    rem(length(parts), 2) == 1 and
      parts
      |> Enum.with_index()
      |> Enum.all?(fn {part, i} -> is_binary(part) and (rem(i, 2) == 0 or part in @slots) end)
  end

  defp template?(_parts), do: false

  # This project's slots, `{:ok, %{"deps" => deps_path, "build" =>
  # build_path}}`, when a relocated build may be installed into it, else
  # `{:error, code, args}`, a reason code for the miss:
  #
  #   * `relocated_paths`: not a unix host whose file names are UTF-8, or a
  #     path that is not absolute and normalised, holds a symlink or a
  #     component that is no directory, or the two paths overlap;
  #   * `relocated_path_ascii`: a path with a byte that is not printable
  #     ASCII. The builder's roots are, so its bytes and code points are
  #     one; a compile here could make either of a path that is not (a
  #     latin1 binary of a code-point path, a UTF-8 one), and the builder's
  #     two-root proof cannot tell them apart;
  #   * `relocated_path_spelling`: a component that is not an exact entry,
  #     byte for byte, of its parent dir's listing, or a parent dir that
  #     cannot be listed. Mix compiles a dependency after a cd into it, so
  #     `__DIR__` and `File.cwd!/0` give the spelling on disk, which a
  #     volume that ignores case or Unicode form lets differ from the
  #     spelling Mix was given (`MIX_DEPS_PATH`, `MIX_BUILD_PATH`,
  #     `deps_path:`, Mix.install's dir).
  @spec user_slots(term(), term()) ::
          {:ok, slots()}
          | {:error, :relocated_paths | :relocated_path_ascii | :relocated_path_spelling,
             [String.t()]}
  def user_slots(deps_path, build_path) do
    paths = [{"deps", deps_path}, {"build", build_path}]

    cond do
      not unix_utf8?() or not Enum.all?(paths, &is_binary(elem(&1, 1))) ->
        {:error, :relocated_paths, []}

      slot = first_slot(paths, &(not printable?(&1))) ->
        {:error, :relocated_path_ascii, [slot]}

      not Enum.all?(paths, &real?(elem(&1, 1))) or overlap?(deps_path, build_path) ->
        {:error, :relocated_paths, []}

      slot = first_slot(paths, &(not spelled?(&1))) ->
        {:error, :relocated_path_spelling, [slot]}

      true ->
        {:ok, %{"deps" => deps_path, "build" => build_path}}
    end
  end

  defp unix_utf8?(),
    do: match?({:unix, _}, :os.type()) and :file.native_name_encoding() == :utf8

  defp first_slot(paths, bad?), do: Enum.find_value(paths, fn {s, p} -> if bad?.(p), do: s end)

  defp printable?(path), do: path =~ ~r/\A[\x20-\x7e]+\z/

  defp real?(path) do
    absolute?(path) and Path.expand(path) == path and
      path |> prefixes() |> Enum.all?(&dir?/1)
  end

  defp prefixes(path), do: path |> Path.split() |> tl() |> Enum.scan("/", &Path.join(&2, &1))

  defp dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  # Every component an exact entry of its parent's listing: no case
  # folding, no Unicode normalisation.
  defp spelled?(path) do
    Enum.all?(prefixes(path), fn prefix ->
      case File.ls(Path.dirname(prefix)) do
        {:ok, names} -> Path.basename(prefix) in names
        {:error, _} -> false
      end
    end)
  end

  # The umbrella reviews' B1 and R1: the builder proved its build at three
  # roots, the record's (`deps`, `build`), the second build's (`second`)
  # and the third's (`third`), unlike in length, depth, case, spaces,
  # project dir name and the order of the two paths. A value its compile
  # derived from a path that is equal at all three is not seen by that
  # proof; it is equal at this project's paths too when they are inside the
  # envelope the roots span, for a threshold on a path's length or depth or
  # a test of which characters it holds. So each of this project's paths
  # must hold only characters of the three roots' paths for its slot, and
  # lie between their shortest and longest and their shallowest and
  # deepest. What no envelope bounds: a test against a constant none of the
  # three roots holds (a prefix such as /opt/, a word), or one that answers
  # the same at all three and otherwise at this project's path. nil when
  # inside, else the miss.
  @spec envelope_reason(map(), slots()) :: Precompiled.Reason.t() | nil
  def envelope_reason(%{"second" => %{} = second, "third" => %{} = third} = record, user) do
    Enum.find_value(@slots, fn slot ->
      roots = [record[slot], second[slot], third[slot]]

      if not inside?(user[slot], roots),
        do: Precompiled.Reason.new(:relocated_path_envelope, [slot])
    end)
  end

  def envelope_reason(_record, _user),
    do: Precompiled.Reason.new(:relocated_path_envelope, ["deps"])

  defp inside?(path, roots) when is_binary(path) do
    if Enum.all?(roots, &is_binary/1) do
      chars = roots |> Enum.flat_map(&:binary.bin_to_list/1) |> MapSet.new()
      lengths = Enum.map(roots, &byte_size/1)
      depths = Enum.map(roots, &depth/1)

      Enum.all?(:binary.bin_to_list(path), &MapSet.member?(chars, &1)) and
        between?(byte_size(path), lengths) and between?(depth(path), depths)
    else
      false
    end
  end

  defp inside?(_path, _roots), do: false

  defp between?(x, bounds), do: x >= Enum.min(bounds) and x <= Enum.max(bounds)
  defp depth(path), do: length(Path.split(path)) - 1

  # A relocated entry's staged files, verified and rewritten in place from
  # the builder's slots (the record's `deps` and `build`) to `to`: what
  # `Precompiled.Fetch` does after staging and verifying the served files
  # of dependency `app` and before anything is renamed into `_build`. The
  # record is not trusted (the client review's S1, the client re-review's
  # R1): its three roots must be the builder's own (pinned_problem/2); `to`
  # must be printable ASCII and inside the envelope of those roots; every
  # beam of the entry's `ebin` must have been compiled from a source in
  # `app`'s dir under the record's deps path (its CInf `source`), and have
  # the occurrences of the builder's paths this client derives from it
  # (`occurrences/2`, which refuses one in any chunk the rewrite does not
  # reach, the module's name or a function's), exactly the ones the record
  # lists for it, none for a beam it does not name; every other file of the
  # entry, its `.app` and its `priv` included, holds no builder path at
  # all; and after the rewrite no rewritten beam holds one in any chunk but
  # `CInf`, `Dbgi` and `Docs`.
  @spec apply_staged(Path.t(), map(), slots(), atom() | String.t()) :: :ok | {:fail, String.t()}
  def apply_staged(staging, %{"relocation" => %{"files" => files} = record} = entry, to, app)
      when is_list(files) do
    from = Map.take(record, @slots)
    ebin = entry_paths(entry["ebin"])
    files = Map.new(record["files"], &{&1["path"], &1["occurrences"]})

    check = %{
      files: files,
      from: from,
      source_dir: Path.join(record["deps"], to_string(app)) <> "/",
      apps: closure_apps(entry, app)
    }

    with :ok <- target_problem(record, ebin, to, check.apps),
         :ok <- each(ebin, &derived(staging, &1, check)),
         :ok <- each(entry_paths(entry["priv"]), &untouched(staging, &1, from)),
         :ok <- each(Map.keys(files), &rewrite_file(staging, &1, files[&1], from, to)) do
      :ok
    else
      {:refuse, why} -> {:fail, "relocation refused: #{why}"}
    end
  rescue
    e -> {:fail, "relocation refused: #{Exception.message(e)}"}
  end

  def apply_staged(_staging, _entry, _to, _app), do: {:fail, "relocation refused: no record"}

  defp entry_paths(files) when is_list(files),
    do: for(%{"path" => path} when is_binary(path) <- files, do: path)

  defp entry_paths(_files), do: []

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        refuse -> {:halt, refuse}
      end
    end)
  end

  defp target_problem(record, ebin, to, apps) do
    cond do
      problem = record_problem(record, ebin, apps) || pinned_problem(record) ->
        {:refuse, problem}

      valid_slots(to) != :ok ->
        valid_slots(to)

      not Enum.all?(Map.values(to), &printable?/1) ->
        {:refuse, "this project's paths are not ASCII"}

      reason = envelope_reason(record, to) ->
        {:refuse, reason.text}

      true ->
        :ok
    end
  end

  # A beam compiled from its package's own dir under the record's deps
  # path, with its own occurrences the record's for it; any other file,
  # none.
  defp derived(staging, rel, check) do
    with {:ok, bytes} <- read(Path.join(staging, rel)) do
      if Path.extname(rel) == ".beam" do
        with :ok <- compiled_in(bytes, rel, check.source_dir),
             do: derived_matches(bytes, rel, check)
      else
        untouched_bytes(rel, bytes, check.from)
      end
    end
  end

  defp derived_matches(bytes, rel, check) do
    case occurrences(bytes, check.from) do
      {:ok, found} ->
        cond do
          tail = tails_problem(found, check.apps) -> {:refuse, "#{rel}: #{tail}"}
          Enum.sort(found) == Enum.sort(Map.get(check.files, rel, [])) -> :ok
          true -> {:refuse, "#{rel}: the record does not match the served beam"}
        end

      {:refuse, why} ->
        {:refuse, "#{rel}: #{why}"}
    end
  end

  # The client re-review's R1: the beam's CInf `source` (the file its
  # compile read) is in `source_dir`, the package's dir under the record's
  # deps path. A beam with no source (a `deterministic` compile) or one
  # compiled elsewhere does not show the record's paths are its own.
  defp compiled_in(bytes, rel, source_dir) do
    with {:ok, chunks} <- chunks(bytes),
         data when is_binary(data) <- chunk(chunks, "CInf"),
         {:ok, info} when is_list(info) <- decode(data),
         source when is_list(source) <- List.keyfind(info, :source, 0) |> source_of(),
         {:ok, path} <- charlist(source),
         true <- String.starts_with?(path, source_dir) and Path.expand(path) == path do
      :ok
    else
      {:refuse, why} -> {:refuse, "#{rel}: #{why}"}
      _ -> {:refuse, "#{rel}: not compiled from the record's deps path"}
    end
  end

  defp source_of({:source, source}), do: source
  defp source_of(_none), do: nil

  defp untouched(staging, rel, from) do
    with {:ok, bytes} <- read(Path.join(staging, rel)), do: untouched_bytes(rel, bytes, from)
  end

  defp untouched_bytes(rel, bytes, from) do
    if contains?(bytes, needles(from)),
      do: {:refuse, "#{rel} holds the builder's path"},
      else: :ok
  end

  defp rewrite_file(staging, rel, occs, from, to) do
    path = Path.join(staging, rel)

    with {:ok, bytes} <- read(path),
         {:ok, moved} <- relocate(bytes, occs, from, to) do
      File.write!(path, moved)
      :ok
    else
      {:refuse, why} -> {:refuse, "#{rel}: #{why}"}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, why} -> {:refuse, "#{Path.basename(path)}: #{:file.format_error(why)}"}
    end
  end

  @doc "A template's value at `slots`."
  @spec render([String.t()], slots()) :: String.t()
  def render(parts, slots), do: render(parts, slots, [])

  defp render([text], _slots, acc), do: IO.iodata_to_binary([acc, text])

  defp render([text, slot | rest], slots, acc),
    do: render(rest, slots, [acc, text, Map.fetch!(slots, slot)])

  # --- slots -----------------------------------------------------------------

  defp valid_slots(slots) when is_map(slots) do
    if Map.keys(slots) |> Enum.sort() == Enum.sort(@slots) and
         Enum.all?(Map.values(slots), &absolute?/1) do
      [deps, build] = Enum.map(@slots, &Map.fetch!(slots, &1))

      if overlap?(deps, build), do: {:refuse, "the deps and build paths overlap"}, else: :ok
    else
      {:refuse, "slots must name an absolute deps and build path"}
    end
  end

  defp valid_slots(_slots), do: {:refuse, "slots must name an absolute deps and build path"}

  defp absolute?(path),
    do: is_binary(path) and String.valid?(path) and String.starts_with?(path, "/")

  defp overlap?(x, y), do: String.contains?(x, y) or String.contains?(y, x)

  defp needles(slots), do: slots |> Map.values() |> Enum.uniq()

  defp contains?(data, needles) when is_binary(data), do: :binary.match(data, needles) != :nomatch

  # The template of `s`: text and slot names in turn.
  defp parts(s, slots) do
    by_value = Map.new(slots, fn {name, value} -> {value, name} end)

    {parts, last} =
      s
      |> :binary.matches(Map.keys(by_value))
      |> Enum.reduce({[], 0}, fn {pos, len}, {acc, at} ->
        text = binary_part(s, at, pos - at)
        slot = Map.fetch!(by_value, binary_part(s, pos, len))
        {[slot, text | acc], pos + len}
      end)

    Enum.reverse([binary_part(s, last, byte_size(s) - last) | parts])
  end

  # --- the IFF container -------------------------------------------------------

  defp chunks(<<"FOR1", size::32, "BEAM", rest::binary>>) when size == byte_size(rest) + 4 do
    with {:ok, chunks} <- read_chunks(rest, []),
         ids = Enum.map(chunks, &elem(&1, 0)),
         true <- ids == Enum.uniq(ids) do
      {:ok, chunks}
    else
      _ -> {:refuse, "unreadable beam"}
    end
  end

  defp chunks(<<31, 139, _::binary>>), do: {:refuse, "a compressed beam"}
  defp chunks(_bytes), do: {:refuse, "unreadable beam"}

  defp read_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_chunks(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    cond do
      byte_size(rest) >= pad -> read_chunks(drop(rest, pad), [{id, data} | acc])
      rest == <<>> -> read_chunks(<<>>, [{id, data} | acc])
      true -> :error
    end
  end

  defp read_chunks(_bytes, _acc), do: :error

  # `bytes` without its first `n` (at most its size).
  defp drop(bytes, n), do: binary_part(bytes, n, byte_size(bytes) - n)

  defp form(chunks) do
    body =
      for {id, data} <- chunks, into: <<>> do
        pad = rem(4 - rem(byte_size(data), 4), 4)
        <<id::binary, byte_size(data)::32, data::binary, 0::size(pad * 8)>>
      end

    <<"FOR1", byte_size(body) + 4::32, "BEAM", body::binary>>
  end

  defp chunk(chunks, id) do
    case List.keyfind(chunks, id, 0) do
      {^id, data} -> data
      nil -> nil
    end
  end

  # --- finding the occurrences ---------------------------------------------------

  defp scan(chunks, slots) do
    needles = needles(slots)

    chunks
    |> Enum.reduce_while({:ok, []}, fn {id, data}, {:ok, acc} ->
      case scan_chunk(id, data, chunks, slots, needles) do
        {:ok, found} -> {:cont, {:ok, acc ++ found}}
        {:refuse, _} = refuse -> {:halt, refuse}
      end
    end)
    |> then(fn
      {:ok, occs} when length(occs) > @max_occurrences -> {:refuse, "too many paths"}
      other -> other
    end)
  end

  defp scan_chunk(id, _data, _chunks, _slots, _needles) when id in @metadata, do: {:ok, []}

  defp scan_chunk("LitT", data, _chunks, slots, needles),
    do: literal_occurrences(data, slots, needles)

  defp scan_chunk("AtU8", data, chunks, slots, needles),
    do: atom_occurrences(data, chunks, slots, needles)

  defp scan_chunk("Attr", data, _chunks, slots, needles),
    do: attr_occurrences(data, slots, needles)

  defp scan_chunk("Line", data, _chunks, slots, needles),
    do: line_occurrences(data, slots, needles)

  defp scan_chunk(id, data, _chunks, _slots, needles) do
    if contains?(data, needles), do: {:refuse, "a path in #{id}"}, else: {:ok, []}
  end

  defp literal_occurrences(data, slots, needles) do
    with {:ok, entries} <- literals(data) do
      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {etf, i}, {:ok, acc} ->
        if contains?(etf, needles) do
          case term_occurrences(etf, slots, needles, "LitT", i) do
            {:ok, found} -> {:cont, {:ok, acc ++ found}}
            refuse -> {:halt, refuse}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)
    end
  end

  defp attr_occurrences(data, slots, needles) do
    if contains?(data, needles),
      do: term_occurrences(data, slots, needles, "Attr", 0),
      else: {:ok, []}
  end

  defp term_occurrences(etf, slots, needles, chunk, index) do
    with {:ok, term} <- decode(etf),
         {:ok, [_ | _] = leaves} <- leaves(term, [], needles) do
      {:ok,
       for {path, kind, value} <- leaves do
         %{
           "chunk" => chunk,
           "index" => index,
           "term" => path,
           "kind" => kind,
           "parts" => parts(value, slots)
         }
       end}
    else
      {:ok, []} -> {:refuse, "a path in #{chunk} #{index} the rewrite cannot reach"}
      {:refuse, _} = refuse -> refuse
    end
  end

  # Misc.BinToTerm, reviewed: only a literal or attribute term that holds a
  # slot value is decoded, at most 4 MiB and never compressed; it may make
  # atoms (the worker's own run VM) and nothing in it is ever called.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode(<<131, 80, _::binary>>), do: {:refuse, "a compressed term"}

  defp decode(etf) when byte_size(etf) <= @max_term_bytes do
    {:ok, :erlang.binary_to_term(etf)}
  rescue
    ArgumentError -> {:refuse, "an unreadable term"}
  end

  defp decode(_etf), do: {:refuse, "a term over 4 MiB"}

  # `{path, kind, value}` of every binary, charlist and atom under `term`
  # that holds a slot value, in walk order.
  defp leaves(term, path, needles) when is_binary(term) do
    if contains?(term, needles), do: {:ok, [{path, "binary", term}]}, else: {:ok, []}
  end

  defp leaves(term, path, needles) when is_atom(term) do
    name = Atom.to_string(term)
    if contains?(name, needles), do: {:ok, [{path, "atom", name}]}, else: {:ok, []}
  end

  defp leaves(term, path, needles) when is_list(term) do
    case charlist(term) do
      {:ok, string} ->
        if contains?(string, needles),
          do: {:ok, [{path, "charlist", string}]},
          else: {:ok, []}

      :error ->
        {items, tail} = split_list(term, [])

        # A proper list's tail, `[]`, holds nothing.
        if(tail == [], do: items, else: items ++ [tail])
        |> Enum.with_index()
        |> all_leaves(path, needles)
    end
  end

  defp leaves(term, path, needles) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.with_index() |> all_leaves(path, needles)

  defp leaves(term, path, needles) when is_map(term) do
    pairs = ordered(term)

    if Enum.any?(pairs, fn {key, _} -> deep_contains?(key, needles) end) do
      {:refuse, "a path in a map key"}
    else
      pairs |> Enum.map(&elem(&1, 1)) |> Enum.with_index() |> all_leaves(path, needles)
    end
  end

  defp leaves(_term, _path, _needles), do: {:ok, []}

  defp all_leaves(indexed, path, needles) do
    Enum.reduce_while(indexed, {:ok, []}, fn {item, i}, {:ok, acc} ->
      case leaves(item, path ++ [i], needles) do
        {:ok, found} -> {:cont, {:ok, acc ++ found}}
        refuse -> {:halt, refuse}
      end
    end)
  end

  defp deep_contains?(term, needles), do: match?({:ok, [_ | _]}, leaves(term, [], needles))

  # A proper, non-empty list of code points.
  defp charlist([_ | _] = list) do
    if proper?(list) and Enum.all?(list, &codepoint?/1),
      do: {:ok, List.to_string(list)},
      else: :error
  end

  defp charlist(_list), do: :error

  defp proper?([]), do: true
  defp proper?([_ | t]), do: proper?(t)
  defp proper?(_), do: false

  defp codepoint?(c), do: is_integer(c) and (c in 0..0xD7FF or c in 0xE000..0x10FFFF)

  # A list's items and its tail (`[]` for a proper list).
  defp split_list([h | t], acc), do: split_list(t, [h | acc])
  defp split_list(tail, acc), do: {Enum.reverse(acc), tail}

  # A map's pairs in term order, as `:maps.iterator(map, :ordered)` gives them.
  defp ordered(map), do: map |> :maps.iterator(:ordered) |> next([])

  defp next(iter, acc) do
    case :maps.next(iter) do
      {k, v, iter} -> next(iter, [{k, v} | acc])
      :none -> Enum.reverse(acc)
    end
  end

  # --- the literal table ---------------------------------------------------------

  # OTP 28 writes it uncompressed (a zero word, then the count); a
  # compressed one (OTP 27 and before) is not read.
  defp literals(<<0::32, count::32, rest::binary>>), do: entries(rest, count, [])
  defp literals(_data), do: {:refuse, "a compressed literal table"}

  defp entries(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp entries(<<len::32, etf::binary-size(len), rest::binary>>, n, acc) when n > 0,
    do: entries(rest, n - 1, [etf | acc])

  defp entries(_rest, _n, _acc), do: {:refuse, "unreadable literal table"}

  defp literal_chunk(entries) do
    body = for etf <- entries, into: <<>>, do: <<byte_size(etf)::32, etf::binary>>
    <<0::32, length(entries)::32, body::binary>>
  end

  # --- the atom table --------------------------------------------------------

  # `{format, atoms}`: OTP 28's long atoms (a negative count, each length a
  # compact-term `u`) or the older byte lengths.
  defp atoms(<<count::signed-32, rest::binary>>) when count < 0,
    do: read_atoms(rest, -count, :long, [])

  defp atoms(<<count::32, rest::binary>>), do: read_atoms(rest, count, :short, [])
  defp atoms(_data), do: {:refuse, "unreadable atom table"}

  defp read_atoms(<<>>, 0, format, acc), do: {:ok, {format, Enum.reverse(acc)}}

  defp read_atoms(rest, n, format, acc) when n > 0 do
    with {:ok, len, rest} <- atom_length(rest, format),
         true <- byte_size(rest) >= len do
      read_atoms(drop(rest, len), n - 1, format, [binary_part(rest, 0, len) | acc])
    else
      _ -> {:refuse, "unreadable atom table"}
    end
  end

  defp read_atoms(_rest, _n, _format, _acc), do: {:refuse, "unreadable atom table"}

  defp atom_length(<<len::8, rest::binary>>, :short), do: {:ok, len, rest}
  defp atom_length(<<len::4, 0::1, 0::3, rest::binary>>, :long), do: {:ok, len, rest}

  defp atom_length(<<hi::3, 0::1, 1::1, 0::3, lo::8, rest::binary>>, :long),
    do: {:ok, hi * 256 + lo, rest}

  defp atom_length(_rest, _format), do: :error

  # The short atom table (`no_long_atoms`) holds a name's length in a byte:
  # a longer name is refused, never truncated.
  defp atom_bytes(:short, names) do
    if Enum.all?(names, &(byte_size(&1) <= 255)),
      do: :ok,
      else: {:refuse, "an atom over 255 bytes in a short atom table"}
  end

  defp atom_bytes(:long, _names), do: :ok

  defp code_points(s), do: s |> String.to_charlist() |> length()

  defp atom_chunk({:long, names}) do
    body = for name <- names, into: <<>>, do: <<compact_u(byte_size(name))::binary, name::binary>>
    <<-length(names)::signed-32, body::binary>>
  end

  defp atom_chunk({:short, names}) do
    body = for name <- names, into: <<>>, do: <<byte_size(name)::8, name::binary>>
    <<length(names)::32, body::binary>>
  end

  # `beam_asm:encode(?tag_u, N)` for the lengths an atom can have.
  defp compact_u(n) when n < 16, do: <<n::4, 0::4>>
  defp compact_u(n) when n < 2048, do: <<div(n, 256)::3, 1::2, 0::3, rem(n, 256)::8>>

  defp atom_occurrences(data, chunks, slots, needles) do
    if contains?(data, needles) do
      with {:ok, {_format, names}} <- atoms(data) do
        named = names_in_code(chunks)

        names
        |> Enum.with_index(1)
        |> Enum.filter(fn {name, _} -> contains?(name, needles) end)
        |> Enum.reduce_while({:ok, []}, fn {name, i}, {:ok, acc} ->
          if i == 1 or MapSet.member?(named, i),
            do: {:halt, {:refuse, "a path in a module or function name"}},
            else: {:cont, {:ok, acc ++ [atom_occurrence(i, name, slots)]}}
        end)
      end
    else
      {:ok, []}
    end
  end

  defp atom_occurrence(i, name, slots),
    do: %{
      "chunk" => "AtU8",
      "index" => i,
      "term" => [],
      "kind" => "atom",
      "parts" => parts(name, slots)
    }

  # The atom indices the import, export, local and fun tables name a module
  # or a function by.
  defp names_in_code(chunks) do
    imports = for <<m::32, f::32, _a::32 <- table(chunks, "ImpT", 12)>>, i <- [m, f], do: i
    exports = for id <- ["ExpT", "LocT"], <<f::32, _::64 <- table(chunks, id, 12)>>, do: f
    funs = for <<f::32, _::binary-size(20) <- table(chunks, "FunT", 24)>>, do: f
    MapSet.new(imports ++ exports ++ funs)
  end

  defp table(chunks, id, size) do
    case chunk(chunks, id) do
      <<count::32, rest::binary>> when byte_size(rest) == count * size -> rest
      _ -> <<>>
    end
  end

  # --- the line table ----------------------------------------------------------

  # `{head, items, names}`: the five header words, the line items' bytes as
  # they are, and the file names, each a 16-bit length and UTF-8.
  defp line_table(<<0::32, _bits::32, _instrs::32, lines::32, count::32, rest::binary>> = data) do
    with {:ok, names_at} <- skip_items(rest, lines, 0),
         {:ok, names} <- line_names(drop(rest, names_at), count, []) do
      {:ok, {binary_part(data, 0, 20), binary_part(rest, 0, names_at), names}}
    else
      _ -> {:refuse, "unreadable line table"}
    end
  end

  defp line_table(_data), do: {:refuse, "unreadable line table"}

  # The bytes the `lines` line items take: each a compact `i` (a line), with
  # a compact `a` (a file name's index) before it when the file changes.
  defp skip_items(_rest, 0, at), do: {:ok, at}

  defp skip_items(rest, lines, at) do
    case compact(rest) do
      {:ok, tag, used} when tag in [1, 2] ->
        skip_items(drop(rest, used), if(tag == 1, do: lines - 1, else: lines), at + used)

      _ ->
        :error
    end
  end

  # A compact term's tag and size in bytes (`beam_asm:encode/2`).
  defp compact(<<b, _::binary>>) when Bitwise.band(b, 8) == 0, do: {:ok, Bitwise.band(b, 7), 1}

  defp compact(<<b, _, _::binary>>) when Bitwise.band(b, 16) == 0,
    do: {:ok, Bitwise.band(b, 7), 2}

  defp compact(<<b, rest::binary>>) do
    case Bitwise.bsr(b, 5) do
      7 ->
        with {:ok, 0, used} <- compact(rest),
             {:ok, len} <- compact_value(binary_part(rest, 0, used)),
             true <- byte_size(rest) >= used + len + 9 do
          {:ok, Bitwise.band(b, 7), 1 + used + len + 9}
        else
          _ -> :error
        end

      n when byte_size(rest) >= n + 2 ->
        {:ok, Bitwise.band(b, 7), n + 3}

      _ ->
        :error
    end
  end

  defp compact(_rest), do: :error

  defp compact_value(<<n::4, 0::1, _::3>>), do: {:ok, n}
  defp compact_value(<<hi::3, 0::1, 1::1, _::3, lo::8>>), do: {:ok, hi * 256 + lo}
  defp compact_value(_term), do: :error

  defp line_names(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp line_names(<<len::16, name::binary-size(len), rest::binary>>, n, acc) when n > 0,
    do: line_names(rest, n - 1, [name | acc])

  defp line_names(_rest, _n, _acc), do: :error

  defp line_chunk({head, items, names}) do
    body = for name <- names, into: <<>>, do: <<byte_size(name)::16, name::binary>>
    <<head::binary, items::binary, body::binary>>
  end

  defp line_occurrences(data, slots, needles) do
    if contains?(data, needles) do
      with {:ok, {_head, _items, names}} <- line_table(data) do
        {:ok,
         for {name, j} <- Enum.with_index(names), contains?(name, needles) do
           %{
             "chunk" => "Line",
             "index" => j,
             "term" => [],
             "kind" => "binary",
             "parts" => parts(name, slots)
           }
         end}
      end
    else
      {:ok, []}
    end
  end

  # --- the rewrite ---------------------------------------------------------------

  defp relocate_chunks(chunks, occs, from, to) do
    by_chunk = Enum.group_by(occs, & &1["chunk"])

    with {:ok, old} <- md5(chunks),
         :ok <- uniq_is_md5(chunks, old),
         :ok <- known_chunks(by_chunk),
         {:ok, chunks} <- rewrite(chunks, "LitT", by_chunk, &rewrite_literals(&1, &2, from, to)),
         {:ok, chunks} <- rewrite(chunks, "AtU8", by_chunk, &rewrite_atoms(&1, &2, from, to)),
         {:ok, chunks} <- rewrite(chunks, "Line", by_chunk, &rewrite_lines(&1, &2, from, to)),
         {:ok, new} <- md5(chunks) do
      chunks
      |> put_uniq(new)
      |> rewrite_attr(Map.get(by_chunk, "Attr", []), from, to, old, new)
    end
  end

  defp known_chunks(by_chunk) do
    case Map.keys(by_chunk) -- @rewritten do
      [] -> :ok
      [id | _] -> {:refuse, "an occurrence in #{id}"}
    end
  end

  defp rewrite(chunks, id, by_chunk, fun) do
    case {Map.get(by_chunk, id, []), List.keyfind(chunks, id, 0)} do
      {[], _} ->
        {:ok, chunks}

      {_occs, nil} ->
        {:refuse, "no #{id} chunk"}

      {occs, {^id, data}} ->
        with {:ok, data} <- fun.(data, occs), do: {:ok, List.keystore(chunks, id, 0, {id, data})}
    end
  end

  defp rewrite_literals(data, occs, from, to) do
    with {:ok, entries} <- literals(data),
         {:ok, entries} <- rewrite_entries(entries, Enum.group_by(occs, & &1["index"]), from, to) do
      if length(Enum.uniq(entries)) == length(entries),
        do: {:ok, literal_chunk(entries)},
        else: {:refuse, "two literals would be one at these paths"}
    end
  end

  defp rewrite_entries(entries, by_index, from, to) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {etf, i}, {:ok, acc} ->
      case Map.get(by_index, i) do
        nil ->
          {:cont, {:ok, [etf | acc]}}

        occs ->
          case rewrite_term(etf, occs, from, to) do
            {:ok, term} -> {:cont, {:ok, [:erlang.term_to_binary(term, @literal_opts) | acc]}}
            refuse -> {:halt, refuse}
          end
      end
    end)
    |> then(fn
      {:ok, acc} when length(acc) == length(entries) -> {:ok, Enum.reverse(acc)}
      {:ok, _} -> {:refuse, "an occurrence past the literal table"}
      refuse -> refuse
    end)
    |> check_indices(by_index, length(entries))
  end

  defp check_indices({:ok, _} = ok, by_index, count) do
    if Enum.all?(Map.keys(by_index), &(is_integer(&1) and &1 >= 0 and &1 < count)),
      do: ok,
      else: {:refuse, "an occurrence past the literal table"}
  end

  defp check_indices(refuse, _by_index, _count), do: refuse

  defp rewrite_term(etf, occs, from, to) do
    with {:ok, term} <- decode(etf) do
      Enum.reduce_while(occs, {:ok, term}, fn occ, {:ok, term} ->
        case update_in_term(term, occ["term"], &replace(&1, occ, from, to)) do
          {:ok, term} -> {:cont, {:ok, term}}
          refuse -> {:halt, refuse}
        end
      end)
    end
  end

  # The value at `path` replaced by `fun`'s result.
  defp update_in_term(term, [], fun), do: fun.(term)

  defp update_in_term(term, [i | path], fun)
       when is_tuple(term) and is_integer(i) and i >= 0 and i < tuple_size(term) do
    with {:ok, value} <- update_in_term(elem(term, i), path, fun),
         do: {:ok, put_elem(term, i, value)}
  end

  defp update_in_term(term, [i | path], fun) when is_list(term) and is_integer(i) and i >= 0 do
    {items, tail} = split_list(term, [])

    cond do
      i < length(items) ->
        with {:ok, value} <- update_in_term(Enum.at(items, i), path, fun),
             do: {:ok, rejoin(List.replace_at(items, i, value), tail)}

      i == length(items) ->
        with {:ok, value} <- update_in_term(tail, path, fun), do: {:ok, rejoin(items, value)}

      true ->
        {:refuse, "a recorded path the literal does not have"}
    end
  end

  defp update_in_term(term, [i | path], fun) when is_map(term) and is_integer(i) and i >= 0 do
    case Enum.at(ordered(term), i) do
      {key, value} ->
        with {:ok, value} <- update_in_term(value, path, fun),
             do: {:ok, Map.put(term, key, value)}

      nil ->
        {:refuse, "a recorded path the literal does not have"}
    end
  end

  defp update_in_term(_term, _path, _fun),
    do: {:refuse, "a recorded path the literal does not have"}

  defp rejoin(items, tail), do: Enum.reduce(Enum.reverse(items), tail, &[&1 | &2])

  # The recorded value, as the beam holds it, becomes its value at `to`.
  defp replace(value, %{"kind" => kind, "parts" => parts}, from, to) when is_list(parts) do
    if as_kind(kind, render(parts, from)) == {:ok, value},
      do: as_kind(kind, render(parts, to)),
      else: {:refuse, "the beam does not hold the recorded path"}
  rescue
    _ -> {:refuse, "an unreadable occurrence"}
  end

  defp replace(_value, _occ, _from, _to), do: {:refuse, "an unreadable occurrence"}

  defp as_kind("binary", s), do: {:ok, s}
  defp as_kind("charlist", s), do: {:ok, String.to_charlist(s)}

  defp as_kind("atom", s) do
    if code_points(s) <= 255,
      do: {:ok, String.to_atom(s)},
      else: {:refuse, "an atom over 255 characters"}
  end

  defp as_kind(_kind, _s), do: {:refuse, "an unknown kind"}

  defp rewrite_atoms(data, occs, from, to) do
    with {:ok, {format, names}} <- atoms(data),
         {:ok, names} <- rewrite_names(names, occs, 1, from, to, 255),
         :ok <- atom_bytes(format, names) do
      if length(Enum.uniq(names)) == length(names),
        do: {:ok, atom_chunk({format, names})},
        else: {:refuse, "two atoms would be one at these paths"}
    end
  end

  defp rewrite_lines(data, occs, from, to) do
    with {:ok, {head, items, names}} <- line_table(data),
         {:ok, names} <- rewrite_names(names, occs, 0, from, to, nil) do
      cond do
        length(Enum.uniq(names)) != length(names) -> {:refuse, "two file names would be one"}
        Enum.any?(names, &(byte_size(&1) > 0xFFFF)) -> {:refuse, "a file name too long"}
        true -> {:ok, line_chunk({head, items, names})}
      end
    end
  end

  # The names (atoms from 1, file names from 0) with each occurrence's index
  # rewritten; an atom must stay at most `max` code points, as OTP counts
  # them, and atom 1, the module's name, is never rewritten.
  defp rewrite_names(names, occs, base, from, to, max) do
    indexed = names |> Enum.with_index(base) |> Map.new(fn {n, i} -> {i, n} end)

    Enum.reduce_while(occs, {:ok, indexed}, fn occ, {:ok, acc} ->
      i = occ["index"]

      with true <- is_map_key(acc, i) and occ["term"] == [],
           true <- Map.fetch!(acc, i) == render(occ["parts"], from),
           new = render(occ["parts"], to),
           true <- base != 1 or i != 1,
           true <- max == nil or code_points(new) <= max do
        {:cont, {:ok, Map.put(acc, i, new)}}
      else
        _ -> {:halt, {:refuse, "the beam does not hold the recorded path"}}
      end
    end)
    |> then(fn
      {:ok, map} -> {:ok, map |> Enum.sort() |> Enum.map(&elem(&1, 1))}
      refuse -> refuse
    end)
  rescue
    _ -> {:refuse, "an unreadable occurrence"}
  end

  # The module's md5 as the running OTP takes it, `beam_lib:md5/1`: the
  # chunks its `md5_chunks/0` lists (OTP 29 adds `Recs` and `DbgB` to
  # OTP 28's), in that order, with every fun's `old_uniq` zeroed. The
  # served beam was built on this OTP major (Match's `otp_reason`).
  defp md5(chunks) do
    case :beam_lib.md5(form(chunks)) do
      {:ok, {_module, md5}} when byte_size(md5) == 16 -> {:ok, md5}
      _ -> {:refuse, "no md5"}
    end
  end

  # The compiler sets every fun's `old_uniq` to the first 27 bits of the
  # module's md5: a served beam whose funs say otherwise was not hashed as
  # this VM hashes it, and its rewrite would not be this VM's compile.
  defp uniq_is_md5(chunks, <<uniq::27, _::101>>) do
    case List.keyfind(chunks, "FunT", 0) do
      {"FunT", <<_count::32, table::binary>>} ->
        if Enum.all?(for(<<_::binary-size(20), u::32 <- table>>, do: u), &(&1 == uniq)),
          do: :ok,
          else: {:refuse, "the served md5 is not this VM's"}

      nil ->
        :ok
    end
  end

  defp put_uniq(chunks, <<uniq::27, _::101>>) do
    case List.keyfind(chunks, "FunT", 0) do
      {"FunT", <<count::32, table::binary>>} ->
        funs =
          for <<keep::binary-size(20), _::32 <- table>>,
            into: <<>>,
            do: <<keep::binary, uniq::32>>

        List.keystore(chunks, "FunT", 0, {"FunT", <<count::32, funs::binary>>})

      nil ->
        chunks
    end
  end

  # `Attr` with its occurrences rewritten and a default `vsn` (the old md5)
  # set to the new md5. A `vsn` that is neither the old md5 nor set by the
  # module itself means the md5 is not taken as the compiler takes it.
  defp rewrite_attr(chunks, occs, from, to, old, new) do
    case List.keyfind(chunks, "Attr", 0) do
      nil when occs == [] ->
        {:ok, chunks}

      nil ->
        {:refuse, "no Attr chunk"}

      {"Attr", data} when occs == [] and old == new ->
        {:ok, List.keystore(chunks, "Attr", 0, {"Attr", data})}

      {"Attr", data} ->
        <<old_vsn::128>> = old
        <<new_vsn::128>> = new

        with {:ok, attrs} <- decode(data),
             {:ok, attrs} <- rewrite_attrs(attrs, occs, from, to),
             {:ok, attrs} <- put_vsn(attrs, old_vsn, new_vsn) do
          {:ok, List.keystore(chunks, "Attr", 0, {"Attr", :erlang.term_to_binary(attrs)})}
        end
    end
  end

  defp rewrite_attrs(attrs, occs, from, to) do
    Enum.reduce_while(occs, {:ok, attrs}, fn occ, {:ok, attrs} ->
      if occ["index"] == 0 do
        case update_in_term(attrs, occ["term"], &replace(&1, occ, from, to)) do
          {:ok, attrs} -> {:cont, {:ok, attrs}}
          refuse -> {:halt, refuse}
        end
      else
        {:halt, {:refuse, "an occurrence past the attributes"}}
      end
    end)
  end

  defp put_vsn(attrs, old, new) when is_list(attrs) do
    case List.keyfind(attrs, :vsn, 0) do
      {:vsn, [^old]} ->
        {:ok, List.keyreplace(attrs, :vsn, 0, {:vsn, [new]})}

      {:vsn, _own} when old == new ->
        {:ok, attrs}

      {:vsn, [n]} when is_integer(n) and n >= 0 and n < @md5_limit ->
        {:refuse, "the vsn is not the md5"}

      _ ->
        {:ok, attrs}
    end
  end

  defp put_vsn(_attrs, _old, _new), do: {:refuse, "unreadable attributes"}

  # No slot value of `from` may be left in any chunk but the metadata.
  defp nothing_left(chunks, from, _to) do
    needles = needles(from)

    case Enum.find(chunks, fn {id, data} -> id not in @metadata and contains?(data, needles) end) do
      nil -> :ok
      {id, _} -> {:refuse, "a builder path is left in #{id}"}
    end
  end
end
