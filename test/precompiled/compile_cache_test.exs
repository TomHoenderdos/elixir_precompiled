# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
unless Code.ensure_loaded?(Precompiled.MixProject.CompileCache) do
  Code.require_file("../../build_support/compile_cache.exs", __DIR__)
end

defmodule Precompiled.CompileCacheTest do
  use ExUnit.Case, async: true

  alias Precompiled.MixProject.CompileCache

  @moduletag :tmp_dir

  @inputs %{
    toolchain: {"1.20.0", "29", "16.0", "9.0"},
    dir: "/deps/precompiled",
    env: :prod,
    args: ["--from-mix-deps-compile"],
    options: [docs: true, debug_info: true],
    erl_compiler_options: nil,
    project: [elixirc_options: [], erlc_options: []],
    sources: [{"lib/a.ex", "aa"}, {"mix.exs", "bb"}],
    deps: [igniter: nil],
    app_env: [source: "https://example.test/api"]
  }

  # A compile_path with two beams and a manifest, as compile.elixir leaves them.
  defp built(dir) do
    ebin = Path.join(dir, "ebin")
    manifest = Path.join([dir, ".mix", "compile.elixir"])
    File.mkdir_p!(ebin)
    File.mkdir_p!(Path.dirname(manifest))
    File.write!(Path.join(ebin, "Elixir.A.beam"), "beam a")
    File.write!(Path.join(ebin, "Elixir.B.beam"), "beam b")
    File.write!(Path.join(ebin, "precompiled.app"), "app")
    File.write!(manifest, "manifest")
    {ebin, manifest}
  end

  defp fresh(dir) do
    {Path.join(dir, "ebin"), Path.join([dir, ".mix", "compile.elixir"])}
  end

  describe "key/1" do
    test "is stable for the same inputs and changes with every input" do
      key = CompileCache.key(@inputs)
      assert key == CompileCache.key(@inputs)
      assert key =~ ~r/\A[0-9a-f]{64}\z/

      changed = [
        toolchain: {"1.20.1", "29", "16.0", "9.0"},
        dir: "/elsewhere/precompiled",
        env: :dev,
        args: ["--from-mix-deps-compile", "--no-optional-deps"],
        options: [docs: false, debug_info: true],
        erl_compiler_options: "deterministic",
        project: [elixirc_options: [debug_info: false], erlc_options: []],
        sources: [{"lib/a.ex", "ab"}, {"mix.exs", "bb"}],
        deps: [igniter: "0.6.0"],
        app_env: [source: "https://other.test/api"]
      ]

      for {field, value} <- changed do
        refute CompileCache.key(Map.put(@inputs, field, value)) == key, "#{field} not in the key"
      end
    end

    test "does not depend on the order sources and deps are listed in" do
      reordered = %{@inputs | sources: Enum.reverse(@inputs.sources)}
      assert CompileCache.key(reordered) == CompileCache.key(@inputs)
    end
  end

  describe "save/4 and restore/4" do
    test "a saved build restores into a fresh compile path", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      assert :ok = CompileCache.save(root, "k1", ebin, manifest)

      {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
      assert :hit = CompileCache.restore(root, "k1", ebin2, manifest2)
      assert File.read!(Path.join(ebin2, "Elixir.A.beam")) == "beam a"
      assert File.read!(Path.join(ebin2, "Elixir.B.beam")) == "beam b"
      assert File.read!(manifest2) == "manifest"
      # The .app is compile.app's to write, from the project as it is now.
      refute File.exists?(Path.join(ebin2, "precompiled.app"))
    end

    test "another key is a miss", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)

      {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
      assert :miss = CompileCache.restore(root, "k2", ebin2, manifest2)
      refute File.exists?(manifest2)
    end

    test "a changed file is a miss and leaves nothing behind", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)
      File.write!(Path.join([root, "k1", "ebin", "Elixir.B.beam"]), "beam X")

      {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
      assert :miss = CompileCache.restore(root, "k1", ebin2, manifest2)
      refute File.exists?(manifest2)
      assert Path.wildcard(Path.join(ebin2, "*")) == []
    end

    test "a missing file is a miss and leaves nothing behind", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)
      File.rm!(Path.join([root, "k1", "compile.elixir"]))

      {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
      assert :miss = CompileCache.restore(root, "k1", ebin2, manifest2)
      refute File.exists?(manifest2)
      assert Path.wildcard(Path.join(ebin2, "*")) == []
    end

    test "an index naming anything but beams and the manifest is a miss", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)
      index = Path.join([root, "k1", "index"])

      for bad <- ["../escape.beam", "ebin/../../x.beam", "ebin/a.txt", "/abs.beam"] do
        entries = :erlang.binary_to_term(File.read!(index))

        File.write!(
          index,
          :erlang.term_to_binary([{bad, 1, :crypto.hash(:sha256, "x")} | entries])
        )

        {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
        assert :miss = CompileCache.restore(root, "k1", ebin2, manifest2), bad
        refute File.exists?(manifest2)
        refute File.exists?(Path.join(tmp, "escape.beam"))
        File.write!(index, :erlang.term_to_binary(entries))
      end
    end

    test "a compile path that already holds a build is left alone", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)

      {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
      File.mkdir_p!(ebin2)
      File.write!(Path.join(ebin2, "Elixir.Old.beam"), "old")
      assert :skip = CompileCache.restore(root, "k1", ebin2, manifest2)
      refute File.exists?(manifest2)

      {ebin3, manifest3} = fresh(Path.join(tmp, "c"))
      File.mkdir_p!(Path.dirname(manifest3))
      File.write!(manifest3, "old manifest")
      assert :skip = CompileCache.restore(root, "k1", ebin3, manifest3)
      assert File.read!(manifest3) == "old manifest"
    end

    test "saving keeps only the newest key", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)
      :ok = CompileCache.save(root, "k2", ebin, manifest)
      assert File.ls!(root) == ["k2"]
    end

    test "saving over an existing entry keeps it", %{tmp_dir: tmp} do
      root = Path.join(tmp, "cache")
      {ebin, manifest} = built(Path.join(tmp, "a"))
      :ok = CompileCache.save(root, "k1", ebin, manifest)
      :ok = CompileCache.save(root, "k1", ebin, manifest)
      {ebin2, manifest2} = fresh(Path.join(tmp, "b"))
      assert :hit = CompileCache.restore(root, "k1", ebin2, manifest2)
    end

    test "a cache dir that cannot be written is not an error", %{tmp_dir: tmp} do
      {ebin, manifest} = built(Path.join(tmp, "a"))
      file = Path.join(tmp, "not_a_dir")
      File.write!(file, "")
      assert {:error, _} = CompileCache.save(Path.join(file, "cache"), "k1", ebin, manifest)
    end
  end

  describe "enabled?/4" do
    @hex_lock {:hex, :precompiled, "0.6.0", "inner", [:mix], [], "hexpm", "outer"}

    test "only for a dep Hex fetched, compiled by deps.compile, unless forced or turned off" do
      args = ["--from-mix-deps-compile"]
      assert CompileCache.enabled?(args, Hex.SCM, @hex_lock, nil)
      assert CompileCache.enabled?(args, Hex.SCM, @hex_lock, "1")
      refute CompileCache.enabled?(args, Hex.SCM, @hex_lock, "0")
      refute CompileCache.enabled?([], Hex.SCM, @hex_lock, nil)
      refute CompileCache.enabled?(["--force" | args], Hex.SCM, @hex_lock, nil)
    end

    test "never for a path or git dep, whatever the lock says" do
      args = ["--from-mix-deps-compile"]
      git_lock = {:git, "https://example.test/precompiled.git", "abc", []}

      for scm <- [Mix.SCM.Path, Mix.SCM.Git, nil], lock <- [@hex_lock, git_lock, nil] do
        refute CompileCache.enabled?(args, scm, lock, nil), inspect({scm, lock})
      end

      refute CompileCache.enabled?(args, Hex.SCM, git_lock, nil)
      refute CompileCache.enabled?(args, Hex.SCM, nil, nil)
    end
  end

  # The cache key covers the runtime config (Application.get_all_env), not
  # compile-time reads: one in lib/ would make a restored build stale.
  test "lib/ reads no config at compile time" do
    lib = Path.expand("../../lib", __DIR__)

    hits =
      for file <- Path.wildcard(Path.join(lib, "**/*.ex")),
          File.read!(file) =~ ~r/Application\.compile_env/,
          do: Path.relative_to(file, lib)

    assert hits == []
  end
