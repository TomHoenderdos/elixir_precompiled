# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.RelocatedMatchTest do
  # Relocated builds (0.9.0): a version's `relocated` lists, read only after
  # the regular, host-native and foreign lists missed, taken only on OTP 28
  # or later and with this project's paths its own real paths.
  use ExUnit.Case, async: true

  alias Precompiled.Match

  @fine {:hex, :fine, "0.2.0", "i", [:mix], [], "hexpm", "FOUTER"}
  @slots %{"deps" => "/home/u/app/deps", "build" => "/home/u/app/_build/dev"}

  defp record(kind \\ "binary") do
    %{
      "deps" => "/work/proj/deps",
      "build" => "/work/proj/_build/host",
      "files" => [
        %{
          "path" => "ebin/Elixir.Fine.beam",
          "occurrences" => [
            %{
              "chunk" => "LitT",
              "index" => 0,
              "term" => [],
              "kind" => kind,
              "parts" => ["", "deps", "/fine/c_include"]
            }
          ]
        }
      ]
    }
  end

  defp relocated_build(over \\ %{}) do
    Map.merge(
      %{
        "target" => "pure_elixir",
        "ebin" => [
          %{
            "path" => "ebin/Elixir.Fine.beam",
            "sha256" => String.duplicate("b", 64),
            "size" => 1,
            "mode" => 33_188
          },
          %{
            "path" => "ebin/fine.app",
            "sha256" => String.duplicate("c", 64),
            "size" => 1,
            "mode" => 33_188
          }
        ],
        "priv" => [],
        "relocation" => record(),
        "build" => %{
          "elixir" => "1.20.3",
          "otp" => "29",
          "system_version" => nil,
          "run_id" => "r",
          "image_digest" => "d",
          "deps" => %{},
          "compile_env" => [],
          "package_checksum" => "FOUTER",
          "dep_env" => "prod"
        }
      },
      over
    )
  end

  defp doc(version_map), do: %{"format" => 2, "versions" => %{"0.2.0" => version_map}}

  defp only_relocated(build \\ relocated_build()),
    do: doc(%{"builds" => [], "relocated" => %{"builds" => [build]}})

  defp ctx(over \\ %{}) do
    Map.merge(
      %{
        name: "fine",
        version: "0.2.0",
        lock_entry: @fine,
        lock: %{fine: @fine},
        system: {"host", ""},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end,
        machine_env: fn _ -> nil end,
        elixir_compiler_options: fn -> :undefined end,
        relocate: @slots
      },
      over
    )
  end

  test "a relocated build is taken after the other lists missed" do
    assert {:ok, build, "pure_elixir"} = Match.select_reason(only_relocated(), ctx())
    assert build["relocation"] == record()
  end

  test "builds_with_inputs of a relocated object are read too" do
    m =
      doc(%{
        "builds" => [],
        "relocated" => %{"builds" => [], "builds_with_inputs" => [relocated_build()]}
      })

    assert {:ok, _, "pure_elixir"} = Match.select_reason(m, ctx())
  end

  test "a regular hit wins" do
    plain = Map.delete(relocated_build(), "relocation")
    m = doc(%{"builds" => [plain], "relocated" => %{"builds" => [relocated_build()]}})
    assert {:ok, ^plain, _} = Match.select_reason(m, ctx())
  end

  test "no slots (a symlinked path, a device, Windows): relocated_paths" do
    assert {:miss, %{code: :relocated_paths}} =
             Match.select_reason(only_relocated(), ctx(%{relocate: nil}))
  end

  test "OTP before 28 never takes one: relocated_otp" do
    build = put_in(relocated_build()["build"]["otp"], "27")

    assert {:miss, %{code: :relocated_otp}} =
             Match.select_reason(only_relocated(build), ctx(%{otp: "27"}))
  end

  test "a charlist occurrence needs ASCII paths" do
    build = relocated_build(%{"relocation" => record("charlist")})
    assert {:ok, _, _} = Match.select_reason(only_relocated(build), ctx())

    utf8 = %{"deps" => "/home/jøn/app/deps", "build" => "/home/jøn/app/_build/dev"}

    assert {:miss, %{code: :relocated_paths}} =
             Match.select_reason(only_relocated(build), ctx(%{relocate: utf8}))
  end

  test "a record naming a file the entry does not ship is refused" do
    bad = put_in(record(), ["files", Access.at(0), "path"], "ebin/Elixir.Other.beam")

    assert {:miss, %{code: :relocation_refused}} =
             Match.select_reason(only_relocated(relocated_build(%{"relocation" => bad})), ctx())
  end

  test "deterministic mode reads no relocated list" do
    det =
      ctx(%{
        machine_env: fn
          "ERL_COMPILER_OPTIONS" -> "deterministic"
          _ -> nil
        end
      })

    m =
      doc(%{
        "builds" => [],
        "relocated" => %{"builds" => [relocated_build()]},
        "deterministic" => %{"builds" => []}
      })

    assert {:miss, reason} = Match.select_reason(m, det)
    refute reason.code in [:relocated_paths, :relocated_otp, :relocation_refused]
  end

  test "files_hash covers the record: another record is another build" do
    plain = Map.delete(relocated_build(), "relocation")
    a = relocated_build()
    b = relocated_build(%{"relocation" => put_in(record(), ["deps"], "/other/deps")})
    assert Match.files_hash(a) != Match.files_hash(plain)
    assert Match.files_hash(a) != Match.files_hash(b)
    assert Match.files_hash(a) == Match.files_hash(relocated_build())
  end
end
