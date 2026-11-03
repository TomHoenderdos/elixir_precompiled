# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Integration.RecheckTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.Fixture, as: F

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
      if System.get_env("ELIXIR_PRECOMPILED") != "0" and Code.ensure_loaded?(ElixirPrecompiled),
        do: apply(ElixirPrecompiled, :run, [[host?: false]])
    end
  end
  """

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
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
    config :elixir_precompiled, source: #{inspect(F.base_url())}, root: #{inspect(f.root_path)}
    """)

    F.publish(f, %{}, sequence: 1)
    mix!(dir, ["deps.get"], [{"ELIXIR_PRECOMPILED", "0"}])

    # Real jason beams, built here and then published as the portal's build.
    mix!(dir, ["deps.compile", "jason"], [{"ELIXIR_PRECOMPILED", "0"}])
    lib = Path.join(proj, "_build/dev/lib/jason")
    entry = jason_entry(f, lib, proj)
    File.rm_rf!(lib)

    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}, sequence: 2)

    out = mix!(dir, ["compile"])
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    assert File.exists?(Path.join(lib, ".mix/elixir_precompiled.json"))
    refute File.exists?(Path.join(lib, ".mix/compile.elixir"))

    # The portal withdraws the build: the next batch no longer names jason.
    F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 3)

    out = mix!(dir, ["compile"])

    assert out =~ ~r/precompiled: jason 1\.4\.5\s+MISS\s+revoked: no longer in the current batch/,
           out

    assert out =~ ~r/==> jason/, out
    assert File.exists?(Path.join(lib, ".mix/compile.elixir"))
    refute File.exists?(Path.join(lib, ".mix/elixir_precompiled.json"))

    out = mix!(dir, ["run", "-e", "IO.puts(\"encoded=\" <> Jason.encode!(%{a: 1}))"])
    assert out =~ ~s(encoded={"a":1}), out

    # And the run after that is quiet: nothing installed, nothing to recheck.
    out = mix!(dir, ["compile"])
    refute out =~ "precompiled: jason", out
  end

  defp jason_entry(f, lib, proj) do
    files =
      for path <- Path.wildcard(Path.join(lib, "ebin/*")) do
        bytes = File.read!(path)

        %{
          "path" => "ebin/" <> Path.basename(path),
          "sha256" => F.file(f, bytes),
          "size" => byte_size(bytes),
          "mode" => 0o100644
        }
      end

    %{jason: {:hex, :jason, "1.4.5", _, _, _, _, outer}} =
      Mix.Dep.Lock.read(Path.join(proj, "mix.lock"))

    %{
      "target" => "pure_elixir",
      "ebin" => files,
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "run_id" => "r",
        "image_digest" => "d",
        "deps" => %{},
        "compile_env" => [],
        "package_checksum" => outer,
        "dep_env" => "prod"
      }
    }
  end

  defp mix!(dir, args, env \\ []) do
    ebin = Path.join(Mix.Project.build_path(), "lib/elixir_precompiled/ebin")

    {out, status} =
      System.cmd("elixir", ["-pa", ebin, "-S", "mix" | args],
        cd: Path.join(dir, "proj"),
        env:
          [
            {"MIX_ENV", "dev"},
            {"MIX_TARGET", nil},
            {"MIX_BUILD_PATH", nil},
            {"MIX_DEPS_PATH", nil},
            {"ELIXIR_PRECOMPILED_HOME", Path.join(dir, "home")}
          ] ++ env,
        stderr_to_stdout: true
      )

    assert status == 0, "mix #{Enum.join(args, " ")} exited #{status}:\n" <> out
    out
  end
end
