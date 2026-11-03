# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainFixture.ProbeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ChainFixture.Probe

  @begin "-----BEGIN CHAIN PROBE-----"
  @finish "-----END CHAIN PROBE-----"

  defp probe(apps) do
    out = capture_io(fn -> assert Probe.run(apps) == :ok end)
    {out, decode_block(out)}
  end

  defp decode_block(out) do
    assert [_before, rest] = String.split(out, @begin <> "\n")
    assert [json, _after] = String.split(rest, "\n" <> @finish)
    JSON.decode!(json)
  end

  test "prints exactly one delimited block" do
    {out, _doc} = probe([:jason])

    assert length(String.split(out, @begin)) == 2
    assert length(String.split(out, @finish)) == 2
  end

  test "lists every ebin and priv file of an app with its sha256" do
    {_out, doc} = probe([:jason])

    assert doc["apps"]["jason"] == "ok"
    files = doc["files"]["jason"]
    entry = Enum.find(files, &(&1["path"] == "ebin/Elixir.Jason.beam"))
    assert entry, "ebin/Elixir.Jason.beam not listed in #{inspect(files)}"
    assert entry["sha256"] =~ ~r/\A[0-9a-f]{64}\z/

    on_disk = Path.join(Application.app_dir(:jason), "ebin/Elixir.Jason.beam")

    assert entry["sha256"] ==
             Base.encode16(:crypto.hash(:sha256, File.read!(on_disk)), case: :lower)

    assert Enum.any?(files, &(&1["path"] == "ebin/jason.app"))
    assert Enum.all?(files, &String.starts_with?(&1["path"], ["ebin/", "priv/"]))
    assert Enum.map(files, & &1["path"]) == Enum.sort(Enum.map(files, & &1["path"]))
  end

  test "a missing app is an error, not a crash" do
    {_out, doc} = probe([:jason, :chain_fixture_no_such_app])

    assert doc["apps"]["jason"] == "ok"
    assert doc["apps"]["chain_fixture_no_such_app"] =~ "error"
    assert doc["files"]["chain_fixture_no_such_app"] == []
  end

  test "module counts, smoke keys and host-only nils" do
    {_out, doc} = probe([:jason])

    assert doc["modules"]["loaded"] > 0
    assert doc["modules"]["failed"] == []
    assert Map.keys(doc["smoke"]) |> Enum.sort() == ["argon2", "exqlite", "gpio"]
    # The NIF deps are target-only; on host the smoke calls report an error, never raise.
    assert Enum.all?(Map.values(doc["smoke"]), &is_binary/1)
    assert doc["firmware_uuid"] == nil
    # No os-release and no KV platform on host: a fallback, never a crash.
    assert doc["nerves_system"] == "unknown"
  end

  test "app names may be given as strings" do
    {_out, doc} = probe(["jason"])
    assert doc["apps"]["jason"] == "ok"
  end

  test "run/0 probes the expected hits" do
    {_out, doc} = probe_default()
    {expected, _} = Code.eval_file(Path.expand("../expected.exs", __DIR__))

    assert Map.keys(doc["apps"]) |> Enum.sort() ==
             Enum.map(expected.hits, &Atom.to_string/1) |> Enum.sort()
  end

  defp probe_default() do
    out = capture_io(fn -> assert Probe.run() == :ok end)
    {out, decode_block(out)}
  end
end
