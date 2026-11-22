# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ProbeInputsTest do
  use ExUnit.Case, async: true

  alias Precompiled.ProbeInputs

  @moduletag :tmp_dir

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

  # A project with deps under `dir`: each `{app, files}` is a dep dir with
  # those files; `names` adds lock-only names.
  defp view(dir, deps, names \\ []) do
    dirs =
      Map.new(deps, fn {app, files} ->
        path = Path.join(dir, app)
        File.mkdir_p!(path)

        for {rel, body} <- files do
          File.mkdir_p!(Path.dirname(Path.join(path, rel)))
          File.write!(Path.join(path, rel), body)
        end

        {app, path}
      end)

    ProbeInputs.view(
      MapSet.new(Map.keys(dirs) ++ names),
      dirs,
      :ets.new(:probe_memo, [:set, :public])
    )
  end

  defp check(item, view, closure \\ %{}, package \\ "pkg"),
    do: ProbeInputs.check(item, closure, package, view)

  describe "a module nothing in the build defines" do
    test "hits when no dep of the project can supply it", %{tmp_dir: dir} do
      v = view(dir, [{"jason", %{"lib/jason.ex" => "defmodule Jason do\nend\n"}}])
      assert check(module("Elixir.Poison", ["poison"]), v) == :ok
    end

    test "misses when a definer is a dep of the project or in its lock", %{tmp_dir: dir} do
      v = view(dir, [{"jason", %{}}], ["poison_fork"])

      assert {:miss, %{code: :probe_definer, args: ["Poison", "poison_fork"]}} =
               check(module("Elixir.Poison", ["poison", "poison_fork"]), v)
    end

    test "misses when a dep outside the build's closure defines it in its sources",
         %{tmp_dir: dir} do
      for {file, body} <- [
            {"lib/p.ex", "defmodule Poison do\nend\n"},
            {"lib/p.ex", "defmodule Elixir.Poison do\nend\n"},
            {"lib/deep/p.ex", "if true do\n  defmodule Poison do\n  end\nend\n"},
            {"lib/p.ex", "defprotocol Poison do\nend\n"}
          ] do
        v =
          view(Path.join(dir, "#{System.unique_integer([:positive])}"), [
            {"vendor", %{file => body}}
          ])

        assert {:miss, %{code: :probe_definer, args: ["Poison", "vendor"]}} =
                 check(module("Elixir.Poison"), v),
               body
      end
    end

    test "finds a nested name and an implementation", %{tmp_dir: dir} do
      # (Jason itself is on this VM's code path: a name that is not.)
      nested = "defmodule Jsn do\n  defmodule Encoder do\n  end\nend\n"
      impl = "defimpl Jsn.Encoder, for: Money do\nend\n"
      v = view(dir, [{"glazer", %{"lib/g.ex" => nested}}, {"money", %{"lib/m.ex" => impl}}])

      assert {:miss, %{code: :probe_definer, args: ["Jsn.Encoder", "glazer"]}} =
               check(module("Elixir.Jsn.Encoder"), v)

      assert {:miss, %{code: :probe_definer, args: ["Jsn.Encoder.Money", "money"]}} =
               check(module("Elixir.Jsn.Encoder.Money"), v)

      # An implementation for another type defines only its own module.
      assert check(module("Elixir.Jsn.Encoder.Decimal"), v) == :ok
    end

    # Elixir nests a module defined inside another under it, and names a
    # top-level one through the aliases in scope; a module a nested one
    # defines is an alias in its parent, which defimpl's for: expands.
    test "follows the names Elixir gives through nesting and aliases", %{tmp_dir: dir} do
      files = %{
        "lib/top.ex" => "alias Other.Top\ndefmodule Top.Inner do\nend\n",
        "lib/as.ex" => "alias Far.Away, as: Near\ndefmodule Near.Deep do\nend\n",
        "lib/multi.ex" => "alias Many.{One, Two}\ndefmodule Two.Sub do\nend\n",
        "lib/nest.ex" =>
          "defmodule Outer do\n  alias Some.Thing\n  defmodule Thing.Inside do\n  end\nend\n",
        "lib/impl.ex" =>
          "defmodule Host do\n  defmodule Struct do\n  end\n  defimpl Proto, for: Struct\nend\n"
      }

      v = view(dir, [{"aliased", files}])

      for name <- ~w(Elixir.Other.Top.Inner Elixir.Top.Inner Elixir.Far.Away.Deep
                     Elixir.Many.Two.Sub Elixir.Outer.Thing.Inside Elixir.Proto.Host.Struct) do
        assert {:miss, %{code: :probe_definer}} = check(module(name), v), name
      end

      # Nesting wins over an alias inside a module.
      assert check(module("Elixir.Some.Thing.Inside"), v) == :ok
    end

    test "a definition inside a quote is named where the macro expands", %{tmp_dir: dir} do
      body =
        "defmacro __using__(_) do\n  quote do\n    defmodule Encoder do\n    end\n  end\nend\n"

      v = view(dir, [{"dsl", %{"lib/d.ex" => body}}])
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.App.Encoder"), v)
    end

    test "an alias it cannot read, at the top level, cannot be told", %{tmp_dir: dir} do
      body = "alias unquote(x)\ndefmodule Poison.Sub do\nend\n"
      v = view(dir, [{"odd", %{"lib/o.ex" => body}}])
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)
    end

    test "finds an Erlang module, and a leex or yecc one by its base name", %{tmp_dir: dir} do
      v =
        view(dir, [
          {"cowboy", %{"src/cowboy_websocket.erl" => "%% x\n-module(cowboy_websocket).\n"}},
          {"lexers", %{"src/my_lexer.xrl" => "Definitions.\n", "src/my_parser.yrl" => "x.\n"}}
        ])

      assert {:miss, %{code: :probe_definer, args: ["cowboy_websocket", "cowboy"]}} =
               check(module("cowboy_websocket"), v)

      assert {:miss, %{args: ["my_lexer", "lexers"]}} = check(module("my_lexer"), v)
      assert {:miss, %{args: ["my_parser", "lexers"]}} = check(module("my_parser"), v)
      assert check(module("cowboy_handler"), v) == :ok
    end

    test "a dep of the build's closure, and the package itself, are the build's", %{tmp_dir: dir} do
      v =
        view(dir, [
          {"pkg", %{"lib/p.ex" => "defmodule Poison do\nend\n"}},
          {"dep", %{"lib/p.ex" => "defmodule Poison do\nend\n"}}
        ])

      closure = %{"dep" => %{"version" => "1.0.0", "checksum" => "x"}}
      assert check(module("Elixir.Poison"), v, closure) == :ok
    end

    test "a file that defines a module under a computed name cannot be told", %{tmp_dir: dir} do
      for body <- [
            "defmodule unquote(name) do\nend\n# Poison\n",
            "Module.create(Module.concat([:Poison]), quote(do: nil), __ENV__)\n",
            "Code.compile_string(\"defmodule Poison do end\")\n",
            "defprotocol unquote(Poison) do\nend\n"
          ] do
        v =
          view(Path.join(dir, "#{System.unique_integer([:positive])}"), [
            {"dsl", %{"lib/d.ex" => body}}
          ])

        assert {:miss, %{code: :probe_unknown, args: ["Poison"]}} =
                 check(module("Elixir.Poison"), v),
               body
      end

      # One that never names the module's last segment defines other names.
      v =
        view(Path.join(dir, "far"), [{"dsl", %{"lib/d.ex" => "defmodule unquote(x) do\nend\n"}}])

      assert check(module("Elixir.Poison"), v) == :ok

      # A computed implementation of another protocol is not this module.
      impl = "defimpl Jason.Encoder, for: unquote(t) do\nend\n# Poison\n"
      v = view(Path.join(dir, "impl"), [{"dsl", %{"lib/d.ex" => impl}}])
      assert check(module("Elixir.Poison"), v) == :ok

      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Jason.Encoder.Poison"), v)
    end

    test "a source it cannot read or parse, or a dep without a dir, cannot be told",
         %{tmp_dir: dir} do
      v = view(dir, [{"broken", %{"lib/b.ex" => "defmodule Poison do\n"}}])
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)

      v = ProbeInputs.view(MapSet.new(["ghost"]), %{"ghost" => Path.join(dir, "nope")}, nil)
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)

      v = ProbeInputs.view(MapSet.new(["ghost"]), %{"ghost" => nil}, nil)
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)

      # A lock entry Mix does not load in this env never compiles here.
      v = ProbeInputs.view(MapSet.new(["ghost"]), %{}, nil)
      assert check(module("Elixir.Poison"), v) == :ok

      v = ProbeInputs.view(MapSet.new(["ghost"]), nil, nil)
      assert {:miss, %{code: :probe_unknown}} = check(module("Elixir.Poison"), v)
    end

    test "a module on this VM's code path is one the project can find", %{tmp_dir: dir} do
      v = view(dir, [])

      assert {:miss, %{code: :probe_definer, args: ["lists", "code_path"]}} =
               check(module("lists"), v)

      assert {:miss, %{code: :probe_definer, args: ["Precompiled.Reason", "code_path"]}} =
               check(module("Elixir.Precompiled.Reason"), v)
    end

    test "hidden dirs, _build and deps of a dep are not its sources", %{tmp_dir: dir} do
      files = %{
        ".hidden/p.ex" => "defmodule Poison do\nend\n",
        "_build/dev/p.ex" => "defmodule Poison do\nend\n",
        "deps/x/p.ex" => "defmodule Poison do\nend\n"
      }

      assert check(module("Elixir.Poison"), view(dir, [{"path_dep", files}])) == :ok
    end

    test "answers from the run's memo once a dep was read", %{tmp_dir: dir} do
      v = view(dir, [{"vendor", %{"lib/p.ex" => "defmodule Poison do\nend\n"}}])
      assert {:miss, %{code: :probe_definer}} = check(module("Elixir.Poison"), v)
      File.rm_rf!(Path.join(dir, "vendor"))
      assert {:miss, %{code: :probe_definer}} = check(module("Elixir.Poison"), v)
    end
  end

  describe "an application" do
    test "hits when no dep is it and nothing installed is", %{tmp_dir: dir} do
      assert check(app("phoenix_html"), view(dir, [{"jason", %{}}])) == :ok
    end

    test "misses when a dep of the project is it", %{tmp_dir: dir} do
      assert {:miss, %{code: :probe_definer, args: ["phoenix_html", "phoenix_html"]}} =
               check(app("phoenix_html"), view(dir, [], ["phoenix_html"]))
    end

    test "misses when this VM finds it", %{tmp_dir: dir} do
      assert {:miss, %{code: :probe_definer, args: ["stdlib", "code_path"]}} =
               check(app("stdlib"), view(dir, []))
    end
  end

  describe "an OTP application no closure application lists" do
    test "hits only where it is not installed", %{tmp_dir: dir} do
      assert check(app("no_such_otp_app", "otp_app"), view(dir, [])) == :ok

      assert {:miss, %{code: :probe_otp_app, args: ["stdlib"]}} =
               check(app("stdlib", "otp_app"), view(dir, []))

      assert {:miss, %{code: :probe_otp_app, args: ["eex"]}} =
               check(app("eex", "otp_app"), view(dir, []))

      assert {:miss, %{code: :probe_otp_app, args: ["wx_like"]}} =
               check(app("wx_like", "otp_app"), view(dir, [], ["wx_like"]))
    end
  end

  test "a malformed item is a malformed entry", %{tmp_dir: dir} do
    v = view(dir, [])

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
end
