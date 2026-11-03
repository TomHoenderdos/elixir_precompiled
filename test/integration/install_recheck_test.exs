# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Integration.InstallRecheckTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # The child VM calls install/2 against the local fixture source; the
  # install project dir under MIX_INSTALL_DIR persists from one child to
  # the next, as it does across boots of a device.
  @script """
  [source, root] = System.argv()
  deps = [{:jason, "1.4.5"}]
  ElixirPrecompiled.install(deps, source: source, root: root)
  IO.puts("encoded=" <> Jason.encode!(%{a: 1}))
  IO.puts("mix_dir=" <> Mix.install_project_dir())
  """

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  # R16 for install/2: a build the portal withdrew must not survive in the
  # install project. Revoking removes it before Mix.install/2 runs, and
  # Mix.install/2 then compiles it from source in the same run.
  test "a revoked install/2 build is compiled by Mix.install/2 in the next run", %{
    tmp_dir: dir
  } do
    f = F.new(dir)
    script = Path.join(dir, "install.exs")
    File.write!(script, @script)

    # Real jason beams, compiled by a plain Mix.install/2 in the same
    # install project, then published as the portal's build.
    F.publish(f, %{}, sequence: 1)
    out = child!(dir, f, [{"ELIXIR_PRECOMPILED", "0"}])
    mix_dir = line!(out, "mix_dir")
    lib = Path.join(mix_dir, "_build/dev/lib/jason")
    entry = jason_entry(f, lib, mix_dir)
    File.rm_rf!(lib)

    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}, sequence: 2)

    out = child!(dir, f)
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    assert out =~ ~s(encoded={"a":1}), out
    assert File.exists?(Path.join(lib, ".mix/elixir_precompiled.json"))
    refute File.exists?(Path.join(lib, ".mix/compile.elixir"))

    # A run with the batch still naming it is quiet and keeps the bytes.
    out = child!(dir, f)
    refute out =~ "precompiled: jason", out
    assert File.exists?(Path.join(lib, ".mix/elixir_precompiled.json"))

    # The portal withdraws the build: the next batch no longer names jason.
    F.publish(f, %{"other" => %{"versions" => %{}}}, sequence: 3)

    out = child!(dir, f)

    assert out =~ ~r/precompiled: jason 1\.4\.5\s+MISS\s+revoked: no longer in the current batch/,
           out

    assert out =~ ~s(encoded={"a":1}), out
    assert File.exists?(Path.join(lib, ".mix/compile.elixir"))
    refute File.exists?(Path.join(lib, ".mix/elixir_precompiled.json"))

    # And the run after that is quiet: nothing installed, nothing to recheck.
    out = child!(dir, f)
    refute out =~ "precompiled: jason", out
    assert out =~ ~s(encoded={"a":1}), out
  end

  defp jason_entry(f, lib, mix_dir) do
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

    assert files != [], "no jason beams under #{lib}"

    %{jason: {:hex, :jason, "1.4.5", _, _, _, _, outer}} =
      Mix.Dep.Lock.read(Path.join(mix_dir, "mix.lock"))

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

  defp child!(dir, f, env \\ []) do
    ebin = Path.join(Mix.Project.build_path(), "lib/elixir_precompiled/ebin")

    {out, status} =
      System.cmd(
        "elixir",
        ["-pa", ebin, Path.join(dir, "install.exs"), F.base_url(), f.root_path],
        env:
          [
            {"MIX_INSTALL_DIR", Path.join(dir, "installs")},
            {"ELIXIR_PRECOMPILED_HOME", Path.join(dir, "home")},
            {"MIX_ENV", nil},
            {"MIX_TARGET", nil},
            {"MIX_BUILD_PATH", nil},
            {"MIX_DEPS_PATH", nil}
          ] ++ env,
        stderr_to_stdout: true
      )

    assert status == 0, "install child exited #{status}:\n" <> out
    out
  end

  defp line!(out, key) do
    case Regex.run(~r/^#{key}=(.+)$/m, out, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("no #{key}= line in the child's output:\n" <> out)
    end
  end
end
