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

  # An entry of `ebin` whose record lists `files`, its second root a long,
  # deep path with every letter, so the user's root under the same tmp dir
  # is inside the envelope.
  defp entry(ctx, builder, ebin, files) do
    second =
      Path.join(
        ctx.tmp_dir,
        "Second Root.d/A-0123456789/abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ/proj"
      )

    record =
      builder
      |> slots()
      |> Map.put("second", slots(second))
      |> Map.put("files", files)

    %{"ebin" => Enum.map(ebin, &%{"path" => &1}), "priv" => [], "relocation" => record}
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

      path = "ebin/Elixir.RelocateTest.Staged.beam"
      entry = entry(ctx, builder, [path], [%{"path" => path, "occurrences" => occs}])

      assert :ok = Relocate.apply_staged(staging, entry, slots(user))
      moved = File.read!(Path.join(staging, path))
      assert stripped(moved) == stripped(own)

      bad =
        put_in(entry, ["relocation", "files"], [
          %{"path" => "ebin/../x.beam", "occurrences" => occs}
        ])

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

  describe "user_slots/2" do
    test "real, absolute, separate paths are this project's slots", ctx do
      real = Path.join(ctx.tmp_dir, "real")
      File.mkdir_p!(Path.join(real, "deps"))
      File.mkdir_p!(Path.join(real, "_build/dev"))
      deps = Path.join(real, "deps")
      build = Path.join(real, "_build/dev")
      linked = Path.join(ctx.tmp_dir, "linked")
      File.ln_s!(real, linked)

      # ExUnit's tmp dir is under the checkout; one under a link has no slots.
      if real_dir?(real),
        do: assert(Relocate.user_slots(deps, build) == {:ok, %{"deps" => deps, "build" => build}})

      for {d, b} <- [
            {Path.join(linked, "deps"), Path.join(linked, "_build/dev")},
            {"deps", build},
            {deps, deps},
            {deps <> "/../deps", build},
            {Path.join(real, "missing"), build}
          ] do
        assert {:error, :relocated_paths, []} = Relocate.user_slots(d, b), inspect({d, b})
      end
    end

    # The client review's B1: Mix compiles a dependency after a cd into it,
    # so its `__DIR__` is the spelling on disk, whatever spelling Mix was
    # given. Every component must be an exact entry of its parent's listing.
    test "a path spelled otherwise than on disk is a miss of its own", ctx do
      real = Path.join(ctx.tmp_dir, "Case/Home/App")
      File.mkdir_p!(Path.join(real, "deps"))
      File.mkdir_p!(Path.join(real, "_build/dev"))
      other = Path.join(ctx.tmp_dir, "case/home/app")

      result = Relocate.user_slots(Path.join(other, "deps"), Path.join(real, "_build/dev"))

      if File.dir?(other) do
        # A volume that ignores case (macOS by default).
        assert result == {:error, :relocated_path_spelling, ["deps"]}
      else
        assert result == {:error, :relocated_paths, []}
      end

      build = Relocate.user_slots(Path.join(real, "deps"), Path.join(other, "_build/dev"))
      refute match?({:ok, _}, build)
    end

    # The client review's B2: the builder's roots are printable ASCII, so a
    # path that is not cannot be told apart from its other byte forms.
    test "a path that is not printable ASCII is a miss of its own", ctx do
      for name <- ["jos\u00e9", "tab\there", "new\nline", "del\x7f"] do
        dir = Path.join([ctx.tmp_dir, name, "app"])
        File.mkdir_p!(Path.join(dir, "deps"))
        File.mkdir_p!(Path.join(dir, "_build/dev"))

        assert {:error, :relocated_path_ascii, ["deps"]} =
                 Relocate.user_slots(Path.join(dir, "deps"), Path.join(dir, "_build/dev")),
               inspect(name)
      end
    end

    @tag :non_root
    test "a parent that cannot be listed is a miss", ctx do
      dir = Path.join(ctx.tmp_dir, "locked")
      File.mkdir_p!(Path.join(dir, "app/deps"))
      File.mkdir_p!(Path.join(dir, "app/_build/dev"))
      File.chmod!(dir, 0o311)

      try do
        assert {:error, :relocated_path_spelling, ["deps"]} =
                 Relocate.user_slots(Path.join(dir, "app/deps"), Path.join(dir, "app/_build/dev"))
      after
        File.chmod!(dir, 0o755)
      end
    end
  end

  # The umbrella review's B1: the client relocates only to paths inside the
  # envelope the builder's two roots span.
  describe "envelope_reason/2" do
    @first %{"deps" => "/work/proj/deps", "build" => "/work/proj/_build/host"}
    @second %{
      "deps" =>
        "/tmp/ncc-relocate-1/A Long.Root-0123456789/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/x/y/The Project-2/Deps vendored_d",
      "build" =>
        "/tmp/ncc-relocate-1/A Long.Root-0123456789/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/x/y/The Project-2/Out.Build-3/Host 4"
    }
    @record Map.put(@first, "second", @second)

    test "a path inside the envelope is taken" do
      for user <- [
            %{"deps" => "/home/u/app/deps", "build" => "/home/u/app/_build/dev"},
            %{
              "deps" => "/Users/alice/My Projects/my-app.2/deps",
              "build" => "/Users/alice/My Projects/my-app.2/_build/dev"
            }
          ] do
        assert Relocate.envelope_reason(@record, user) == nil, inspect(user)
      end
    end

    test "a path outside the envelope is a miss of its own" do
      inside = %{"deps" => "/home/u/app/deps", "build" => "/home/u/app/_build/dev"}

      for {slot, path} <- [
            {"deps", "/app/deps"},
            {"deps", "/home/u+x/app/deps"},
            {"deps", "/home/~u/app/deps"},
            {"deps", "/" <> String.duplicate("a/", 20) <> "deps"},
            {"deps", "/" <> String.duplicate("a", 300) <> "/deps"},
            {"build", "/app/_build/dev"}
          ] do
        user = Map.put(inside, slot, path)

        assert %{code: :relocated_path_envelope, args: [^slot]} =
                 Relocate.envelope_reason(@record, user),
               inspect(path)
      end
    end
  end

  defp real_dir?(path) do
    path
    |> Path.split()
    |> tl()
    |> Enum.scan("/", &Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))
  end
end
