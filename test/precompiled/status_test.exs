# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.StatusTest do
  use ExUnit.Case, async: true
  alias Precompiled.Status
  @moduletag :tmp_dir

  defp dep(lib, name, vsn, prov) do
    File.mkdir_p!(Path.join([lib, name, "ebin"]))

    File.write!(
      Path.join([lib, name, "ebin", name <> ".app"]),
      "{application, #{name}, [{vsn, \"#{vsn}\"}]}.\n"
    )

    if prov do
      File.mkdir_p!(Path.join([lib, name, ".mix"]))
      File.write!(Path.join([lib, name, ".mix/precompiled.json"]), prov)
    end
  end

  test "lists provenance-marked deps and cleans exactly those", %{tmp_dir: lib} do
    dep(
      lib,
      "jason",
      "1.4.5",
      ~s({"manifest_sha256":"#{String.duplicate("a", 64)}","batch_sequence":9,"source":"https://example.test/p"})
    )

    dep(lib, "ash", "3.5.2", "not json")
    dep(lib, "decimal", "2.3.0", nil)

    assert [
             %{name: "ash", version: "3.5.2", manifest: nil, sequence: nil},
             %{
               name: "jason",
               version: "1.4.5",
               manifest: "aaaa" <> _,
               sequence: 9,
               source: "https://example.test/p"
             }
           ] = Status.installed(lib)

    assert Status.format(%{
             name: "jason",
             version: "1.4.5",
             manifest: String.duplicate("a", 64),
             sequence: 9,
             source: "s"
           }) =~
             ~r/jason 1\.4\.5\s+batch 9\s+manifest aaaaaaaaaaaa\s+s/

    assert length(Status.sweep(lib).removed) == 2
    assert File.ls!(lib) == ["decimal"]
  end

  test "a missing build lib lists nothing and cleans nothing", %{tmp_dir: dir} do
    lib = Path.join(dir, "nope")
    assert Status.installed(lib) == []
    assert Status.sweep(lib).removed == []
  end

  test "links are never followed: a linked dep dir, .mix or provenance is not an install", %{
    tmp_dir: dir
  } do
    lib = Path.join(dir, "lib")
    outside = Path.join(dir, "outside")
    dep(outside, "far", "1.0.0", "{}")
    File.mkdir_p!(lib)

    # The dep dir itself a link.
    File.ln_s!(Path.join(outside, "far"), Path.join(lib, "far"))
    # .mix a link.
    File.mkdir_p!(Path.join(lib, "mixlink"))
    File.ln_s!(Path.join(outside, "far/.mix"), Path.join(lib, "mixlink/.mix"))
    # The provenance file a link.
    File.mkdir_p!(Path.join(lib, "provlink/.mix"))

    File.ln_s!(
      Path.join(outside, "far/.mix/precompiled.json"),
      Path.join(lib, "provlink/.mix/precompiled.json")
    )

    # A real install holding a link out of the build: removed, the link
    # target kept.
    dep(lib, "real", "2.0.0", "{}")
    File.ln_s!(Path.join(outside, "far"), Path.join(lib, "real/priv"))

    assert [%{name: "real"}] = Status.installed(lib)
    assert length(Status.sweep(lib).removed) == 1
    assert File.ls!(lib) |> Enum.sort() == ["far", "mixlink", "provlink"]
    assert File.regular?(Path.join(outside, "far/ebin/far.app"))
    assert File.regular?(Path.join(outside, "far/.mix/precompiled.json"))
  end

  test "a build lib that is itself a link is not walked", %{tmp_dir: dir} do
    real = Path.join(dir, "real")
    dep(real, "jason", "1.4.5", "{}")
    File.ln_s!(real, Path.join(dir, "lib"))
    assert Status.installed(Path.join(dir, "lib")) == []
    assert Status.sweep(Path.join(dir, "lib")).removed == []
    assert File.dir?(Path.join(real, "jason"))
  end

  test "a dep Mix compiled after an install is Mix's build: only its stale provenance goes", %{
    tmp_dir: lib
  } do
    dep(lib, "rebuilt", "1.0.0", "{}")
    prov = Path.join(lib, "rebuilt/.mix/precompiled.json")
    File.touch!(prov, 1_000)
    File.write!(Path.join(lib, "rebuilt/.mix/compile.elixir"), "m")
    File.touch!(Path.join(lib, "rebuilt/.mix/compile.elixir"), 2_000)

    # A Mix manifest older than the provenance file: an install after it.
    dep(lib, "reinstalled", "1.0.0", "{}")
    File.write!(Path.join(lib, "reinstalled/.mix/compile.erlang"), "m")
    File.touch!(Path.join(lib, "reinstalled/.mix/compile.erlang"), 1)

    assert [%{name: "reinstalled"}] = Status.installed(lib)
    assert %{removed: ["reinstalled"], failed: []} = Status.sweep(lib)
    assert File.ls!(lib) == ["rebuilt"]
    refute File.exists?(prov)
    assert File.regular?(Path.join(lib, "rebuilt/ebin/rebuilt.app"))
    assert File.regular?(Path.join(lib, "rebuilt/.mix/compile.elixir"))
  end
end
