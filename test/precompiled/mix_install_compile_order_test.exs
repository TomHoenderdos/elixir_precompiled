# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.MixInstallCompileOrderTest do
  # Against a real Mix.install/2 in a fresh VM: the compile order the client
  # reads for the install project before Mix.install/2 runs, and what it
  # says each dep sees of solo_b's :k when it compiles, are what
  # Mix.install/2's own deps.compile then does. The fixture is the one
  # compile_order_test.exs runs `mix deps.compile` on: each dep's module
  # logs, as it compiles, its name and Application.fetch_env(:solo_b, :k),
  # whose .app default is 1.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @fixture Path.expand("../fixtures/compile_order/deps_src", __DIR__)

  defp dep(app), do: {app, path: Path.join(@fixture, Atom.to_string(app))}

  # The client's side is what Install.run/4 hands Check, captured by the
  # check itself, with the user config as the check reads it. Then the real
  # Mix.install/2 compiles and the log says what each dep saw. Each dep is
  # then checked as a build would record it: a config_order item for
  # solo_b's :k, read by that dep, with the value its compile logged and
  # solo_b's default (unrecordable when solo_b is not a dep, as the portal
  # records an app outside a build's closure).
  defp run(tmp, apps, partitions, mix_opts \\ []) do
    ebin = Path.dirname(:code.which(Precompiled.Install))
    log = Path.join(tmp, "order.log")
    deps = Enum.map(apps, &dep/1)

    script = """
    Mix.start()
    deps = #{inspect(deps)}
    parent = self()

    check = fn env ->
      send(parent, {:env, env, Precompiled.CompileInputs.user_config("solo_b", "k")})
    end

    :ok = Precompiled.Install.run(deps, #{inspect(mix_opts)}, %{}, check: check)
    {order, user} = receive do {:env, env, user} -> {env.compile_order, user} end

    lines =
      for line <- String.split(File.read!(#{inspect(log)}), "\\n", trim: true) do
        [app, seen] = String.split(line, " ", parts: 2)
        {app, elem(Code.eval_string(seen), 0)}
      end

    rec = &(&1 |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false))
    default = if :solo_b in #{inspect(apps)}, do: rec.({:ok, 1}), else: "unrecordable"
    ctx = %{compile_order: order, user_config: fn _app, _key -> user end}

    checked =
      for {reader, seen} <- lines, reader != "solo_b", into: %{} do
        item = %{"kind" => "config_order", "app" => "solo_b", "path" => ["k"],
                 "reader" => reader, "default" => default, "seen" => rec.(seen)}
        {reader, Precompiled.CompileInputs.host([item], &System.get_env/1, ctx)}
      end

    # The same reader as a build that saw solo_b's default would record it.
    saw_default =
      for {reader, _seen} <- lines, reader != "solo_b", into: %{} do
        item = %{"kind" => "config_order", "app" => "solo_b", "path" => ["k"],
                 "reader" => reader, "default" => rec.({:ok, 1}), "seen" => rec.({:ok, 1})}
        {reader, Precompiled.CompileInputs.host([item], &System.get_env/1, ctx)}
      end

    loaded =
      Map.new(lines, fn {reader, _} ->
        {reader, Precompiled.CompileOrder.loaded_before?(order, "solo_b", reader)}
      end)

    result = {order, Precompiled.CompileOrder.apps(order), loaded, checked, saw_default, lines}
    IO.puts("RESULT " <> Base.encode64(:erlang.term_to_binary(result)))
    """

    path = Path.join(tmp, "install.exs")
    File.write!(path, script)

    {out, status} =
      System.cmd("elixir", ["-pa", ebin, path],
        cd: tmp,
        env: [
          {"MIX_INSTALL_DIR", Path.join(tmp, "installs")},
          {"MIX_ENV", nil},
          {"ORDER_LOG", log},
          {"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", partitions}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    [encoded] = for "RESULT " <> e <- String.split(out, "\n"), do: e

    {order, apps, loaded, checked, saw_default, lines} =
      encoded |> Base.decode64!() |> :erlang.binary_to_term()

    %{
      order: order,
      apps: apps,
      loaded: loaded,
      checked: checked,
      saw_default: saw_default,
      lines: lines,
      out: out
    }
  end

  test "the client's order and loaded_before? are what Mix.install/2's deps.compile does", %{
    tmp_dir: tmp
  } do
    r = run(tmp, [:zeta, :alpha, :solo_b], nil)
    real = Enum.map(r.lines, &elem(&1, 0))

    assert Enum.sort(real) == ["alpha", "base", "mid", "solo_b", "zeta"], r.out
    assert r.apps == real, r.out

    seen = for {app, value} <- r.lines, app != "solo_b", into: %{}, do: {app, value == {:ok, 1}}

    # As in a Mix project: Mix before 1.19 compiles solo_b first, so every
    # reader sees its default; from 1.19 on base compiles before it and
    # sees nothing. Either way each reader's prediction is checked.
    assert Enum.any?(seen, &elem(&1, 1))
    if hd(real) != "solo_b", do: refute(Enum.all?(seen, &elem(&1, 1)))

    for {reader, saw_default?} <- seen do
      assert r.loaded[reader] == saw_default?, reader
      assert r.checked[reader] == :ok, reader
    end
  end

  # An app that is not a dep of the install project never compiles or loads
  # there: every reader sees it unset, and a build that recorded it unset
  # hits (phoenix_view under phoenix_live_dashboard without it).
  test "an app outside the install project's deps is unset for every reader", %{tmp_dir: tmp} do
    r = run(tmp, [:zeta, :alpha], nil)
    real = Enum.map(r.lines, &elem(&1, 0))

    assert Enum.sort(real) == ["alpha", "base", "mid", "zeta"], r.out
    assert r.apps == real

    for {reader, value} <- r.lines do
      assert value == :error, reader
      assert r.loaded[reader] == false, reader
      assert r.checked[reader] == :ok, reader
    end
  end

  # Mix.install/2 applies config: and then config_path: before its deps
  # compile, so every reader sees them whatever the order; the check sees
  # them too, and keeps the order.
  test "config: wins over the order", %{tmp_dir: tmp} do
    r = run(tmp, [:zeta, :alpha, :solo_b], nil, config: [solo_b: [k: 2]])

    assert %{apps: [_ | _]} = r.order

    for {reader, value} <- r.lines do
      assert value == {:ok, 2}, reader
      if reader != "solo_b", do: assert(r.checked[reader] == :ok, reader)
    end

    # A build whose reader saw solo_b's default, even one compiled after
    # solo_b here, would differ: config: set another value.
    assert map_size(r.saw_default) == 4

    for {reader, result} <- r.saw_default do
      assert {:miss, %{code: :config_order_differs, args: ["solo_b", "k"]}} = result, reader
    end
  end

  test "config_path: wins over config: and the order", %{tmp_dir: tmp} do
    file = Path.join(tmp, "solo_b_config.exs")
    File.write!(file, "import Config\nconfig :solo_b, k: 3\n")
    r = run(tmp, [:zeta, :alpha], nil, config: [solo_b: [k: 2]], config_path: file)

    assert %{apps: [_ | _]} = r.order

    for {reader, value} <- r.lines do
      assert value == {:ok, 3}, reader
      assert r.checked[reader] == :ok, reader
    end
  end

  # A partitioned deps.compile has no single order: the client cannot say
  # what an app among the deps sees, but one outside them is still unset in
  # every partition.
  describe "a partitioned compile" do
    test "an app among the deps is unknown", %{tmp_dir: tmp} do
      r = run(tmp, [:zeta, :alpha, :solo_b], "2")

      assert {:ambiguous, "MIX_OS_DEPS_COMPILE_PARTITION_COUNT", _} = r.order
      assert r.apps == []

      for {reader, _value} <- r.lines, reader != "solo_b" do
        assert r.loaded[reader] == :unknown, reader

        assert {:miss, %{code: :config_order_differs, args: ["solo_b", "k"]}} =
                 r.checked[reader]
      end
    end

    test "an app outside the deps is unset", %{tmp_dir: tmp} do
      r = run(tmp, [:zeta, :alpha], "2")

      assert {:ambiguous, "MIX_OS_DEPS_COMPILE_PARTITION_COUNT", _} = r.order
      assert Enum.sort(Enum.map(r.lines, &elem(&1, 0))) == ["alpha", "base", "mid", "zeta"]

      for {reader, value} <- r.lines do
        assert value == :error, reader
        assert r.loaded[reader] == false, reader
        assert r.checked[reader] == :ok, reader
      end
    end
  end
end
