# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.SnapshotLayer1Test do
  use ExUnit.Case, async: true

  alias ChainTest.Snapshot

  @moduletag :tmp_dir

  defp info(v2), do: %{manifests: %{}, manifests_v2: v2}
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp snap(dir, previous, old \\ {:missing, "none kept"}) do
    %{
      dir: dir,
      sequence: 9,
      info: info(%{"jason" => "j9", "ash" => "a9", "plug" => "p9"}),
      deps: %{
        "jason" => %{builds: 1, manifest: "v2/manifests/jason.json"},
        "ash" => %{builds: 1, manifest: "v2/manifests/ash.json"},
        "plug" => %{builds: 0, manifest: "v2/manifests/plug.json"}
      },
      previous: previous,
      old: old
    }
  end

  defp older(seq, v2, manifests \\ %{}),
    do: {:ok, %{sequence: seq, path: "batches/#{seq}.json", info: info(v2), manifests: manifests}}

  describe "recheck/1 and :previous_differs (R16)" do
    test "a held dep N-1 names another manifest for differs, one it names none for is unnamed",
         %{tmp_dir: dir} do
      # ash: none; plug: another one, but the snapshot holds no build of it.
      s = snap(dir, older(8, %{"jason" => "j8", "plug" => "p8"}))
      assert Snapshot.recheck(s) == %{"jason" => :differs, "ash" => :unnamed}
      assert Snapshot.available(s, :previous_differs) == :ok
    end

    test "N-1 naming N's manifests for every held dep: missing, not testable",
         %{tmp_dir: dir} do
      s = snap(dir, older(8, %{"jason" => "j9", "ash" => "a9", "plug" => "p8"}))
      assert Snapshot.recheck(s) == %{}
      assert {:missing, why} = Snapshot.available(s, :previous_differs)
      assert why =~ "same manifest"
    end

    test "no previous batch: the previous batch's kind passes through", %{tmp_dir: dir} do
      for kind <- [:missing, :unavailable, :invalid] do
        s = snap(dir, {kind, "why"})
        assert Snapshot.recheck(s) == %{}
        assert {^kind, why} = Snapshot.available(s, :previous_differs)
        assert why =~ "previous batch"
      end
    end
  end

  describe ":older_manifest_bytes (M3)" do
    test "an older batch's other manifest without its bytes is missing, naming it",
         %{tmp_dir: dir} do
      s = snap(dir, older(8, %{}, %{"jason" => %{dir: "v2/manifests", sha256: sha("old")}}))
      assert Snapshot.older_manifests(s) == []
      assert {:missing, why} = Snapshot.available(s, :older_manifest_bytes)
      assert why =~ "jason (batch 8)"
      assert why =~ "serves only the current batch's"
    end

    test "no older manifest that differs at all is missing too", %{tmp_dir: dir} do
      s = snap(dir, older(8, %{}), older(3, %{}))
      assert {:missing, why} = Snapshot.available(s, :older_manifest_bytes)
      assert why =~ "names a fixture manifest batch 9 does not"
    end

    test "a stored older manifest that hashes to its name is available", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "older_manifests"))
      File.write!(Path.join(dir, "older_manifests/#{sha("old")}.json"), "old")
      File.write!(Path.join(dir, "older_manifests/#{sha("bad")}.json"), "not bad")

      manifests = %{
        "jason" => %{dir: "v2/manifests", sha256: sha("old")},
        "ash" => %{dir: "v2/manifests", sha256: sha("bad")}
      }

      s = snap(dir, older(8, %{}, manifests))
      assert Snapshot.older_manifests(s) == [{"jason", "older_manifests/#{sha("old")}.json"}]
      assert Snapshot.available(s, :older_manifest_bytes) == :ok
    end

    test "an older batch that is unavailable or invalid outranks missing bytes",
         %{tmp_dir: dir} do
      assert {:unavailable, _} =
               Snapshot.available(snap(dir, {:unavailable, "503"}), :older_manifest_bytes)

      assert {:invalid, _} =
               Snapshot.available(
                 snap(dir, {:unavailable, "503"}, {:invalid, "bad sig"}),
                 :older_manifest_bytes
               )
    end

    test "both needs are known names" do
      assert :previous_differs in Snapshot.need_names()
      assert :older_manifest_bytes in Snapshot.need_names()
    end
  end
end
