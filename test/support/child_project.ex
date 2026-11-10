# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ChildProject do
  @moduledoc false
  # Real Mix projects in a tmp dir that depend on this checkout by path,
  # exactly as a user adds the library, served by the test fixture, and the
  # one way every integration test starts a child VM (cmd!/3; a unit test
  # holds test/integration to that). Every child runs under a timeout with
  # its own HEX_HOME, seeded from the user's Hex cache, so it neither reads
  # nor rewrites the shared one. With the packages in that cache (registry
  # entries and tarballs, written by this Hex version) the child runs with
  # HEX_OFFLINE=1 and touches no network at all; otherwise the command is
  # retried once online, into the private HEX_HOME.
  #
  # MIX_HOME is shared on purpose: it holds the Hex archive and rebar, which
  # the children only read.
  import ExUnit.Assertions
  alias Precompiled.Fixture, as: F

  @alias ~s(["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"])
  @timeout_s 300

  @spec alias_value() :: String.t()
  def alias_value(), do: @alias

  @spec plain!(Path.t(), map(), keyword()) :: Path.t()
  def plain!(dir, f, opts \\ []) do
    proj = Path.join(dir, "proj")
    File.mkdir_p!(proj)
    aliases = Keyword.get(opts, :aliases, ~s(["deps.loadpaths": #{@alias}]))
    prelude = Keyword.get(opts, :prelude, "")
    deps = Keyword.get(opts, :deps, ~s([{:jason, "1.4.5"}, #{own_dep()}]))

    File.write!(Path.join(proj, "mix.exs"), """
    #{prelude}
    defmodule Proj.MixProject do
      use Mix.Project

      def project do
        [app: :proj, version: "0.1.0", deps: deps(), aliases: #{aliases}]
      end

      defp deps do
        #{deps}
      end
    end
    """)

    write_config!(proj, f)
    proj
  end

  @doc "This checkout as a child's dependency, as a user adds it."
  @spec own_dep() :: String.t()
  def own_dep(), do: "{:precompiled, path: #{inspect(File.cwd!())}, runtime: false}"

  @spec umbrella!(Path.t(), map()) :: Path.t()
  def umbrella!(dir, f) do
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
          deps: [{:jason, "1.4.5"}, {:precompiled, path: #{inspect(File.cwd!())}, runtime: false}]
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
    config :precompiled, source: #{inspect(F.base_url())}, root: #{inspect(f.root_path)}
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
    mix!(proj, ["deps.compile", "jason"], [{"PRECOMPILED", "0"}])
    lib = Path.join(proj, "_build/dev/lib/jason")
    entry = jason_entry(f, lib, proj)
    File.rm_rf!(lib)

    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}, sequence: 2)

    entry
  end

  @spec jason_entry(map(), Path.t(), Path.t()) :: map()
  def jason_entry(f, lib, proj) do
    %{jason: {:hex, :jason, "1.4.5", _, _, _, _, outer}} =
      Mix.Dep.Lock.read(Path.join(proj, "mix.lock"))

    build_entry(f, lib, outer)
  end

  @doc """
  The beams under `lib` (a compiled dep's build dir) published to the
  fixture as a portal `pure_elixir` build made on this toolchain, with
  `checksum` as its package checksum.
  """
  @spec build_entry(map(), Path.t(), String.t()) :: map()
  def build_entry(f, lib, checksum) do
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

    assert files != [], "no beams under #{lib}"

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
        "package_checksum" => checksum,
        "dep_env" => "prod"
      }
    }
  end

  # `pa:` puts this checkout's compiled ebin on the child's code path
  # (`elixir -pa ebin -S mix`) for a project that calls the library without
  # depending on it, as nerves.init does.
  @spec mix!(Path.t(), [String.t()], [{String.t(), String.t() | nil}], keyword()) :: String.t()
  def mix!(proj, args, env \\ [], opts \\ []) do
    argv =
      if Keyword.get(opts, :pa, false),
        do: ["elixir", "-pa", own_ebin(), "-S", "mix" | args],
        else: ["mix" | args]

    env =
      [
        {"MIX_ENV", "dev"},
        {"MIX_TARGET", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_BUILD_ROOT", nil},
        {"MIX_DEPS_PATH", nil},
        {"MIX_EXS", nil},
        {"PRECOMPILED_HOME", Path.join(Path.dirname(proj), "home")}
      ] ++ env

    cmd!(argv, Path.dirname(proj), [cd: proj, env: env] ++ Keyword.take(opts, [:packages]))
  end

  @doc """
  Every Hex package in this checkout's mix.lock as `name-version`, for
  seeding a child that resolves against a copy of that lock.
  """
  @spec lock_packages() :: [String.t()]
  def lock_packages() do
    for {_, {:hex, name, vsn, _, _, _, _, _}} <-
          Mix.Dep.Lock.read(Path.join(File.cwd!(), "mix.lock")),
        do: "#{name}-#{vsn}"
  end

  @spec own_ebin() :: Path.t()
  def own_ebin(), do: Path.join(Mix.Project.build_path(), "lib/precompiled/ebin")

  @doc """
  Runs `argv` with `base/hex` as its HEX_HOME, seeded with `:packages`
  (default jason 1.4.5). `offline: false` skips the offline attempt, for a
  child that needs the network anyway. Raises on a non-zero exit.
  """
  @spec cmd!([String.t()], Path.t(), keyword()) :: String.t()
  def cmd!([exe | args], base, opts) do
    hex_home = Path.join(base, "hex")
    packages = Keyword.get(opts, :packages, ["jason-1.4.5"])
    offline? = Keyword.get(opts, :offline, true) and seed_hex_home!(hex_home, packages)

    run =
      &run_cmd(
        exe,
        args,
        Keyword.put(opts, :env, Keyword.get(opts, :env, []) ++ hex_env(hex_home, &1))
      )

    {out, status} = run.(offline?)

    # A seeded cache another Hex version wrote reads as empty to this one.
    {out, status} =
      if offline? and status != 0 and out =~ "is not cached locally" do
        File.write!(Path.join(hex_home, ".seeded"), seed_marker(false, packages))
        run.(false)
      else
        {out, status}
      end

    assert status == 0, "#{Enum.join([exe | args], " ")} exited #{status}:\n" <> out
    out
  end

  @doc "The HEX_HOME pair every child env carries; HEX_OFFLINE only when offline."
  @spec hex_env(Path.t(), boolean()) :: [{String.t(), String.t() | nil}]
  def hex_env(hex_home, offline?),
    do: [{"HEX_HOME", hex_home}, {"HEX_OFFLINE", if(offline?, do: "1")}]

  defp run_cmd(exe, args, opts) do
    {exe, args} =
      case System.find_executable("timeout") do
        nil -> {exe, args}
        timeout -> {timeout, [to_string(@timeout_s), exe | args]}
      end

    cmd_opts = [env: opts[:env], stderr_to_stdout: true] ++ Keyword.take(opts, [:cd])
    System.cmd(exe, args, cmd_opts)
  end

  # Copies the user's Hex registry cache and the packages' tarballs into
  # `home`; true when all were there to copy. .seeded records the answer for
  # this package list; a call with another list seeds again.
  defp seed_hex_home!(home, packages) do
    marker = Path.join(home, ".seeded")

    case File.read(marker) do
      {:ok, content} ->
        cond do
          content == seed_marker(true, packages) -> true
          content == seed_marker(false, packages) -> false
          true -> seed!(home, packages, marker)
        end

      {:error, _} ->
        seed!(home, packages, marker)
    end
  end

  defp seed!(home, packages, marker) do
    src = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))
    files = ["cache.ets" | Enum.map(packages, &"packages/hexpm/#{&1}.tar")]

    offline? =
      Enum.all?(files, fn rel ->
        match?({:ok, _}, File.copy(Path.join(src, rel), Path.join(home, rel)))
      end)

    File.write!(marker, seed_marker(offline?, packages))
    offline?
  end

  defp seed_marker(offline?, packages),
    do:
      "#{if offline?, do: "offline", else: "online"} #{packages |> Enum.sort() |> Enum.join(",")}"
end
