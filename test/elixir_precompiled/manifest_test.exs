# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.ManifestTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.Manifest

  @entry %{"ebin" => [], "priv" => [], "build" => %{"elixir" => "1.20.3", "otp" => "29"}}

  test "format 1 becomes a build list with the key as target and dep_env prod" do
    {:ok, m} =
      Manifest.normalize(%{
        "versions" => %{"1.0.0" => %{"pure_elixir" => @entry, "nerves_system_rpi4" => @entry}}
      })

    assert m["format"] == 2
    builds = m["versions"]["1.0.0"]["builds"]

    assert Enum.map(builds, & &1["target"]) |> Enum.sort() == [
             "nerves_system_rpi4",
             "pure_elixir"
           ]

    assert Enum.all?(builds, &(&1["build"]["dep_env"] == "prod"))
  end

  test "format 2 passes through and keeps its dep_env" do
    doc = %{
      "format" => 2,
      "versions" => %{
        "1.0.0" => %{
          "builds" => [
            Map.put(@entry, "target", "pure_elixir") |> put_in(["build", "dep_env"], "dev")
          ]
        }
      }
    }

    assert {:ok, ^doc} = Manifest.normalize(doc)
  end

  test "a newer format is refused" do
    assert {:fail, "manifest format 3 not supported"} =
             Manifest.normalize(%{"format" => 3, "versions" => %{}})
  end

  test "garbage is refused" do
    assert {:fail, "manifest malformed"} = Manifest.normalize(%{"versions" => "nope"})

    assert {:fail, "manifest malformed"} =
             Manifest.normalize(%{
               "format" => 2,
               "versions" => %{"1.0.0" => %{"builds" => "nope"}}
             })
  end

  test "a format-1 entry whose build is not a map passes through for Match to judge" do
    {:ok, m} =
      Manifest.normalize(%{"versions" => %{"1.0.0" => %{"pure_elixir" => %{"build" => "x"}}}})

    assert [%{"target" => "pure_elixir", "build" => "x"}] = m["versions"]["1.0.0"]["builds"]
  end
end