end

defmodule Precompiled.CompileCacheMixTest do
  # Mix compiling this library as a Hex dependency of a fresh project, the
  # way `deps.compile precompiled` in the deps.loadpaths alias does.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  @repo Path.expand("../..", __DIR__)

  defp mix(project, args) do
    System.cmd("mix", args,
      cd: project,
      env: [
        {"MIX_ENV", "dev"},
        {"PRECOMPILED", "0"},
        {"PRECOMPILED_COMPILE_CACHE", nil},
        {"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", nil}
      ],
      stderr_to_stdout: true
    )
  end

  # The library as Hex leaves it in deps/: the package's files, its
  # hex_metadata.config, the .hex file Hex.SCM checks against the lock, and
  # the lock entry. No network: the lock already matches.
  setup %{tmp_dir: tmp} do
    project = Path.join(tmp, "app")
    dep = Path.join(project, "deps/precompiled")
    unpack(dep)
    version = Mix.Project.config()[:version]
    {inner, outer} = {String.duplicate("a", 64), String.duplicate("b", 64)}

    hex = %{
      name: "precompiled",
      version: version,
      managers: [:mix],
      inner_checksum: inner,
      outer_checksum: outer,
      repo: "hexpm"
    }

    File.write!(Path.join(dep, ".hex"), :erlang.term_to_binary({{:hex, 2, 0}, hex}))

    File.write!(Path.join(project, "mix.lock"), """
    %{"precompiled": {:hex, :precompiled, "#{version}", "#{inner}", [:mix], [], "hexpm", "#{outer}"}}
    """)

    write_project(project, ~s|{:precompiled, "#{version}", runtime: false}|)
    %{dep: dep, project: project, tmp: tmp}
  end

  defp unpack(dep) do
    File.mkdir_p!(dep)

    for f <- ["mix.exs", "lib", "priv", "build_support"],
        do: File.cp_r!(Path.join(@repo, f), Path.join(dep, f))

    File.write!(Path.join(dep, "hex_metadata.config"), "{<<\"name\">>,<<\"precompiled\">>}.\n")
  end

  defp write_project(project, dep) do
    File.write!(Path.join(project, "mix.exs"), """
    defmodule App.MixProject do
      use Mix.Project

      def project do
        [app: :app, version: "0.1.0", deps: [#{dep}]]
      end
    end
    """)
  end

  test "a fresh _build restores the library instead of compiling it", ctx do
    %{dep: dep, project: project} = ctx
    {out, 0} = mix(project, ["deps.compile", "precompiled"])
    assert out =~ "Compiling"
    [key] = File.ls!(Path.join(dep, ".compile_cache"))

    ebin = Path.join(project, "_build/dev/lib/precompiled/ebin")
    beams = for f <- File.ls!(ebin), into: %{}, do: {f, File.read!(Path.join(ebin, f))}

    File.rm_rf!(Path.join(project, "_build"))
    {out, 0} = mix(project, ["deps.compile", "precompiled"])
    refute out =~ "Compiling"
    assert File.ls!(Path.join(dep, ".compile_cache")) == [key]
    assert for(f <- File.ls!(ebin), into: %{}, do: {f, File.read!(Path.join(ebin, f))}) == beams

    # The restored build is one Mix takes as its own: nothing recompiles,
    # and the modules load.
    {out, 0} =
      mix(project, ["run", "--no-start", "-e", "IO.puts(Precompiled.Host.module_info(:module))"])

    refute out =~ "Compiling"
    assert out =~ "Elixir.Precompiled.Host"

    # A changed source is another key: compiled again, and the entry replaced.
    File.write!(
      Path.join(dep, "lib/precompiled/extra.ex"),
      "defmodule Precompiled.Extra, do: nil\n"
    )

    File.rm_rf!(Path.join(project, "_build"))
    {out, 0} = mix(project, ["deps.compile", "precompiled"])
    assert out =~ "Compiling"
    assert File.regular?(Path.join(ebin, "Elixir.Precompiled.Extra.beam"))
    [new_key] = File.ls!(Path.join(dep, ".compile_cache"))
    refute new_key == key
  end

  test "the project's config for this library is in the key", ctx do
    %{dep: dep, project: project} = ctx
    {_, 0} = mix(project, ["deps.compile", "precompiled"])
    [key] = File.ls!(Path.join(dep, ".compile_cache"))

    File.mkdir_p!(Path.join(project, "config"))

    File.write!(Path.join(project, "config/config.exs"), """
    import Config
    config :precompiled, except: [:jason]
    """)

    File.rm_rf!(Path.join(project, "_build"))
    {out, 0} = mix(project, ["deps.compile", "precompiled"])
    assert out =~ "Compiling"
    [new_key] = File.ls!(Path.join(dep, ".compile_cache"))
    refute new_key == key
  end

  test "an unpacked Hex tree used as a path dep is never written to", ctx do
    %{tmp: tmp, project: project} = ctx
    tree = Path.join(tmp, "unpacked/precompiled")
    unpack(tree)
    File.rm_rf!(Path.join(project, "deps"))
    File.rm!(Path.join(project, "mix.lock"))
    write_project(project, "{:precompiled, path: #{inspect(tree)}, runtime: false}")

    {out, 0} = mix(project, ["deps.compile", "precompiled"])
    assert out =~ "Compiling"
    refute File.exists?(Path.join(tree, ".compile_cache"))
  end

  test "a git checkout is never written to, even with a Hex lock entry", ctx do
    %{dep: dep, project: project} = ctx
    File.rm!(Path.join(dep, ".hex"))
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dep)
    {_, 0} = System.cmd("git", ["add", "."], cd: dep)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"],
        cd: dep
      )

    {rev, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dep)
    rev = String.trim(rev)
    url = "file://" <> dep
    write_project(project, "{:precompiled, git: #{inspect(url)}, runtime: false}")

    File.write!(Path.join(project, "mix.lock"), """
    %{"precompiled": {:git, #{inspect(url)}, "#{rev}", []}}
    """)

    {out, 0} = mix(project, ["deps.compile", "precompiled"])
    assert out =~ "Compiling"
    refute File.exists?(Path.join(dep, ".compile_cache"))
  end

  test "PRECOMPILED_COMPILE_CACHE=0 turns it off", ctx do
    %{dep: dep, project: project} = ctx

    {_, 0} =
      System.cmd("mix", ["deps.compile", "precompiled"],
        cd: project,
        env: [{"MIX_ENV", "dev"}, {"PRECOMPILED_COMPILE_CACHE", "0"}],
        stderr_to_stdout: true
      )

    refute File.exists?(Path.join(dep, ".compile_cache"))
  end
end
