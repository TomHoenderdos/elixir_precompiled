# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.PolicyTest do
  use ExUnit.Case, async: true

  alias ChainTest.{LocalServer, Policy, Result, Signed}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    served = Path.join(tmp, "served")
    File.mkdir_p!(served)
    {base, pid} = LocalServer.serve(served)
    on_exit(fn -> LocalServer.stop(pid) end)
    key = Signed.key()
    root = Path.join(tmp, "root.json")
    File.write!(root, Signed.root(key))
    File.write!(Path.join(served, "root.json"), File.read!(root))
    %{served: served, source: base, key: key, root: root}
  end

  defp check(ctx, batch, opts \\ []) do
    if batch, do: File.write!(Path.join(ctx.served, "batch.json"), batch)

    Policy.check(%{
      source: ctx.source,
      trust_opts: %{root_path: ctx.root, library_root_path: ctx.root},
      now: Keyword.get(opts, :now, DateTime.utc_now())
    })
  end

  defp ago(s), do: DateTime.add(DateTime.utc_now(), -s, :second)

  test "a batch issued minutes ago for 24 hours passes, one row named R20", ctx do
    now = DateTime.utc_now()
    issued = DateTime.add(now, -120, :second)

    batch =
      Signed.batch(ctx.key,
        sequence: 41,
        issued: issued,
        expires: DateTime.add(issued, 24, :hour)
      )

    assert %Result{step: :policy, check: "R20", class: :pass, detail: detail} =
             check(ctx, batch, now: now)

    assert detail =~ "batch 41"
    assert detail =~ "lifetime 86400 s"
    assert detail =~ "age 120 s when the response arrived"
  end

  test "a lifetime over 24 hours fails, naming it", ctx do
    issued = ago(60)
    batch = Signed.batch(ctx.key, issued: issued, expires: DateTime.add(issued, 7, :day))

    assert %Result{class: :fail, detail: detail} = check(ctx, batch)
    assert detail =~ "lifetime 604800 s exceeds 86400 s"
  end

  test "a batch older than 15 minutes at fetch time fails, naming its age", ctx do
    now = DateTime.utc_now()
    batch = Signed.batch(ctx.key, issued: DateTime.add(now, -16 * 60, :second))
    assert %Result{class: :fail, detail: detail} = check(ctx, batch, now: now)
    assert detail =~ "age 960 s exceeds 900 s when the response arrived"
  end

  test "15 minutes exactly and 24 hours exactly pass", ctx do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    issued = DateTime.add(now, -900, :second)
    batch = Signed.batch(ctx.key, issued: issued, expires: DateTime.add(issued, 24, :hour))
    assert %Result{class: :pass} = check(ctx, batch, now: now)
  end

  test "a batch issued more than 300 s ahead of this clock fails", ctx do
    issued = DateTime.add(DateTime.utc_now(), 600, :second)
    batch = Signed.batch(ctx.key, issued: issued)
    assert %Result{class: :fail, detail: detail} = check(ctx, batch)
    assert detail =~ "ahead of this clock"
  end

  test "a batch that does not verify fails: its dates mean nothing", ctx do
    batch = Signed.batch(Signed.key(), issued: ago(60))
    assert %Result{class: :fail, detail: detail} = check(ctx, batch)
    assert detail =~ "does not verify"
  end

  test "an unreachable batch is not exercised", ctx do
    assert %Result{class: :not_exercised, detail: detail} = check(ctx, nil)
    assert detail =~ "batch.json"
  end
end
