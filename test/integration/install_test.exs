# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled.Integration.InstallTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @source "https://compatibility.nerves-project.org/api/precompiled"
  @script """
  deps = [{:jason, "1.4.5"}, {:decimal, "3.2.0"}]
  opts = [source: "#{@source}"]
  NervesPrecompiled.install(deps, opts)
  IO.puts("encoded=" <> Jason.encode!(%{a: 1}))
  IO.puts("mix_dir=" <> Mix.install_project_dir())
  IO.puts("our_dir=" <> NervesPrecompiled.Install.project_dir(deps, []))

  beam = Path.join(Mix.install_project_dir(), "_build/dev/lib/jason/ebin/Elixir.Jason.beam")
  sha = :crypto.hash(:sha256, File.read!(beam)) |> Base.encode16(case: :lower)
  IO.puts("jason_beam_sha=" <> sha)
  """

  # jason 1.4.5 and decimal 3.2.0 have pure_elixir entries built with
  # Elixir 1.20.3 / OTP 29 (checked 2026-10-24); another toolchain MISSes
  # on the version rule, which is correct, so the HIT assertion is gated.
  test "install/2 in a fresh VM hits production and the dir formula matches Mix", %{tmp_dir: dir} do
    script = Path.join(dir, "install.exs")
    File.write!(script, @script)
    ebin = Path.join(Mix.Project.build_path(), "lib/nerves_precompiled/ebin")

    {out, status} =
      System.cmd("elixir", ["-pa", ebin, script],
        env: [
          {"MIX_INSTALL_DIR", Path.join(dir, "installs")},
          {"NERVES_PRECOMPILED_HOME", Path.join(dir, "home")},
          {"MIX_ENV", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "encoded={\"a\":1}"
    mix_dir = line!(out, "mix_dir")
    assert mix_dir == line!(out, "our_dir")

    if System.version() == "1.20.3" and :erlang.system_info(:otp_release) == ~c"29" do
      assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/
      assert out =~ ~r/precompiled: decimal 3\.2\.0\s+HIT/
      assert out =~ "precompiled: 2 hit, 0 miss, 0 fail of 2 deps"
      assert File.exists?(Path.join([mix_dir, "_build/dev/lib/jason/.mix/compile.elixir_scm"]))

      # The markers are also there after a recompile; Mix printing no
      # "==> dep" and the placed beam being the portal's prove it kept the hits.
      refute out =~ ~r/==> jason/, out
      refute out =~ ~r/==> decimal/, out
      sha = line!(out, "jason_beam_sha")

      {:ok, body} = NervesPrecompiled.HTTP.get(@source <> "/manifests/jason.json")
      ebin = get_in(:json.decode(body), ["versions", "1.4.5", "pure_elixir", "ebin"])
      assert sha in Enum.map(ebin, & &1["sha256"]), out
    end
  end

  defp line!(out, key) do
    case Regex.run(~r/^#{key}=(.+)$/m, out, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("no #{key}= line in the child's output:\n" <> out)
    end
  end
end
