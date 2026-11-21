# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.RelocatedInstallTest do
  # 0.9.0: installing a relocated build rewrites its beams to this project's
  # paths after the served files are verified, records the relocated
  # hashes in the provenance, and a later run takes the install as its own
  # only while those paths are still the project's.
  use ExUnit.Case, async: false

  alias Precompiled.{Fetch, Relocate}
  alias Precompiled.Fixture, as: F

  @moduletag :tmp_dir
  @lock_entry {:hex, :fx, "0.2.0", "i", [:mix], [], "hexpm", "OUTER"}
  @module RelocInstall.Fx

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  defp slots(root),
    do: %{"deps" => Path.join(root, "deps"), "build" => Path.join(root, "_build/dev")}

  # fine's shape, compiled from `<root>/deps/fx`.
  defp compile(root, module \\ @module) do
    dir = Path.join(root, "deps/fx")
    File.mkdir_p!(dir)

    source =
      "defmodule #{inspect(module)} do\n@d Path.expand(\"c_include\")\ndef d, do: @d\nend\n"

    [{^module, beam}] =
      File.cd!(dir, fn -> Code.compile_string(source, Path.join(dir, "lib/fx.ex")) end)

    :code.delete(module)
    :code.purge(module)
    beam
  end

  defp file_entry(sha, size, path),
    do: %{"path" => path, "sha256" => sha, "size" => size, "mode" => 33_188}

  setup %{tmp_dir: dir} do
    f = F.new(dir)

    config = %{
      source: F.base_url(),
      except: [],
      root_path: f.root_path,
      home: Path.join(dir, "home")
    }

    builder = Path.join(dir, "work/proj")
    user = Path.join(dir, "home/u/app")
    File.mkdir_p!(Path.join(user, "deps"))
    File.mkdir_p!(Path.join(user, "_build/dev/lib"))
    served = compile(builder)
    # OTP 27 compresses the literal table, which no rewrite reads: there the
    # occurrence is the one a portal would record on OTP 28.
    occs =
      case Relocate.occurrences(served, slots(builder)) do
        {:ok, occs} ->
          occs

        {:refuse, _} ->
          [
            %{
              "chunk" => "LitT",
              "index" => 0,
              "term" => [],
              "kind" => "binary",
              "parts" => ["", "deps", "/fx/c_include"]
            }
          ]
      end

    app = "{application, fx, [{modules, ['Elixir.#{inspect(@module)}']}]}.\n"
    beam_path = "ebin/Elixir.#{inspect(@module)}.beam"

    entry = %{
      "target" => "pure_elixir",
      "ebin" => [
        file_entry(F.file(f, served), byte_size(served), beam_path),
        file_entry(F.file(f, app), byte_size(app), "ebin/fx.app")
      ],
      "priv" => [],
      "build" => %{},
      "relocation" =>
        slots(builder)
        |> Map.put(
          "second",
          slots(Path.join(dir, "Second Root.d/A-0123456789/abcdefghijklmnopqrstuvwxyz/proj"))
        )
        |> Map.put("files", [%{"path" => beam_path, "occurrences" => occs}])
    }

    %{
      f: f,
      config: config,
      entry: entry,
      served: served,
      occs: occs,
      builder: builder,
      user: user,
      lib: Path.join(user, "_build/dev/lib"),
      deps: Path.join(user, "deps"),
      beam_path: beam_path,
      prov: %{
        sha: String.duplicate("ab", 32),
        path: "v2/manifests",
        sequence: 1,
        files_sha256: "h"
      }
    }
  end

  @otp28 String.to_integer(System.otp_release()) >= 28

  describe "on OTP 28 or later" do
    @describetag skip: not @otp28 and "relocated builds need OTP 28 or later"

    test "the installed beam is the served one relocated to this project's paths", ctx do
      to = slots(ctx.user)

      assert {:ok, _} =
               Fetch.install(ctx.config, :fx, ctx.entry, @lock_entry, ctx.lib,
                 deps_path: ctx.deps,
                 provenance: ctx.prov,
                 relocate: to
               )

      installed = File.read!(Path.join([ctx.lib, "fx", ctx.beam_path]))
      {:ok, expected} = Relocate.relocate(ctx.served, ctx.occs, slots(ctx.builder), to)
      assert installed == expected
      assert installed != ctx.served

      doc = ctx.lib |> Fetch.provenance_path(:fx) |> File.read!() |> :json.decode()
      assert %{"deps" => deps, "build" => build, "files" => %{} = files} = doc["relocated"]
      assert %{"deps" => deps, "build" => build} == to
      assert files[ctx.beam_path] == %{"sha256" => sha(installed), "size" => byte_size(installed)}
    end

    test "installed_as? takes the install while its paths are the project's", ctx do
      to = slots(ctx.user)

      {:ok, _} =
        Fetch.install(ctx.config, :fx, ctx.entry, @lock_entry, ctx.lib,
          deps_path: ctx.deps,
          provenance: ctx.prov,
          relocate: to
        )

      assert Fetch.installed_as?(ctx.lib, :fx, ctx.entry, relocate: to)
      assert Fetch.relocated_for?(ctx.lib, :fx, ctx.entry, to)
      moved = slots(Path.join(ctx.user, "moved"))
      refute Fetch.installed_as?(ctx.lib, :fx, ctx.entry, relocate: moved)
      refute Fetch.relocated_for?(ctx.lib, :fx, ctx.entry, moved)
      refute Fetch.installed_as?(ctx.lib, :fx, ctx.entry)

      # A kept build's provenance rewrite keeps the record.
      assert :ok = Fetch.write_provenance_file(ctx.lib, :fx, %{ctx.prov | sequence: 2})
      assert Fetch.installed_as?(ctx.lib, :fx, ctx.entry, relocate: to)
    end

    # The client review's S1: the client derives every occurrence from the
    # served beams itself and checks every file of the entry.
    test "a record that does not match the served beams installs nothing", ctx do
      fewer = put_in(ctx.entry, ["relocation", "files"], [])

      other =
        put_in(
          ctx.entry,
          ["relocation", "files", Access.at(0), "occurrences", Access.at(0), "index"],
          7
        )

      for entry <- [fewer, other] do
        assert {:fail, "relocation refused: " <> _} =
                 Fetch.install(ctx.config, :fx, entry, @lock_entry, ctx.lib,
                   deps_path: ctx.deps,
                   provenance: ctx.prov,
                   relocate: slots(ctx.user)
                 )

        refute File.exists?(Path.join(ctx.lib, "fx"))
      end
    end

    test "a builder path in a file the record does not name installs nothing", ctx do
      # A second beam that holds the builder's path, left out of the record.
      second = compile(ctx.builder, RelocInstall.Other)
      [beam, app] = ctx.entry["ebin"]
      mods = "['Elixir.#{inspect(@module)}', 'Elixir.RelocInstall.Other']"
      app_bytes = "{application, fx, [{modules, #{mods}}]}.\n"

      entry = %{
        ctx.entry
        | "ebin" => [
            beam,
            file_entry(
              F.file(ctx.f, second),
              byte_size(second),
              "ebin/Elixir.RelocInstall.Other.beam"
            ),
            %{app | "sha256" => F.file(ctx.f, app_bytes), "size" => byte_size(app_bytes)}
          ]
      }

      assert {:fail, "relocation refused: " <> why} =
               Fetch.install(ctx.config, :fx, entry, @lock_entry, ctx.lib,
                 deps_path: ctx.deps,
                 provenance: ctx.prov,
                 relocate: slots(ctx.user)
               )

      assert why =~ "Elixir.RelocInstall.Other.beam"

      # And a priv file that holds it.
      text = "dir=" <> Path.join(ctx.builder, "deps/fx")
      priv = [file_entry(F.file(ctx.f, text), byte_size(text), "priv/where.txt")]

      assert {:fail, "relocation refused: " <> why} =
               Fetch.install(ctx.config, :fx, %{ctx.entry | "priv" => priv}, @lock_entry, ctx.lib,
                 deps_path: ctx.deps,
                 provenance: ctx.prov,
                 relocate: slots(ctx.user)
               )

      assert why =~ "priv/where.txt"
    end

    test "without this project's slots nothing is installed", ctx do
      assert {:fail, "relocation refused: " <> _} =
               Fetch.install(ctx.config, :fx, ctx.entry, @lock_entry, ctx.lib,
                 deps_path: ctx.deps,
                 provenance: ctx.prov,
                 relocate: nil
               )

      refute File.exists?(Path.join(ctx.lib, "fx"))
    end

    test "a served beam that does not hold the recorded path is not installed", ctx do
      other = compile(Path.join(ctx.user, "elsewhere"))
      [beam, app] = ctx.entry["ebin"]

      entry = %{
        ctx.entry
        | "ebin" => [%{beam | "sha256" => F.file(ctx.f, other), "size" => byte_size(other)}, app]
      }

      assert {:fail, "relocation refused: " <> _} =
               Fetch.install(ctx.config, :fx, entry, @lock_entry, ctx.lib,
                 deps_path: ctx.deps,
                 provenance: ctx.prov,
                 relocate: slots(ctx.user)
               )
    end
  end

  describe "on OTP 27" do
    @describetag skip: @otp28 and "OTP 27 only"

    test "OTP 27: a relocated entry is never installed", ctx do
      assert {:fail, "relocation refused: " <> _} =
               Fetch.install(ctx.config, :fx, ctx.entry, @lock_entry, ctx.lib,
                 deps_path: ctx.deps,
                 provenance: ctx.prov,
                 relocate: slots(ctx.user)
               )
    end
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
