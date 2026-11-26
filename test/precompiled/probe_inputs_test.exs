# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ProbeInputsTest do
  use ExUnit.Case, async: true

  alias Precompiled.ProbeInputs

  defp module(name, definers \\ []),
    do: %{
      "kind" => "probe",
      "of" => "module",
      "name" => name,
      "answer" => "absent",
      "definers" => definers
    }

  defp app(name, of \\ "app"),
    do: %{"kind" => "probe", "of" => of, "name" => name, "answer" => "absent"}

  # A project whose Mix-loaded deps are `lists` (`app => [module]` or
  # `:unknown`), plus `non_hex` deps and lock-only `names`.
  defp view(lists, opts \\ []) do
    me = self()

    modules_of = fn app ->
      send(me, {:asked, app})

      case Map.fetch!(lists, app) do
        :unknown -> :unknown
        modules -> {:ok, MapSet.new(modules)}
      end
    end

    ProbeInputs.view(
      MapSet.new(Map.keys(lists) ++ Keyword.get(opts, :names, [])),
      Map.keys(lists),
      Keyword.get(opts, :non_hex, []),
      modules_of
    )
  end

  defp check(item, view, closure \\ %{}, package \\ "pkg"),
    do: ProbeInputs.check(item, closure, package, view)

  describe "a module nothing in the build defines" do
    test "hits when no dep's exact module list holds it" do
      v = view(%{"jason" => ["Elixir.Jason", "Elixir.Jason.Encoder"]})
      assert check(module("Elixir.Poison", ["poison"]), v) == :ok
      assert_received {:asked, "jason"}
    end

    test "misses when a definer is a dep of the project or in its lock" do
      v = view(%{"jason" => []}, names: ["poison_fork"])

      assert {:miss, %{code: :probe_definer, args: ["Poison", "poison_fork"]}} =
               check(module("Elixir.Poison", ["poison", "poison_fork"]), v)
    end

    # The list is the dep's served build's: its ebin and the modules its
    # compile defined in memory (a `.exs` its `mix.exs` loads, a nested
    # `defmodule` in a `defimpl`, `-module (x).`): every form, as built.
    test "misses when a dep outside the build's closure lists it" do
      v =
        view(%{
          "vendor" => ["Elixir.Poison", "cw_mod", "Elixir.Jsn.Encoder.Money.Helper"],
          "other" => []
        })

      for {name, shown} <- [
            {"Elixir.Poison", "Poison"},
            {"cw_mod", "cw_mod"},
            {"Elixir.Jsn.Encoder.Money.Helper", "Jsn.Encoder.Money.Helper"}
          ] do
        assert {:miss, %{code: :probe_definer, args: [^shown, "vendor"]}} =
                 check(module(name), v),
               name
      end
    end

    test "a dep of the build's closure, and the package itself, are the build's: not asked" do
      v = view(%{"pkg" => ["Elixir.Poison"], "dep" => ["Elixir.Poison"]})
      closure = %{"dep" => %{"version" => "1.0.0", "checksum" => "x"}}
      assert check(module("Elixir.Poison"), v, closure) == :ok
      refute_received {:asked, _}
    end

    # A Hex release with no served list for this project (no build of it
    # that matches here, a build from before the lists, a release the
    # portal does not know): this client cannot tell.
    test "a dep outside the closure with no exact list cannot be told" do
      v = view(%{"vendor" => :unknown, "jason" => []})

      assert {:miss, %{code: :probe_unknown, args: ["Poison"]}} =
               check(module("Elixir.Poison"), v)
    end

    # A path or git dep (a path-overridden closure dep included) has no
    # served list: any module probe misses.
    test "a non-Hex dep cannot be told" do
      v = view(%{"jason" => []}, non_hex: ["my_fork"])

      assert {:miss, %{code: :probe_unknown, args: ["Poison"]}} =
               check(module("Elixir.Poison"), v)

      refute_received {:asked, _}
    end

    test "with no view of the deps, it cannot be told" do
      for v <- [nil, ProbeInputs.view(MapSet.new(), nil, [], fn _ -> :unknown end)] do
        assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)
      end

      v = ProbeInputs.view(MapSet.new(), [], nil, fn _ -> :unknown end)
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)
    end

    test "a module on this VM's code path, or loaded in it, is one the project supplies" do
      v = view(%{})

      assert {:miss, %{code: :probe_definer, args: ["lists", "code_path"]}} =
               check(module("lists"), v)

      assert {:miss, %{code: :probe_definer, args: ["Precompiled.Reason", "code_path"]}} =
               check(module("Elixir.Precompiled.Reason"), v)

      name = "Elixir.ProbeInputsTest.Loaded#{System.unique_integer([:positive])}"

      {:module, _, _, _} =
        Module.create(String.to_atom(name), quote(do: nil), Macro.Env.location(__ENV__))

      assert {:miss, %{code: :probe_definer, args: [_, "code_path"]}} = check(module(name), v)
    end
  end

  # S10 round 3, the declared-optional-dependency rule: the module lies in
  # the namespace of a package the prober declares as an optional
  # dependency; that package and every indexed definer are the definers,
  # and no other dep's module list is needed.
  # S10 round 3, the declared-optional-dependency rule, per release since
  # round 5: the module lies in the namespace of a package the prober
  # declares as an optional dependency; that package's presence decides,
  # and each dep outside the closure at its locked release, against the
  # batch's module index per release (`index`). No module list is asked for.
  describe "a module its declared packages decide" do
    defp declared(name, definers, declared),
      do: Map.put(module(name, definers), "declared", declared)

    # `read`: the apps whose locked release the index read; `defines`:
    # `{module, app}` pairs whose locked release defines the module.
    defp indexed(deps, opts \\ []) do
      read = Keyword.get(opts, :read, deps)
      defines = Keyword.get(opts, :defines, [])

      index = %{
        read?: fn app -> app in read end,
        defines?: fn module, app -> {module, app} in defines end
      }

      ProbeInputs.view(
        MapSet.new(deps ++ Keyword.get(opts, :names, [])),
        deps,
        Keyword.get(opts, :non_hex, []),
        fn _ -> raise "no module list is asked for" end,
        Keyword.get(opts, :inert, []),
        index
      )
    end

    @pg "Elixir.Postgrex"

    test "hits when no dep at its locked release defines it, and every one was read" do
      assert check(declared(@pg, ["postgrex"], ["postgrex"]), indexed(["vendor", "jason"])) == :ok
    end

    # The review's U1: jason_uo 1.4.98 defines Jason and Jason.Encoder; its
    # last release does not. Locked at 1.4.98 it is a definer. (The same
    # shape under a name this test VM does not have loaded.)
    test "misses when a dep at its locked release defines it" do
      v = indexed(["jsn_uo"], defines: [{"Elixir.JsnR5.Encoder", "jsn_uo"}])

      assert {:miss, %{code: :probe_definer, args: ["JsnR5.Encoder", "jsn_uo"]}} =
               check(declared("Elixir.JsnR5.Encoder", ["jsn"], ["jsn"]), v)
    end

    test "misses as unknown when a dep's locked release was not read, or no index" do
      v = indexed(["fresh_pkg", "jason"], read: ["jason"])

      assert {:miss, %{code: :probe_unknown, args: ["Postgrex"]}} =
               check(declared(@pg, ["postgrex"], ["postgrex"]), v)

      no_index = %{indexed(["jason"]) | index: nil}

      assert {:miss, %{code: :probe_unknown}} =
               check(declared(@pg, ["postgrex"], ["postgrex"]), no_index)

      unknown = put_in(indexed(["jason"]).index.read?, fn _ -> :unknown end)

      assert {:miss, %{code: :probe_unknown}} =
               check(declared(@pg, ["postgrex"], ["postgrex"]), unknown)
    end

    test "a dep of the build's closure, and the package itself, are the build's: not asked" do
      v = indexed(["pkg", "dep"], read: [], defines: [{@pg, "dep"}])
      closure = %{"dep" => %{"version" => "1.0.0", "checksum" => "x"}}
      assert check(declared(@pg, ["postgrex"], ["postgrex"]), v, closure) == :ok
    end

    test "misses when the declared package, or another named definer, is a dep" do
      assert {:miss, %{code: :probe_definer, args: ["Postgrex", "postgrex"]}} =
               check(
                 declared(@pg, ["postgrex"], ["postgrex"]),
                 indexed(["jason"], names: ["postgrex"])
               )

      assert {:miss, %{code: :probe_definer, args: ["Jason.Encoder", "glazer"]}} =
               check(
                 declared("Elixir.Jason.Encoder", ["glazer", "jason"], ["jason"]),
                 indexed(["jason_dep"], names: ["glazer"])
               )
    end

    test "misses when the module is on the code path, or a dep is no Hex dep" do
      assert {:miss, %{code: :probe_definer, args: ["lists", "code_path"]}} =
               check(declared("lists", ["stdlib_fork"], ["stdlib_fork"]), indexed([]))

      assert {:miss, %{code: :probe_unknown, args: ["Postgrex"]}} =
               check(
                 declared(@pg, ["postgrex"], ["postgrex"]),
                 indexed(["jason"], non_hex: ["my_fork"])
               )

      assert {:miss, %{code: :probe_unknown}} =
               check(declared(@pg, ["postgrex"], ["postgrex"]), nil)
    end

    test "a declared package that is no definer, or a malformed list, is malformed" do
      for bad <- [
            declared(@pg, ["postgrex"], ["jason"]),
            declared(@pg, ["postgrex"], []),
            declared(@pg, ["postgrex"], "postgrex"),
            Map.put(declared(@pg, ["postgrex"], ["postgrex"]), "extra", 1)
          ] do
        assert {:miss, %{code: :malformed_entry}} = check(bad, view(%{})), inspect(bad)
      end
    end
  end

  describe "an application" do
    test "hits when no dep is it and nothing installed is" do
      assert check(app("phoenix_html"), view(%{"jason" => []})) == :ok
    end

    test "misses when a dep of the project is it" do
      assert {:miss, %{code: :probe_definer, args: ["phoenix_html", "phoenix_html"]}} =
               check(app("phoenix_html"), view(%{}, names: ["phoenix_html"]))
    end

    test "misses when this VM finds it, or has it loaded" do
      assert {:miss, %{code: :probe_definer, args: ["stdlib", "code_path"]}} =
               check(app("stdlib"), view(%{}))

      name = "probe_inputs_loaded_#{System.unique_integer([:positive])}"
      :ok = :application.load({:application, String.to_atom(name), [vsn: ~c"1.0.0"]})

      assert {:miss, %{code: :probe_definer, args: [^name, "code_path"]}} =
               check(app(name), view(%{}))
    end

    test "with no view, it cannot be told" do
      assert {:miss, %{code: :probe_unknown}} = check(app("phoenix_html"), nil)
    end
  end

  describe "an OTP application no closure application lists" do
    test "hits only where it is not installed" do
      assert check(app("no_such_otp_app", "otp_app"), view(%{})) == :ok

      for name <- ["stdlib", "eex"] do
        assert {:miss, %{code: :probe_otp_app, args: [^name]}} =
                 check(app(name, "otp_app"), view(%{}))
      end

      assert {:miss, %{code: :probe_otp_app, args: ["wx_like"]}} =
               check(app("wx_like", "otp_app"), view(%{}, names: ["wx_like"]))
    end

    # The review's N2: no view is no project to check, as for the others.
    test "with no view, it cannot be told" do
      assert {:miss, %{code: :probe_unknown, args: ["no_such_otp_app"]}} =
               check(app("no_such_otp_app", "otp_app"), nil)
    end
  end

  test "a malformed item is a malformed entry" do
    v = view(%{})

    for bad <- [
          Map.put(module("Elixir.Poison"), "extra", 1),
          %{module("Elixir.Poison") | "answer" => "present"},
          %{module("Elixir.Poison") | "name" => "Elixir.Bad Name"},
          %{module("Elixir.Poison") | "definers" => "poison"},
          %{module("Elixir.Poison") | "definers" => ["Poison"]},
          Map.delete(module("Elixir.Poison"), "definers"),
          %{app("x") | "of" => "process"},
          Map.put(app("x"), "definers", []),
          %{app("x") | "name" => "Elixir.X"}
        ] do
      assert {:miss, %{code: :malformed_entry}} = check(bad, v), inspect(bad)
    end
  end

  describe "a served build's exact module list" do
    defp entry(ebin, build),
      do: %{
        "target" => "pure_elixir",
        "ebin" => Enum.map(ebin, &%{"path" => "ebin/" <> &1, "sha256" => "x", "size" => 1}),
        "build" => build
      }

    test "is its ebin's beams and its defined_modules" do
      e = entry(["Elixir.A.beam", "a_erl.beam", "pkg.app"], %{"defined_modules" => ["Elixir.M"]})
      assert {:ok, set} = ProbeInputs.module_set(e)
      assert Enum.sort(set) == ["Elixir.A", "Elixir.M", "a_erl"]
    end

    test "is unknown without defined_modules, or with a malformed one" do
      for build <- [%{}, %{"defined_modules" => nil}, %{"defined_modules" => "Elixir.M"}] do
        assert ProbeInputs.module_set(entry(["Elixir.A.beam"], build)) == :unknown
      end

      assert ProbeInputs.module_set(%{"build" => %{"defined_modules" => []}}) == :unknown
    end
  end
end
