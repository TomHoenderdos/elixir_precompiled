# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.CLITest do
  use ExUnit.Case, async: true

  alias ChainTest.CLI

  test "missing --target raises with a usage line" do
    assert_raise Mix.Error, ~r/usage: mix chain_test --target/, fn ->
      CLI.main(["--device", "dev.local"])
    end
  end

  test "missing --device raises with a usage line" do
    assert_raise Mix.Error, ~r/usage: mix chain_test --target/, fn ->
      CLI.main(["--target", "rpi4"])
    end
  end

  test "an unsupported target is refused" do
    assert_raise Mix.Error, ~r/rpi4, rpi0_2/, fn ->
      CLI.main(["--target", "bbb", "--device", "dev.local"])
    end
  end

  test "an unknown switch is refused" do
    assert_raise Mix.Error, ~r/usage:/, fn ->
      CLI.main(["--target", "rpi4", "--device", "d", "--accept-new"])
    end
  end

  test "parse!/1 fills the defaults" do
    opts = CLI.parse!(["--target", "rpi0_2", "--device", "dev.local"])

    assert opts.target == "rpi0_2"
    assert opts.device == "dev.local"
    assert opts.known_hosts == Path.expand("~/.config/chain_test/known_hosts")
    assert opts.source == "https://compatibility.nerves-project.org/api/precompiled"
    assert opts.target_config == Path.expand("~/.config/chain_test/target.exs")
    assert Path.dirname(opts.report_dir) == Path.expand(System.tmp_dir!())
    assert Path.basename(opts.report_dir) =~ ~r/\Achain_test-\d{8}T\d{6}Z\z/
    assert opts.fixture_dir == Path.expand("../../fixture", __DIR__)
  end

  test "parse!/1 takes the overrides" do
    opts =
      CLI.parse!([
        "--target",
        "rpi4",
        "--device",
        "d",
        "--known-hosts",
        "/k",
        "--source",
        "http://127.0.0.1:1/api/precompiled/",
        "--report-dir",
        "/r",
        "--target-config",
        "/t.exs"
      ])

    assert opts.known_hosts == "/k"
    assert opts.source == "http://127.0.0.1:1/api/precompiled"
    assert opts.report_dir == "/r"
    assert opts.target_config == "/t.exs"
  end
end
