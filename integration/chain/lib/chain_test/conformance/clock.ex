# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Clock do
  @moduledoc """
  A case's clock, relative to the snapshot batch's issue rather than to
  now. A case's `client_config` may give `clock_offset_seconds: {:age,
  seconds}`: the client's clock is then set `seconds` after the batch's
  `issued`, whatever the snapshot's age or the case's place in the run.
  The runner resolves it to the integer offset the client takes,
  `seconds - (now - issued)`, just before the build.
  """

  @doc """
  Whether `config` is a case's `client_config`: a build's, with a clock age
  allowed, and a root that may be `{:test_root, name}`, one of
  `ChainTest.TestKey.root_names/0` (layer 2: resolved at run time to that
  test root's path).
  """
  @spec case_config?(term()) :: boolean()
  def case_config?(%{root: {:test_root, name}} = config),
    do: name in ChainTest.TestKey.root_names() and case_config?(%{config | root: "/test-root"})

  def case_config?(%{clock_offset_seconds: {:age, age}} = config) when is_integer(age),
    do: ChainTest.Build.client_config?(%{config | clock_offset_seconds: 0})

  def case_config?(%{clock_offset_seconds: {_, _}}), do: false
  def case_config?(config), do: ChainTest.Build.client_config?(config)

  @doc "Whether `config` gives a clock age that needs the batch's issue to resolve."
  @spec relative?(map() | nil) :: boolean()
  def relative?(%{clock_offset_seconds: {:age, _}}), do: true
  def relative?(_config), do: false

  @doc "`config` with a clock age turned into the offset from `now`; anything else as it is."
  @spec resolve(map() | nil, DateTime.t(), DateTime.t()) :: map() | nil
  def resolve(%{clock_offset_seconds: {:age, age}} = config, issued, now),
    do: %{config | clock_offset_seconds: age - DateTime.diff(now, issued, :second)}

  def resolve(config, _issued, _now), do: config
end
