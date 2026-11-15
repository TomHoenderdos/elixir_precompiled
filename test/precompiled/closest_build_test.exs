# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ClosestBuildTest do
  use ExUnit.Case, async: true
  alias Precompiled.{Match, Reason}

  @spark {:hex, :spark, "2.7.8", "inner", [:mix], [], "hexpm", "SPARKOUTER"}
  @decimal {:hex, :decimal, "2.3.0", "inner", [:mix], [], "hexpm", "DECOUTER"}
  @ash {:hex, :ash, "3.5.2", "inner", [:mix],
        [
          {:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]},
          {:decimal, "~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}
        ], "hexpm", "ASHOUTER"}
  @plain {:hex, :ash, "3.5.2", "inner", [:mix],
          [{:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]}], "hexpm",
          "ASHOUTER"}
  @lock %{spark: @spark, ash: @ash, decimal: @decimal}

  @spark_dep %{"spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"}}
  @decimal_dep %{"decimal" => %{"version" => "2.3.0", "checksum" => "DECOUTER"}}

  defp ctx(over \\ []) do
    Map.merge(
      %{
        name: "ash",
        version: "3.5.2",
        lock_entry: @ash,
        lock: @lock,
        system: {"nerves_system_rpi4", "1.31.0"},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end,
        env_closure: [:decimal, :spark]
      },
      Map.new(over)
    )
  end

  defp build(over \\ %{}) do
    Map.merge(
      %{
        "elixir" => "1.20.3",
        "otp" => "29",
        "dep_env" => "prod",
        "system_version" => nil,
        "run_id" => "r",
        "deps" => Map.merge(@spark_dep, @decimal_dep),
        "compile_env" => [],
        "package_checksum" => "ASHOUTER"
      },
      over
    )
  end

  defp entry(target, b) do
    %{
      "target" => target,
      "ebin" => [
        %{
          "path" => "ebin/Elixir.Ash.beam",
          "sha256" => String.duplicate("a", 64),
          "size" => 1,
          "mode" => 33188
        }
      ],
      "priv" => [],
      "build" => b
    }
  end

  defp pe(b), do: entry("pure_elixir", b)
  defp short(e), do: binary_part(Match.files_hash(e), 0, 12)

  defp doc(builds, closure \\ []),
    do: %{
      "format" => 2,
      "versions" => %{"3.5.2" => %{"builds" => builds, "builds_closure" => closure}}
    }

  describe "a miss names the closest build" do
    test "its short hash, variant and toolchain, with code, args and text unchanged" do
      e = pe(build(%{"elixir" => "1.19.4"}))
      {:miss, r} = Match.select_reason(doc([e]), ctx())

      assert %Reason{code: :toolchain_elixir, args: ["1.19.4", "1.20.3"]} = r
      assert r.text == "built with Elixir 1.19.4, running 1.20.3"
      assert r.closest == "#{short(e)}: with, Elixir 1.19.4/OTP 29"
      assert Match.select(doc([e]), ctx()) == {:miss, r.text}
    end

    test "a build without the optional dep is the without variant, with its closure difference" do
      e = pe(build(%{"deps" => @spark_dep}))
      {:miss, r} = Match.select_reason(doc([e]), ctx())

      assert r.code == :closure_without
      assert r.closest == "#{short(e)}: without, Elixir 1.20.3/OTP 29, closure -decimal"
    end

    test "a build with a dep Mix leaves out here shows it as +" do
      e = pe(build())
      {:miss, r} = Match.select_reason(doc([e]), ctx(env_closure: [:spark]))

      assert r.code == :closure_env_absent
      assert r.closest =~ "closure +decimal"
    end

    test "a world build is named by its world" do
      e = pe(build(%{"variant" => "world_phx", "otp" => "28"}))
      {:miss, r} = Match.select_reason(doc([], [e]), ctx())

      assert r.code == :toolchain_otp
      assert r.closest == "#{short(e)}: world_phx, Elixir 1.20.3/OTP 28"
    end

    test "a system build names its system and release" do
      e = entry("nerves_system_rpi4", build(%{"system_version" => "1.31.0", "otp" => "28"}))
      {:miss, r} = Match.select_reason(doc([e]), ctx())

      assert r.closest == "#{short(e)}: with, Elixir 1.20.3/OTP 28, nerves_system_rpi4 1.31.0"
    end

    test "the build that passed the most rules is the one named" do
      far = pe(build(%{"elixir" => "1.18.0"}))
      near = pe(build(%{"otp" => "28"}) |> Map.put("run_id", "near"))
      near = put_in(near, ["ebin", Access.at(0), "sha256"], String.duplicate("b", 64))
      {:miss, r} = Match.select_reason(doc([far, near]), ctx())

      assert r.code == :toolchain_otp
      assert String.starts_with?(r.closest, short(near) <> ":")
    end

    test "a package without optional deps has no variant" do
      e = pe(build(%{"deps" => @spark_dep, "otp" => "28"}))

      {:miss, r} =
        Match.select_reason(doc([e]), ctx(lock_entry: @plain, env_closure: [:spark]))

      assert r.closest == "#{short(e)}: Elixir 1.20.3/OTP 28"
    end

    test "with no env closure the lock decides the difference" do
      e = pe(build(%{"deps" => @spark_dep}))
      {:miss, r} = Match.select_reason(doc([e]), ctx(env_closure: nil))

      assert r.code == :closure_without
      assert r.closest =~ "closure -decimal"
    end

    test "no build for this version or system names none" do
      assert {:miss, %Reason{code: :not_built_version, closest: nil}} =
               Match.select_reason(doc([]), ctx(version: "9.9.9"))

      e = entry("nerves_system_bbb", build())

      assert {:miss, %Reason{code: :not_built_target, closest: nil}} =
               Match.select_reason(doc([e]), ctx())
    end

    test "manifest strings outside the argument charset print as ?" do
      e = pe(build(%{"variant" => "x y/../z", "elixir" => "1.19\n4"}))
      {:miss, r} = Match.select_reason(doc([], [e]), ctx())

      assert r.closest == "#{short(e)}: ?, Elixir ?/OTP 29"
    end

    test "env values are never printed" do
      secret = "s3cr3t-value"

      e =
        pe(
          build(%{
            "compile_inputs" => %{"env" => %{"MY_FLAG" => secret}},
            "otp" => "28"
          })
        )

      {:miss, r} =
        Match.select_reason(doc([e]), ctx(getenv: fn _ -> secret end))

      refute r.text =~ secret
      refute r.closest =~ secret
      refute r.closest =~ "MY_FLAG"
    end
  end

  describe "describe/2" do
    test "names the build a hit installs" do
      e = pe(build())
      assert Match.describe(e, ctx()) == "#{short(e)}: with, Elixir 1.20.3/OTP 29"
    end

    test "a malformed build is still named, never a crash" do
      assert Match.describe(%{"target" => 1, "build" => "x", "ebin" => 3}, ctx()) == "?"
      assert is_binary(Match.describe(%{"build" => %{"deps" => [1], "elixir" => 1}}, ctx()))
    end
  end
end
