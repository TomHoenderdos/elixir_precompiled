# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.RelocateTest do
  # 0.9.0's proof for relocated builds: fine 0.2.0, whose Fine.include_dir/0
  # returns the path its compile ran in (`Path.expand("c_include")` from
  # fine's own dir), compiled from source by Mix twice, in a builder's
  # project and in a user's at another path. The builder's beam relocated
  # to the user's deps and build paths must be the user's own compile chunk
  # for chunk after beam_lib:strip/1, its Attr too, and load to return the
  # user's path.
  use ExUnit.Case, async: false

  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F
  alias Precompiled.Relocate

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @packages ["fine-0.2.0"]
  @include ~s|IO.puts("include=" <> Fine.include_dir())|

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  defp project!(dir, path) do
    proj = Path.join([dir, path, "proj"])
    File.mkdir_p!(proj)

    File.write!(Path.join(proj, "mix.exs"), """
    defmodule P.MixProject do
      use Mix.Project
      def project, do: [app: :p, version: "0.1.0", deps: [{:fine, "== 0.2.0"}]]
    end
    """)

    C.mix!(proj, ["deps.get"], [], packages: @packages)
    C.mix!(proj, ["deps.compile"], [], packages: @packages)
    proj
  end

  defp mix!(proj, args, env \\ []), do: C.mix!(proj, args, env, packages: @packages)

  defp include(proj) do
    out = mix!(proj, ["run", "--no-start", "-e", @include])
    [path] = Regex.run(~r/^include=(.+)$/m, out, capture: :all_but_first)
    path
  end

  defp publish!(f, entry, seq) do
    F.publish(
      f,
      %{
        "fine" => %{
          "versions" => %{"0.2.0" => %{"builds" => [], "relocated" => %{"builds" => [entry]}}}
        }
      },
      sequence: seq
    )
  end

  defp put_mode(entry, path, mode) do
    Map.update!(entry, "ebin", fn files ->
      Enum.map(files, &if(&1["path"] == path, do: %{&1 | "mode" => mode}, else: &1))
    end)
  end

  defp slots(proj),
    do: %{"deps" => Path.join(proj, "deps"), "build" => Path.join(proj, "_build/dev")}

  defp beam(proj), do: File.read!(Path.join(proj, "_build/dev/lib/fine/ebin/Elixir.Fine.beam"))

  defp stripped(beam) do
    {:ok, {_, plain}} = :beam_lib.strip(beam)
    {:ok, _, chunks} = :beam_lib.all_chunks(plain)
    {:ok, _, all} = :beam_lib.all_chunks(beam)
    chunks ++ [List.keyfind(all, ~c"Attr", 0)]
  end

  if String.to_integer(System.otp_release()) >= 28 do
    test "fine built at the builder's paths, relocated, is the user's own compile", %{
      tmp_dir: dir
    } do
      builder = project!(dir, "w")
      user = project!(dir, "home/someone/projects/my_app")
      served = beam(builder)
      own = beam(user)
      refute served == own

      assert {:ok, [occ]} = Relocate.occurrences(served, slots(builder))

      assert %{"chunk" => "LitT", "kind" => "binary", "parts" => ["", "deps", "/fine/c_include"]} =
               occ

      to = Relocate.user_slots(Path.join(user, "deps"), Path.join(user, "_build/dev"))
      assert to == slots(user)
      assert {:ok, moved} = Relocate.relocate(served, [occ], slots(builder), to)

      assert stripped(moved) == stripped(own)
      assert :beam_lib.md5(moved) == :beam_lib.md5(own)

      {:module, Fine} = :code.load_binary(Fine, ~c"Elixir.Fine.beam", moved)

      try do
        assert apply(Fine, :include_dir, []) == Path.join(user, "deps/fine/c_include")
        {:ok, {Fine, md5}} = :beam_lib.md5(own)
        assert apply(Fine, :module_info, [:md5]) == md5
      after
        :code.delete(Fine)
        :code.purge(Fine)
      end
    end

    # 0.9.0 end to end: fine built from source in a builder's project,
    # published as the portal publishes a relocated build (under the
    # version's `relocated` object, with its record), installed into a
    # user's project and taken through its lifecycle: a re-run, a changed
    # manifest, a moved project. The installed beam is then compared with
    # the user's own compile at the same paths.
    test "lifecycle: a relocated install is the user's own compile, moved or not", %{
      tmp_dir: dir
    } do
      f = F.new(dir)
      F.publish(f, %{}, sequence: 1)
      deps = ~s([{:fine, "== 0.2.0"}, #{C.own_dep()}])

      builder = C.plain!(Path.join(dir, "w"), f, deps: deps)
      mix!(builder, ["deps.get"])
      mix!(builder, ["compile"], [{"PRECOMPILED", "0"}])
      lock_path = Path.join(builder, "mix.lock")
      lock = Mix.Dep.Lock.read(lock_path)
      blib = Path.join(builder, "_build/dev/lib")
      entry = C.build_entry(f, Path.join(blib, "fine"), elem(lock[:fine], 7))
      from = slots(builder)
      assert {:ok, occs} = Relocate.occurrences(beam(builder), from)
      files = [%{"path" => "ebin/Elixir.Fine.beam", "occurrences" => occs}]
      entry = Map.put(entry, "relocation", Map.put(from, "files", files))
      publish!(f, entry, 2)

      # A fresh project on the same lock: installed, relocated to its paths.
      user = Path.join([dir, "home/someone/projects/app", "proj"])
      File.mkdir_p!(Path.dirname(user))
      user = C.plain!(Path.dirname(user), f, deps: deps)
      File.cp!(lock_path, Path.join(user, "mix.lock"))
      mix!(user, ["deps.get"])
      out = mix!(user, ["compile"])
      assert out =~ ~r/precompiled: fine 0\.2\.0\s+HIT/, out
      refute out =~ ~r/==> fine\n/, out
      first = beam(user)
      refute first == beam(builder)
      assert include(user) == Path.join(user, "deps/fine/c_include")

      # A second run keeps it, rewriting nothing.
      again = mix!(user, ["compile"])
      refute again =~ "HIT", again
      refute again =~ "MISS", again
      assert beam(user) == first

      # A changed manifest whose files differ: installed again, relocated
      # to the same paths.
      publish!(f, put_mode(entry, "ebin/fine.app", 0o100755), 3)
      replaced = mix!(user, ["compile"])
      assert replaced =~ ~r/precompiled: fine 0\.2\.0\s+HIT/, replaced
      assert beam(user) == first

      # The project moved: installed again, relocated to its new paths.
      moved = Path.join(dir, "elsewhere/a/much/longer/path/proj")
      File.mkdir_p!(Path.dirname(moved))
      File.rename!(user, moved)
      out = mix!(moved, ["compile"])
      assert out =~ ~r/precompiled: fine 0\.2\.0\s+HIT/, out
      assert include(moved) == Path.join(moved, "deps/fine/c_include")
      installed = beam(moved)
      refute installed == first

      # The proof: Mix's own compile of fine at the same paths.
      disabled = mix!(moved, ["compile"], [{"PRECOMPILED", "0"}])
      assert disabled =~ ~r/==> fine\n/, disabled
      own = beam(moved)
      assert stripped(installed) == stripped(own)
      assert :beam_lib.md5(installed) == :beam_lib.md5(own)
    end
  end
end
