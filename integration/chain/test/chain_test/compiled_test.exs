# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.CompiledTest do
  use ExUnit.Case, async: true

  alias ChainTest.{Compiled, Result, Synthetic}

  @moduletag :tmp_dir

  @beam %{"ebin/x.beam" => "x"}

  setup %{tmp_dir: tmp} do
    %{build_lib: Synthetic.tree(Path.join(tmp, "fixture"), "rpi4", %{})}
  end

  defp run(build_lib, lines) do
    Compiled.run(%{
      build_lib: build_lib,
      report: Synthetic.report(lines),
      allowlist: Compiled.allowlist("chain_fixture")
    })
  end

  defp find(results, check), do: Enum.find(results, &(&1.check == check))

  test "an installed hit passes", %{build_lib: lib} do
    Synthetic.dep(lib, :jason, @beam, :installed)
    results = run(lib, [{"jason", "1.4.5", "hit", ""}])

    assert %Result{step: :compiled, class: :pass} = find(results, "compiled:jason")
    assert %Result{class: :pass} = find(results, "compiled_here")
  end

  test "an install the report does not name is checked like a hit", %{build_lib: lib} do
    Synthetic.dep(lib, :jason, @beam, :installed)
    results = run(lib, [])

    assert %Result{class: :pass} = find(results, "compiled:jason")
  end

  test "a hit that carries compile.elixir fails", %{build_lib: lib} do
    Synthetic.dep(lib, :jason, @beam, :elixir)
    results = run(lib, [{"jason", "1.4.5", "hit", ""}])

    assert %Result{class: :fail, detail: detail} = find(results, "compiled:jason")
    assert detail =~ "compile.elixir"
  end

  test "a rebar or make hit with a marker but no provenance fails", %{build_lib: lib} do
    Synthetic.dep(lib, :yamerl, @beam, :scm)
    results = run(lib, [{"yamerl", "0.10.0", "hit", ""}])

    assert %Result{class: :fail, detail: detail} = find(results, "compiled:yamerl")
    assert detail =~ "precompiled.json"
  end

  test "a hit missing from _build is a disagreement", %{build_lib: lib} do
    results = run(lib, [{"jason", "1.4.5", "hit", ""}])
    assert %Result{class: :disagreement} = find(results, "compiled:jason")
  end

  test "compiled tooling and the project itself pass", %{build_lib: lib} do
    Synthetic.dep(lib, :nerves, @beam, :elixir)
    Synthetic.dep(lib, :nerves_system_br, @beam, :scm)
    Synthetic.dep(lib, :nerves_toolchain_aarch64_nerves_linux_gnu, @beam, :scm)
    Synthetic.dep(lib, :precompiled, @beam, :elixir)
    Synthetic.dep(lib, :chain_fixture, @beam, :elixir)

    assert %Result{class: :pass, detail: detail} = find(run(lib, []), "compiled_here")
    assert detail =~ "nerves_system_br"
    assert detail =~ "chain_fixture"
  end

  test "a compiled dep the report lists as a miss passes", %{build_lib: lib} do
    Synthetic.dep(lib, :argon2_elixir, @beam, :elixir)
    results = run(lib, [{"argon2_elixir", "4.1.3", "miss", "built against elixir_make"}])

    assert %Result{class: :pass, detail: detail} = find(results, "compiled_here")
    assert detail =~ "argon2_elixir"
  end

  test "a compiled dep that is neither tooling nor a reported miss fails", %{build_lib: lib} do
    Synthetic.dep(lib, :telemetry, @beam, :scm)

    assert %Result{class: :fail, detail: detail} = find(run(lib, []), "compiled_here")
    assert detail =~ "telemetry"
  end

  test "allowlist patterns match names and prefixes" do
    list = Compiled.allowlist("chain_fixture")
    assert Compiled.allowed?("nerves_system_rpi4", list)
    assert Compiled.allowed?("tablet", list)
    refute Compiled.allowed?("nerves_ssh", list)
    refute Compiled.allowed?("nerves_systemx", list)
  end

  test "the project's own path deps are allowed to compile here" do
    refute Compiled.allowed?("chain_path_dep", Compiled.allowlist("chain_fixture"))
    list = Compiled.allowlist("chain_fixture", ["chain_path_dep"])
    assert Compiled.allowed?("chain_path_dep", list)
    refute Compiled.allowed?("nerves_ssh", list)

    fixture = Path.expand("../../fixture", __DIR__)

    assert Compiled.allowed?(
             "chain_path_dep",
             Compiled.fixture_allowlist(fixture, "chain_fixture")
           )
  end

  # The fixture's deps/<dep>/lib/<file>, next to the synthetic _build.
  defp source(build_lib, dep, file) do
    path = Path.expand("../../../deps/#{dep}/#{file}", build_lib)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule X do end\n")
  end

  test "a reported miss with Elixir sources and Mix's compile manifest passes", %{build_lib: lib} do
    source(lib, :jason, "lib/jason.ex")
    Synthetic.dep(lib, :jason, @beam, :elixir)
    results = run(lib, [{"jason", "1.4.5", "miss", "no manifest"}])

    assert %Result{class: :pass} = find(results, "reported_miss:jason")
    assert %Result{class: :pass} = find(results, "compiled_here")
  end

  test "a reported miss with Elixir sources but only the marker is a disagreement",
       %{build_lib: lib} do
    source(lib, :jason, "lib/jason.ex")
    Synthetic.dep(lib, :jason, @beam, :scm)
    results = run(lib, [{"jason", "1.4.5", "miss", "no manifest"}])

    assert %Result{class: :disagreement, detail: detail} = find(results, "reported_miss:jason")
    assert detail =~ "compile.elixir"
  end

  test "a reported miss without Elixir sources compiled by its own tool passes",
       %{build_lib: lib} do
    source(lib, :yamerl, "src/yamerl.erl")
    Synthetic.dep(lib, :yamerl, @beam, :scm)
    results = run(lib, [{"yamerl", "0.10.0", "fail", "file not available"}])

    assert %Result{class: :pass} = find(results, "reported_miss:yamerl")
  end

  test "a reported miss without Elixir sources and without any Mix file is a disagreement",
       %{build_lib: lib} do
    source(lib, :yamerl, "src/yamerl.erl")
    beam = Path.join(lib, "yamerl/ebin/yamerl.beam")
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "x")
    results = run(lib, [{"yamerl", "0.10.0", "miss", "no manifest"}])

    assert %Result{class: :disagreement, detail: detail} = find(results, "reported_miss:yamerl")
    assert detail =~ "marker"
  end

  test "a reported miss _build does not have is not exercised", %{build_lib: lib} do
    results = run(lib, [{"jason", "1.4.5", "miss", "no manifest"}])

    assert %Result{class: :not_exercised} = find(results, "reported_miss:jason")
  end

  test "a hit is not also checked as a miss", %{build_lib: lib} do
    Synthetic.dep(lib, :jason, @beam, :installed)
    results = run(lib, [{"jason", "1.4.5", "hit", ""}])

    assert find(results, "reported_miss:jason") == nil
  end
end
