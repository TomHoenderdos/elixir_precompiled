# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.ForeignPrivTest do
  # 0.8.0 against a local signed source: kino 0.19.1 and kino_vega_lite
  # 0.1.13 built from source here, published as the portal publishes them
  # (kino under `foreign_priv` with `foreign_priv_target`, the writer under
  # `foreign_priv` with its archives), then installed precompiled in fresh
  # projects and in Mix.install, and taken through kino's lifecycle (spec 7,
  # item 5).
  #
  # Install versus source (spec 7, items 1 to 4), against a second
  # from-source build made later, never the one published: the ebin of each
  # installed app equal (beams stripped, .app terms), kino's build dir
  # holding the same files, its priv/assets the same dirs each holding one
  # archive of the same name whose members are equal in name, order, type,
  # size, mode, owner and bytes (only member mtimes may differ), and the
  # archive each beam names on disk at run time.
  #
  # The second build is made in the first one's dir: kino's macros quote
  # with `location: :keep`, so its beams (and those of modules that use
  # them) carry the absolute path of the deps dir they were compiled from,
  # and two builds in two dirs never have equal beams. An app Mix compiled
  # in a test's own project is from source by definition; only its files,
  # archives and run time are compared.
  use ExUnit.Case, async: false

  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  # Every Hex package the children fetch.
  @packages ~w(kino-0.19.1 kino_vega_lite-0.1.13 table-0.1.2 vega_lite-0.1.11)
  @modules ~w(Kino.VegaLite KinoVegaLite.ChartCell)
  @run_time ~s"""
  for m <- [Kino.VegaLite, KinoVegaLite.ChartCell] do
    IO.puts(inspect(m) <> "=" <> to_string(File.regular?(m.__assets_info__().archive_path)))
  end
  """
  @except "\nconfig :precompiled, except: [:kino]\n"
  @both ["kino", "kino_vega_lite"]

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  defp deps(), do: ~s([{:kino, "== 0.19.1"}, {:kino_vega_lite, "== 0.1.13"}, #{C.own_dep()}])

  defp mix!(proj, args, env \\ []), do: C.mix!(proj, args, env, packages: @packages)

  test "a writer installed precompiled is what Mix builds from source", %{tmp_dir: dir} do
    f = F.new(dir)
    %{ref: ref, lock_path: lock_path, kino: kino, writer: writer} = sources!(dir, f)
    publish!(f, kino, writer, 2)

    # ON: a fresh project on the same lock.
    on_proj = project!(dir, "on", f, lock_path)
    out = mix!(on_proj, ["compile"])
    assert out =~ ~r/precompiled: kino 0\.19\.1\s+HIT/, out
    assert out =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT.*; 2 archives into kino/, out
    refute out =~ ~r/==> kino\n/, out
    refute out =~ ~r/==> kino_vega_lite\n/, out
    on = Path.join(on_proj, "_build/dev/lib")

    # The installed archives are the published ones, not the reference
    # build's bytes (its tar members carry another clock): what compare!/3
    # checks below is their content.
    for e <- writer["foreign_priv"] do
      bytes = File.read!(Path.join([on, "kino", e["path"]]))
      assert sha256(bytes) == e["sha256"], e["path"]
      refute bytes == File.read!(Path.join([ref, "kino", e["path"]])), e["path"]
    end

    compare!(on, ref, @both)
    assert_archives!(run!(on_proj))

    # A second run writes nothing.
    stats = mtimes(on)
    Process.sleep(1100)
    again = mix!(on_proj, ["compile"])
    refute again =~ "HIT", again
    refute again =~ "MISS", again
    assert mtimes(on) == stats

    # kino replaced (a changed manifest whose files differ): the writer is
    # kept, its archives with it.
    publish!(f, put_mode(kino, "ebin/kino.app", 0o100755), writer, 3)
    replaced = mix!(on_proj, ["compile"])
    assert replaced =~ ~r/precompiled: kino 0\.19\.1\s+HIT/, replaced
    refute replaced =~ "kino_vega_lite", replaced
    assert Bitwise.band(File.stat!(Path.join(on, "kino/ebin/kino.app")).mode, 0o111) != 0
    compare!(on, ref, @both)
    assert_archives!(run!(on_proj))

    # Mix.install: the same engine, its own install project, on the same lock.
    install_lib = mix_install!(dir, f, lock_path)
    compare!(install_lib, ref, @both)

    # kino excepted compiles from source, and so, after it, does the
    # writer, whose own compile writes its archives again.
    File.write!(Path.join(on_proj, "config/config.exs"), @except, [:append])
    excepted = mix!(on_proj, ["compile"])
    assert excepted =~ ~r/precompiled: kino 0\.19\.1\s+MISS\s+excepted/, excepted

    assert excepted =~
             ~r/precompiled: kino_vega_lite 0\.1\.13\s+MISS\s+writes into kino's priv; kino compiles from source in this run/,
           excepted

    assert excepted =~ ~r/==> kino_vega_lite\n/, excepted
    compare!(on, ref, [])
    assert_archives!(run!(on_proj))

    # kino Mix-built and current: a writer Mix would compile again is
    # installed, its archives placed into that kino.
    config = Path.join(on_proj, "config/config.exs")
    File.write!(config, String.replace(File.read!(config), @except, ""))
    File.rm_rf!(Path.join(on, "kino_vega_lite"))
    mix_built = mix!(on_proj, ["compile"])
    refute mix_built =~ ~r/precompiled: kino 0\.19\.1/, mix_built

    assert mix_built =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT.*; 2 archives into kino/,
           mix_built

    refute mix_built =~ ~r/==> kino_vega_lite\n/, mix_built
    compare!(on, ref, ["kino_vega_lite"])
    assert_archives!(run!(on_proj))

    # Disabled: every install goes, Mix compiles kino and then the writer,
    # whose compile writes its archives.
    off_proj = project!(dir, "disable", f, lock_path)
    out = mix!(off_proj, ["compile"])
    assert out =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT/, out
    disabled = mix!(off_proj, ["compile"], [{"PRECOMPILED", "0"}])
    assert disabled =~ "precompiled: disabled; removed 2 installed builds", disabled
    assert disabled =~ ~r/==> kino\n/, disabled
    assert disabled =~ ~r/==> kino_vega_lite\n/, disabled
    disabled_lib = Path.join(off_proj, "_build/dev/lib")
    compare!(disabled_lib, ref, [])
    assert_archives!(run!(off_proj, [{"PRECOMPILED", "0"}]))
  end

  # Kino installed precompiled, the writer compiled by Mix into it (the batch
  # serves kino alone), then kino removed by this library: Mix compiles kino,
  # which wipes kino's build dir, and must then compile the writer again,
  # whose own compile writes its archives back. Mix 1.17 and 1.18 recompile
  # a dep whose .mix/compile.fetch is gone, 1.19 and later one whose
  # .mix/compile.elixir_scm is.
  test "a Mix-built writer compiles again after kino's removal", %{tmp_dir: dir} do
    f = F.new(dir)
    %{ref: ref, lock_path: lock_path, kino: kino} = sources!(dir, f)
    publish!(f, kino, nil, 2)

    for arm <- [:except, :disabled] do
      proj = project!(dir, Atom.to_string(arm), f, lock_path)
      out = mix!(proj, ["compile"])
      assert out =~ ~r/precompiled: kino 0\.19\.1\s+HIT/, out
      assert out =~ ~r/==> kino_vega_lite\n/, out
      assert_archives!(run!(proj))

      again =
        case arm do
          :except ->
            File.write!(Path.join(proj, "config/config.exs"), @except, [:append])
            again = mix!(proj, ["compile"])
            assert again =~ ~r/precompiled: kino 0\.19\.1\s+MISS\s+excepted/, again
            again

          :disabled ->
            mix!(proj, ["compile"], [{"PRECOMPILED", "0"}])
        end

      assert again =~ ~r/==> kino\n/, again
      assert again =~ ~r/==> kino_vega_lite\n/, again
      compare!(Path.join(proj, "_build/dev/lib"), ref, [])
      assert_archives!(run!(proj, [{"PRECOMPILED", "0"}]))
    end
  end

  # Two from-source builds on one lock: the first, which the entries are
  # published from (the fixture keeps their bytes), then, its _build
  # removed, `ref`, built again in the same dir, which installs are
  # compared with.
  defp sources!(dir, f) do
    F.publish(f, %{}, sequence: 1)
    source = C.plain!(Path.join(dir, "src"), f, deps: deps())
    mix!(source, ["deps.get"])
    mix!(source, ["compile"], [{"PRECOMPILED", "0"}])
    src = Path.join(source, "_build/dev/lib")
    lock_path = Path.join(source, "mix.lock")
    lock = Mix.Dep.Lock.read(lock_path)
    kino_dirs = app_dirs(Path.join(src, "kino"), "kino")
    writer_dirs = app_dirs(Path.join(src, "kino_vega_lite"), "kino_vega_lite")
    assert kino_dirs != [] and writer_dirs != []

    # Every archive in the source kino's priv is kino's own or the writer's.
    for d <- assets(src), do: assert(d in kino_dirs or d in writer_dirs, d)

    kino =
      f
      |> C.build_entry(Path.join(src, "kino"), elem(lock[:kino], 7))
      |> with_priv(f, Path.join(src, "kino"), kino_dirs)
      |> put_build(%{"foreign_priv_target" => "kino", "deps" => build_deps(lock, :kino)})

    writer =
      f
      |> C.build_entry(Path.join(src, "kino_vega_lite"), elem(lock[:kino_vega_lite], 7))
      |> with_foreign(f, src, writer_dirs)
      |> put_build(%{
        "foreign_priv_rule" => "kino_js_v1",
        "deps" => build_deps(lock, :kino_vega_lite),
        "compile_inputs" => [%{"kind" => "os_type", "family" => "unix"}]
      })

    assert Map.keys(writer["build"]["deps"]) |> Enum.sort() == ~w(kino table vega_lite)

    # Kino.JS stamps tar members with the wall clock: a second apart, the
    # two builds' archives differ in bytes whatever their members.
    File.rm_rf!(Path.join(source, "_build"))
    Process.sleep(1100)
    mix!(source, ["compile"], [{"PRECOMPILED", "0"}])
    %{ref: src, lock_path: lock_path, kino: kino, writer: writer}
  end

  defp publish!(f, kino, writer, seq) do
    writer_doc =
      if writer,
        do: %{
          "kino_vega_lite" => %{
            "versions" => %{
              "0.1.13" => %{
                "builds" => [],
                "foreign_priv" => %{"builds" => [], "builds_with_inputs" => [writer]}
              }
            }
          }
        },
        else: %{}

    F.publish(
      f,
      Map.merge(
        %{
          "kino" => %{
            "versions" => %{
              "0.19.1" => %{"builds" => [], "foreign_priv" => %{"builds" => [kino]}}
            }
          }
        },
        writer_doc
      ),
      sequence: seq
    )
  end

  defp project!(dir, name, f, lock_path) do
    proj = C.plain!(Path.join(dir, name), f, deps: deps())
    File.cp!(lock_path, Path.join(proj, "mix.lock"))
    mix!(proj, ["deps.get"])
    proj
  end

  defp run!(proj, env \\ []), do: mix!(proj, ["run", "--no-start", "-e", @run_time], env)

  defp mix_install!(dir, f, lock_path) do
    script = Path.join(dir, "install.exs")

    File.write!(script, """
    Application.put_env(:precompiled, :source, #{inspect(F.base_url())})
    Application.put_env(:precompiled, :root, #{inspect(f.root_path)})

    Precompiled.Host.install([{:kino, "== 0.19.1"}, {:kino_vega_lite, "== 0.1.13"}],
      lockfile: #{inspect(lock_path)}
    )

    IO.puts("dir=" <> Mix.install_project_dir())
    #{@run_time}
    """)

    installed =
      C.cmd!(["elixir", "-pa", C.own_ebin(), script], dir,
        env: [
          {"MIX_INSTALL_DIR", Path.join(dir, "installs")},
          {"PRECOMPILED_HOME", Path.join(dir, "home")},
          {"MIX_ENV", nil}
        ],
        packages: @packages
      )

    assert installed =~ ~r/precompiled: kino 0\.19\.1\s+HIT/, installed

    assert installed =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT.*archives into kino/,
           installed

    assert_archives!(installed)
    [install_dir] = Regex.run(~r/^dir=(.+)$/m, installed, capture: :all_but_first)
    Path.join(install_dir, "_build/dev/lib")
  end

  defp put_build(entry, fields), do: Map.update!(entry, "build", &Map.merge(&1, fields))

  defp put_mode(entry, path, mode) do
    Map.update!(entry, "ebin", fn files ->
      Enum.map(files, &if(&1["path"] == path, do: %{&1 | "mode" => mode}, else: &1))
    end)
  end

  # The `<d>` of every Elixir module the built `.app` lists.
  defp app_dirs(lib, app) do
    {:ok, [{:application, _, props}]} =
      :file.consult(String.to_charlist(Path.join([lib, "ebin", app <> ".app"])))

    for m <- props[:modules],
        d = Precompiled.ForeignPriv.dir_name(Atom.to_string(m)),
        d != nil,
        do: d
  end

  defp assets(lib),
    do:
      lib
      |> Path.join("kino/priv/assets/*")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp mtimes(lib) do
    for path <- Path.wildcard(Path.join(lib, "{kino,kino_vega_lite}/**"), match_dot: true),
        into: %{},
        do: {path, File.lstat!(path, time: :posix).mtime}
  end

  defp file_entry(f, path, rel) do
    bytes = File.read!(path)
    %{"path" => rel, "sha256" => F.file(f, bytes), "size" => byte_size(bytes), "mode" => 0o100644}
  end

  # Kino's own build: its ebin (build_entry/3) and the archives its own
  # modules' compile wrote under priv; the writer's are not kino's.
  defp with_priv(entry, f, lib, own) do
    priv =
      for path <- Path.wildcard(Path.join(lib, "priv/**")),
          File.regular?(path),
          rel = Path.relative_to(path, lib),
          own?(rel, own),
          do: file_entry(f, path, rel)

    assert priv != [], "kino wrote no archive of its own"
    Map.put(entry, "priv", priv)
  end

  defp own?("priv/assets/" <> rest, own), do: hd(String.split(rest, "/")) in own
  defp own?(_rel, _own), do: true

  # The writer's archives: the dirs of its own modules under kino's priv.
  defp with_foreign(entry, f, src, dirs) do
    kino = Path.join(src, "kino")

    foreign =
      for d <- dirs, path <- Path.wildcard(Path.join([kino, "priv/assets", d, "*.tar.gz"])) do
        f |> file_entry(path, Path.relative_to(path, kino)) |> Map.put("app", "kino")
      end

    assert length(foreign) == length(@modules), "kino_vega_lite wrote no archive into kino's priv"
    Map.put(entry, "foreign_priv", foreign)
  end

  # The package's closure in the lock, as the portal records a build's deps.
  defp build_deps(lock, app) do
    for d <- closure(lock, children(lock, app), MapSet.new()), into: %{} do
      {:hex, _, v, _, _, _, _, outer} = lock[d]
      {Atom.to_string(d), %{"version" => v, "checksum" => outer}}
    end
  end

  defp closure(_lock, [], seen), do: seen

  defp closure(lock, [app | rest], seen) do
    if MapSet.member?(seen, app),
      do: closure(lock, rest, seen),
      else: closure(lock, children(lock, app) ++ rest, MapSet.put(seen, app))
  end

  defp children(lock, app) do
    {:hex, _, _, _, _, deps, _, _} = lock[app]
    for {d, _, _} <- deps, Map.has_key?(lock, d), do: d
  end

  # Spec 7, items 1 to 3, against the reference build `ref`; the ebin of
  # each app in `installed` (the apps installed precompiled) file by file.
  defp compare!(on, ref, installed) do
    for app <- ["kino", "kino_vega_lite"] do
      assert files(Path.join(on, app)) == files(Path.join(ref, app)), app
    end

    for app <- installed, path <- Path.wildcard(Path.join([ref, app, "ebin/*"])) do
      other = Path.join([on, app, "ebin", Path.basename(path)])
      assert ebin_file(other) == ebin_file(path), Path.basename(path)
    end

    assert assets(on) == assets(ref)

    for d <- assets(ref) do
      [a] = Path.wildcard(Path.join([ref, "kino/priv/assets", d, "*"]))
      [b] = Path.wildcard(Path.join([on, "kino/priv/assets", d, "*"]))
      assert Path.basename(a) == Path.basename(b), d
      assert members(a) == members(b), d
    end
  end

  # Every regular file under a build dir, but Mix's and this library's
  # bookkeeping in .mix.
  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.reject(&String.starts_with?(&1, ".mix/"))
    |> Enum.sort()
  end

  defp ebin_file(path) do
    if String.ends_with?(path, ".beam") do
      {:ok, {_, stripped}} = :beam_lib.strip(File.read!(path))
      stripped
    else
      {:ok, terms} = :file.consult(String.to_charlist(path))
      terms
    end
  end

  # Every member in archive order: name, type, size, mode, owner and bytes;
  # only the mtime may differ (spec 7, item 2).
  defp members(path) do
    {:ok, table} = :erl_tar.table(String.to_charlist(path), [:compressed, :verbose])
    {:ok, files} = :erl_tar.extract(String.to_charlist(path), [:memory, :compressed])

    headers =
      for {name, type, size, _mtime, mode, uid, gid} <- table,
          do: {name, type, size, mode, uid, gid}

    {headers, files}
  end

  defp assert_archives!(out) do
    for m <- @modules, do: assert(out =~ "#{m}=true", out)
  end
end
