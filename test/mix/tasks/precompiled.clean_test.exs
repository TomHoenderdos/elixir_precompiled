# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.CleanTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp in_project(dir, fun) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CleanTestProject.MixProject do
      use Mix.Project
      def project, do: [app: :clean_test_project, version: "0.1.0"]
    end
    """)

    Mix.Project.in_project(:clean_test_project, dir, fn _ -> fun.() end)
  end

  defp infos(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> infos([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp put(path, bytes \\ "x") do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  test "status lists installs; clean removes only those, --cache also the cache", %{
    tmp_dir: dir
  } do
    home = Path.join(dir, "home")
    System.put_env("ELIXIR_PRECOMPILED_HOME", home)
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_HOME") end)
    put(Path.join(home, "files/" <> String.duplicate("a", 64)))
    put(Path.join(home, "batch.json"))

    in_project(dir, fn ->
      lib = Path.join(Mix.Project.build_path(), "lib")
      put(Path.join(lib, "jason/ebin/jason.app"), ~s({application, jason, [{vsn, "1.4.5"}]}.\n))
      put(Path.join(lib, "jason/.mix/elixir_precompiled.json"), ~s({"batch_sequence":3}))
      put(Path.join(lib, "decimal/ebin/decimal.app"))

      Mix.Tasks.Precompiled.Status.run([])
      out = infos()
      assert out =~ ~r/jason 1\.4\.5\s+batch 3/, out
      assert out =~ "precompiled: 1 installed in ", out
      refute out =~ "decimal", out

      Mix.Tasks.Precompiled.Clean.run([])
      assert_received {:mix_shell, :info, ["precompiled: removed 1 installed build (jason)"]}
      assert File.ls!(lib) == ["decimal"]
      assert File.exists?(Path.join(home, "files"))

      Mix.Tasks.Precompiled.Clean.run(["--cache"])
      assert_received {:mix_shell, :info, ["precompiled: removed 0 installed builds"]}
      assert_received {:mix_shell, :info, ["precompiled: cleared the download cache in " <> _]}
      refute File.exists?(Path.join(home, "files"))
      assert File.exists?(Path.join(home, "batch.json"))
    end)
  end

  test "a configured home is the cache status names and clean --cache clears", %{tmp_dir: dir} do
    configured = Path.join(dir, "configured")
    other = Path.join(dir, "other")
    # Lower precedence than the app env, as in a run; stands in for the default.
    System.put_env("ELIXIR_PRECOMPILED_HOME", other)
    Application.put_env(:elixir_precompiled, :home, configured)

    on_exit(fn ->
      System.delete_env("ELIXIR_PRECOMPILED_HOME")
      Application.delete_env(:elixir_precompiled, :home)
    end)

    put(Path.join(configured, "files/" <> String.duplicate("a", 64)))
    put(Path.join(other, "files/" <> String.duplicate("b", 64)))

    in_project(dir, fn ->
      Mix.Tasks.Precompiled.Status.run([])
      out = infos()
      assert out =~ "cache #{configured}", out
      refute out =~ other, out

      Mix.Tasks.Precompiled.Clean.run(["--cache"])
      out = infos()
      assert out =~ "cleared the download cache in #{configured}", out
      refute out =~ other, out
      refute File.exists?(Path.join(configured, "files"))
      assert File.exists?(Path.join(other, "files/" <> String.duplicate("b", 64)))
    end)
  end
end
