# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.ChildProject do
  @moduledoc false
  # Real Mix projects in a tmp dir that depend on this checkout by path,
  # exactly as a user adds the library, served by the test fixture. Every
  # child mix runs under a timeout with its own HEX_HOME, seeded from the
  # user's Hex cache, so it neither reads nor rewrites the shared one. With
  # jason 1.4.5 in that cache (the registry entry and the tarball, written
  # by this Hex version) the child runs with HEX_OFFLINE=1 and touches no
  # network at all; otherwise the one deps.get fetches jason from hex.pm.
  import ExUnit.Assertions
  alias ElixirPrecompiled.Fixture, as: F

  @alias ~s(["deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"])
  @timeout_s 300

  @spec alias_value() :: String.t()
  def alias_value(), do: @alias

  @spec plain!(Path.t(), map(), keyword()) :: Path.t()
  def plain!(dir, f, opts \\ []) do
    proj = Path.join(dir, "proj")
    File.mkdir_p!(proj)
    aliases = Keyword.get(opts, :aliases, ~s(["deps.loadpaths": #{@alias}]))
    prelude = Keyword.get(opts, :prelude, "")

    File.write!(Path.join(proj, "mix.exs"), """
    #{prelude}
    defmodule Proj.MixProject do
      use Mix.Project

      def project do
        [app: :proj, version: "0.1.0", deps: deps(), aliases: #{aliases}]
      end

      defp deps do
        [{:jason, "1.4.5"}, {:elixir_precompiled, path: #{inspect(File.cwd!())}, runtime: false}]
      end
    end
    """)

    write_config!(proj, f)
    proj
  end

  @spec umbrella!(Path.t(), map(), keyword()) :: Path.t()
  def umbrella!(dir, f, _opts \\ []) do
    root = Path.join(dir, "umb")
    app = Path.join(root, "apps/a")
    File.mkdir_p!(Path.join(app, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Umb.MixProject do
      use Mix.Project

      def project do
        [apps_path: "apps", version: "0.1.0", deps: [], aliases: ["deps.loadpaths": #{@alias}]]
      end
    end
    """)

    File.write!(Path.join(app, "mix.exs"), """
    defmodule A.MixProject do
      use Mix.Project

      def project do
        [
          app: :a,
          version: "0.1.0",
          build_path: "../../_build",
          config_path: "../../config/config.exs",
          deps_path: "../../deps",
          lockfile: "../../mix.lock",
          deps: [{:jason, "1.4.5"}, {:elixir_precompiled, path: #{inspect(File.cwd!())}, runtime: false}]
        ]
      end
    end
    """)

    write_config!(root, f)
    root
  end

  defp write_config!(proj, f) do
    File.mkdir_p!(Path.join(proj, "config"))

    File.write!(Path.join(proj, "config/config.exs"), """
    import Config
    config :elixir_precompiled, source: #{inspect(F.base_url())}, root: #{inspect(f.root_path)}
    """)
  end

  # deps.get with the alias in place (it must not run the alias), then the
  # real jason beams built here, published as the portal's pure_elixir
  # build, and removed so Mix would have to compile jason again. In an
  # umbrella `proj` is the root, where the shared _build and mix.lock live.
  @spec publish_jason!(map(), Path.t()) :: map()
  def publish_jason!(f, proj) do
    F.publish(f, %{}, sequence: 1)
    mix!(proj, ["deps.get"])
    mix!(proj, ["deps.compile", "jason"], [{"ELIXIR_PRECOMPILED", "0"}])
    lib = Path.join(proj, "_build/dev/lib/jason")
    entry = jason_entry(f, lib, proj)
    File.rm_rf!(lib)

    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}, sequence: 2)

    entry
  end

  @spec jason_entry(map(), Path.t(), Path.t()) :: map()
  def jason_entry(f, lib, proj) do
    files =
      for path <- Path.wildcard(Path.join(lib, "ebin/*")) do
        bytes = File.read!(path)

        %{
          "path" => "ebin/" <> Path.basename(path),
          "sha256" => F.file(f, bytes),
          "size" => byte_size(bytes),
          "mode" => 0o100644
        }
      end

    %{jason: {:hex, :jason, "1.4.5", _, _, _, _, outer}} =
      Mix.Dep.Lock.read(Path.join(proj, "mix.lock"))

    %{
      "target" => "pure_elixir",
      "ebin" => files,
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "run_id" => "r",
        "image_digest" => "d",
        "deps" => %{},
        "compile_env" => [],
        "package_checksum" => outer,
        "dep_env" => "prod"
      }
    }
  end

  @spec mix!(Path.t(), [String.t()], [{String.t(), String.t() | nil}]) :: String.t()
  def mix!(proj, args, env \\ []) do
    hex_home = Path.join(Path.dirname(proj), "hex")
    offline? = seed_hex_home!(hex_home)
    {out, status} = run_mix(proj, args, env, hex_home, offline?)

    # A seeded cache another Hex version wrote reads as empty to this one:
    # fetch jason's registry entry from hex.pm once, into this HEX_HOME.
    {out, status} =
      if offline? and status != 0 and out =~ "is not cached locally" do
        File.write!(Path.join(hex_home, ".seeded"), "online")
        run_mix(proj, args, env, hex_home, false)
      else
        {out, status}
      end

    assert status == 0, "mix #{Enum.join(args, " ")} exited #{status}:\n" <> out
    out
  end

  defp run_mix(proj, args, env, hex_home, offline?) do
    System.cmd(cmd(), cmd_args(args),
      cd: proj,
      env:
        [
          {"MIX_ENV", "dev"},
          {"MIX_TARGET", nil},
          {"MIX_BUILD_PATH", nil},
          {"MIX_DEPS_PATH", nil},
          {"MIX_EXS", nil},
          {"HEX_HOME", hex_home},
          {"HEX_OFFLINE", if(offline?, do: "1")},
          {"ELIXIR_PRECOMPILED_SOURCE", nil},
          {"ELIXIR_PRECOMPILED_HOME", Path.join(Path.dirname(proj), "home")}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  # coreutils timeout bounds a hung child mix; without it the ExUnit
  # timeout still ends the test.
  defp cmd(), do: System.find_executable("timeout") || "mix"

  defp cmd_args(args) do
    if System.find_executable("timeout"), do: [to_string(@timeout_s), "mix" | args], else: args
  end

  # Copies the user's Hex registry cache and the jason tarball into `home`
  # once; true when both were there to copy.
  defp seed_hex_home!(home) do
    marker = Path.join(home, ".seeded")

    if File.exists?(marker) do
      File.read!(marker) == "offline"
    else
      src = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")
      tar = "packages/hexpm/jason-1.4.5.tar"
      File.mkdir_p!(Path.join(home, "packages/hexpm"))

      offline? =
        Enum.all?(["cache.ets", tar], fn rel ->
          match?({:ok, _}, File.copy(Path.join(src, rel), Path.join(home, rel)))
        end)

      File.write!(marker, if(offline?, do: "offline", else: "online"))
      offline?
    end
  end
end
