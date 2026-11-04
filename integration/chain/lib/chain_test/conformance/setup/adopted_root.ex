# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Setup.AdoptedRoot do
  @moduledoc """
  R17: the client's state as a client that already adopted the test root
  v2 (`rotated_v2` of `ChainTest.TestKey`, chained from v1) would have left
  it: `roots.json` holding that envelope and `root_version` 2, in the state
  dir of the case's source and root. Only with a test root; no args.
  """
  @behaviour ChainTest.Conformance.Setup

  alias ChainTest.Conformance.Setup
  alias ChainTest.TestKey

  @doc "Only for a case pinned to a test root."
  @spec test_root_only?() :: true
  def test_root_only?(), do: true

  @impl true
  def valid_args?(args), do: args == %{}

  @impl true
  def setup(home, %{case: ctx} = snap, _args) do
    test = TestKey.test!(snap)

    with {:ok, dir} <- Setup.state_dir(home, ctx.source, ctx.root) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "roots.json"), JSON.encode!([JSON.decode!(test.rotated_v2)]))
      File.write!(Path.join(dir, "root_version"), "2")
      :ok
    end
  end
end
