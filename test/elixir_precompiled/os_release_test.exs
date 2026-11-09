# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.OsReleaseTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.OsRelease

  @moduletag :tmp_dir

  # Verbatim from nerves_system_rpi4 2.2.1's /usr/lib/os-release.
  @rpi4 """
  NAME=Nerves
  ID=nerves
  NERVES_SYSTEM_BR_VERSION=1.35.3
  NERVES_SYSTEM_NAME=nerves_system_rpi4
  NERVES_SYSTEM_VERSION=2.2.1
  NERVES_BUILDROOT_VERSION=2026.08.1
  """

  test "the Nerves system from os-release", %{tmp_dir: dir} do
    path = Path.join(dir, "os-release")
    File.write!(path, @rpi4)
    assert OsRelease.system([path]) == {"nerves_system_rpi4", "2.2.1"}
  end

  test "quotes, comments and a later path", %{tmp_dir: dir} do
    path = Path.join(dir, "b")

    File.write!(
      path,
      "# c\nNERVES_SYSTEM_NAME=\"nerves_system_qemu_aarch64\"\nNERVES_SYSTEM_VERSION=\"0.5.1\"\n"
    )

    assert OsRelease.system([Path.join(dir, "missing"), path]) ==
             {"nerves_system_qemu_aarch64", "0.5.1"}
  end

  test "a plain Linux os-release, an empty name and no file give nil", %{tmp_dir: dir} do
    path = Path.join(dir, "debian")
    File.write!(path, "NAME=Debian\nID=debian\n")
    assert OsRelease.system([path]) == nil
    File.write!(path, "NERVES_SYSTEM_NAME=\nNERVES_SYSTEM_VERSION=1\n")
    assert OsRelease.system([path]) == nil
    assert OsRelease.system([Path.join(dir, "none")]) == nil
  end

  test "parse keeps every key, without quotes" do
    assert OsRelease.parse(@rpi4)["NERVES_BUILDROOT_VERSION"] == "2026.08.1"
    assert OsRelease.parse("# x\n\nA=\"b c\"\nnoequals\n") == %{"A" => "b c"}
  end
end
