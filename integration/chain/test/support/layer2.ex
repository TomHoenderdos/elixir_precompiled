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

  @doc """
  The fixture dir of `snapshot/1` under `tmp`: three levels below it, so
  the path dep `../../..` (elixir_precompiled, as in the real fixture) is
  `tmp`, whose `mix.exs` gives version 0.1.0; `nerves` is a git dep at
  `0123456789abcdef0123456789abcdef01234567`, its `deps/nerves/mix.exs`
  version 2.0.0-pre.4.
  """
  @spec fixture_dir(Path.t()) :: Path.t()
  def fixture_dir(tmp), do: Path.join([tmp, "w", "x", "fixture"])

  @doc "Takes the snapshot; returns it. The server is stopped on test exit."
  @spec snapshot(Path.t()) :: map()
  def snapshot(tmp) do
    key = Signed.key()
    root = Signed.root(key)
    root_path = Path.join(tmp, "root.json")
    File.write!(root_path, root)

    served = Path.join(tmp, "served")
    # First, a build for another system whose files the snapshot never
    # fetches: forgeries must take their bytes from a build it holds.
    foreign =
      Synthetic.build(
        %{"ebin/Elixir.Jason.beam" => "foreign beam", "ebin/jason.app" => "foreign app"},
        outer: @outer,
        target: "nerves_system_other",
        system_version: "1.0.0"
      )

    manifest =
      Synthetic.manifest("1.4.5", [foreign, Synthetic.build(files(), outer: @outer)])

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

    fixture = fixture_dir(tmp)
    Synthetic.tree(fixture, "rpi4", %{jason: {"1.4.5", @outer}})
    lock = Path.join(fixture, "mix.lock")

    File.write!(
      lock,
      String.replace(
        File.read!(lock),
        "%{\n",
        ~s(%{\n  "nerves": {:git, "https://example.invalid/nerves.git", ) <>
          ~s("0123456789abcdef0123456789abcdef01234567", [branch: "main"]},\n),
        global: false
      )
    )

    File.mkdir_p!(Path.join(fixture, "deps/nerves"))
    File.write!(Path.join(fixture, "deps/nerves/mix.exs"), ~s(@version "2.0.0-pre.4"\n))
    File.write!(Path.join(tmp, "mix.exs"), ~s(  @version "0.1.0"\n))

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
