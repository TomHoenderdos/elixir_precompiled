# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.RelocateTest do
  # A beam compiled at the builder's paths, relocated to this project's,
  # must be this project's own compile of the same source: chunk for chunk
  # after beam_lib:strip/1, and its Attr.
  use ExUnit.Case, async: false

  alias Precompiled.Relocate

  @moduletag :tmp_dir

  @otp28 String.to_integer(System.otp_release()) >= 28

  defp slots(root),
    do: %{"deps" => Path.join(root, "deps"), "build" => Path.join(root, "_build/dev")}

  # `body` in module `name`, compiled as `<root>/deps/fx/lib/fx.ex` from
  # the dependency's own dir, as Mix compiles a dependency; `@build` is the
  # root's build path.
  defp compile(root, name, body) do
    module = Module.concat([RelocateTest, name])
    dir = Path.join(root, "deps/fx")
    File.mkdir_p!(dir)
    build = slots(root)["build"]

    attr = if body =~ "@build", do: "@build #{inspect(build)}\n", else: ""
    source = "defmodule #{inspect(module)} do\n#{attr}#{body}\nend\n"

    [{^module, beam}] =
      File.cd!(dir, fn -> Code.compile_string(source, Path.join(dir, "lib/fx.ex")) end)

    :code.delete(module)
    :code.purge(module)
    beam
  end

  defp stripped(beam) do
    {:ok, {_, plain}} = :beam_lib.strip(beam)
    {:ok, _, chunks} = :beam_lib.all_chunks(plain)
    {:ok, _, all} = :beam_lib.all_chunks(beam)
    chunks ++ [List.keyfind(all, ~c"Attr", 0)]
  end

  defp roots(ctx), do: {Path.join(ctx.tmp_dir, "work/proj"), Path.join(ctx.tmp_dir, "home/u/app")}

  @fine "@include_dir Path.expand(\"c_include\")\ndef include_dir, do: @include_dir"

  if @otp28 do
    test "fine's literal, relocated, is the user's own compile", ctx do
      {builder, user} = roots(ctx)
      served = compile(builder, Fine, @fine)
      own = compile(user, Fine, @fine)

      assert {:ok, [occ]} = Relocate.occurrences(served, slots(builder))
      assert occ["parts"] == ["", "deps", "/fx/c_include"]
      assert {:ok, moved} = Relocate.relocate(served, [occ], slots(builder), slots(user))
      assert stripped(moved) == stripped(own)
      assert :beam_lib.md5(moved) == :beam_lib.md5(own)
    end

    test "paths in maps, keyword lists, atoms and the build path", ctx do
      body = """
      @cfg %{file: Path.join(__DIR__, "x"), opts: [priv: Path.join(@build, "lib/fx/priv")]}
      @a String.to_atom(__DIR__)
      def cfg, do: {@cfg, @a, fn -> :ok end}
      """

      {builder, user} = roots(ctx)
      served = compile(builder, Deep, body)
      own = compile(user, Deep, body)
      assert {:ok, occs} = Relocate.occurrences(served, slots(builder))
      assert {:ok, moved} = Relocate.relocate(served, occs, slots(builder), slots(user))
      assert stripped(moved) == stripped(own)
    end

    test "refuses a beam that does not hold the recorded path", ctx do
      {builder, user} = roots(ctx)
      served = compile(builder, Other, @fine)
      assert {:ok, occs} = Relocate.occurrences(served, slots(builder))
      other = compile(user, Other, @fine)
      assert {:refuse, _} = Relocate.relocate(other, occs, slots(builder), slots(user))
    end

    test "refuses where two literals would be one at the user's paths", ctx do
      {builder, user} = roots(ctx)
      clash = inspect(Path.join(user, "deps/fx/lib"))
      served = compile(builder, Clash, "def a, do: __DIR__\ndef b, do: #{clash}")
      assert {:ok, occs} = Relocate.occurrences(served, slots(builder))

      assert {:refuse, "two literals" <> _} =
               Relocate.relocate(served, occs, slots(builder), slots(user))
    end

    test "apply_staged rewrites the staged beam in place", ctx do
      {builder, user} = roots(ctx)
      served = compile(builder, Staged, @fine)
      own = compile(user, Staged, @fine)
      {:ok, occs} = Relocate.occurrences(served, slots(builder))
      staging = Path.join(ctx.tmp_dir, "staging")
      File.mkdir_p!(Path.join(staging, "ebin"))
      File.write!(Path.join(staging, "ebin/Elixir.RelocateTest.Staged.beam"), served)

      record =
        Map.put(slots(builder), "files", [
          %{"path" => "ebin/Elixir.RelocateTest.Staged.beam", "occurrences" => occs}
        ])

      assert :ok = Relocate.apply_staged(staging, record, slots(user))
      moved = File.read!(Path.join(staging, "ebin/Elixir.RelocateTest.Staged.beam"))
      assert stripped(moved) == stripped(own)

      bad = Map.put(record, "files", [%{"path" => "ebin/../x.beam", "occurrences" => occs}])

      assert {:fail, "relocation refused: " <> _} =
               Relocate.apply_staged(staging, bad, slots(user))
    end
  else
    test "OTP 27's compressed literal table is not relocated", ctx do
      {builder, _user} = roots(ctx)
      served = compile(builder, Fine, @fine)

      assert {:refuse, "a compressed literal table"} =
               Relocate.occurrences(served, slots(builder))
    end
  end

  test "user_slots needs real, absolute, separate paths", ctx do
    real = Path.join(ctx.tmp_dir, "real")
    File.mkdir_p!(Path.join(real, "deps"))
    File.mkdir_p!(Path.join(real, "_build/dev"))
    deps = Path.join(real, "deps")
    build = Path.join(real, "_build/dev")
    linked = Path.join(ctx.tmp_dir, "linked")
    File.ln_s!(real, linked)

    # ExUnit's tmp dir is under the checkout; one under a link has no slots.
    expected = if real_dir?(real), do: %{"deps" => deps, "build" => build}
    assert Relocate.user_slots(deps, build) == expected

    assert Relocate.user_slots(Path.join(linked, "deps"), Path.join(linked, "_build/dev")) == nil
    assert Relocate.user_slots("deps", build) == nil
    assert Relocate.user_slots(deps, deps) == nil
    assert Relocate.user_slots(deps <> "/../deps", build) == nil
  end

  defp real_dir?(path) do
    path
    |> Path.split()
    |> tl()
    |> Enum.scan("/", &Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))
  end
end
