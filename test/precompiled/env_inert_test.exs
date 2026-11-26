# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.EnvInertTest do
  # 0.10.0, fix round 2 (proposal B), against Mix's real dep loading: a path
  # or git dep with no mix.exs, rebar.config or Makefile and `compile: false`
  # (phx.new's `heroicons`) has no manager, so Mix evaluates and compiles
  # nothing of it. Its module list is the beams on disk in its ebin dirs. A
  # `compile: false` dep with a mix.exs is evaluated, so it stays a non-Hex
  # dep with no list.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  defp project(tmp) do
    File.mkdir_p!(Path.join(tmp, "deps_src/icons/optimized"))
    File.write!(Path.join(tmp, "deps_src/icons/optimized/arrow.svg"), "<svg/>")
    File.mkdir_p!(Path.join(tmp, "deps_src/evaluated"))

    File.write!(Path.join(tmp, "deps_src/evaluated/mix.exs"), """
    defmodule Evaluated.MixProject do
      use Mix.Project
      def project, do: [app: :evaluated, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(tmp, "mix.exs"), """
    defmodule InertFixture.MixProject do
      use Mix.Project

      def project,
        do: [
          app: :inert_fixture,
          version: "0.1.0",
          deps: [
            {:icons, path: "deps_src/icons", app: false, compile: false},
            {:evaluated, path: "deps_src/evaluated", app: false, compile: false}
          ]
        ]
    end
    """)
  end

  defp loaded(tmp) do
    ebin = Path.dirname(:code.which(Precompiled.Env.MixProject))

    code = """
    Code.prepend_path(#{inspect(ebin)})
    env = Precompiled.Env.MixProject.load()
    beams = Map.new(env.inert_deps, fn {app, dirs} -> {app, Precompiled.Check.beams_in(dirs)} end)
    IO.puts("ENV " <> Base.encode64(:erlang.term_to_binary({env.inert_deps, env.non_hex_deps, beams})))
    """

    {out, status} =
      System.cmd(
        "elixir",
        ["-S", "mix", "run", "--no-compile", "--no-deps-check", "--no-start", "-e", code],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, out
    [encoded] = for "ENV " <> e <- String.split(out, "\n"), do: e
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  test "a dep with no manager and compile: false is inert; one with a mix.exs is not", %{
    tmp_dir: tmp
  } do
    project(tmp)
    {inert, non_hex, beams} = loaded(tmp)

    assert [:icons] == Map.keys(inert)
    [build_ebin, dest_ebin] = inert.icons
    assert String.ends_with?(build_ebin, "_build/dev/lib/icons/ebin")
    assert String.ends_with?(dest_ebin, "deps_src/icons/ebin")
    assert non_hex == [:evaluated]
    assert beams == %{icons: MapSet.new()}

    # What it can supply is what is on disk: a beam put in its ebin dir.
    File.mkdir_p!(Path.join(tmp, "deps_src/icons/ebin"))
    File.write!(Path.join(tmp, "deps_src/icons/ebin/Elixir.Poison.beam"), "")
    {_inert, _non_hex, beams} = loaded(tmp)
    assert beams == %{icons: MapSet.new(["Elixir.Poison"])}
  end
end
