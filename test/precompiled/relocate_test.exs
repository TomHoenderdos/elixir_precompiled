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
  @otp29 String.to_integer(System.otp_release()) >= 29

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

  # An Erlang module compiled from `<root>/deps/fx/src/<name>.erl`, as Mix
  # compiles one: `?FILE` is that absolute path.
  defp compile_erl(root, name, body) do
    file = Path.join(root, "deps/fx/src/#{name}.erl")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "-module(#{name}).\n" <> body)

    {:ok, ^name, beam} =
      File.cd!(Path.join(root, "deps/fx"), fn ->
        :compile.file(String.to_charlist(file), [:binary, :report_errors])
      end)

    beam
  end

  # Dependency fxa's macro keeps its location; fxb's module uses it, so
  # fxb's line table names fxa's file by its absolute path.
  defp compile_keep(root) do
    a_dir = Path.join(root, "deps/fxa")
    b_dir = Path.join(root, "deps/fxb")
    File.mkdir_p!(a_dir)
    File.mkdir_p!(b_dir)

    a = """
    defmodule RelocateTest.KeepA do
      defmacro __using__(_opts) do
        quote location: :keep do
          def hello, do: :hello
        end
      end
    end
    """

    [{RelocateTest.KeepA, _}] =
      File.cd!(a_dir, fn -> Code.compile_string(a, Path.join(a_dir, "lib/a.ex")) end)

    b = "defmodule RelocateTest.KeepB do\n  use RelocateTest.KeepA\nend\n"

    [{RelocateTest.KeepB, beam}] =
      File.cd!(b_dir, fn -> Code.compile_string(b, Path.join(b_dir, "lib/b.ex")) end)

    for m <- [RelocateTest.KeepA, RelocateTest.KeepB], do: :code.delete(m) && :code.purge(m)
    beam
  end

  # `beam` with its CInf `source` left out, as a deterministic compile
  # writes it.
  defp no_source(beam) do
    {:ok, mod, chunks} = :beam_lib.all_chunks(beam)

    chunks =
      for {id, data} <- chunks do
        if id == ~c"CInf",
          do:
            {id,
             data
             |> :erlang.binary_to_term()
             |> List.keydelete(:source, 0)
             |> :erlang.term_to_binary()},
          else: {id, data}
      end

    {:ok, bytes} = :beam_lib.build_module(chunks)
    _ = mod
    bytes
  end

  defp all_but_metadata(beam) do
    {:ok, _, chunks} = :beam_lib.all_chunks(beam)
    for {id, data} <- chunks, id not in [~c"CInf", ~c"Dbgi", ~c"Docs"], do: {id, data}
  end

  defp stripped(beam) do
    {:ok, {_, plain}} = :beam_lib.strip(beam)
    {:ok, _, chunks} = :beam_lib.all_chunks(plain)
    {:ok, _, all} = :beam_lib.all_chunks(beam)
    chunks ++ [List.keyfind(all, ~c"Attr", 0)]
  end

  # The builder's three roots under `prefix` (pinned_record/2), which the
  # client takes while `config :precompiled, relocation_prefix:` names it.
  defp pin!(prefix) do
    Application.put_env(:precompiled, :relocation_prefix, prefix)
    on_exit(fn -> Application.delete_env(:precompiled, :relocation_prefix) end)
    Relocate.pinned_record(1, prefix)
  end

  # An entry of `ebin` whose record, the builder's roots under the tmp dir,
  # lists `files`: the user's root under the same tmp dir is inside the
  # envelope.
  defp entry(ctx, ebin, files) do
    record = ctx.tmp_dir |> pin!() |> Map.put("files", files)
    %{"ebin" => Enum.map(ebin, &%{"path" => &1}), "priv" => [], "relocation" => record}
  end

  defp roots(ctx), do: {Path.join(ctx.tmp_dir, "work/proj"), Path.join(ctx.tmp_dir, "home/u/app")}

  # Roots under a short dir of the system's temp dir, for a test that makes
  # an atom of a path: an atom holds at most 255 characters, and ExUnit's
  # tmp dir under a checkout can be longer than that.
  defp short_roots() do
    base = Path.join(System.tmp_dir!(), "s4r#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {Path.join(base, "work/proj"), Path.join(base, "home/u/app")}
  end

  @fine "@include_dir Path.expand(\"c_include\")\ndef include_dir, do: @include_dir"

  # OTP 27 compresses the literal table, which no rewrite reads: these run
  # on OTP 28 and later, the one below on OTP 27 alone.
  describe "on OTP 28 or later" do
    @describetag skip: not @otp28 and "relocated builds need OTP 28 or later"

    # The client review's S2: the md5 as the running OTP takes it
    # (beam_lib:md5/1; OTP 29 adds Recs and DbgB). An Erlang module with
    # its own vsn, beam debug info and a fun: its FunT old_uniq comes from
    # the md5, and nothing else would show a wrong one. On OTP 29 also a
    # native record whose default is the path (the client re-review's R4),
    # so the module has a Recs chunk.
    test "an Erlang module with its own vsn, beam debug info and a fun", ctx do
      {builder, user} = roots(ctx)

      record =
        if @otp29,
          do: "-export([h/0]).\n-record #st{file = ?FILE}.\n",
          else: ""

      body =
        record <>
          """
          -vsn("1.2").
          -compile(beam_debug_info).
          -export([f/0, g/0]).
          f() -> ?FILE.
          g() -> fun() -> ok end.
          """ <> if(@otp29, do: "h() -> #st{}.\n", else: "")

      served = compile_erl(builder, :reloc_md5, body)
      own = compile_erl(user, :reloc_md5, body)
      {:ok, _, chunks} = :beam_lib.all_chunks(served)
      assert List.keymember?(chunks, ~c"Recs", 0) == @otp29
      assert {:ok, occs} = Relocate.occurrences(served, slots(builder))
      assert {:ok, moved} = Relocate.relocate(served, occs, slots(builder), slots(user))
      assert stripped(moved) == stripped(own)
      assert all_but_metadata(moved) == all_but_metadata(own)
    end

    # The client review's N2: a Line occurrence from a real compile, a
    # macro of another dependency that keeps its location.
    test "a line table file name from another dependency's macro", ctx do
      {builder, user} = roots(ctx)
      served = compile_keep(builder)
      own = compile_keep(user)
      assert {:ok, occs} = Relocate.occurrences(served, slots(builder))
      assert Enum.any?(occs, &(&1["chunk"] == "Line"))
      assert {:ok, moved} = Relocate.relocate(served, occs, slots(builder), slots(user))
      assert stripped(moved) == stripped(own)
      assert all_but_metadata(moved) == all_but_metadata(own)
    end

    # The client review's S1 and N2: atom 1 is the module's name; no
    # record may rename it.
    test "a record that names atom 1, the module's name, is refused", _ctx do
      {builder, user} = short_roots()
      module = String.to_atom(Path.join(builder, "deps/fx/lib"))

      forms = [
        {:attribute, 1, :module, module},
        {:attribute, 1, :export, [d: 0]},
        {:function, 1, :d, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
      ]

      {:ok, ^module, served} = :compile.forms(forms, [:binary])

      assert {:refuse, "a path in a module or function name"} =
               Relocate.occurrences(served, slots(builder))

      occ = %{
        "chunk" => "AtU8",
        "index" => 1,
        "term" => [],
        "kind" => "atom",
        "parts" => ["", "deps", "/fx/lib"]
      }

      assert {:refuse, _} = Relocate.relocate(served, [occ], slots(builder), slots(user))
    end

    # The client review's S4: the limit on an atom is 255 code points, and
    # a beam's short atom table holds 255 bytes; nothing is truncated.
    test "an atom over 255 code points, or over 255 bytes in a short table, is refused", _ctx do
      base = Path.join(System.tmp_dir!(), "s4atom#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      builder = Path.join(base, "b")
      served = compile(builder, Atomic, "@a String.to_atom(__DIR__)\ndef a, do: @a")
      {:ok, occs} = Relocate.occurrences(served, slots(builder))
      marks = "/" <> String.duplicate("e\u0301", 130)

      # 130 graphemes, 260 code points.
      assert {:refuse, _} =
               Relocate.relocate(served, occs, slots(builder), slots(Path.join(base, marks)))

      short =
        compile(
          builder,
          Short,
          "@compile :no_long_atoms\n@a String.to_atom(__DIR__ <> String.duplicate(\"\u00e9\", 80))\ndef a, do: @a"
        )

      {:ok, occs} = Relocate.occurrences(short, slots(builder))
      longer = Path.join(base, String.duplicate("b", 40))

      assert {:refuse, _} = Relocate.relocate(short, occs, slots(builder), slots(longer))
    end

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

    test "paths in maps, keyword lists, atoms and the build path", _ctx do
      body = """
      @cfg %{file: Path.join(__DIR__, "x"), opts: [priv: Path.join(@build, "lib/fx/priv")]}
      @a String.to_atom(__DIR__)
      def cfg, do: {@cfg, @a, fn -> :ok end}
      """

      {builder, user} = short_roots()
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
      path = "ebin/Elixir.RelocateTest.Staged.beam"
      entry = entry(ctx, [path], [])
      from = Map.take(entry["relocation"], ["deps", "build"])
      assert from["deps"] == Path.join(builder, "deps")
      {:ok, occs} = Relocate.occurrences(served, from)
      entry = put_in(entry, ["relocation", "files"], [%{"path" => path, "occurrences" => occs}])
      staging = Path.join(ctx.tmp_dir, "staging")
      File.mkdir_p!(Path.join(staging, "ebin"))
      File.write!(Path.join(staging, path), served)

      assert :ok = Relocate.apply_staged(staging, entry, slots(user), :fx)
      moved = File.read!(Path.join(staging, path))
      assert stripped(moved) == stripped(own)

      bad =
        put_in(entry, ["relocation", "files"], [
          %{"path" => "ebin/../x.beam", "occurrences" => occs}
        ])

      assert {:fail, "relocation refused: " <> _} =
               Relocate.apply_staged(staging, bad, slots(user), :fx)
    end

    # The client re-review's R1: the record's roots are the builder's own,
    # and each served beam was compiled from the package's own dir under
    # the record's deps path.
    test "apply_staged refuses roots not the builder's, or a beam compiled elsewhere", ctx do
      {builder, user} = roots(ctx)
      path = "ebin/Elixir.RelocateTest.Where.beam"
      entry = entry(ctx, [path], [])
      from = Map.take(entry["relocation"], ["deps", "build"])
      served = compile(builder, Where, @fine)
      {:ok, occs} = Relocate.occurrences(served, from)
      entry = put_in(entry, ["relocation", "files"], [%{"path" => path, "occurrences" => occs}])
      staging = Path.join(ctx.tmp_dir, "staging")
      File.mkdir_p!(Path.join(staging, "ebin"))

      stage = fn beam -> File.write!(Path.join(staging, path), beam) end

      # Another package's dir under the same deps path.
      stage.(served)

      assert {:fail, "relocation refused: " <> why} =
               Relocate.apply_staged(staging, entry, slots(user), :fy)

      assert why =~ "not compiled from the record's deps path"

      # Compiled from the same package dir at another root.
      elsewhere = Path.join(ctx.tmp_dir, "other/work/proj")
      stage.(compile(elsewhere, Where, @fine))

      assert {:fail, "relocation refused: " <> _} =
               Relocate.apply_staged(staging, entry, slots(user), :fx)

      # A beam with no source: a deterministic compile.
      stage.(served)
      assert :ok = Relocate.apply_staged(staging, entry, slots(user), :fx)
      stage.(no_source(served))

      assert {:fail, "relocation refused: " <> why} =
               Relocate.apply_staged(staging, entry, slots(user), :fx)

      assert why =~ "not compiled from the record's deps path"

      # The builder's roots under no prefix: not these.
      stage.(served)
      Application.put_env(:precompiled, :relocation_prefix, "")

      assert {:fail, "relocation refused: the record's roots are not the builder's"} =
               Relocate.apply_staged(staging, entry, slots(user), :fx)
    end
  end

  describe "on OTP 28 or later, round 3" do
    @describetag skip: not @otp28 and "relocated builds need OTP 28 or later"

    # The client re-review's R5: nothing ties the build root to the beams
    # but Mix's own layout under it. A build slot followed by anything but
    # nothing, `/lib/` or `/consolidated/` is refused, in the record and
    # in the occurrences derived from the served beam.
    for {label, tail} <- [{"an underscore", "_x"}, {"another dir", "/x"}] do
      test "a build path followed by #{label} is refused", ctx do
        {builder, user} = roots(ctx)
        path = "ebin/Elixir.RelocateTest.Tail.beam"
        entry = entry(ctx, [path], [])
        from = Map.take(entry["relocation"], ["deps", "build"])
        body = "@p #{inspect(from["build"] <> unquote(tail) <> "/lib/fx/priv")}\ndef p, do: @p"
        assert Path.dirname(from["deps"]) == builder
        served = compile(builder, Tail, body)
        {:ok, occs} = Relocate.occurrences(served, from)
        assert [%{"parts" => ["", "build", unquote(tail) <> "/lib/fx/priv"]}] = occs
        files = [%{"path" => path, "occurrences" => occs}]
        entry = put_in(entry, ["relocation", "files"], files)

        assert Relocate.record_problem(entry["relocation"], [path]) =~ "a build path followed by"

        staging = Path.join(ctx.tmp_dir, "staging")
        File.mkdir_p!(Path.join(staging, "ebin"))
        File.write!(Path.join(staging, path), served)

        assert {:fail, "relocation refused: " <> why} =
                 Relocate.apply_staged(staging, entry, slots(user), :fx)

        assert why =~ "a build path followed by"

        # The derived occurrences are held to the rule too, whatever the
        # record says.
        assert {:fail, "relocation refused: " <> _} =
                 Relocate.apply_staged(
                   staging,
                   put_in(entry, ["relocation", "files"], []),
                   slots(user),
                   :fx
                 )
      end
    end

    test "a build path followed by /lib/ is taken", ctx do
      {builder, user} = roots(ctx)
      path = "ebin/Elixir.RelocateTest.Lib.beam"
      entry = entry(ctx, [path], [])
      from = Map.take(entry["relocation"], ["deps", "build"])
      body = "@p #{inspect(from["build"] <> "/lib/fx/priv")}\ndef p, do: @p"
      served = compile(builder, Lib, body)
      {:ok, occs} = Relocate.occurrences(served, from)
      entry = put_in(entry, ["relocation", "files"], [%{"path" => path, "occurrences" => occs}])
      staging = Path.join(ctx.tmp_dir, "staging")
      File.mkdir_p!(Path.join(staging, "ebin"))
      File.write!(Path.join(staging, path), served)
      assert :ok = Relocate.apply_staged(staging, entry, slots(user), :fx)
    end

    # The umbrella re-review's Q1: a dependent held only for its
    # dependencies is served as a relocated build with no file to rewrite:
    # its beams must hold no builder path, and the envelope and the source
    # check still hold.
    test "a record with no files installs beams that hold no builder path", ctx do
      {builder, user} = roots(ctx)
      path = "ebin/Elixir.RelocateTest.Plain.beam"
      entry = entry(ctx, [path], [])
      assert Relocate.record_problem(entry["relocation"], [path]) == nil
      served = compile(builder, Plain, "def a, do: :a")
      staging = Path.join(ctx.tmp_dir, "staging")
      File.mkdir_p!(Path.join(staging, "ebin"))
      File.write!(Path.join(staging, path), served)
      assert :ok = Relocate.apply_staged(staging, entry, slots(user), :fx)
      assert File.read!(Path.join(staging, path)) == served

      holder = compile(builder, Holder, @fine)
      File.write!(Path.join(staging, path), holder)

      assert {:fail, "relocation refused: " <> why} =
               Relocate.apply_staged(staging, entry, slots(user), :fx)

      assert why =~ "the record does not match the served beam"
    end
  end

  describe "on OTP 27" do
    @describetag skip: @otp28 and "OTP 27 only"

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

  # The umbrella reviews' B1 and R1: the client relocates only to paths
  # inside the envelope the builder's three roots span.
  describe "envelope_reason/2" do
    @record Relocate.pinned_record(1)

    test "a path inside the envelope is taken" do
      for user <- [
            %{"deps" => "/home/u/app/deps", "build" => "/home/u/app/_build/dev"},
            %{
              "deps" => "/Users/alice/My Projects/my-app.2/deps",
              "build" => "/Users/alice/My Projects/my-app.2/_build/dev"
            },
            %{
              "deps" => "/home/u/.cache/mix/installs/elixir-1.19.1-erts-15.2/0a1b2c3d/deps",
              "build" => "/home/u/.cache/mix/installs/elixir-1.19.1-erts-15.2/0a1b2c3d/_build/dev"
            },
            %{"deps" => "/srv/x_y@z~1/app/deps", "build" => "/srv/x_y@z~1/app/_build/dev"}
          ] do
        assert Relocate.envelope_reason(@record, user) == nil, inspect(user)
      end
    end

    test "the third root widens the envelope: upper case, spaces and long paths" do
      deps =
        "/Users/Alice Smith/Projects/" <> String.duplicate("Long Directory Name ", 6) <> "x/deps"

      assert byte_size(deps) > byte_size(@record["second"]["deps"])
      assert byte_size(deps) <= byte_size(@record["third"]["deps"])
      user = %{"deps" => deps, "build" => "/home/u/app/_build/dev"}
      assert Relocate.envelope_reason(@record, user) == nil

      # Without the third root the same path is outside.
      two = Map.put(@record, "third", Map.take(@record, ["deps", "build"]))
      assert %{code: :relocated_path_envelope} = Relocate.envelope_reason(two, user)
    end

    test "a path outside the envelope is a miss of its own" do
      inside = %{"deps" => "/home/u/app/deps", "build" => "/home/u/app/_build/dev"}

      for {slot, path} <- [
            {"deps", "/app/deps"},
            {"deps", "/home/u+x/app/deps"},
            {"deps", "/home/u!x/app/deps"},
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

  # The client re-review's R1: the same roots as the portal's
  # Compatibility.Relocation.pinned_record/1, byte for byte. The umbrella's
  # relocation test pins the same literal.
  describe "pinned_problem/2" do
    @pinned_7 %{
      "deps" => "/work/proj/deps",
      "build" => "/work/proj/_build/host",
      "second" => %{
        "deps" =>
          "/home/ncc-relocate/.cache/mix/installs/elixir-1.20.5-erts-16.4.0.2/ncc-relocate-7/nix/store/src/code/projects/x_y@z~0.d/app/deps",
        "build" =>
          "/home/ncc-relocate/.cache/mix/installs/elixir-1.20.5-erts-16.4.0.2/ncc-relocate-7/nix/store/src/code/projects/x_y@z~0.d/app/out.d/host-1"
      },
      "third" => %{
        "deps" =>
          "/Users/Ncc-Relocate 7/Library/Mobile Documents/ABCDEFGHIJKLMNOPQRSTUVWXYZ/0123456789/abcdefghijklmnopqrstuvwxyz/Long Relocation.Path-0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz/x/Y/z-0/Projects/The Relocated.Project-2/Deps vendored_d",
        "build" =>
          "/Users/Ncc-Relocate 7/Library/Mobile Documents/ABCDEFGHIJKLMNOPQRSTUVWXYZ/0123456789/abcdefghijklmnopqrstuvwxyz/Long Relocation.Path-0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz/x/Y/z-0/Projects/The Relocated.Project-2/Build-3/Host 4"
      }
    }

    test "the builder's own roots, byte for byte the portal's" do
      assert Relocate.pinned_record(7) == @pinned_7
      assert Relocate.pinned_problem(Map.put(@pinned_7, "files", []), "") == nil
    end

    test "any other root is refused" do
      bad = "the record's roots are not the builder's"

      for record <- [
            put_in(@pinned_7, ["build"], "/work/proj/_build/dev"),
            put_in(
              @pinned_7,
              ["second", "deps"],
              String.replace(@pinned_7["second"]["deps"], "-7/", "-8/")
            ),
            put_in(@pinned_7, ["third"], Relocate.pinned_record(8)["third"]),
            put_in(@pinned_7, ["third", "deps"], "/tmp/deps"),
            Map.delete(@pinned_7, "third"),
            %{},
            nil
          ] do
        assert Relocate.pinned_problem(record, "") == bad, inspect(record)
      end

      # Under a prefix (tests), the real roots are not taken.
      assert Relocate.pinned_problem(@pinned_7, "/tmp/x") == bad
      assert Relocate.pinned_problem(Relocate.pinned_record(7, "/tmp/x"), "/tmp/x") == nil
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
