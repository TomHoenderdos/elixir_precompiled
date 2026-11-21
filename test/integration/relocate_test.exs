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
  alias Precompiled.Relocate

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @packages ["fine-0.2.0"]

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
  end
end
