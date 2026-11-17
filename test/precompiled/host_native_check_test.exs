# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HostNativeCheckTest do
  # Host-native builds through a whole run: the opt-in, the batch, the
  # manifest's builds_host_native list, the install. The host's identity
  # comes from the :native_host seam, so the run is the same on any OS.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.{Check, Env}
  alias Precompiled.Fixture, as: F
  @moduletag :tmp_dir

  @x {:hex, :x, "1.0.0", "i", [:mix], [], "hexpm", "XOUTER"}
  @hex String.duplicate("cd", 32)
  @archive "libx-v1.0.0-nif-2.16-aarch64-unknown-linux-gnu.so.tar.gz"
  @libz Path.expand("../fixtures/elf/libz_aarch64.so.1", __DIR__)
  @so File.read!(Path.expand("../fixtures/elf/nif_aarch64.so", __DIR__))

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      configure([])
      System.delete_env("PRECOMPILED_HOME")
    end)

    f = F.new(dir)
    System.put_env("PRECOMPILED_HOME", Path.join(dir, "home"))
    lib = Path.join(dir, "_build/dev/lib")
    deps = Path.join(dir, "deps")
    File.mkdir_p!(Path.join(deps, "x"))
    File.write!(Path.join([deps, "x", "checksum.exs"]), ~s|%{"#{@archive}" => "sha256:#{@hex}"}|)
    roots = Path.join(dir, "roots")
    File.mkdir_p!(roots)
    File.cp!(@libz, Path.join(roots, "libz.so.1"))

    %{
      f: f,
      dir: dir,
      lib: lib,
      host: %{
        triple: "aarch64-linux-gnu",
        system_architecture: "aarch64-unknown-linux-gnu",
        otp_full: otp() <> ".1",
        nif_version: "2.17",
        lib_roots: [roots]
      },
      env: %Env{
        candidates: [%{name: :x, version: "1.0.0", lock_entry: @x}],
        lock: %{x: @x},
        system: nil,
        build_lib: lib,
        deps_path: deps
      }
    }
  end

  defp otp(), do: to_string(:erlang.system_info(:otp_release))

  defp configure(opts) do
    for {k, _} <- Application.get_all_env(:precompiled),
        do: Application.delete_env(:precompiled, k)

    Application.put_all_env([{:precompiled, opts}])
  end

  defp config(c, host_native) do
    configure(source: F.base_url(), root: c.f.root_path, host_native: host_native)
    Precompiled.Config.load()
  end

  defp run(c, config, host \\ nil) do
    opts = [config_fun: fn _, _ -> :error end, native_host: host || c.host]

    out =
      capture_io(:stderr, fn ->
        stdio = capture_io(fn -> send(self(), {:report, Check.check(config, c.env, opts)}) end)
        send(self(), {:stdio, stdio})
      end)

    assert_received {:report, {:ok, report}}
    assert_received {:stdio, stdio}
    {report, stdio <> out}
  end

  defp file(f, path, bytes, mode),
    do: %{
      "path" => path,
      "sha256" => F.file(f, bytes),
      "size" => byte_size(bytes),
      "mode" => mode
    }

  defp entry(f, target, over) do
    app = "{application, x, [{vsn, \"1.0.0\"}, {modules, ['Elixir.X']}]}.\n"

    %{
      "target" => target,
      "ebin" => [
        file(f, "ebin/Elixir.X.beam", "beam x", 33188),
        file(f, "ebin/x.app", app, 33188)
      ],
      "priv" =>
        if(target == "host_native", do: [file(f, "priv/native/libx.so", @so, 33261)], else: []),
      "build" =>
        Map.merge(
          %{
            "elixir" => System.version(),
            "otp" => otp(),
            "dep_env" => "prod",
            "deps" => %{},
            "compile_env" => [],
            "package_checksum" => "XOUTER",
            "run_id" => "r",
            "image_digest" => "d"
          },
          over
        )
    }
  end

  defp host_native(f, over \\ %{}) do
    entry(
      f,
      "host_native",
      Map.merge(
        %{
          "triple" => "aarch64-linux-gnu",
          "libc" => "glibc",
          "otp_full" => otp(),
          "nif_version" => "2.16",
          "mix_target" => "host",
          "compile_inputs" => [],
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
    )
  end

  defp firmware(f), do: entry(f, "nerves_system_rpi4", %{"system_version" => "1.31.0"})

  defp publish(f, version) do
    F.publish(f, %{"x" => %{"versions" => %{"1.0.0" => version}}})
  end

  defp lines(report), do: Enum.map(report.lines, &Map.delete(&1, :seconds))

  test "off: the list is never read and the run is what it was without it", c do
    config = config(c, false)
    publish(c.f, %{"builds" => [firmware(c.f)]})
    {without, out} = run(c, config)
    assert out =~ ~r/x 1\.0\.0\s+MISS\s+not built for host$/m

    publish(c.f, %{"builds" => [firmware(c.f)], "builds_host_native" => [host_native(c.f)]})
    {with, out2} = run(c, config)
    assert lines(with) == lines(without)
    assert String.replace(out2, ~r/[\d.]+ s\b/, "") == String.replace(out, ~r/[\d.]+ s\b/, "")
    refute File.exists?(Path.join(c.lib, "x"))
  end

  test "on: a host-native build installs, priv .so with its mode", c do
    config = config(c, true)
    publish(c.f, %{"builds" => [firmware(c.f)], "builds_host_native" => [host_native(c.f)]})
    {report, out} = run(c, config)
    assert report.hits == 1
    assert out =~ ~r/x 1\.0\.0\s+HIT/
    assert out =~ "host_native aarch64-linux-gnu"

    so = Path.join(c.lib, "x/priv/native/libx.so")
    assert File.read!(so) == @so
    assert Bitwise.band(File.stat!(so).mode, 0o777) == 0o755
    assert File.read!(Path.join(c.lib, "x/ebin/Elixir.X.beam")) == "beam x"
    assert File.exists?(Path.join(c.lib, "x/.mix/compile.elixir_scm"))

    # Rechecked, it stays; with the opt-in turned off it goes, so Mix
    # compiles it from source.
    c = %{c | env: %{c.env | candidates: [], installed: [:x]}}
    {report, _} = run(c, config)
    assert report.fails == 0 and report.misses == 0
    assert File.read!(so) == @so

    {report, out} = run(c, config(c, false))
    assert report.misses == 1
    assert out =~ ~r/x 1\.0\.0\s+MISS\s+not built for host/
    refute File.exists?(Path.join(c.lib, "x"))
  end

  test "on, on a host without a triple: the miss names this machine", c do
    config = config(c, true)
    publish(c.f, %{"builds" => [firmware(c.f)], "builds_host_native" => [host_native(c.f)]})

    host = %{
      c.host
      | triple: nil,
        system_architecture: "aarch64-apple-darwin24.6.0",
        lib_roots: []
    }

    {report, out} = run(c, config, host)
    assert report.misses == 1

    assert out =~
             ~r/x 1\.0\.0\s+MISS\s+built for aarch64-linux-gnu, this machine is aarch64-apple-darwin24\.6\.0/

    assert [%{reason: {:triple_differs, ["aarch64-linux-gnu", "aarch64-apple-darwin24.6.0"]}}] =
             report.lines
  end

  test "on, a Nerves project never reads it", c do
    config = config(c, true)
    publish(c.f, %{"builds" => [], "builds_host_native" => [host_native(c.f)]})
    c = %{c | env: %{c.env | system: {"nerves_system_rpi4", "1.31.0"}, mix_target: "rpi4"}}
    {report, out} = run(c, config)
    assert report.misses == 1
    assert out =~ ~r/x 1\.0\.0\s+MISS\s+not built for 1\.0\.0/
  end

  test "on, an origin the checksum file does not list is a miss", c do
    config = config(c, true)

    origin = %{
      "path" => "priv/native/libx.so",
      "checksum_file" => "checksum.exs",
      "archive" => @archive,
      "archive_sha256" => String.duplicate("0", 64)
    }

    publish(c.f, %{
      "builds" => [],
      "builds_host_native" => [host_native(c.f, %{"origins" => [origin]})]
    })

    {report, out} = run(c, config)
    assert report.misses == 1
    assert out =~ "#{@archive} not in the package's checksum file"
    refute File.exists?(Path.join(c.lib, "x"))
  end

  # A revoked build leaves the manifest: the next run with a fresh batch
  # matches the install again, finds nothing, and removes it, so Mix
  # compiles the dep from source in that same run.
  test "on, an installed host-native build the manifest no longer lists goes", c do
    config = config(c, true)
    publish(c.f, %{"builds" => [firmware(c.f)], "builds_host_native" => [host_native(c.f)]})
    {report, _} = run(c, config)
    assert report.hits == 1

    publish(c.f, %{"builds" => [firmware(c.f)]})
    c = %{c | env: %{c.env | candidates: [], installed: [:x]}}
    {report, out} = run(c, config)
    assert report.misses == 1
    assert out =~ ~r/x 1\.0\.0\s+MISS\s+not built for host/
    refute File.exists?(Path.join(c.lib, "x"))
  end

  # The portal checks both at ingest; the signed manifest is what the
  # client trusts, so a wrong entry (a build filed under another triple, a
  # library its origins leave out) is refused here too, from the bytes.
  test "on, a priv library for another machine is not installed", c do
    config = config(c, true)
    x86 = File.read!(Path.expand("../fixtures/elf/nif_x86_64.so", __DIR__))
    entry = host_native(c.f)
    entry = %{entry | "priv" => [file(c.f, "priv/native/libx.so", x86, 33261)]}
    publish(c.f, %{"builds" => [], "builds_host_native" => [entry]})

    {report, out} = run(c, config)
    assert report.hits == 0
    assert out =~ "priv/native/libx.so is not a 64-bit aarch64-linux-gnu library"
    refute File.exists?(Path.join(c.lib, "x"))
  end

  test "on, a priv library its origins do not name is not installed", c do
    config = config(c, true)
    entry = host_native(c.f)
    extra = file(c.f, "priv/native/libextra.so", @so, 33261)

    publish(c.f, %{
      "builds" => [],
      "builds_host_native" => [%{entry | "priv" => entry["priv"] ++ [extra]}]
    })

    {report, out} = run(c, config)
    assert report.hits == 0
    assert out =~ "priv/native/libextra.so has no checksum-pinned origin"
    refute File.exists?(Path.join(c.lib, "x"))

    # Nor one outside priv, which a beam may load_nif from all the same
    # (staging refuses any file in ebin but beams and the .app).
    ebin = file(c.f, "ebin/libx.so", @so, 33188)

    publish(c.f, %{
      "builds" => [],
      "builds_host_native" => [%{entry | "ebin" => entry["ebin"] ++ [ebin]}]
    })

    {report, out} = run(c, config)
    assert report.hits == 0
    assert out =~ ~s("ebin/libx.so" does not belong in ebin)
    refute File.exists?(Path.join(c.lib, "x"))
  end

  # Staging writes every file by its path, whichever list names it: a priv
  # path under `ebin` lands in priv all the same, so it is read back too.
  test "on, a priv library listed under ebin is read back as well", c do
    config = config(c, true)
    entry = host_native(c.f)
    extra = file(c.f, "priv/native/libextra.so", @so, 33261)

    publish(c.f, %{
      "builds" => [],
      "builds_host_native" => [%{entry | "ebin" => entry["ebin"] ++ [extra]}]
    })

    {report, out} = run(c, config)
    assert report.hits == 0
    assert out =~ "priv/native/libextra.so has no checksum-pinned origin"
    refute File.exists?(Path.join(c.lib, "x"))
  end

  # A relocatable object or an executable is no library a NIF loads: the
  # portal takes only ET_DYN, and so does the read-back.
  test "on, an origin-named priv ELF that is no shared library is not installed", c do
    config = config(c, true)
    rel = File.read!(Path.expand("../fixtures/elf/rel_aarch64.o", __DIR__))
    <<head::binary-16, _type::little-16, rest::binary>> = @so
    exec = <<head::binary, 2::little-16, rest::binary>>

    for bytes <- [rel, exec] do
      entry = host_native(c.f)
      entry = %{entry | "priv" => [file(c.f, "priv/native/libx.so", bytes, 33261)]}
      publish(c.f, %{"builds" => [], "builds_host_native" => [entry]})

      {report, out} = run(c, config)
      assert report.hits == 0
      assert out =~ "priv/native/libx.so is not a 64-bit aarch64-linux-gnu library"
      refute File.exists?(Path.join(c.lib, "x"))
    end
  end

  # The worker publishes no host-native pass without its env reads (the
  # TARGET_* overrides, a force-build variable): one without the list could
  # have dropped them, and this client would take it whatever its env says.
  test "on, a host-native build without compile_inputs misses", c do
    config = config(c, true)
    entry = host_native(c.f)
    entry = %{entry | "build" => Map.delete(entry["build"], "compile_inputs")}
    publish(c.f, %{"builds" => [], "builds_host_native" => [entry]})

    {report, out} = run(c, config)
    assert report.hits == 0
    assert out =~ ~r/x 1\.0\.0\s+MISS\s+build predates compile inputs/
    refute File.exists?(Path.join(c.lib, "x"))
  end

  test "a regular hit still wins with the opt-in on", c do
    config = config(c, true)
    pure = entry(c.f, "pure_elixir", %{})
    publish(c.f, %{"builds" => [pure], "builds_host_native" => [host_native(c.f)]})
    {report, _out} = run(c, config)
    assert report.hits == 1
    refute File.exists?(Path.join(c.lib, "x/priv"))
  end
end
