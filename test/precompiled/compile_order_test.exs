# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CompileOrderTest do
  use ExUnit.Case, async: true

  alias Precompiled.CompileOrder

  defp dep(app, children \\ [], manager \\ :mix, opts \\ []),
    do: %Mix.Dep{
      app: app,
      deps: Enum.map(children, &%Mix.Dep{app: &1}),
      manager: manager,
      opts: opts
    }

  test "the order is Mix's list as given, never re-sorted" do
    order = CompileOrder.from_deps([dep(:zeta), dep(:alpha)], nil)
    assert CompileOrder.apps(order) == ["zeta", "alpha"]
  end

  test "umbrella children are left out, as deps.compile does" do
    order = CompileOrder.from_deps([dep(:a), dep(:child, [], :mix, from_umbrella: true)], nil)
    assert CompileOrder.apps(order) == ["a"]
  end

  test "a Mix dep compiled earlier is loaded; a later one is not" do
    assert CompileOrder.loaded_before?(CompileOrder.from_deps([dep(:a), dep(:r)], nil), "a", "r") ==
             true

    assert CompileOrder.loaded_before?(CompileOrder.from_deps([dep(:r), dep(:a)], nil), "a", "r") ==
             false
  end

  test "an app in the reader's own tree is loaded" do
    order = CompileOrder.from_deps([dep(:a), dep(:r, [:a])], nil)
    assert CompileOrder.loaded_before?(order, "a", "r") == true
  end

  test "a rebar3, make or custom-compiled dep loads nothing, unless an earlier Mix dep's tree holds it" do
    for {manager, opts} <- [{:rebar3, []}, {:make, []}, {:mix, [compile: "make"]}] do
      order = CompileOrder.from_deps([dep(:a, [], manager, opts), dep(:r)], nil)
      assert CompileOrder.loaded_before?(order, "a", "r") == false, inspect(manager)
    end

    order = CompileOrder.from_deps([dep(:a, [], :rebar3), dep(:q, [:a]), dep(:r)], nil)
    assert CompileOrder.loaded_before?(order, "a", "r") == true
  end

  # An app outside the project's deps never compiles or loads here, so the
  # reader sees it unset (e.g. phoenix_view in a project without it).
  test "an app the project does not depend on is never loaded" do
    order = CompileOrder.from_deps([dep(:a), dep(:r)], nil)
    assert CompileOrder.loaded_before?(order, "precompiled_no_such_app_x", "r") == false
  end

  # An OTP or Elixir app is not in the deps but may be loaded by an earlier
  # dep's compile all the same: the order cannot say.
  test "an app that ships with OTP or Elixir is unknown" do
    order = CompileOrder.from_deps([dep(:a), dep(:r)], nil)
    assert CompileOrder.loaded_before?(order, "ssl", "r") == :unknown
    assert CompileOrder.loaded_before?(order, "eex", "r") == :unknown
  end

  test "unknown: reader not in the deps, a reader Mix does not compile, no order" do
    order = CompileOrder.from_deps([dep(:a), dep(:r), dep(:e, [], :rebar3)], nil)
    assert CompileOrder.loaded_before?(order, "a", "gone") == :unknown
    assert CompileOrder.loaded_before?(order, "a", "e") == :unknown
    assert CompileOrder.loaded_before?(nil, "a", "r") == :unknown
  end

  test "a partitioned compile is ambiguous" do
    for count <- ["2", "8", "x"] do
      order = CompileOrder.from_deps([dep(:a), dep(:r)], count)
      assert {:ambiguous, _, _} = order
      assert CompileOrder.loaded_before?(order, "a", "r") == :unknown
      assert CompileOrder.apps(order) == []
    end

    for count <- [nil, "", "0", "1"] do
      assert %{apps: ["a", "r"]} = CompileOrder.from_deps([dep(:a), dep(:r)], count),
             inspect(count)
    end
  end

  # An app absent from the deps loads in no partition either.
  test "a partitioned compile still knows an app the project does not depend on" do
    order = CompileOrder.from_deps([dep(:a), dep(:r)], "2")
    assert CompileOrder.loaded_before?(order, "precompiled_no_such_app_x", "r") == false
    assert CompileOrder.loaded_before?(order, "ssl", "r") == :unknown
    assert CompileOrder.loaded_before?(order, "a", "r") == :unknown
    assert CompileOrder.loaded_before?(order, "precompiled_no_such_app_x", "gone") == :unknown
  end

  describe "against Mix's real deps.compile" do
    @describetag :tmp_dir
    @describetag timeout: 300_000

    @fixture Path.expand("../fixtures/compile_order", __DIR__)

    test "the client's order and loaded_before? are what deps.compile does", %{tmp_dir: tmp} do
      File.cp_r!(@fixture, tmp)
      log = Path.join(tmp, "order.log")

      {out, 0} =
        System.cmd("mix", ["deps.compile"],
          cd: tmp,
          env: [
            {"ORDER_LOG", log},
            {"MIX_ENV", "dev"},
            {"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", nil}
          ],
          stderr_to_stdout: true
        )

      lines =
        for line <- String.split(File.read!(log), "\n", trim: true),
            do: String.split(line, " ", parts: 2)

      real = Enum.map(lines, &hd/1)

      # The client's side runs in the fixture's own Mix VM, as it does in a
      # user's project: Mix.Dep.load_and_cache/0 there, CompileOrder from
      # this build's ebin on the code path. Mix prunes the code path to the
      # project's deps when it loads them, dropping a -pa entry, so the code
      # adds it itself.
      ebin = Path.dirname(:code.which(CompileOrder))

      code = """
      Code.prepend_path(#{inspect(ebin)})
      o = Precompiled.Env.MixProject.load().compile_order
      apps = Precompiled.CompileOrder.apps(o)
      loaded = Map.new(apps, &{&1, Precompiled.CompileOrder.loaded_before?(o, "solo_b", &1)})
      IO.puts("ORDER " <> Base.encode64(:erlang.term_to_binary({apps, loaded})))
      """

      {run, 0} =
        System.cmd(
          "elixir",
          [
            "-S",
            "mix",
            "run",
            "--no-compile",
            "--no-deps-check",
            "--no-start",
            "-e",
            code
          ],
          cd: tmp,
          env: [{"MIX_ENV", "dev"}, {"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", nil}],
          stderr_to_stdout: true
        )

      [encoded] = for "ORDER " <> e <- String.split(run, "\n"), do: e
      {apps, loaded} = encoded |> Base.decode64!() |> :erlang.binary_to_term()

      assert apps == real, out

      seen =
        for [app, value] <- lines, app != "solo_b", into: %{}, do: {app, value == "{:ok, 1}"}

      assert Enum.any?(seen, &elem(&1, 1)) and not Enum.all?(seen, &elem(&1, 1))

      for {reader, saw_default?} <- seen do
        assert loaded[reader] == saw_default?, reader
      end
    end
  end
end

defmodule Precompiled.CompileOrderCodePathTest do
  # Changes the VM's code path, so not async.
  use ExUnit.Case, async: false

  alias Precompiled.CompileOrder

  # Mix prunes the code path to the project's deps before the check runs,
  # yet a later dep can still load an OTP app (Mix's builtin apps): an
  # app that ships with OTP is found on disk, not on the code path.
  test "an OTP app off the code path is still unknown" do
    paths = Path.wildcard(Path.join([:code.lib_dir(), "{ssh,os_mon}-*", "ebin"]))
    assert length(paths) == 2
    on_path = Enum.filter(paths, &(String.to_charlist(&1) in :code.get_path()))

    try do
      Enum.each(on_path, &Code.delete_path/1)
      assert :code.where_is_file(~c"ssh.app") == :non_existing
      assert :code.where_is_file(~c"os_mon.app") == :non_existing

      order = CompileOrder.from_deps([%Mix.Dep{app: :r, deps: [], manager: :mix, opts: []}], nil)
      assert CompileOrder.loaded_before?(order, "ssh", "r") == :unknown
      assert CompileOrder.loaded_before?(order, "os_mon", "r") == :unknown
    after
      Enum.each(on_path, &Code.append_path/1)
    end
  end
end
