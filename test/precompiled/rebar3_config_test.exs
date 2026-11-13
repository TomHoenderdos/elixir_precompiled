# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Rebar3ConfigTest do
  use ExUnit.Case, async: true
  alias Precompiled.{Match, Rebar3Config}

  @moduletag :tmp_dir

  @ash {:hex, :ash, "3.5.2", "inner", [:rebar3], [], "hexpm", "ASHOUTER"}

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

  # A tmp HOME with `content` as its global rebar3 config.
  defp home(dir, content) do
    cfg = Path.join([dir, ".config", "rebar3"])
    File.mkdir_p!(cfg)
    File.write!(Path.join(cfg, "rebar.config"), content)
    Path.join(cfg, "rebar.config")
  end

  describe "check/1" do
    test "no global config is fine", %{tmp_dir: dir} do
      assert :ok = Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
    end

    test "no HOME and no REBAR_GLOBAL_CONFIG_DIR is fine" do
      assert :ok = Rebar3Config.check(fn _ -> nil end)
    end

    test "erl_opts in the global config is a miss naming the file and the key, not the value",
         %{tmp_dir: dir} do
      file = home(dir, "{erl_opts, [{d, 'SECRET_FLAG'}]}.\n")

      assert {:miss, reason} = Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
      assert reason.code == :rebar3_global_config
      assert reason.args == ["erl_opts"]
      assert reason.text == "global rebar3 config #{file} sets erl_opts"
      refute reason.text =~ "SECRET_FLAG"
    end

    test "settings no compile reads are fine", %{tmp_dir: dir} do
      home(dir, """
      {hex, [{doc, edoc}]}.
      {dialyzer, [{warnings, [unknown]}]}.
      {erl_opts, []}.
      {profiles, [{test, [{erl_opts, [nowarn_export_all]}]}]}.
      """)

      assert :ok = Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
    end

    test "an empty file is fine", %{tmp_dir: dir} do
      home(dir, "%% nothing here\n")
      assert :ok = Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
    end

    test "the prod profile's erl_opts is a miss (Mix compiles deps as prod)", %{tmp_dir: dir} do
      home(dir, "{profiles, [{prod, [{erl_opts, [native]}]}]}.\n")

      assert {:miss, %{args: ["profiles.prod.erl_opts"]}} =
               Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
    end

    for key <- ~w(overrides pre_hooks provider_hooks plugins erl_first_files src_dirs) do
      test "#{key} is a miss", %{tmp_dir: dir} do
        home(dir, "{#{unquote(key)}, [x]}.\n")

        assert {:miss, %{args: [unquote(key)]}} =
                 Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
      end
    end

    test "REBAR_GLOBAL_CONFIG_DIR wins over HOME", %{tmp_dir: dir} do
      home_dir = Path.join(dir, "home")
      other = Path.join(dir, "other")
      home(home_dir, "{hex, []}.\n")
      file = home(other, "{erl_opts, [debug_info]}.\n")
      env = %{"HOME" => home_dir, "REBAR_GLOBAL_CONFIG_DIR" => other}

      assert {:miss, %{text: text}} = Rebar3Config.check(&Map.get(env, &1))
      assert text == "global rebar3 config #{file} sets erl_opts"

      File.rm!(file)
      assert :ok = Rebar3Config.check(&Map.get(env, &1))
    end

    test "REBAR_CONFIG is not the global config: Mix sets it to its own file", %{tmp_dir: dir} do
      other = Path.join(dir, "elsewhere.config")
      File.write!(other, "{erl_opts, [{d, 'X'}]}.\n")
      env = %{"HOME" => dir, "REBAR_CONFIG" => other}

      assert :ok = Rebar3Config.check(&Map.get(env, &1))
    end

    test "an unparsable file is a miss, without a crash", %{tmp_dir: dir} do
      file = home(dir, "{erl_opts, [{d, X\n")

      assert {:miss, reason} = Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
      assert reason.code == :rebar3_global_config
      assert reason.args == ["unreadable"]
      assert reason.text == "global rebar3 config #{file} could not be read"
    end

    test "a config dir that cannot be searched is a miss, not an absent file", %{tmp_dir: dir} do
      home(dir, "{hex, []}.\n")
      cfg = Path.join([dir, ".config", "rebar3"])
      File.chmod!(cfg, 0o000)
      on_exit(fn -> File.chmod(cfg, 0o755) end)

      # Root searches anything: nothing to test there.
      if match?({:error, _}, File.ls(cfg)) do
        assert {:miss, %{code: :rebar3_global_config, args: ["unreadable"], text: text}} =
                 Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))

        assert text ==
                 "global rebar3 config #{Path.join(cfg, "rebar.config")} could not be checked"
      end
    end

    test "a path through a file is an absent config", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".config"), "")
      assert :ok = Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
    end

    test "a term that is not a {key, value} pair is a miss", %{tmp_dir: dir} do
      home(dir, "erl_opts.\n")

      assert {:miss, %{args: ["unreadable"]}} =
               Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))
    end

    test "a rebar.config.script beside it is a miss", %{tmp_dir: dir} do
      file = home(dir, "{hex, []}.\n")
      File.write!(file <> ".script", "CONFIG.\n")

      assert {:miss, %{args: ["script"], text: text}} =
               Rebar3Config.check(&Map.get(%{"HOME" => dir}, &1))

      assert text == "global rebar3 config #{file} has a .script beside it"
    end
  end

  describe "the host check" do
    test "a rebar3 dep misses while the global config sets erl_opts", %{tmp_dir: dir} do
      file = home(dir, "{erl_opts, [{d, 'DEBUG'}]}.\n")
      env = %{"HOME" => dir}

      assert {:miss, "global rebar3 config #{file} sets erl_opts"} ==
               Match.select(doc(@build), ctx(env, manager: "rebar3"))

      assert {:miss, %{code: :rebar3_global_config}} =
               Match.select_reason(
                 doc(Map.put(@build, "manager", "rebar3")),
                 ctx(env, manager: "rebar3")
               )
    end

    test "a rebar3 dep hits without a global config", %{tmp_dir: dir} do
      env = %{"HOME" => dir}
      assert {:ok, _, "pure_elixir"} = Match.select(doc(@build), ctx(env, manager: "rebar3"))
    end

    test "a rebar3 dep hits when REBAR_CONFIG points at a file with erl_opts", %{tmp_dir: dir} do
      other = Path.join(dir, "elsewhere.config")
      File.write!(other, "{erl_opts, [{d, 'DEBUG'}]}.\n")
      env = %{"HOME" => dir, "REBAR_CONFIG" => other}

      assert {:ok, _, _} = Match.select(doc(@build), ctx(env, manager: "rebar3"))
    end

    test "a rebar3 dep misses on an unparsable global config", %{tmp_dir: dir} do
      file = home(dir, "{erl_opts, [")

      assert {:miss, "global rebar3 config #{file} could not be read"} ==
               Match.select(doc(@build), ctx(%{"HOME" => dir}, manager: "rebar3"))
    end

    test "a Mix dep is not affected by the global rebar3 config", %{tmp_dir: dir} do
      home(dir, "{erl_opts, [{d, 'DEBUG'}]}.\n")
      env = %{"HOME" => dir}

      assert {:ok, _, _} = Match.select(doc(@build), ctx(env, manager: "mix"))

      assert {:ok, _, _} =
               Match.select(doc(Map.put(@build, "manager", "mix")), ctx(env, manager: "mix"))
    end
  end
end
