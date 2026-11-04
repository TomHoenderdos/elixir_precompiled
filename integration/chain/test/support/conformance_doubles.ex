# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.TestSetup do
  @moduledoc """
  A `ChainTest.Conformance.Setup` for tests: writes `files` (`%{rel =>
  bytes}`) under the home, or `{:state, bytes}` as the state file of the
  case's source; `fail: why` returns `{:error, why}`, `raise: msg` raises;
  `needs` is returned by `needs/1`. Sends `{:setup, home, snapshot}` to
  `notify` (a registered name) when given.
  """
  @behaviour ChainTest.Conformance.Setup

  alias ChainTest.Conformance.Setup

  @keys [:files, :state, :fail, :raise, :needs, :notify]

  @impl true
  def valid_args?(args), do: Enum.all?(Map.keys(args), &(&1 in @keys))

  @impl true
  def needs(args), do: Map.get(args, :needs, [])

  @impl true
  def setup(home, snapshot, args) do
    if name = args[:notify], do: send(name, {:setup, home, snapshot})
    if msg = args[:raise], do: raise(msg)

    for {rel, bytes} <- Map.get(args, :files, %{}) do
      path = Path.join(home, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    if state = args[:state] do
      {:ok, dir} = Setup.state_dir(home, snapshot.case.source, snapshot.case.root)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "state"), state)
    end

    case args[:fail] do
      nil -> :ok
      why -> {:error, why}
    end
  end
end

defmodule ChainTest.TestTransform do
  @moduledoc """
  A `ChainTest.Mirror.Transform` for tests: `mirrors: 2` asks for a second
  mirror; the case mirror redirects `batch.json` to the second mirror's
  `batch.json`, the second serves unchanged. `needs` is returned by
  `needs/1`.
  """
  @behaviour ChainTest.Mirror.Transform

  @impl true
  def valid_args?(args), do: Enum.all?(Map.keys(args), &(&1 in [:mirrors, :needs]))

  @impl true
  def needs(args), do: Map.get(args, :needs, [])

  @impl true
  def transform("batch.json", _bytes, %{case: %{mirror: 1, second_url: url}})
      when is_binary(url),
      do: {:redirect, 302, url <> "/batch.json"}

  def transform(_path, bytes, _args), do: {200, bytes}
end
