# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Layer2Fixture do
  @moduledoc """
  A real `ChainTest.Snapshot` of a served test "portal" (its own key, a
  batch naming jason's v2 manifest with one pure build of a beam and a
  well-formed `.app`), taken under `tmp`, for the layer-2 tests.
  """

  alias ChainTest.{LocalServer, Signed, Snapshot, Synthetic}

  @outer String.duplicate("a", 64)

  @doc "The fixture's jason files."
  @spec files() :: %{String.t() => binary()}
  def files(),
    do: %{
      "ebin/Elixir.Jason.beam" => "jason beam",
      "ebin/jason.app" =>
        ~s({application,jason,[{description,"jason"},{vsn,"1.4.5"},{modules,['Elixir.Jason']}]}.\n)
    }

  @doc "Takes the snapshot; returns it. The server is stopped on test exit."
  @spec snapshot(Path.t()) :: map()
  def snapshot(tmp) do
    key = Signed.key()
    root = Signed.root(key)
    root_path = Path.join(tmp, "root.json")
    File.write!(root_path, root)

    served = Path.join(tmp, "served")
    manifest = Synthetic.manifest("1.4.5", [Synthetic.build(files(), outer: @outer)])
    Synthetic.serve_manifest(served, "v2/manifests", "jason", manifest)

    for {_path, bytes} <- files() do
      File.mkdir_p!(Path.join(served, "files"))
      File.write!(Path.join([served, "files", Synthetic.sha(bytes)]), bytes)
    end

    File.write!(Path.join(served, "root.json"), root)

    File.write!(
      Path.join(served, "batch.json"),
      Signed.batch(key, manifests: %{}, manifests_v2: %{"jason" => Synthetic.sha(manifest)})
    )

    {source, pid} = LocalServer.serve(served)
    ExUnit.Callbacks.on_exit(fn -> LocalServer.stop(pid) end)

    fixture = Path.join(tmp, "fixture")
    Synthetic.tree(fixture, "rpi4", %{jason: {"1.4.5", @outer}})

    {:ok, snap} =
      Snapshot.take(%{
        source: source,
        fixture_dir: fixture,
        target: "rpi4",
        dir: Path.join(tmp, "snap"),
        repo_root: Path.join(tmp, "repo"),
        trust_opts: %{root_path: root_path, library_root_path: root_path}
      })

    snap
  end
end
