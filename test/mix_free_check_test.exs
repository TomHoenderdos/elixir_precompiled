# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule MixFreeCheckTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup_all do
    Code.require_file("scripts/mix_free_check.exs")
    :ok
  end

  defp compile_into(dir, source) do
    for {mod, bin} <- Code.compile_string(source) do
      File.write!(Path.join(dir, "#{mod}.beam"), bin)
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  # ElixirPrecompiled.Output and ElixirPrecompiled.Fetch are the real
  # library's own modules, already loaded in this test VM. Code.compile_string
  # would redefine (reload) them under those names and then compile_into's
  # purge/delete would unload them outright, breaking every other test that
  # runs against the real modules in the same (async) run. :compile.forms
  # with the :binary option compiles straight to a beam binary without ever
  # touching the code server, so the real modules stay untouched.
  defp compile_colliding_into(dir, module, forms) do
    {:ok, ^module, bin} = :compile.forms(forms, [:binary])
    File.write!(Path.join(dir, "#{module}.beam"), bin)
  end

  test "a device module that reaches Mix through a helper fails", %{tmp_dir: dir} do
    compile_into(dir, """
    defmodule ElixirPrecompiled.Device.Fake do
      def go, do: ElixirPrecompiled.FakeHelper.go()
    end
    defmodule ElixirPrecompiled.FakeHelper do
      def go, do: Mix.env()
    end
    """)

    assert {:error, [line]} = MixFreeCheck.run(dir)
    assert line == "Elixir.ElixirPrecompiled.FakeHelper calls Elixir.Mix.env/0"
  end

  test "a helper reached only through a captured fun is walked too", %{tmp_dir: dir} do
    compile_into(dir, """
    defmodule ElixirPrecompiled.Device.FakeCapture do
      def go, do: &ElixirPrecompiled.FakeCaptured.go/0
    end
    defmodule ElixirPrecompiled.FakeCaptured do
      def go, do: Mix.env()
    end
    """)

    assert {:error, [line]} = MixFreeCheck.run(dir)
    assert line == "Elixir.ElixirPrecompiled.FakeCaptured calls Elixir.Mix.env/0"
  end

  test "a host-only module that calls Mix is fine when the device layer does not reach it", %{
    tmp_dir: dir
  } do
    compile_into(dir, """
    defmodule Precompiled.Fake do
      def go, do: :ok
    end
    defmodule ElixirPrecompiled.HostOnly do
      def go, do: Mix.Project.config()
    end
    """)

    assert {:ok, [Precompiled.Fake]} = MixFreeCheck.run(dir)
  end

  test "Hex calls fail too, and no roots at all fails", %{tmp_dir: dir} do
    compile_into(
      dir,
      "defmodule Precompiled.Fake2 do\n def go, do: Hex.State.fetch!(:home)\nend\n"
    )

    assert {:error, ["Elixir.Precompiled.Fake2 calls Elixir.Hex.State.fetch!/1"]} =
             MixFreeCheck.run(dir)

    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)
    assert {:error, ["no device-layer modules in " <> _]} = MixFreeCheck.run(empty)
  end

  # Elixir's compiler folds `apply(Mix, :env, [])` (literal module, literal
  # function, literal arg list) into the same call_ext as `Mix.env()`, so
  # this form is already caught by the plain remote-call scan above. It is
  # still asserted here per the brief: apply/3 must never be a loophole,
  # whichever of the two detection layers below ends up catching it.
  test "apply/3 with a literal Mix module is caught like a direct call", %{tmp_dir: dir} do
    compile_into(dir, """
    defmodule ElixirPrecompiled.Device.FakeApplyLiteral do
      def go, do: ElixirPrecompiled.FakeApplyLiteralHelper.go()
    end
    defmodule ElixirPrecompiled.FakeApplyLiteralHelper do
      def go, do: apply(Mix, :env, [])
    end
    """)

    assert {:error, [line]} = MixFreeCheck.run(dir)
    assert line == "Elixir.ElixirPrecompiled.FakeApplyLiteralHelper calls Elixir.Mix.env/0"
  end

  # A module threaded through a parameter (built in one function, applied in
  # another) defeats that compile-time fold: no call_ext to Mix ever lands
  # in the imports chunk. Only the atoms chunk still carries the bare `Mix`
  # atom, so the check must also scan that chunk to catch this.
  test "a truly dynamic apply/3 through a variable still fails, with no precise call site", %{
    tmp_dir: dir
  } do
    compile_into(dir, """
    defmodule ElixirPrecompiled.Device.FakeApplyDyn do
      def go, do: ElixirPrecompiled.FakeApplyDynHelper.call()
    end
    defmodule ElixirPrecompiled.FakeApplyDynHelper do
      def call, do: dispatch(Mix)
      def dispatch(m), do: apply(m, :env, [])
    end
    """)

    assert {:error, [line]} = MixFreeCheck.run(dir)
    assert line == "Elixir.ElixirPrecompiled.FakeApplyDynHelper calls Elixir.Mix dynamically"
  end

  # `&Mix.env/0` never appears as a call_ext or a plain atom: the compiler
  # stores the whole fun value as one literal in the module's literal
  # table. The check must decode that table and look for external funs.
  test "a captured fun reference to Mix fails even though it is never called directly", %{
    tmp_dir: dir
  } do
    compile_into(dir, """
    defmodule ElixirPrecompiled.Device.FakeFun do
      def go, do: ElixirPrecompiled.FakeFunHelper.fun()
    end
    defmodule ElixirPrecompiled.FakeFunHelper do
      def fun, do: &Mix.env/0
    end
    """)

    assert {:error, [line]} = MixFreeCheck.run(dir)
    assert line == "Elixir.ElixirPrecompiled.FakeFunHelper calls Elixir.Mix.env/0"
  end

  # The one allowed call in the real library (Output -> Mix.shell/0, guarded
  # by mix_running?/0) and the one allowed bare atom (Fetch's Hex.SCM
  # marker) must not trip either detection layer. Built as raw Erlang forms
  # under the real module names (see compile_colliding_into/3) so this
  # never redefines the real, already-loaded Output/Fetch modules.
  test "the allowlisted Output -> Mix.shell/0 call and Fetch's Hex.SCM atom are not flagged", %{
    tmp_dir: dir
  } do
    compile_into(dir, """
    defmodule ElixirPrecompiled.Device.FakeAllowed do
      def go do
        ElixirPrecompiled.Output.go()
        ElixirPrecompiled.Fetch.go()
      end
    end
    """)

    compile_colliding_into(dir, ElixirPrecompiled.Output, [
      {:attribute, 1, :module, ElixirPrecompiled.Output},
      {:attribute, 1, :export, [go: 0]},
      {:function, 1, :go, 0,
       [{:clause, 1, [], [], [{:call, 1, {:remote, 1, {:atom, 1, Mix}, {:atom, 1, :shell}}, []}]}]}
    ])

    compile_colliding_into(dir, ElixirPrecompiled.Fetch, [
      {:attribute, 1, :module, ElixirPrecompiled.Fetch},
      {:attribute, 1, :export, [go: 0]},
      {:function, 1, :go, 0, [{:clause, 1, [], [], [{:atom, 1, Hex.SCM}]}]}
    ])

    assert {:ok, mods} = MixFreeCheck.run(dir)
    assert ElixirPrecompiled.Device.FakeAllowed in mods
  end

  # The device-root prefix must match on a path boundary: a module named
  # "ElixirPrecompiled.DeviceFixture" is not under
  # "ElixirPrecompiled.Device.", so it must never become a root by itself,
  # while the bare "ElixirPrecompiled.Device" module (no suffix) must.
  test "DeviceFixture is not mistaken for a device-layer root, but bare Device is", %{
    tmp_dir: dir
  } do
    fixture_only = Path.join(dir, "fixture_only")
    File.mkdir_p!(fixture_only)

    # The real DeviceFixture is test support loaded in this VM: compiled
    # without touching the code server, so async tests that use it keep it.
    compile_colliding_into(fixture_only, ElixirPrecompiled.DeviceFixture, [
      {:attribute, 1, :module, ElixirPrecompiled.DeviceFixture},
      {:attribute, 1, :export, [go: 0]},
      {:function, 1, :go, 0,
       [{:clause, 1, [], [], [{:call, 1, {:remote, 1, {:atom, 1, Mix}, {:atom, 1, :env}}, []}]}]}
    ])

    assert {:error, ["no device-layer modules in " <> _]} = MixFreeCheck.run(fixture_only)

    bare_device = Path.join(dir, "bare_device")
    File.mkdir_p!(bare_device)

    compile_into(bare_device, """
    defmodule ElixirPrecompiled.Device do
      def go, do: Mix.env()
    end
    """)

    assert {:error, [line]} = MixFreeCheck.run(bare_device)
    assert line == "Elixir.ElixirPrecompiled.Device calls Elixir.Mix.env/0"
  end

  test "the real library is Mix-free from the device layer" do
    ebin = Path.join([Mix.Project.build_path(), "lib", "elixir_precompiled", "ebin"])
    assert {:ok, mods} = MixFreeCheck.run(ebin)
    assert ElixirPrecompiled.Device.Env in mods
    assert ElixirPrecompiled.Device.Rules in mods
  end
end
