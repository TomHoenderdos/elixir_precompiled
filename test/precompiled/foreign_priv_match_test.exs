# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ForeignPrivMatchTest do
  # Foreign priv builds (0.8.0): a version's `foreign_priv` lists, read only
  # after the regular lists missed, with a known rule and V1-V4 on a build
  # that has entries, and kino's own entry-less builds matched as regular.
  use ExUnit.Case, async: true

  alias Precompiled.{ForeignPriv, Match}

  @kino {:hex, :kino, "0.19.1", "i", [:mix], [], "hexpm", "KOUTER"}
  @writer {:hex, :kino_vega_lite, "0.1.13", "i", [:mix],
           [{:kino, "~> 0.19", [hex: :kino, repo: "hexpm", optional: false]}], "hexpm", "WOUTER"}
  @h "uxwh53kfq2wszgf23hqwgkuiza"

  defp entry(over \\ %{}),
    do:
      Map.merge(
        %{
          "app" => "kino",
          "path" => "priv/assets/Kino_VegaLite/#{@h}.tar.gz",
          "sha256" => String.duplicate("a", 64),
          "size" => 10,
          "mode" => 33_188
        },
        over
      )

  defp writer_build(over \\ %{}, build_over \\ %{}) do
    Map.merge(
      %{
        "target" => "pure_elixir",
        "ebin" => [
          %{
            "path" => "ebin/Elixir.Kino.VegaLite.beam",
            "sha256" => String.duplicate("b", 64),
            "size" => 1,
            "mode" => 33_188
          },
          %{
            "path" => "ebin/kino_vega_lite.app",
            "sha256" => String.duplicate("c", 64),
            "size" => 1,
            "mode" => 33_188
          }
        ],
        "priv" => [],
        "foreign_priv" => [entry()],
        "build" =>
          Map.merge(
            %{
              "elixir" => "1.20.3",
              "otp" => "29",
              "system_version" => nil,
              "run_id" => "r",
              "image_digest" => "d",
              "deps" => %{"kino" => %{"version" => "0.19.1", "checksum" => "KOUTER"}},
              "compile_env" => [],
              "package_checksum" => "WOUTER",
              "dep_env" => "prod",
              "foreign_priv_rule" => "kino_js_v1"
            },
            build_over
          )
      },
      over
    )
  end

  defp doc(version_map), do: %{"format" => 2, "versions" => %{"0.1.13" => version_map}}

  # The Match ctx, as match_test.exs's ctx/1 builds it, on a machine whose
  # ERL_COMPILER_OPTIONS is unset.
  defp ctx(over \\ %{}) do
    Map.merge(
      %{
        name: "kino_vega_lite",
        version: "0.1.13",
        lock_entry: @writer,
        lock: %{kino: @kino, kino_vega_lite: @writer},
        system: {"host", ""},
        elixir: "1.20.3",
        otp: "29",
        dep_env: "prod",
        config: fn _app, _path -> :error end,
        machine_env: fn _ -> nil end,
        elixir_compiler_options: fn -> :undefined end
      },
      over
    )
  end

  test "a foreign build is taken after the regular lists missed" do
    assert {:ok, build, "pure_elixir"} =
             Match.select_reason(
               doc(%{"builds" => [], "foreign_priv" => %{"builds" => [writer_build()]}}),
               ctx()
             )

    assert ForeignPriv.entries(build) == [entry()]
  end

  test "builds_with_inputs of a foreign_priv object are read too" do
    m =
      doc(%{
        "builds" => [],
        "foreign_priv" => %{"builds" => [], "builds_with_inputs" => [writer_build()]}
      })

    assert {:ok, _, "pure_elixir"} = Match.select_reason(m, ctx())
  end

  test "a regular hit wins; a foreign build is never read from a regular list's place" do
    plain = writer_build(%{"foreign_priv" => nil}, %{"foreign_priv_rule" => nil})
    m = doc(%{"builds" => [plain], "foreign_priv" => %{"builds" => [writer_build()]}})
    assert {:ok, ^plain, _} = Match.select_reason(m, ctx())
  end

  test "deterministic mode reads deterministic.foreign_priv only" do
    det =
      ctx(%{
        machine_env: fn
          "ERL_COMPILER_OPTIONS" -> "deterministic"
          _ -> nil
        end
      })

    sibling = writer_build(%{}, %{"erl_compiler_options" => ["deterministic"]})

    m =
      doc(%{
        "builds" => [],
        "foreign_priv" => %{"builds" => [sibling]},
        "deterministic" => %{"builds" => []}
      })

    assert {:miss, _} = Match.select_reason(m, det)

    m =
      doc(%{
        "builds" => [],
        "deterministic" => %{"builds" => [], "foreign_priv" => %{"builds" => [sibling]}}
      })

    assert {:ok, ^sibling, _} = Match.select_reason(m, det)
    assert {:miss, _} = Match.select_reason(m, ctx())
  end

  test "builds_closure is read only with an env closure" do
    m =
      doc(%{
        "builds" => [],
        "foreign_priv" => %{"builds" => [], "builds_closure" => [writer_build()]}
      })

    assert {:miss, %{code: :not_built_version}} = Match.select_reason(m, ctx())
    assert {:ok, _, _} = Match.select_reason(m, ctx(%{env_closure: [:kino]}))
  end

  test "an unknown rule misses with its own code" do
    m =
      doc(%{
        "builds" => [],
        "foreign_priv" => %{
          "builds" => [writer_build(%{}, %{"foreign_priv_rule" => "kino_js_v9"})]
        }
      })

    assert {:miss, %{code: :foreign_priv_rule_unknown, args: ["kino", "kino_js_v9"]}} =
             Match.select_reason(m, ctx())

    m =
      doc(%{
        "builds" => [],
        "foreign_priv" => %{"builds" => [writer_build(%{}, %{"foreign_priv_rule" => nil})]}
      })

    assert {:miss, %{code: :foreign_priv_rule_unknown}} = Match.select_reason(m, ctx())
  end

  test "V1 to V4: another app, a bad path or mode, a dir no ebin module has, too many or too big" do
    a = String.duplicate("a", 26)

    for bad <- [
          [entry(%{"app" => "kino_db"})],
          [entry(%{"path" => "priv/assets/Kino_VegaLite/x.tar.gz"})],
          [entry(%{"path" => "priv/assets/../ebin/#{a}.tar.gz"})],
          [entry(%{"path" => "priv/assets/Kino_VegaLite/#{a}.tar.gz/"})],
          [entry(%{"mode" => 0o755})],
          [entry(%{"sha256" => "A" <> String.duplicate("a", 63)})],
          [entry(%{"size" => -1})],
          [entry(%{"path" => "priv/assets/Kino_Other/#{a}.tar.gz"})],
          [entry(), entry(%{"path" => "priv/assets/Kino_VegaLite/#{a}.tar.gz"})],
          List.duplicate(entry(), 65),
          [entry(%{"size" => 10 * 1024 * 1024 + 1})],
          [Map.delete(entry(), "mode")],
          ["not a map"]
        ] do
      m =
        doc(%{
          "builds" => [],
          "foreign_priv" => %{"builds" => [writer_build(%{"foreign_priv" => bad})]}
        })

      assert {:miss, %{code: :malformed_entry}} = Match.select_reason(m, ctx()),
             inspect(Enum.take(bad, 1))
    end
  end

  test "both archive modes the portal may write pass V2" do
    for mode <- [0o644, 0o100644] do
      m =
        doc(%{
          "builds" => [],
          "foreign_priv" => %{
            "builds" => [writer_build(%{"foreign_priv" => [entry(%{"mode" => mode})]})]
          }
        })

      assert {:ok, _, _} = Match.select_reason(m, ctx())
    end
  end

  # Plan Ruling 2: kino's own 0b build has no entries and no rule.
  test "a foreign-list build without entries is matched by the regular rules alone" do
    kino_build =
      writer_build(
        %{
          "foreign_priv" => nil,
          "ebin" => [
            %{
              "path" => "ebin/kino.app",
              "sha256" => String.duplicate("c", 64),
              "size" => 1,
              "mode" => 33_188
            }
          ]
        },
        %{
          "foreign_priv_rule" => nil,
          "foreign_priv_target" => "kino",
          "deps" => %{},
          "package_checksum" => "KOUTER"
        }
      )

    m = %{
      "format" => 2,
      "versions" => %{
        "0.19.1" => %{"builds" => [], "foreign_priv" => %{"builds" => [kino_build]}}
      }
    }

    assert {:ok, ^kino_build, _} =
             Match.select_reason(m, ctx(%{name: "kino", version: "0.19.1", lock_entry: @kino}))

    # ... and by them alone: one that fails a regular rule still misses.
    m =
      put_in(m, ["versions", "0.19.1", "foreign_priv", "builds"], [
        put_in(kino_build, ["build", "otp"], "28")
      ])

    assert {:miss, %{code: :toolchain_otp}} =
             Match.select_reason(m, ctx(%{name: "kino", version: "0.19.1", lock_entry: @kino}))
  end

  # The portal never lists one there; Phase A would install it without
  # placing a single archive.
  test "a regular-list build with foreign entries, or a non-list foreign_priv, is malformed" do
    m = doc(%{"builds" => [writer_build()]})
    assert {:miss, %{code: :malformed_entry}} = Match.select_reason(m, ctx())

    m = doc(%{"builds" => [], "builds_with_inputs" => [writer_build(%{"foreign_priv" => "x"})]})
    assert {:miss, %{code: :malformed_entry}} = Match.select_reason(m, ctx())

    m =
      doc(%{
        "builds" => [],
        "foreign_priv" => %{"builds" => [writer_build(%{"foreign_priv" => "x"})]}
      })

    assert {:miss, %{code: :malformed_entry}} = Match.select_reason(m, ctx())
  end

  test "a regular miss that is not not_built stands over a foreign one" do
    plain = writer_build(%{"foreign_priv" => nil}, %{"foreign_priv_rule" => nil, "otp" => "28"})

    m =
      doc(%{
        "builds" => [plain],
        "foreign_priv" => %{"builds" => [writer_build(%{}, %{"elixir" => "1.19.5"})]}
      })

    assert {:miss, %{code: :toolchain_otp}} = Match.select_reason(m, ctx())
  end

  # Review Focus 3.
  test "a writer built against another kino misses on the lock" do
    other = {:hex, :kino, "0.18.2", "i", [:mix], [], "hexpm", "K18"}
    m = doc(%{"builds" => [], "foreign_priv" => %{"builds" => [writer_build()]}})

    assert {:miss, %{code: code}} =
             Match.select_reason(m, ctx(%{lock: %{kino: other, kino_vega_lite: @writer}}))

    assert code in [:closure_mismatch, :closure_checksum]

    other = {:hex, :kino, "0.19.1", "i", [:mix], [], "hexpm", "KOTHER"}

    assert {:miss, %{code: :closure_checksum}} =
             Match.select_reason(m, ctx(%{lock: %{kino: other, kino_vega_lite: @writer}}))
  end

  test "files_hash covers the foreign entries, and an entry without them hashes as before" do
    plain = writer_build(%{"foreign_priv" => nil})
    assert Match.files_hash(plain) == Match.files_hash(Map.delete(plain, "foreign_priv"))
    assert Match.files_hash(plain) == Match.files_hash(Map.put(plain, "foreign_priv", []))
    refute Match.files_hash(writer_build()) == Match.files_hash(plain)

    refute Match.files_hash(writer_build()) ==
             Match.files_hash(
               writer_build(%{
                 "foreign_priv" => [entry(%{"sha256" => String.duplicate("d", 64)})]
               })
             )
  end

  test "dir_name/1 and dir/1" do
    assert ForeignPriv.dir_name("Elixir.Kino.VegaLite") == "Kino_VegaLite"
    assert ForeignPriv.dir_name("Elixir.KinoVegaLite.ChartCell") == "KinoVegaLite_ChartCell"
    assert ForeignPriv.dir_name("kino_vega_lite") == nil
    assert ForeignPriv.dir_name("Elixir.") == nil
    assert ForeignPriv.dir(entry()) == "Kino_VegaLite"
    assert ForeignPriv.target() == :kino
    assert ForeignPriv.rules() == ["kino_js_v1"]
    assert ForeignPriv.max_entries() == 64
    assert ForeignPriv.max_bytes() == 10_485_760
  end
end
