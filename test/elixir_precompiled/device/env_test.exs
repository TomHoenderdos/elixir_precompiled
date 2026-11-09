# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Device.EnvTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.Device.Env

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    os = Path.join(dir, "os-release")
    File.write!(os, "NERVES_SYSTEM_NAME=nerves_system_rpi4\nNERVES_SYSTEM_VERSION=2.2.1\n")
    mounts = Path.join(dir, "mounts")

    File.write!(
      mounts,
      "/dev/root / squashfs ro,relatime 0 0\n/dev/mmcblk0p7 /root f2fs rw,nodev,relatime 0 0\n"
    )

    lib = Path.join(dir, "lib")
    # :ssh is an atom in every VM; a release that ships it without starting it.
    for d <- ["ssh-5.2.4", "logger-1.20.3", "not_an_app", "zz_never_an_atom_qq-1.0.0"],
        do: File.mkdir_p!(Path.join(lib, d))

    opts = [
      os_release_paths: [os],
      mounts_path: mounts,
      kv: fn -> %{"nerves_fw_platform" => "rpi4", "nerves_fw_architecture" => "aarch64"} end,
      loaded: [{:logger, ~c"logger", ~c"1.20.4"}, {:kernel, ~c"k", ~c"10.4"}],
      lib_dir: lib,
      otp: "29",
      elixir: "1.20.3",
      cpu: "aarch64-unknown-linux-gnu"
    ]

    %{opts: opts}
  end

  test "collects every fact from its source", %{opts: opts} do
    env = Env.load(opts)
    assert env.system == {"nerves_system_rpi4", "2.2.1"}
    assert {env.platform, env.arch} == {"rpi4", "aarch64"}
    assert {env.otp, env.elixir, env.cpu} == {"29", "1.20.3", "aarch64-unknown-linux-gnu"}
    assert {"/root", ["rw", "nodev", "relatime"]} in env.mounts
  end

  test "present apps: loaded ones at their loaded version, release lib dirs for the rest (Q1)",
       %{opts: opts} do
    env = Env.load(opts)
    assert env.present[:logger] == %{vsn: "1.20.4", loaded?: true}
    assert env.present[:kernel] == %{vsn: "10.4", loaded?: true}
    assert env.present[:ssh] == %{vsn: "5.2.4", loaded?: false}
    refute Map.has_key?(env.present, :not_an_app)
    assert Enum.all?(Map.keys(env.present), &is_atom/1)
    assert map_size(env.present) == 3
  end

  test "a host without Nerves files and without KV: system and platform nil", %{
    opts: opts,
    tmp_dir: dir
  } do
    env =
      Env.load(
        Keyword.merge(opts,
          os_release_paths: [Path.join(dir, "x")],
          kv: fn -> nil end,
          lib_dir: Path.join(dir, "nolib")
        )
      )

    assert env.system == nil
    assert env.platform == nil
    assert env.present[:logger].vsn == "1.20.4"
  end

  test "a lib dir splits at the first dash before a digit: pre-releases, dashed names, OTP vsns",
       %{opts: opts, tmp_dir: dir} do
    lib = Path.join(dir, "lib2")

    for d <- ["crypto-6.0.0-rc.1", "ex_unit-1.20.3-dev", "ssl-11.7.8.1", "eex-x.y"],
        do: File.mkdir_p!(Path.join(lib, d))

    env = Env.load(Keyword.merge(opts, loaded: [], lib_dir: lib))
    assert env.present[:crypto] == %{vsn: "6.0.0-rc.1", loaded?: false}
    assert env.present[:ex_unit] == %{vsn: "1.20.3-dev", loaded?: false}
    assert env.present[:ssl] == %{vsn: "11.7.8.1", loaded?: false}
    refute Map.has_key?(env.present, :eex)
  end

  test "a missing mounts file gives no mounts", %{opts: opts, tmp_dir: dir} do
    assert Env.load(Keyword.put(opts, :mounts_path, Path.join(dir, "nomounts"))).mounts == []
  end
end
