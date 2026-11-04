# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Layer1SetupsTest do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Setup
  alias ChainTest.Conformance.Setup.{PlantRoot, State}
  alias ChainTest.Trust

  @moduletag :tmp_dir

  @a "http://127.0.0.1:4101"
  @b "http://127.0.0.1:4102"

  defp snap(mirrors \\ [@a, @b]),
    do: %{sequence: 1020, case: %{source: @a, root: Trust.library_root_path(), mirrors: mirrors}}

  defp state(home, source) do
    {:ok, dir} = Setup.state_dir(home, source, Trust.library_root_path())
    File.read(Path.join(dir, "state"))
  end

  describe "State" do
    test "writes the snapshot's sequence as the case source's state", %{tmp_dir: home} do
      assert Setup.run({State, %{sequence: :snapshot}}, home, snap()) == :ok
      assert state(home, @a) == {:ok, "1020"}
      assert state(home, @b) == {:error, :enoent}
    end

    test "below: n writes a sequence n lower, never below 0", %{tmp_dir: home} do
      assert Setup.run({State, %{sequence: {:below, 40}}}, home, snap()) == :ok
      assert state(home, @a) == {:ok, "980"}

      assert Setup.run({State, %{sequence: {:below, 40}}}, home, %{snap() | sequence: 7}) == :ok
      assert state(home, @a) == {:ok, "0"}
    end

    test "corrupt writes a state the client cannot parse", %{tmp_dir: home} do
      assert Setup.run({State, %{sequence: :corrupt}}, home, snap()) == :ok
      assert {:ok, bytes} = state(home, @a)
      assert Integer.parse(String.trim(bytes)) == :error
    end

    test "source: :second writes the second mirror's state, not the case source's",
         %{tmp_dir: home} do
      assert Setup.run({State, %{sequence: :snapshot, source: :second}}, home, snap()) == :ok
      assert state(home, @b) == {:ok, "1020"}
      assert state(home, @a) == {:error, :enoent}

      assert {:error, why} =
               Setup.run({State, %{sequence: :snapshot, source: :second}}, home, snap([@a]))

      assert why =~ "second mirror"
    end

    test "args" do
      for sequence <- [:snapshot, :corrupt, {:below, 40}],
          do: assert(Setup.valid?({State, %{sequence: sequence}}))

      assert Setup.valid?({State, %{sequence: :snapshot, source: :second}})
      refute Setup.valid?({State, %{sequence: {:below, -1}}})
      refute Setup.valid?({State, %{sequence: 5}})
      refute Setup.valid?({State, %{sequence: :snapshot, source: :other}})
      refute Setup.valid?({State, %{sequence: :snapshot, extra: 1}})
      refute Setup.valid?({State, %{}})
    end
  end

  describe "PlantRoot" do
    test "writes an attacker's self-signed root at path under the home", %{tmp_dir: home} do
      assert Setup.run({PlantRoot, %{path: "attacker/root.json"}}, home, snap()) == :ok
      bytes = File.read!(Path.join(home, "attacker/root.json"))
      %{"payload" => p, "signatures" => [%{"keyid" => kid}]} = JSON.decode!(bytes)
      root = JSON.decode!(Base.url_decode64!(p, padding: false))
      assert root["roles"]["root"]["keyids"] == [kid]
      # Not the shipped root: the state dir it would name differs.
      refute Setup.state_dir(home, @a, Path.join(home, "attacker/root.json")) ==
               Setup.state_dir(home, @a, Trust.library_root_path())
    end

    test "args: a relative path inside the home" do
      assert Setup.valid?({PlantRoot, %{path: "attacker/root.json"}})
      refute Setup.valid?({PlantRoot, %{path: "/tmp/root.json"}})
      refute Setup.valid?({PlantRoot, %{path: "../root.json"}})
      refute Setup.valid?({PlantRoot, %{path: "a/../../root.json"}})
      refute Setup.valid?({PlantRoot, %{path: ""}})
      refute Setup.valid?({PlantRoot, %{}})
    end
  end
end
