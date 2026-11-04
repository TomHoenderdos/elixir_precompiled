# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.SetupTest do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Setup
  alias ChainTest.{Signed, Trust}

  @moduletag :tmp_dir

  test "valid?/1 takes a module with setup/3 and args it accepts" do
    assert Setup.valid?({ChainTest.TestSetup, %{files: %{}}})
    refute Setup.valid?({ChainTest.TestSetup, %{other: 1}})
    refute Setup.valid?({ChainTest.TestSetup, %{needs: [:newer]}})
    refute Setup.valid?({ChainTest.TestSetup, %{case: %{}}})
    refute Setup.valid?({String, %{}})
    refute Setup.valid?({ChainTest.TestSetup, []})
    refute Setup.valid?(ChainTest.TestSetup)
  end

  test "needs/1 is the module's, else none" do
    assert Setup.needs({ChainTest.TestSetup, %{needs: [:previous]}}) == [:previous]
    assert Setup.needs({ChainTest.TestSetup, %{}}) == []
  end

  test "run/3 passes the home, the snapshot and the args through", %{tmp_dir: tmp} do
    snap = %{case: %{source: "http://127.0.0.1:9", root: Trust.library_root_path()}}

    assert :ok =
             Setup.run({ChainTest.TestSetup, %{files: %{"files/x" => "y"}}}, tmp, snap)

    assert File.read!(Path.join(tmp, "files/x")) == "y"
  end

  test "run/3 turns an error, a raise or a bad answer into {:error, why}", %{tmp_dir: tmp} do
    assert {:error, "nope"} = Setup.run({ChainTest.TestSetup, %{fail: "nope"}}, tmp, %{})
    assert {:error, why} = Setup.run({ChainTest.TestSetup, %{raise: "boom"}}, tmp, %{})
    assert why =~ "boom"
  end

  test "state_dir/3 names the client's state dir: source and the root's first root key",
       %{tmp_dir: tmp} do
    key = Signed.key()
    root = Path.join(tmp, "root.json")
    File.write!(root, Signed.root(key))

    hash =
      :crypto.hash(:sha256, "http://127.0.0.1:9|" <> Signed.keyid(key))
      |> Base.encode16(case: :lower)

    expected = Path.join(tmp, binary_part(hash, 0, 16))
    assert Setup.state_dir(tmp, "http://127.0.0.1:9", root) == {:ok, expected}
    # The client trims a trailing slash off its source.
    assert Setup.state_dir(tmp, "http://127.0.0.1:9/", root) == {:ok, expected}
    assert {:error, _} = Setup.state_dir(tmp, "http://127.0.0.1:9", Path.join(tmp, "absent"))
  end
end
