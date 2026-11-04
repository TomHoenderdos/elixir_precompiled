# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.ClockTest do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Clock

  @issued ~U[2026-11-04 10:00:00Z]

  test "an age is the offset that puts the client's clock that long after the batch's issue" do
    # A snapshot taken 2 hours ago: the batch is already 2 hours old.
    now = DateTime.add(@issued, 2 * 3600, :second)

    for age <- [23 * 3600, 25 * 3600, 365 * 86_400] do
      %{clock_offset_seconds: offset} =
        Clock.resolve(%{clock_offset_seconds: {:age, age}}, @issued, now)

      assert DateTime.diff(DateTime.add(now, offset, :second), @issued) == age
    end

    assert Clock.resolve(%{clock_offset_seconds: {:age, 23 * 3600}}, @issued, now) ==
             %{clock_offset_seconds: 21 * 3600}
  end

  test "an integer offset, other keys and no config pass through" do
    config = %{clock_offset_seconds: -60, source: "http://127.0.0.1:1"}
    assert Clock.resolve(config, @issued, DateTime.utc_now()) == config
    assert Clock.resolve(nil, @issued, DateTime.utc_now()) == nil
    assert Clock.relative?(%{clock_offset_seconds: {:age, 1}})
    refute Clock.relative?(config)
    refute Clock.relative?(nil)
  end

  test "the case form: an integer age is valid, anything else is not" do
    assert Clock.case_config?(%{clock_offset_seconds: {:age, 3600}})
    assert Clock.case_config?(%{clock_offset_seconds: 5, root: "/r.json"})
    refute Clock.case_config?(%{clock_offset_seconds: {:age, "1"}})
    refute Clock.case_config?(%{clock_offset_seconds: {:ago, 1}})
    refute Clock.case_config?(%{clock_offset_seconds: {:age, 1}, other: 1})
  end
end
