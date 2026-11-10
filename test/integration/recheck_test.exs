# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.RecheckTest do
  use ExUnit.Case, async: false
  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # A tiny Mix project whose deps.loadpaths alias calls the library first,
  # where nerves.init calls it in a Nerves project. The library is on the
  # code path (-pa), not a dep, so it never compiles in the child.
  @mix_exs """
  defmodule Proj.MixProject do
    use Mix.Project

    def project do
      [
        app: :proj,
        version: "0.1.0",
        deps: [{:jason, "1.4.5"}],
        aliases: ["deps.loadpaths": [&precompiled/1, "deps.loadpaths"]]
      ]
    end

    defp precompiled(_args) do
      if System.get_env("PRECOMPILED") != "0" and Code.ensure_loaded?(Precompiled.Host),
        do: apply(Precompiled.Host, :run, [[host?: false]])
    end
  end
  """

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  # The point of R16: a build the portal withdrew must not survive in a warm
  # _build. Revoking removes it, and Mix must then compile it from source in
  # the same run, or the run fails with a missing dep.
  test "a revoked install is compiled by Mix in the same run", %{tmp_dir: dir} do
    f = F.new(dir)
    proj = Path.join(dir, "proj")
    File.mkdir_p!(Path.join(proj, "config"))
    File.write!(Path.join(proj, "mix.exs"), @mix_exs)

    File.write!(Path.join(proj, "config/config.exs"), """
    import Config
    config :precompiled, source: #{inspect(F.base_url())}, root: #{inspect(f.root_path)}
    """)

    F.publish(f, %{}, sequence: 1)
    C.mix!(proj, ["deps.get"], [{"PRECOMPILED", "0"}], pa: true)

    # Real jason beams, built here and then published as the portal's build.
    C.mix!(proj, ["deps.compile", "jason"], [{"PRECOMPILED", "0"}], pa: true)
    lib = Path.join(proj, "_build/dev/lib/jason")
    entry = C.jason_entry(f, lib, proj)
    File.rm_rf!(lib)

    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}, sequence: 2)

    out = C.mix!(proj, ["compile"], [], pa: true)
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    assert File.exists?(Path.join(lib, ".mix/precompiled.json"))
    refute File.exists?(Path.join(lib, ".mix/compile.elixir"))

    # The portal withdraws the build: the next batch no longer names jason.
    F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 3)

    out = C.mix!(proj, ["compile"], [], pa: true)

    assert out =~ ~r/precompiled: jason 1\.4\.5\s+MISS\s+revoked: no longer in the current batch/,
           out

    assert out =~ ~r/==> jason/, out
    assert File.exists?(Path.join(lib, ".mix/compile.elixir"))
    refute File.exists?(Path.join(lib, ".mix/precompiled.json"))

    out =
      C.mix!(proj, ["run", "-e", "IO.puts(\"encoded=\" <> Jason.encode!(%{a: 1}))"], [], pa: true)

    assert out =~ ~s(encoded={"a":1}), out

    # And the run after that is quiet: nothing installed, nothing to recheck.
    out = C.mix!(proj, ["compile"], [], pa: true)
    refute out =~ "precompiled: jason", out
  end
end
