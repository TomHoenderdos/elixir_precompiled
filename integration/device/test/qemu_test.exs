# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule DeviceQemuTest do
  use ExUnit.Case, async: false
  @moduletag :qemu
  @moduletag timeout: 1_800_000

  # ssh -p 10022 to the qemu guest; nerves_ssh evaluates the command as Elixir.
  defp dev(expr), do: DeviceQemu.dev!(expr)

  # The inspected value of `expr` on the guest, one line, nothing else.
  defp value(expr), do: DeviceQemu.value!(expr)

  setup_all do
    on_exit(&DeviceQemu.stop!/0)
    DeviceQemu.boot!(offline: false, fresh: true)
    :ok
  end

  test "the release has no Mix, and the device layer is on it" do
    assert dev("IO.inspect(:code.which(Mix))") =~ ":non_existing"
    assert dev("IO.inspect(Code.ensure_loaded?(Precompiled))") =~ "true"
    assert value("Application.get_all_env(:elixir_precompiled)") == "[]"
    # DEVICE_TEST_MODE=embedded for a firmware built with EMBEDDED=1.
    mode = System.get_env("DEVICE_TEST_MODE", "interactive")
    assert dev("IO.inspect(:code.get_mode())") =~ ":#{mode}"
  end

  test "recon (pure_elixir) installs and runs" do
    DeviceQemu.wait_online!()

    assert dev("IO.inspect(Precompiled.install(:recon))") =~
             "{:ok, [%Precompiled.Installed{app: :recon"

    assert dev("IO.inspect(:recon.info(self(), :memory))") =~ "{:memory,"
  end

  test "circuits_gpio (NIF, system build) installs and its NIF is loaded" do
    DeviceQemu.wait_online!()
    out = dev("IO.inspect(Precompiled.install({:circuits_gpio, \"2.3.1\"}))")
    assert out =~ "target: \"nerves_system_qemu_aarch64\""
    assert dev("IO.inspect(Circuits.GPIO.backend_info())") =~ "name: Circuits.GPIO.CDev"
  end

  test "dry run against production writes a report and installs nothing (production smoke)" do
    DeviceQemu.wait_online!()

    assert dev(
             "IO.inspect(Precompiled.install(:telemetry, dry_run: true, report: \"/data/report.json\"))"
           ) =~ "%Precompiled.Plan{"

    assert dev("IO.inspect(File.exists?(\"/data/report.json\"))") =~ "true"
    assert dev("IO.inspect(File.exists?(\"/data/precompiled/telemetry-1.3.0\"))") =~ "false"
  end

  test "negatives: already present, noexec /data, clock unsynchronized" do
    assert dev("IO.inspect(Precompiled.install(:nerves_runtime))") =~
             "{:error, {:already_present, :nerves_runtime,"

    # Active and cached apps never reach the noexec check: take circuits_gpio
    # out of the VM and the store first.
    assert value("Precompiled.uninstall(:circuits_gpio, force: true, remove: true)") == ":ok"

    dev(":os.cmd(~c\"mount -o remount,noexec /root\")")

    try do
      assert dev("IO.inspect(Precompiled.install({:circuits_gpio, \"2.3.1\"}))") =~
               "{:error, {:noexec, \"/root\"}}"
    after
      dev(":os.cmd(~c\"mount -o remount,exec /root\")")
    end

    # The clock seam is refused unless test_seams is set on the guest.
    assert dev("IO.inspect(Precompiled.install(:recon, clock_synchronized?: fn -> false end))") =~
             "{:error, {:bad_option, :clock_synchronized?}}"

    assert dev(
             "Application.put_env(:elixir_precompiled, :test_seams, true); " <>
               "r = Precompiled.install(:recon, clock_synchronized?: fn -> false end); " <>
               "Application.delete_env(:elixir_precompiled, :test_seams); IO.inspect(r)"
           ) =~ "{:error, {:clock_unsynchronized,"

    # Back on an exec mount, the same install goes through.
    DeviceQemu.wait_online!()

    assert dev("IO.inspect(Precompiled.install({:circuits_gpio, \"2.3.1\"}))") =~
             "{:ok, [%Precompiled.Installed{app: :circuits_gpio"
  end

  test "reboot: nothing loads at boot; installing again loads from the cache without downloading" do
    # recon is still loaded from the first install: nothing to do.
    assert value("Precompiled.install(:recon)") == "{:ok, []}"
    assert value("Precompiled.uninstall(:circuits_gpio, force: true)") == ":ok"
    DeviceQemu.reboot!()
    assert value(":code.which(:recon)") == ":non_existing"
    assert value(":code.which(Circuits.GPIO)") == ":non_existing"

    # circuits_gpio stays cached on /data, unloaded, although nothing in
    # this VM has named the app since the reboot.
    assert value("Enum.sort(Enum.map(Precompiled.list(), &{&1.app, &1.loaded?}))") ==
             "[circuits_gpio: false, recon: false]"

    assert value(~s|File.dir?("/data/precompiled/circuits_gpio-2.3.1")|) == "true"

    DeviceQemu.wait_online!()
    out = dev("IO.inspect(Precompiled.install(:recon))")
    assert out =~ "from_cache?: true"
    assert out =~ "(1 from cache)"
    assert dev("IO.inspect(:recon.info(self(), :memory))") =~ "{:memory,"
  end

  test "a cached file changed on /data is replaced by a fresh download" do
    DeviceQemu.wait_online!()
    DeviceQemu.reboot!()

    dev(
      ~s|[b \| _] = Path.wildcard("/data/precompiled/recon-*/ebin/*.beam"); File.write!(b, "evil")|
    )

    DeviceQemu.wait_online!()
    assert dev("IO.inspect(Precompiled.install(:recon))") =~ "from_cache?: false"
    assert dev("IO.inspect(:recon.info(self(), :memory))") =~ "{:memory,"
  end

  test "clean/0 empties the cache except what is loaded" do
    # circuits_gpio is cached and not loaded since the reboot; recon is loaded.
    assert value(~s|File.dir?("/data/precompiled/circuits_gpio-2.3.1")|) == "true"

    assert value("with {:ok, r} <- Precompiled.clean(), do: {r.removed, r.kept}") ==
             "{[:circuits_gpio], [:recon]}"

    assert value("Enum.sort(Enum.map(Precompiled.list(), &{&1.app, &1.loaded?}))") ==
             "[recon: true]"

    assert value(~s|Path.wildcard("/data/precompiled/circuits_gpio-*")|) == "[]"
  end

  test "offline: a bundle on /data with the network down, and a tampered file" do
    bundle = DeviceQemu.make_bundle!(["recon"])
    DeviceQemu.reboot!(offline: true)
    # Nothing is loaded after the reboot: clean/0 empties the cache, so the
    # bundle install below cannot be a cache hit.
    dev("Precompiled.clean()")
    DeviceQemu.copy_dir!(bundle, "/data/bundle")

    # Restarted without a network, the guest restores its clock from a file
    # but NTP never confirms it: an online install refuses before any request.
    assert dev("IO.inspect(Precompiled.install(:recon))") =~ "{:error, {:clock_unsynchronized"

    out = dev("IO.inspect(Precompiled.install(:recon, source: \"file:///data/bundle\"))")
    assert out =~ "{:ok, [%Precompiled.Installed{app: :recon"
    assert out =~ "from_cache?: false"

    # remove: true, or the next install is a cache hit that never reads the
    # tampered file.
    dev("Precompiled.uninstall(:recon, force: true, remove: true)")
    DeviceQemu.tamper_one_file!("/data/bundle")

    assert dev("IO.inspect(Precompiled.install(:recon, source: \"file:///data/bundle\"))") =~
             "{:error, {:fetch, \"recon\", \"sha256 mismatch"
  end
end
