# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ErlCompilerEnvTest do
  use ExUnit.Case, async: true
  alias Precompiled.{ErlCompilerEnv, Match}

  @moduletag :tmp_dir

  @ash {:hex, :ash, "3.5.2", "inner", [:mix], [], "hexpm", "ASHOUTER"}

  @build %{
    "elixir" => "1.20.3",
    "otp" => "29",
    "dep_env" => "prod",
    "system_version" => nil,
    "deps" => %{},
    "compile_env" => [],
    "package_checksum" => "ASHOUTER"
  }

  defp doc(build),
    do: %{
      "format" => 2,
      "versions" => %{
        "3.5.2" => %{
          "builds" => [%{"target" => "pure_elixir", "ebin" => [], "priv" => [], "build" => build}]
        }
      }
    }

  defp ctx(env, over) do
    Map.merge(
      %{
        name: "ash",
        version: "3.5.2",
        lock_entry: @ash,
        lock: %{ash: @ash},
        system: {"host", ""},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end,
        prefer: nil,
        machine_env: &Map.get(env, &1)
      },
      Map.new(over)
    )
  end

  defp check(env), do: ErlCompilerEnv.check(&Map.get(env, &1))

  describe "ERL_COMPILER_OPTIONS" do
    test "unset or blank is fine", %{tmp_dir: dir} do
      assert :ok = check(%{"HOME" => dir})
      assert :ok = check(%{"HOME" => dir, "ERL_COMPILER_OPTIONS" => "  \n"})
    end

    test "set is a miss naming the variable, never the value", %{tmp_dir: dir} do
      env = %{"HOME" => dir, "ERL_COMPILER_OPTIONS" => "[{d,'SECRET_FLAG'}]"}

      assert {:miss, reason} = check(env)
      assert reason.code == :erl_compiler_options
      assert reason.args == ["ERL_COMPILER_OPTIONS"]
      assert reason.text == "ERL_COMPILER_OPTIONS is set, which changes every compile"
      refute reason.text =~ "SECRET_FLAG"
      refute Enum.any?(reason.args, &(&1 =~ "SECRET"))
    end

    test "every candidate misses, Mix and rebar3 alike (Elixir applies it too)", %{tmp_dir: dir} do
      env = %{"HOME" => dir, "ERL_COMPILER_OPTIONS" => "[no_line_info]"}

      for manager <- ["mix", "rebar3", nil] do
        assert {:miss, %{code: :erl_compiler_options}} =
                 Match.select_reason(doc(@build), ctx(env, manager: manager))
      end

      assert {:ok, _, _} = Match.select(doc(@build), ctx(%{"HOME" => dir}, manager: "mix"))
    end
  end

  describe "ERL_FLAGS, ERL_AFLAGS, ERL_ZFLAGS" do
    for var <- ~w(ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS) do
      test "#{var} with only runtime flags is fine", %{tmp_dir: dir} do
        env = %{
          "HOME" => dir,
          unquote(var) => "-kernel shell_history enabled +S 4 -name a@b -setcookie c"
        }

        assert :ok = check(env)
      end

      for token <- ~w(-eval -s -run -S -pa -pz -env -args_file -boot -config -compiler -elixir
                      -mix -stdlib -extra -code_path_choice -boot_var -path) do
        test "#{var} with #{token} is a miss naming the variable", %{tmp_dir: dir} do
          env = %{"HOME" => dir, unquote(var) => "-kernel x y #{unquote(token)} secret_value"}

          assert {:miss, reason} = check(env)
          assert reason.code == :erl_compiler_options
          assert reason.args == [unquote(var)]

          assert reason.text ==
                   "#{unquote(var)} has #{unquote(token)}, which can change every compile"

          refute reason.text =~ "secret_value"
        end
      end
    end

    test "they miss in the host check", %{tmp_dir: dir} do
      env = %{"HOME" => dir, "ERL_AFLAGS" => "-env ERL_COMPILER_OPTIONS [no_line_info]"}

      assert {:miss, "ERL_AFLAGS has -env, which can change every compile"} =
               Match.select(doc(@build), ctx(env, manager: "mix"))
    end
  end

  describe ".erlang" do
    test "a .erlang in HOME is a miss naming the file", %{tmp_dir: dir} do
      file = Path.join(dir, ".erlang")
      File.write!(file, "ok.\n")

      assert {:miss, reason} = check(%{"HOME" => dir})
      assert reason.code == :erl_compiler_options
      assert reason.args == [".erlang"]
      assert reason.text == "#{file} runs at every Erlang start, which can change every compile"
    end

    test "a .erlang in the user config dir is a miss", %{tmp_dir: dir} do
      cfg = ErlCompilerEnv.user_config_dir(&Map.get(%{"HOME" => dir}, &1))
      assert String.starts_with?(cfg, dir)
      File.mkdir_p!(cfg)
      File.write!(Path.join(cfg, ".erlang"), "ok.\n")

      assert {:miss, %{args: [".erlang"]}} = check(%{"HOME" => dir})
    end

    test "a home that cannot be searched is a miss", %{tmp_dir: dir} do
      home = Path.join(dir, "locked")
      File.mkdir_p!(home)
      File.chmod!(home, 0o000)
      on_exit(fn -> File.chmod(home, 0o755) end)

      # Root searches anything: nothing to test there.
      if match?({:error, _}, File.ls(home)) do
        assert {:miss, %{args: [".erlang"], text: text}} = check(%{"HOME" => home})
        assert text =~ "could not be checked"
      end
    end
  end
end
