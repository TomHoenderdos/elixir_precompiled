# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HostNativeMatchTest do
  use ExUnit.Case, async: true
  alias Precompiled.{Match, Reason}
  @moduletag :tmp_dir

  @spark {:hex, :spark, "2.7.8", "inner", [:mix], [], "hexpm", "SPARKOUTER"}
  @x {:hex, :x, "1.0.0", "inner", [:mix],
      [{:spark, "~> 2.7", [hex: :spark, repo: "hexpm", optional: false]}], "hexpm", "XOUTER"}
  @lock %{spark: @spark, x: @x}
  @hex String.duplicate("ab", 32)
  @archive "libx-v1.0.0-nif-2.16-aarch64-unknown-linux-gnu.so.tar.gz"
  @libz Path.expand("../fixtures/elf/libz_aarch64.so.1", __DIR__)

  setup %{tmp_dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)
    File.cp!(@libz, Path.join(lib, "libz.so.1"))
    deps = Path.join(dir, "deps")
    File.mkdir_p!(Path.join(deps, "x"))
    File.write!(Path.join([deps, "x", "checksum.exs"]), ~s|%{"#{@archive}" => "sha256:#{@hex}"}|)
    %{lib: lib, deps: deps}
  end

  defp host(c, over \\ %{}) do
    Map.merge(
      %{
        triple: "aarch64-linux-gnu",
        system_architecture: "aarch64-unknown-linux-gnu",
        otp_full: "28.1.1",
        nif_version: "2.17",
        lib_roots: [c.lib],
        deps_path: c.deps
      },
      Map.new(over)
    )
  end

  defp ctx(c, over \\ []) do
    Map.merge(
      %{
        name: "x",
        version: "1.0.0",
        lock_entry: @x,
        lock: @lock,
        system: {"host", ""},
        elixir: "1.20.3",
        otp: "28",
        dep_env: "prod",
        config: fn _app, _path -> :error end,
        host_native: host(c)
      },
      Map.new(over)
    )
  end

  defp hn(over \\ %{}) do
    build =
      Map.merge(
        %{
          "triple" => "aarch64-linux-gnu",
          "libc" => "glibc",
          "elixir" => "1.20.3",
          "otp" => "28",
          "otp_full" => "28.1",
          "nif_version" => "2.17",
          "dep_env" => "prod",
          "mix_target" => "host",
          "deps" => %{"spark" => %{"version" => "2.7.8", "checksum" => "SPARKOUTER"}},
          "compile_env" => [],
          "package_checksum" => "XOUTER",
          "run_id" => "r1",
          "image_digest" => "d",
          "native" => true,
          "elf" => %{"needs" => %{"libz.so.1" => ["ZLIB_1.2.9"]}},
          "origins" => [
            %{
              "path" => "priv/native/libx.so",
              "checksum_file" => "checksum.exs",
              "archive" => @archive,
              "archive_sha256" => @hex
            }
          ]
        },
        over
      )

    %{
      "target" => "host_native",
      "ebin" => [
        %{
          "path" => "ebin/x.app",
          "sha256" => String.duplicate("a", 64),
          "size" => 1,
          "mode" => 33188
        }
      ],
      "priv" => [
        %{
          "path" => "priv/native/libx.so",
          "sha256" => String.duplicate("b", 64),
          "size" => 1,
          "mode" => 33261
        }
      ],
      "build" => build
    }
  end

  defp doc(builds, host_native),
    do: %{
      "format" => 2,
      "versions" => %{"1.0.0" => %{"builds" => builds, "builds_host_native" => host_native}}
    }

  defp firmware(),
    do: %{
      "target" => "nerves_system_rpi4",
      "ebin" => [],
      "priv" => [],
      "build" => hn()["build"] |> Map.put("system_version", "1.31.0")
    }

  defp pure(over \\ %{}),
    do: %{
      "target" => "pure_elixir",
      "ebin" => [],
      "priv" => [],
      "build" => Map.merge(hn()["build"], over)
    }

  defp miss_code(c, builds, entries, over \\ []) do
    assert {:miss, %Reason{code: code} = r} =
             Match.select_reason(doc(builds, entries), ctx(c, over))

    {code, r}
  end

  test "a host-native build hits when every rule holds", c do
    assert {:ok, %{"target" => "host_native"}, "host_native"} =
             Match.select_reason(doc([firmware()], [hn()]), ctx(c))
  end

  test "without the opt-in the list is never read", c do
    ctx = c |> ctx() |> Map.delete(:host_native)
    assert {:miss, r} = Match.select_reason(doc([firmware()], [hn()]), ctx)
    assert r.code == :not_built_target
    assert r.text == "not built for host"

    assert {:miss, %Reason{code: :not_built_version}} =
             Match.select_reason(doc([], [hn()]), ctx)

    assert {:miss, %Reason{code: :not_built_target}} =
             Match.select_reason(doc([firmware()], [hn()]), ctx(c, host_native: nil))
  end

  test "a Nerves system never reads it", c do
    ctx = ctx(c, system: {"nerves_system_rpi4", "1.30.0"})

    assert {:miss, %Reason{code: :not_built_target}} =
             Match.select_reason(doc([firmware()], [hn()]), ctx)
  end

  test "a regular hit wins over a host-native one", c do
    assert {:ok, %{"target" => "pure_elixir"}, "pure_elixir"} =
             Match.select_reason(doc([pure()], [hn()]), ctx(c))
  end

  test "a regular miss that is not about the target keeps its own reason", c do
    {code, _} =
      miss_code(c, [pure(%{"package_checksum" => "OTHER"})], [hn(%{"elixir" => "1.19.0"})])

    assert code == :checksum_differs
  end

  test "another triple, libc or target is triple_differs", c do
    {code, r} = miss_code(c, [firmware()], [hn(%{"triple" => "x86_64-linux-gnu"})])
    assert code == :triple_differs
    assert r.args == ["x86_64-linux-gnu", "aarch64-linux-gnu"]
    assert r.text == "built for x86_64-linux-gnu, this machine is aarch64-linux-gnu"
    assert r.closest =~ "host_native x86_64-linux-gnu"

    assert {:triple_differs, %{args: ["musl", _]}} =
             miss_code(c, [], [hn(%{"libc" => "musl"})])

    assert {:triple_differs, _} = miss_code(c, [], [hn(%{"libc" => nil})])
    assert {:triple_differs, _} = miss_code(c, [], [hn() |> Map.put("target", "host")])
  end

  test "a musl or darwin host has no triple and misses every entry", c do
    for arch <- ["x86_64-alpine-linux-musl", "aarch64-apple-darwin24.6.0"] do
      over = [host_native: host(c, triple: nil, system_architecture: arch, lib_roots: [])]
      {code, r} = miss_code(c, [firmware()], [hn()], over)
      assert code == :triple_differs
      assert r.args == ["aarch64-linux-gnu", arch]
    end
  end

  test "the rules of any host build apply", c do
    assert {:toolchain_elixir, _} = miss_code(c, [], [hn(%{"elixir" => "1.19.5"})])
    assert {:dep_env_differs, _} = miss_code(c, [], [hn(%{"dep_env" => "dev"})])
    assert {:checksum_differs, _} = miss_code(c, [], [hn(%{"package_checksum" => "NO"})])
    assert {:closure_without, _} = miss_code(c, [], [hn(%{"deps" => %{}})])

    assert {:closure_checksum, _} =
             miss_code(c, [], [
               hn(%{"deps" => %{"spark" => %{"version" => "2.7.8", "checksum" => "NO"}}})
             ])

    item = %{
      "app" => "x",
      "path" => ["k"],
      "value" => Base.url_encode64(:erlang.term_to_binary(1), padding: false)
    }

    assert {:compile_env_differs, _} = miss_code(c, [], [hn(%{"compile_env" => [item]})])
  end

  test "OTP: the major must equal, the full version must be no newer", c do
    assert {:toolchain_otp, _} = miss_code(c, [], [hn(%{"otp" => "27", "otp_full" => "27.3"})])

    {code, r} = miss_code(c, [], [hn(%{"otp_full" => "28.2"})])
    assert code == :toolchain_otp_minor
    assert r.args == ["28.2", "28.1.1"]

    assert {:ok, _, _} = Match.select_reason(doc([], [hn(%{"otp_full" => "28.1.1"})]), ctx(c))
    assert {:ok, _, _} = Match.select_reason(doc([], [hn(%{"otp_full" => "28"})]), ctx(c))
    assert {:malformed_entry, _} = miss_code(c, [], [hn(%{"otp_full" => nil})])
  end

  test "a NIF version newer than this VM's", c do
    {code, r} = miss_code(c, [], [hn(%{"nif_version" => "2.18"})])
    assert code == :nif_version_newer
    assert r.text == "built for NIF 2.18, this VM has 2.17"
    assert {:malformed_entry, _} = miss_code(c, [], [hn(%{"nif_version" => nil})])
  end

  test "every needed library and symbol version must be here", c do
    {code, r} = miss_code(c, [], [hn(%{"elf" => %{"needs" => %{"libssl.so.3" => []}}})])
    assert code == :needed_lib_missing
    assert r.args == ["libssl.so.3"]

    {code, r} = miss_code(c, [], [hn(%{"elf" => %{"needs" => %{"libz.so.1" => ["ZLIB_9.9"]}}})])
    assert code == :symbol_version_missing
    assert r.args == ["libz.so.1", "ZLIB_9.9"]

    assert {:ok, _, _} =
             Match.select_reason(doc([], [hn(%{"elf" => %{"needs" => %{}}})]), ctx(c))

    assert {:malformed_entry, _} = miss_code(c, [], [hn(%{"elf" => nil})])
    assert {:malformed_entry, _} = miss_code(c, [], [hn(%{"native" => false})])
  end

  test "a library of another machine does not count", c do
    over = [
      host_native: host(c, triple: "x86_64-linux-gnu", system_architecture: "x86_64-pc-linux-gnu")
    ]

    assert {:needed_lib_missing, _} =
             miss_code(c, [], [hn(%{"triple" => "x86_64-linux-gnu"})], over)
  end

  test "every origin's archive must be in the package's checksum file", c do
    assert {:ok, _, _} = Match.select_reason(doc([], [hn()]), ctx(c))
    assert {:origin_unverified, _} = miss_code(c, [], [hn(%{"origins" => []})])

    bad = [%{hd(hn()["build"]["origins"]) | "archive_sha256" => String.duplicate("0", 64)}]
    assert {:origin_unverified, r} = miss_code(c, [], [hn(%{"origins" => bad})])
    assert r.text == "#{@archive} not in the package's checksum file"

    File.write!(Path.join([c.deps, "x", "checksum.exs"]), ~s|Code.eval_string("1")|)
    assert {:origin_unverified, _} = miss_code(c, [], [hn()])

    File.rm!(Path.join([c.deps, "x", "checksum.exs"]))
    assert {:origin_unverified, _} = miss_code(c, [], [hn()])
  end

  test "of several passing builds the newest run wins; the closest miss explains", c do
    old = hn(%{"run_id" => "r1"})
    new = hn(%{"run_id" => "r2"})

    assert {:ok, %{"build" => %{"run_id" => "r2"}}, _} =
             Match.select_reason(doc([], [old, new]), ctx(c))

    {code, _} =
      miss_code(c, [firmware()], [
        hn(%{"triple" => "x86_64-linux-gnu"}),
        hn(%{"nif_version" => "9.0"})
      ])

    assert code == :nif_version_newer
  end

  test "an entry that is not a map is malformed, the others still serve", c do
    assert {:ok, _, _} = Match.select_reason(doc([], ["nope", 1, hn()]), ctx(c))
    assert {:malformed_entry, _} = miss_code(c, [], ["nope"])
  end
end
