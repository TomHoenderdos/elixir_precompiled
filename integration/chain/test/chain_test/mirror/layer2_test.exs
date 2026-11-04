# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Layer2Test do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Setup
  alias ChainTest.Conformance.Setup.AdoptedRoot
  alias ChainTest.{Layer2Fixture, Synthetic, TestKey}
  alias ChainTest.Mirror.{Forge, TestBatch, Transform}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    snap = Layer2Fixture.snapshot(tmp)
    {:ok, l2} = TestKey.prepare(snap, Layer2Fixture.fixture_dir(tmp))
    on_exit(fn -> TestKey.cleanup(l2) end)
    batch = File.read!(Path.join(l2.snapshot.dir, "batch.json"))
    %{snap: snap, l2: l2, s: l2.snapshot, batch: batch}
  end

  defp args(s, args), do: Map.put(args, :case, %{mirror: 1, second_url: nil, snapshot: s})

  defp decode(envelope) do
    %{"payload" => p, "signatures" => sigs} = JSON.decode!(envelope)
    {JSON.decode!(Base.url_decode64!(p, padding: false)), Enum.map(sigs, & &1["keyid"])}
  end

  defp root_keyids(path, role) do
    %{"payload" => p} = JSON.decode!(File.read!(path))
    JSON.decode!(Base.url_decode64!(p, padding: false))["roles"][role]["keyids"]
  end

  defp instant(s), do: s |> DateTime.from_iso8601() |> elem(1)

  describe "TestBatch" do
    test "re-signs the test batch by the signers it names, repeats kept", %{s: s, batch: batch} do
      {real, [batch_key]} = decode(batch)

      {200, out} = TestBatch.transform("batch.json", batch, args(s, %{signers: [:outside]}))
      {payload, [kid]} = decode(out)
      assert payload == real
      refute kid == batch_key

      {200, out} =
        TestBatch.transform("batch.json", batch, args(s, %{signers: [:pair_a, :pair_a]}))

      assert {_, [a, a]} = decode(out)
    end

    test "issued_ahead moves the issue to now plus that, the lifetime kept", %{s: s, batch: batch} do
      {real, _} = decode(batch)
      life = DateTime.diff(instant(real["expires"]), instant(real["issued"]))
      before = DateTime.utc_now()

      {200, out} = TestBatch.transform("batch.json", batch, args(s, %{issued_ahead: 3600}))
      {payload, _} = decode(out)
      issued = instant(payload["issued"])
      assert DateTime.diff(issued, before) in 3600..3602
      assert DateTime.diff(instant(payload["expires"]), issued) == life
      assert Map.drop(payload, ["issued", "expires"]) == Map.drop(real, ["issued", "expires"])
    end

    test "lifetime sets expires that long after the batch's own issue", %{s: s, batch: batch} do
      {real, _} = decode(batch)

      {200, out} =
        TestBatch.transform("batch.json", batch, args(s, %{lifetime: 3650 * 86_400}))

      {payload, _} = decode(out)
      assert payload["issued"] == real["issued"]

      assert DateTime.diff(instant(payload["expires"]), instant(payload["issued"])) ==
               3650 * 86_400
    end

    test "root: :unchained or :rotated serves that v2; :withheld a 404; others unchanged",
         %{s: s} do
      assert {200, s.test.rotated_v2} ==
               TestBatch.transform("root.json", "v1", args(s, %{root: :rotated}))

      assert {200, s.test.unchained_v2} ==
               TestBatch.transform("root.json", "v1", args(s, %{root: :unchained}))

      assert {404, ""} == TestBatch.transform("root.json", "v1", args(s, %{root: :withheld}))
      assert {200, "v1"} == TestBatch.transform("root.json", "v1", args(s, %{signers: [:batch]}))

      assert {200, "m"} ==
               TestBatch.transform("v2/manifests/jason.json", "m", args(s, %{root: :withheld}))
    end

    test "raises on a snapshot signed with the real root", %{snap: snap, batch: batch} do
      assert_raise ArgumentError, fn ->
        TestBatch.transform("batch.json", batch, args(snap, %{signers: [:outside]}))
      end
    end

    test "args" do
      for good <- [
            %{signers: [:outside]},
            %{signers: [:pair_a, :pair_a]},
            %{issued_ahead: 300},
            %{lifetime: 3600},
            %{root: :withheld},
            %{root: :unchained, signers: [:unchained]}
          ],
          do: assert(Transform.valid?({TestBatch, good}), inspect(good))

      for bad <- [
            %{},
            %{signers: []},
            %{signers: [:root]},
            %{issued_ahead: "1h"},
            %{lifetime: 0},
            %{root: :served_twice},
            %{typo: 1}
          ],
          do: refute(Transform.valid?({TestBatch, bad}), inspect(bad))

      assert TestBatch.test_root_only?()
    end
  end

  describe "Forge" do
    defp forged(s, kind), do: s.dir |> Path.join("forged/#{kind}.json") |> File.read!()

    defp forged_builds(s, kind) do
      %{"versions" => %{"1.4.5" => %{"builds" => builds}}} = JSON.decode!(forged(s, kind))
      builds
    end

    defp entries(build), do: build["ebin"] ++ build["priv"]

    test "every kind is prepared; the batch names the forged manifest, signed by the test batch key",
         %{s: s, batch: batch, l2: l2} do
      [batch_key] = root_keyids(l2.roots.v1, "batch")
      {real, _} = decode(batch)

      for kind <- Forge.kinds() do
        {200, out} = Forge.transform("batch.json", batch, args(s, %{forge: kind}))
        {payload, [^batch_key]} = decode(out)

        named =
          Map.new(Forge.forged(s, kind), fn {name, rel} ->
            {name, Synthetic.sha(File.read!(Path.join(s.dir, rel)))}
          end)

        names = Map.keys(named)

        expected =
          case kind do
            :path_dep -> ["elixir_precompiled", "nerves"]
            :unlocked_package -> ["chain_absent"]
            _ -> ["jason"]
          end

        assert Enum.sort(names) == expected, "#{kind}"
        assert Map.take(payload["manifests_v2"], names) == named, "#{kind}"

        assert Map.drop(payload["manifests_v2"], names) == Map.drop(real["manifests_v2"], names)
        assert Map.drop(payload, ["manifests_v2"]) == Map.drop(real, ["manifests_v2"])
      end
    end

    test "jason's manifest is the forged one; a dep the batch newly names is served from disk",
         %{s: s} do
      assert {200, forged(s, :dotdot)} ==
               Forge.transform("v2/manifests/jason.json", "real", args(s, %{forge: :dotdot}))

      assert {200, "real"} ==
               Forge.transform("v2/manifests/jason.json", "real", args(s, %{forge: :path_dep}))

      assert File.read!(Path.join(s.dir, "v2/manifests/chain_absent.json")) ==
               forged(s, :unlocked_package)
    end

    test "P5: each git or path dep gets a build at its own identity, so only the git/path rule can stop it",
         %{s: s} do
      for {name, vsn, checksum} <- [
            {"nerves", "2.0.0-pre.4", "0123456789abcdef0123456789abcdef01234567"},
            {"elixir_precompiled", "0.1.0", nil}
          ] do
        rel = Map.fetch!(Forge.forged(s, :path_dep), name)
        assert rel == "v2/manifests/#{name}.json"
        doc = JSON.decode!(File.read!(Path.join(s.dir, rel)))
        assert %{"format" => 2, "versions" => %{^vsn => %{"builds" => [build]}}} = doc
        assert build["target"] == "pure_elixir"
        assert build["build"]["elixir"] == System.version()
        assert build["build"]["otp"] == System.otp_release()
        assert build["build"]["dep_env"] == "prod"
        if checksum, do: assert(build["build"]["package_checksum"] == checksum)
        assert [%{"path" => app_path, "sha256" => sha}] = build["ebin"]
        assert app_path == "ebin/#{name}.app"
        app = File.read!(Path.join(s.dir, "files/#{sha}"))
        assert app =~ "{application,#{name}," and app =~ ~s("#{vsn}")
      end
    end

    test "forging never writes over a file that exists (hard links into the real snapshot)",
         %{snap: snap, s: s} do
      real = Path.join(snap.dir, "v2/manifests/jason.json")
      before = File.read!(real)

      # A second prepare over the same layer-2 snapshot finds every file in place.
      assert :ok = Forge.prepare(s, Layer2Fixture.fixture_dir(Path.dirname(snap.dir)))
      assert File.read!(real) == before

      for {_n, %{file_shas: shas}} <- snap.deps,
          sha <- shas,
          do: assert(Synthetic.sha(File.read!(Path.join(snap.dir, "files/#{sha}"))) == sha)
    end

    test "path, mode and app-dir forgeries", %{s: s} do
      for {kind, path} <- [
            dotdot: "ebin/../../chain_forged.beam",
            absolute: "/tmp/chain_forged.beam",
            outside_dirs: "lib/chain_forged.beam",
            escape_app_dir: "ebin/../../chain_fixture/ebin/chain_fixture.app",
            project_app: "ebin/chain_fixture.app"
          ],
          build <- forged_builds(s, kind) do
        assert Enum.any?(entries(build), &(&1["path"] == path)), "#{kind}"
      end

      app = fn build -> Enum.find(build["ebin"], &(&1["path"] == "ebin/jason.app")) end

      for {kind, mode} <- [setuid: 0o104755, mode_777: 0o100777],
          {real, build} <- Enum.zip(forged_builds(s, :package_checksum), forged_builds(s, kind)) do
        assert %{"mode" => ^mode} = app.(build)
        # Each build keeps its own .app bytes.
        assert app.(build)["sha256"] == app.(real)["sha256"]
      end
    end

    test "lock forgeries", %{s: s} do
      for build <- forged_builds(s, :package_checksum),
          do: assert(build["build"]["package_checksum"] == String.duplicate("0", 64))

      for build <- forged_builds(s, :deps_lock) do
        assert %{"version" => _, "checksum" => checksum} =
                 build["build"]["deps"]["nerves_system_rpi4"]

        assert checksum == String.duplicate("0", 64)
      end
    end

    test "a forged .app is a served file naming another app or version", %{s: s} do
      for {kind, want} <- [app_name: ~r/\{application,chain_forged,/, app_version: ~r/"9\.9\.9"/],
          build <- forged_builds(s, kind) do
        app = Enum.find(build["ebin"], &(&1["path"] == "ebin/jason.app"))
        bytes = File.read!(Path.join(s.dir, "files/#{app["sha256"]}"))
        assert Synthetic.sha(bytes) == app["sha256"] and byte_size(bytes) == app["size"]
        assert bytes =~ want
        assert {:ok, _, _} = :erl_scan.string(String.to_charlist(bytes))
      end
    end

    test "path collisions", %{s: s} do
      for build <- forged_builds(s, :duplicate) do
        paths = Enum.map(entries(build), & &1["path"])
        assert paths -- Enum.uniq(paths) == ["ebin/Elixir.Jason.beam"]
      end

      for build <- forged_builds(s, :case_variant),
          do: assert("ebin/elixir.jason.beam" in Enum.map(entries(build), & &1["path"]))

      for build <- forged_builds(s, :unicode_variant) do
        paths = Enum.map(build["priv"], & &1["path"])
        assert "priv/café" in paths and "priv/café" in paths
        [a, b] = Enum.filter(build["priv"], &String.starts_with?(&1["path"], "priv/caf"))
        refute a["sha256"] == b["sha256"]
      end
    end

    test "every file a selectable forged build names is served, not a foreign build's", %{s: s} do
      [foreign, _own] = forged_builds(s, :dotdot)
      assert foreign["target"] == "nerves_system_other"
      refute File.regular?(Path.join(s.dir, "files/#{hd(foreign["ebin"])["sha256"]}"))

      for kind <- Forge.kinds() -- [:path_dep],
          build <- forged_builds(s, kind),
          build["target"] == "pure_elixir",
          %{"sha256" => sha} <- entries(build),
          do: assert(File.regular?(Path.join(s.dir, "files/#{sha}")), "#{kind}: #{sha}")
    end

    test "args and the real root", %{snap: snap, batch: batch} do
      for kind <- Forge.kinds(), do: assert(Transform.valid?({Forge, %{forge: kind}}))
      refute Transform.valid?({Forge, %{forge: :nope}})
      refute Transform.valid?({Forge, %{forge: :dotdot, extra: 1}})
      assert Forge.test_root_only?()

      assert_raise ArgumentError, fn ->
        Forge.transform("batch.json", batch, args(snap, %{forge: :dotdot}))
      end
    end
  end

  describe "AdoptedRoot" do
    test "writes the rotated v2 as the adopted chain and its version, in the case's state dir",
         %{s: s, l2: l2, tmp_dir: tmp} do
      home = Path.join(tmp, "home")
      File.mkdir_p!(home)
      ctx = %{source: "http://127.0.0.1:1", root: l2.roots.v1, mirrors: []}
      assert :ok = Setup.run({AdoptedRoot, %{}}, home, Map.put(s, :case, ctx))

      {:ok, dir} = Setup.state_dir(home, ctx.source, ctx.root)
      assert [env] = JSON.decode!(File.read!(Path.join(dir, "roots.json")))
      assert env == JSON.decode!(s.test.rotated_v2)
      assert File.read!(Path.join(dir, "root_version")) == "2"
      refute File.exists?(Path.join(dir, "state"))
    end

    test "args and the real root", %{snap: snap, tmp_dir: tmp} do
      assert Setup.valid?({AdoptedRoot, %{}})
      refute Setup.valid?({AdoptedRoot, %{version: 3}})
      assert AdoptedRoot.test_root_only?()
      ctx = %{source: "http://127.0.0.1:1", root: "/nonexistent", mirrors: []}
      assert {:error, _} = Setup.run({AdoptedRoot, %{}}, tmp, Map.put(snap, :case, ctx))
    end
  end
end
