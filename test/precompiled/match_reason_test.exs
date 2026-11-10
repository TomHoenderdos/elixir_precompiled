# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.MatchReasonTest do
  use ExUnit.Case, async: true
  alias Precompiled.{Match, Reason}

  @spark {:hex, :spark, "2.7.8", "inner", [:mix], [], "hexpm", "SPARKOUTER"}
  @ash {:hex, :ash, "3.5.2", "inner", [:mix],
        [{:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]}], "hexpm", "ASHOUTER"}
  @lock %{spark: @spark, ash: @ash}

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
        config: fn _app, _path -> :error end
      },
      Map.new(over)
    )
  end

  defp build(over) do
    Map.merge(
      %{
        "elixir" => "1.20.3",
        "otp" => "29",
        "dep_env" => "prod",
        "system_version" => "1.31.0",
        "run_id" => "r",
        "deps" => %{"spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"}},
        "compile_env" => [],
        "package_checksum" => "ASHOUTER"
      },
      Map.new(over, fn {k, v} -> {Atom.to_string(k), v} end)
    )
  end

  defp doc(target, b),
    do: %{
      "versions" => %{
        "3.5.2" => %{
          "builds" => [%{"target" => target, "ebin" => [], "priv" => [], "build" => b}]
        }
      }
    }

  defp rpi4(over \\ []), do: doc("nerves_system_rpi4", build(over))

  @value Base.url_encode64(:erlang.term_to_binary(:on), padding: false)

  for {label, manifest, ctx_over, code, args} <- [
        {"version not built", quote(do: rpi4()), [version: "9.9.9"], :not_built_version,
         ["9.9.9"]},
        {"only other systems", quote(do: doc("nerves_system_bbb", build([]))), [],
         :not_built_target, ["nerves_system_rpi4", "1.31.0"]},
        {"other system version", quote(do: rpi4(system_version: "1.30.0")), [], :not_built_target,
         ["nerves_system_rpi4", "1.31.0"]},
        {"build method unknown", quote(do: rpi4()), [build_method_unknown: "boom at /home/me/x"],
         :build_method_unknown, []},
        {"override", quote(do: rpi4()), [overrides: [:manager]], :build_method_override,
         ["manager"]},
        {"manager differs", quote(do: rpi4(manager: "rebar3")), [manager: "make"],
         :build_method_mismatch, ["rebar3", "make"]},
        {"manager unknown", quote(do: rpi4(manager: "rebar3")), [], :build_method_mismatch,
         ["rebar3", "unknown"]},
        {"unscannable", quote(do: rpi4()), [reads: {:unscannable, "file /x/y.ex over 2 MB"}],
         :rule8_unscannable, []},
        {"reads env", quote(do: rpi4()), [reads: %{env: ["SECRET_DIR"]}], :rule8_env, []},
        {"reads target", quote(do: rpi4()), [reads: %{target: true}, mix_target: "rpi5"],
         :rule8_target, ["rpi4", "rpi5"]},
        {"no toolchain", quote(do: rpi4(elixir: nil, otp: nil)), [], :build_predates,
         ["toolchain"]},
        {"elixir", quote(do: rpi4()), [elixir: "1.20.1"], :toolchain_elixir,
         ["1.20.3", "1.20.1"]},
        {"otp", quote(do: rpi4()), [otp: "28"], :toolchain_otp, ["29", "28"]},
        {"no dep_env", quote(do: rpi4(dep_env: nil)), [], :build_predates, ["dep_env"]},
        {"dep_env", quote(do: rpi4()), [dep_env: "dev"], :dep_env_differs, ["prod", "dev"]},
        {"no checksum", quote(do: rpi4(package_checksum: nil)), [], :build_predates,
         ["package_checksum"]},
        {"checksum", quote(do: rpi4(package_checksum: "OTHER")), [], :checksum_differs, []},
        {"no deps", quote(do: rpi4(deps: nil)), [], :build_predates, ["deps"]},
        {"dep version",
         quote(do: rpi4(deps: %{"spark" => %{"version" => "2.7.7", "checksum" => "SPARKOUTER"}})),
         [], :closure_mismatch, ["spark", "2.7.7", "2.7.8"]},
        {"dep checksum",
         quote(do: rpi4(deps: %{"spark" => %{"version" => "2.7.8", "checksum" => "X"}})), [],
         :closure_checksum, ["spark", "2.7.8"]},
        {"dep not in lock",
         quote(
           do:
             rpi4(
               deps: %{
                 "spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"},
                 "zzz_absent_dep" => %{"version" => "1.0.0", "checksum" => "Z"}
               }
             )
         ), [], :closure_absent, ["zzz_absent_dep", "1.0.0"]},
        {"declared dep missing", quote(do: rpi4(deps: %{})), [], :closure_without,
         ["spark", "2.7.8"]},
        {"no compile_env", quote(do: rpi4(compile_env: nil)), [], :build_predates,
         ["compile_env"]},
        {"compile_env",
         quote(do: rpi4(compile_env: [%{"app" => "ash", "path" => ["x"], "value" => @value}])),
         [], :compile_env_differs, ["ash"]},
        {"malformed", quote(do: rpi4(deps: ["not a pair"])), [], :malformed_entry, []}
      ] do
    test "#{label} has code #{code}" do
      manifest = unquote(manifest)
      ctx = ctx(unquote(Macro.escape(ctx_over)))

      assert {:miss, %Reason{code: unquote(code), args: unquote(args)} = r} =
               Match.select_reason(manifest, ctx)

      # The printed text is unchanged: select/2 gives the same reason's text.
      assert {:miss, text} = Match.select(manifest, ctx)
      assert text == r.text
    end
  end

  test "the paths a reason prints never reach its args" do
    {:miss, r} = Match.select_reason(rpi4(), ctx(build_method_unknown: "boom at /home/me/x"))
    assert r.text =~ "/home/me/x"
    refute Enum.any?(r.args, &(&1 =~ "/"))
  end

  test "a hit is unchanged" do
    assert {:ok, %{"target" => "nerves_system_rpi4"}, "nerves_system_rpi4"} =
             Match.select_reason(rpi4(), ctx())
  end
end
