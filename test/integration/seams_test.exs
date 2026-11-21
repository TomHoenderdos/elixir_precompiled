# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.SeamsTest do
  # The client re-reviews' R8 and R10: the test seams are compiled in only
  # when this library is built in its own test env. Built as a dependency,
  # as every user builds it, neither `test_seams` nor `relocation_prefix`
  # in the application env opens anything.
  use ExUnit.Case, async: false
  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  test "built as a dependency, the seams stay shut whatever the app env says", %{tmp_dir: dir} do
    f = F.new(dir)
    F.publish(f, %{}, sequence: 1)
    proj = C.plain!(dir, f, deps: "[#{C.own_dep()}]")
    C.mix!(proj, ["deps.get"])

    script = """
    Application.put_env(:precompiled, :test_seams, true)
    Application.put_env(:precompiled, :relocation_prefix, "/tmp/x")
    IO.inspect(Precompiled.install(:recon, clock_synchronized?: fn -> false end), label: "clock")
    IO.inspect(Precompiled.install(:recon, root: "/tmp/root.json"), label: "root")
    record = Precompiled.Relocate.pinned_record(1, "/tmp/x")
    IO.inspect(Precompiled.Relocate.pinned_problem(record), label: "prefixed")
    IO.inspect(Precompiled.Relocate.pinned_problem(Precompiled.Relocate.pinned_record(1)), label: "real")
    """

    out = C.mix!(proj, ["run", "--no-start", "-e", script])
    assert out =~ "clock: {:error, {:bad_option, :clock_synchronized?}}", out
    assert out =~ "root: {:error, {:bad_option, :root}}", out
    assert out =~ ~s(prefixed: "the record's roots are not the builder's"), out
    assert out =~ "real: nil", out
  end
end
