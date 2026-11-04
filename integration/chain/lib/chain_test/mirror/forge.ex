# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Forge do
  @moduledoc """
  Layer 2, a compromised portal (P1-P6, P8, P9): a forged manifest signed
  into a test batch. Only with a test root (`ChainTest.TestKey`): the batch
  is re-signed by the test batch key and names the forged manifest's sha,
  so every signature and hash the client checks holds, and only its checks
  behind them can refuse.

  `prepare/1` (called by `ChainTest.TestKey.prepare/1`) writes each kind's
  forged manifest to `forged/<kind>.json` in the layer-2 snapshot, the
  extra files it names under `files/`, and, for the kinds that name new
  deps, the manifest under their own manifest path. A forgery changes every
  build of jason's locked version, whichever the client selects:

    * `:dotdot`, `:absolute`, `:outside_dirs` (P1) - one more file at
      `ebin/../../chain_forged.beam`, `/tmp/chain_forged.beam` or
      `lib/chain_forged.beam`;
    * `:setuid`, `:mode_777` (P2) - `ebin/jason.app`'s mode `0o104755` or
      `0o100777`;
    * `:escape_app_dir` (P3) - one more file at
      `ebin/../../chain_fixture/ebin/chain_fixture.app`, the project's own
      app dir; `:project_app` (P3) - one more file `ebin/chain_fixture.app`,
      the project's `.app` name in jason's ebin, ahead of the project's
      own on the code path;
    * `:package_checksum`, `:deps_lock` (P4) - the build's package checksum,
      or one locked dep's checksum in its deps lock, zeroed;
    * `:path_dep` (P5-path) - the batch also names a manifest for the
      fixture's own path dep `chain_path_dep` (not Nerves tooling, which the
      client skips first), with one build at that dep's own identity: the
      version from its `mix.exs`, the sha256 of that `mix.exs` as its
      package checksum (a path dep has none), a `pure_elixir` build for
      this Elixir and OTP, an `.app` naming the dep at that version. Mix
      never locks a path dep, so the client's lock check (the one P9
      exercises) keeps it out before its git/path rule is reached; the
      outcome, never precompiled, holds for every path dep. P5 for a git
      dep, which the lock does name, is the client suite's (its end-to-end
      git-dep test; `ChainTest.Report.known_gaps/0`);
    * `:app_name`, `:app_version` (P6) - `ebin/jason.app` replaced by a served
      `.app` naming `chain_forged`, or version `9.9.9`;
    * `:duplicate`, `:case_variant`, `:unicode_variant` (P8) - one more
      `ebin/Elixir.Jason.beam` with other bytes; `ebin/elixir.jason.beam`;
      `priv/café` written precomposed and decomposed, with other bytes;
    * `:unlocked_package` (P9) - the batch also names jason's manifest for
      `chain_absent`, which the fixture does not lock.

  The manifests of new names (`<dir>/nerves.json`, ...) sit in the layer-2
  snapshot for every case that uses it, but only a batch that names them,
  this transform's for those kinds, leads a client there. The snapshot's
  manifests and files are hard links into the real snapshot, so nothing
  here writes over a file that exists (`write_new!/2`).
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.{Lock, Preflight, TestKey, Trust}

  @target "jason"
  @project_app "chain_fixture"
  @zero String.duplicate("0", 64)
  @kinds [
    :dotdot,
    :absolute,
    :outside_dirs,
    :setuid,
    :mode_777,
    :escape_app_dir,
    :project_app,
    :package_checksum,
    :deps_lock,
    :path_dep,
    :app_name,
    :app_version,
    :duplicate,
    :case_variant,
    :unicode_variant,
    :unlocked_package
  ]
  @new_names %{path_dep: ["chain_path_dep"], unlocked_package: ["chain_absent"]}
  @doc "Every forgery this transform serves."
  @spec kinds() :: [atom()]
  def kinds(), do: @kinds

  @doc "Only for a case pinned to a test root."
  @spec test_root_only?() :: true
  def test_root_only?(), do: true

  @impl true
  def valid_args?(%{forge: kind} = args) when map_size(args) == 1, do: kind in @kinds
  def valid_args?(_args), do: false

  @impl true
  def transform("batch.json", bytes, %{forge: kind, case: %{snapshot: snap}}) do
    test = TestKey.test!(snap)
    {key, _dir} = batch_key(snap)

    named =
      Map.new(forged(snap, kind), fn {name, rel} ->
        {name, sha256(File.read!(Path.join(snap.dir, rel)))}
      end)

    payload =
      bytes
      |> TestKey.payload!()
      |> JSON.decode!()
      |> Map.update(key, named, &Map.merge(&1, named))
      |> JSON.encode!()

    {200, TestKey.envelope(test, payload, [:batch])}
  end

  def transform(path, bytes, %{forge: kind, case: %{snapshot: snap}}) do
    TestKey.test!(snap)
    {_key, dir} = batch_key(snap)

    if kind not in Map.keys(@new_names) and path == "#{dir}/#{@target}.json",
      do: {200, File.read!(forged_path(snap, kind))},
      else: {200, bytes}
  end

  @doc """
  The manifests `kind` makes the batch name, `%{dep => path under the
  snapshot}`: jason's forged manifest, or for P5-path and P9 the new names'.
  """
  @spec forged(map(), atom()) :: %{String.t() => String.t()}
  def forged(snap, kind) when kind in @kinds do
    case Map.fetch(@new_names, kind) do
      {:ok, names} ->
        {_key, mdir} = batch_key(snap)
        Map.new(names, &{&1, "#{mdir}/#{&1}.json"})

      :error ->
        %{@target => "forged/#{kind}.json"}
    end
  end

  defp forged_path(snap, kind), do: Path.join(snap.dir, "forged/#{kind}.json")

  # The batch map naming jason's manifest, and that manifest's directory.
  defp batch_key(snap) do
    case Trust.manifest_sha(snap.info, @target) do
      {_sha, "v2/manifests"} -> {"manifests_v2", "v2/manifests"}
      {_sha, dir} -> {"manifests", dir}
      nil -> raise ArgumentError, "the snapshot's batch names no #{@target} manifest to forge"
    end
  end

  @doc """
  Writes every forgery into the layer-2 snapshot `snap` (see the
  moduledoc); `fixture_dir` is the fixture project, whose lock and deps
  give P5-path's identity. Raises when one cannot be found.
  """
  @spec prepare(map(), Path.t()) :: :ok
  def prepare(%{dir: dir} = snap, fixture_dir) do
    ctx = context(snap)
    {_key, mdir} = batch_key(snap)
    File.mkdir_p!(Path.join(dir, "forged"))
    File.mkdir_p!(Path.join(dir, mdir))

    for kind <- @kinds -- [:path_dep] do
      {doc, extra} = forge(kind, ctx)
      for bytes <- extra, do: write_new!(Path.join([dir, "files", sha256(bytes)]), bytes)
      bytes = JSON.encode!(doc)
      write_new!(forged_path(snap, kind), bytes)

      for name <- Map.get(@new_names, kind, []),
          do: write_new!(Path.join([dir, mdir, "#{name}.json"]), bytes)
    end

    for {name, rel} <- forged(snap, :path_dep) do
      {doc, app} = identity_manifest(name, fixture_dir)
      write_new!(Path.join([dir, "files", sha256(app)]), app)
      write_new!(Path.join(dir, rel), JSON.encode!(doc))
    end

    :ok
  end

  # A file that exists is left alone when it holds these bytes and refused
  # otherwise: it may be a hard link into the real snapshot.
  defp write_new!(path, bytes) do
    case File.lstat(path) do
      {:error, :enoent} ->
        File.write!(path, bytes)

      {:ok, %File.Stat{type: :regular}} ->
        if File.read!(path) == bytes,
          do: :ok,
          else: raise(ArgumentError, "will not write over #{path}")

      other ->
        raise ArgumentError, "will not write #{path}: #{inspect(other)}"
    end
  end

  # P5-path: a format-2 manifest with one build at the dep's own identity, and
  # its `.app` bytes.
  defp identity_manifest(name, fixture_dir) do
    {:ok, lock} = Lock.read(Path.join(fixture_dir, "mix.lock"))

    {dir, checksum} =
      case Lock.git_ref(lock, name) do
        nil -> path_dep(name, fixture_dir)
        ref -> {Path.join([fixture_dir, "deps", name]), ref}
      end

    mix_exs = File.read!(Path.join(dir, "mix.exs"))

    vsn =
      case Regex.run(~r/@version\s+"([^"]+)"/, mix_exs) do
        [_, v] -> v
        _ -> raise ArgumentError, "no @version in #{dir}/mix.exs"
      end

    app =
      ~s({application,#{name},[{description,"#{name}"},{vsn,"#{vsn}"},{modules,[]}]}.\n)

    build = %{
      "target" => "pure_elixir",
      "ebin" => [
        %{
          "path" => "ebin/#{name}.app",
          "sha256" => sha256(app),
          "size" => byte_size(app),
          "mode" => 0o100644
        }
      ],
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "dep_env" => "prod",
        "package_checksum" => checksum || sha256(mix_exs),
        "deps" => %{},
        "compile_env" => [],
        "run_id" => "chain-forged"
      }
    }

    {%{"format" => 2, "versions" => %{vsn => %{"builds" => [build]}}}, app}
  end

  defp path_dep(name, fixture_dir) do
    case Map.fetch(Preflight.path_deps(fixture_dir), name) do
      {:ok, rel} -> {Path.expand(rel, fixture_dir), nil}
      :error -> raise ArgumentError, "the fixture declares no git or path dep #{name}"
    end
  end

  defp context(snap) do
    dep = Map.get(snap.deps, @target) || raise ArgumentError, "the snapshot holds no #{@target}"
    doc = snap.dir |> Path.join(dep.manifest) |> File.read!() |> JSON.decode!()
    # The .app and a beam of one build whose files the snapshot holds (a
    # build the client could select): the bytes an extra entry names must
    # be servable, or the client refuses on a 404 instead of the forgery.
    {app, beam} =
      Enum.find_value(builds(doc, dep.version), fn b ->
        ebin = List.wrap(b["ebin"])
        app = Enum.find(ebin, &(&1["path"] == "ebin/#{@target}.app"))
        beam = Enum.find(ebin, &String.ends_with?(to_string(&1["path"]), ".beam"))

        if app && beam && Enum.all?([app, beam], &held?(snap, &1)), do: {app, beam}
      end) || raise ArgumentError, "the snapshot holds no #{@target} build with a .app and a beam"

    other =
      snap.deps |> Map.delete(@target) |> Enum.sort() |> List.first() ||
        raise ArgumentError, "the snapshot holds no other dep to name in a deps lock"

    %{
      doc: doc,
      version: dep.version,
      app: app,
      beam: beam,
      app_bytes: File.read!(Path.join([snap.dir, "files", app["sha256"]])),
      other: other
    }
  end

  defp held?(snap, %{"sha256" => sha}) when is_binary(sha),
    do: File.regular?(Path.join([snap.dir, "files", sha]))

  defp held?(_snap, _entry), do: false

  defp forge(kind, ctx) when kind in [:path_dep, :unlocked_package], do: {ctx.doc, []}

  defp forge(:app_name, ctx),
    do:
      app_forge(ctx, fn {:application, _, props} ->
        {:application, :chain_forged, props}
      end)

  defp forge(:app_version, ctx),
    do:
      app_forge(ctx, fn {:application, name, props} ->
        {:application, name, List.keystore(props, :vsn, 0, {:vsn, ~c"9.9.9"})}
      end)

  defp forge(kind, ctx), do: {update_builds(ctx, &change(kind, &1, ctx)), []}

  defp app_forge(ctx, fun) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(ctx.app_bytes))
    {:ok, term} = :erl_parse.parse_term(tokens)
    bytes = IO.chardata_to_string(:io_lib.format(~c"~tp.~n", [fun.(term)]))
    entry = %{ctx.app | "sha256" => sha256(bytes), "size" => byte_size(bytes)}
    {update_builds(ctx, &replace_app(&1, entry)), [bytes]}
  end

  defp change(:dotdot, b, ctx),
    do: add(b, "ebin", %{ctx.app | "path" => "ebin/../../chain_forged.beam"})

  defp change(:absolute, b, ctx),
    do: add(b, "ebin", %{ctx.app | "path" => "/tmp/chain_forged.beam"})

  defp change(:outside_dirs, b, ctx),
    do: add(b, "ebin", %{ctx.app | "path" => "lib/chain_forged.beam"})

  defp change(:setuid, b, _ctx), do: app_mode(b, 0o104755)
  defp change(:mode_777, b, _ctx), do: app_mode(b, 0o100777)

  defp change(:escape_app_dir, b, ctx),
    do:
      add(b, "ebin", %{ctx.app | "path" => "ebin/../../#{@project_app}/ebin/#{@project_app}.app"})

  defp change(:project_app, b, ctx),
    do: add(b, "ebin", %{ctx.app | "path" => "ebin/#{@project_app}.app"})

  defp change(:package_checksum, b, _ctx),
    do: Map.update(b, "build", %{}, &Map.put(&1, "package_checksum", @zero))

  defp change(:deps_lock, b, ctx) do
    {name, %{version: vsn}} = ctx.other
    locked = %{"version" => vsn, "checksum" => @zero}

    Map.update(b, "build", %{}, fn build ->
      Map.update(build, "deps", %{name => locked}, &Map.put(&1 || %{}, name, locked))
    end)
  end

  defp change(:duplicate, b, ctx),
    do: add(b, "ebin", other_bytes(ctx.beam, ctx.app))

  defp change(:case_variant, b, ctx),
    do:
      add(b, "ebin", %{
        other_bytes(ctx.beam, ctx.app)
        | "path" => String.downcase(ctx.beam["path"])
      })

  defp change(:unicode_variant, b, ctx) do
    b
    |> add("priv", %{ctx.app | "path" => "priv/café", "mode" => 0o100644})
    |> add("priv", %{ctx.beam | "path" => "priv/café", "mode" => 0o100644})
  end

  # `entry`'s path with `other`'s bytes.
  defp other_bytes(entry, other),
    do: %{entry | "sha256" => other["sha256"], "size" => other["size"]}

  defp add(build, list, entry), do: Map.update(build, list, [entry], &(List.wrap(&1) ++ [entry]))

  # Each build's own .app entry, its mode changed.
  defp app_mode(build, mode) do
    Map.update(build, "ebin", [], fn ebin ->
      Enum.map(
        ebin,
        &if(&1["path"] == "ebin/#{@target}.app", do: %{&1 | "mode" => mode}, else: &1)
      )
    end)
  end

  defp replace_app(build, entry) do
    Map.update(build, "ebin", [], fn ebin ->
      Enum.map(ebin, &if(&1["path"] == entry["path"], do: entry, else: &1))
    end)
  end

  # The builds (format 2) or entries (format 1) of `version`.
  defp builds(%{"format" => 2, "versions" => versions}, version),
    do: get_in(versions, [version, "builds"]) || []

  defp builds(%{"versions" => versions}, version),
    do: versions |> Map.get(version, %{}) |> Map.values()

  defp update_builds(%{doc: %{"format" => 2} = doc, version: v}, fun),
    do: update_in(doc, ["versions", v, "builds"], &Enum.map(&1, fun))

  defp update_builds(%{doc: doc, version: v}, fun),
    do: update_in(doc, ["versions", v], &Map.new(&1, fn {t, e} -> {t, fun.(e)} end))

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
