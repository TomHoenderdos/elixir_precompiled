# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.ForeignPrivTest do
  # 0.8.0 against a local signed source: kino 0.19.1 and kino_vega_lite
  # 0.1.13 built from source here, published as the portal publishes them
  # (kino under `foreign_priv` with `foreign_priv_target`, the writer under
  # `foreign_priv` with its archives), then installed precompiled in a fresh
  # project and in Mix.install, and into a kino Mix built. Install versus
  # source: the writer's beams equal, kino's priv/assets the same
  # directories holding the same members, and the archive each beam names
  # is on disk at run time.
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

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  defp deps(), do: ~s([{:kino, "== 0.19.1"}, {:kino_vega_lite, "== 0.1.13"}, #{C.own_dep()}])

  defp mix!(proj, args, env \\ []), do: C.mix!(proj, args, env, packages: @packages)

  test "a writer installed precompiled is what Mix builds from source", %{tmp_dir: dir} do
    f = F.new(dir)
    F.publish(f, %{}, sequence: 1)

    # OFF: the source build every comparison is against.
    source = C.plain!(Path.join(dir, "off"), f, deps: deps())
    mix!(source, ["deps.get"])
    mix!(source, ["compile"], [{"PRECOMPILED", "0"}])
    off = Path.join(source, "_build/dev/lib")
    lock = Mix.Dep.Lock.read(Path.join(source, "mix.lock"))
    outer = fn app -> elem(lock[app], 7) end

    kino_dirs = app_dirs(Path.join(off, "kino"), "kino")
    writer_dirs = app_dirs(Path.join(off, "kino_vega_lite"), "kino_vega_lite")
    assert kino_dirs != [] and writer_dirs != []

    # Every archive in the source kino's priv is kino's own or the writer's.
    for d <- assets(off), do: assert(d in kino_dirs or d in writer_dirs, d)

    kino =
      f
      |> C.build_entry(Path.join(off, "kino"), outer.(:kino))
      |> with_priv(f, Path.join(off, "kino"), kino_dirs)
      |> put_build(%{"foreign_priv_target" => "kino", "deps" => build_deps(lock, :kino)})

    writer =
      f
      |> C.build_entry(Path.join(off, "kino_vega_lite"), outer.(:kino_vega_lite))
      |> with_foreign(f, off, writer_dirs)
      |> put_build(%{
        "foreign_priv_rule" => "kino_js_v1",
        "deps" => build_deps(lock, :kino_vega_lite),
        "compile_inputs" => [%{"kind" => "os_type", "family" => "unix"}]
      })

    assert Map.keys(writer["build"]["deps"]) |> Enum.sort() == ~w(kino table vega_lite)

    F.publish(
      f,
      %{
        "kino" => %{
          "versions" => %{"0.19.1" => %{"builds" => [], "foreign_priv" => %{"builds" => [kino]}}}
        },
        "kino_vega_lite" => %{
          "versions" => %{
            "0.1.13" => %{
              "builds" => [],
              "foreign_priv" => %{"builds" => [], "builds_with_inputs" => [writer]}
            }
          }
        }
      },
      sequence: 2
    )

    # ON: a fresh project on the same lock.
    on_proj = C.plain!(Path.join(dir, "on"), f, deps: deps())
    File.cp!(Path.join(source, "mix.lock"), Path.join(on_proj, "mix.lock"))
    mix!(on_proj, ["deps.get"])
    out = mix!(on_proj, ["compile"])
    assert out =~ ~r/precompiled: kino 0\.19\.1\s+HIT/, out
    assert out =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT.*; 2 archives into kino/, out
    refute out =~ ~r/==> kino\n/, out
    refute out =~ ~r/==> kino_vega_lite\n/, out
    on = Path.join(on_proj, "_build/dev/lib")

    compare!(on, off)

    # At run time the archive each beam names is there.
    assert_archives!(mix!(on_proj, ["run", "--no-start", "-e", @run_time]))

    # A second run writes nothing.
    again = mix!(on_proj, ["compile"])
    refute again =~ "HIT", again
    refute again =~ "MISS", again
    compare!(on, off)

    # Mix.install: the same engine, its own install project, on the same lock.
    script = Path.join(dir, "install.exs")

    File.write!(script, """
    Application.put_env(:precompiled, :source, #{inspect(F.base_url())})
    Application.put_env(:precompiled, :root, #{inspect(f.root_path)})

    Precompiled.Host.install([{:kino, "== 0.19.1"}, {:kino_vega_lite, "== 0.1.13"}],
      lockfile: #{inspect(Path.join(source, "mix.lock"))}
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

    [install_dir] = Regex.run(~r/^dir=(.+)$/m, installed, capture: :all_but_first)
    compare!(Path.join(install_dir, "_build/dev/lib"), off)
    assert_archives!(installed)

    # Spec 7, item 5: kino excepted compiles from source, and so, after it,
    # does the writer, whose own compile writes its archives again.
    File.write!(
      Path.join(on_proj, "config/config.exs"),
      "\nconfig :precompiled, except: [:kino]\n",
      [:append]
    )

    excepted = mix!(on_proj, ["compile"])
    assert excepted =~ ~r/precompiled: kino 0\.19\.1\s+MISS\s+excepted/, excepted

    assert excepted =~
             ~r/precompiled: kino_vega_lite 0\.1\.13\s+MISS\s+writes into kino's priv; kino compiles from source in this run/,
           excepted

    assert assets(on) == assets(off)
    assert_archives!(mix!(on_proj, ["run", "--no-start", "-e", @run_time]))

    # Kino Mix-built and current: a writer Mix would compile again is
    # installed, its archives placed into that kino.
    File.rm_rf!(Path.join(on, "kino_vega_lite"))
    mix_built = mix!(on_proj, ["compile"])
    refute mix_built =~ ~r/precompiled: kino 0\.19\.1/, mix_built

    assert mix_built =~ ~r/precompiled: kino_vega_lite 0\.1\.13\s+HIT.*; 2 archives into kino/,
           mix_built

    refute mix_built =~ ~r/==> kino_vega_lite\n/, mix_built
    compare!(on, off)
    assert_archives!(mix!(on_proj, ["run", "--no-start", "-e", @run_time]))
  end

  defp put_build(entry, fields), do: Map.update!(entry, "build", &Map.merge(&1, fields))

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
  defp with_foreign(entry, f, off, dirs) do
    kino = Path.join(off, "kino")

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

  # Spec 7, items 1 to 3.
  defp compare!(on, off) do
    for app <- ["kino_vega_lite"], beam <- Path.wildcard(Path.join([off, app, "ebin/*.beam"])) do
      other = Path.join([on, app, "ebin", Path.basename(beam)])
      {:ok, {_, a}} = :beam_lib.strip(File.read!(beam))
      {:ok, {_, b}} = :beam_lib.strip(File.read!(other))
      assert a == b, Path.basename(beam)
    end

    assert assets(on) == assets(off)

    for d <- assets(off) do
      [a] = Path.wildcard(Path.join([off, "kino/priv/assets", d, "*"]))
      [b] = Path.wildcard(Path.join([on, "kino/priv/assets", d, "*"]))
      assert Path.basename(a) == Path.basename(b), d
      assert members(a) == members(b), d
    end
  end

  defp members(path) do
    {:ok, files} = :erl_tar.extract(String.to_charlist(path), [:memory, :compressed])
    Enum.sort(files)
  end

  defp assert_archives!(out) do
    for m <- @modules, do: assert(out =~ "#{m}=true", out)
  end
end
