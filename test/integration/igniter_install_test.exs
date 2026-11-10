# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.IgniterInstallTest do
  use ExUnit.Case, async: false
  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  # Igniter's own dependencies need Elixir 1.18.
  if Version.match?(System.version(), "< 1.18.0"),
    do: @moduletag(skip: "Igniter needs Elixir 1.18")

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  # A project with Igniter and without this library, resolving against a
  # copy of this checkout's lock (the versions this repo tests with).
  defp igniter_project!(dir, f, opts) do
    proj =
      C.plain!(
        dir,
        f,
        Keyword.merge(
          [deps: ~s([{:jason, "1.4.5"}, {:igniter, "~> 0.8", only: [:dev, :test]}])],
          opts
        )
      )

    File.cp!(Path.join(File.cwd!(), "mix.lock"), Path.join(proj, "mix.lock"))
    # The config plain!/3 wrote is the installer's to write.
    File.rm!(Path.join(proj, "config/config.exs"))
    File.write!(Path.join(proj, ".formatter.exs"), "[inputs: [\"*.exs\", \"config/*.exs\"]]\n")
    proj
  end

  defp install!(proj, f) do
    packages = C.lock_packages()
    C.mix!(proj, ["deps.get"], [], packages: packages)

    out =
      C.mix!(
        proj,
        [
          "igniter.install",
          "precompiled@path:#{File.cwd!()}",
          "--yes"
        ],
        [],
        packages: packages
      )

    # The fixture's source and root, which no installer writes.
    config = Path.join(proj, "config/config.exs")
    File.mkdir_p!(Path.dirname(config))

    File.write!(
      config,
      if(File.exists?(config), do: File.read!(config), else: "import Config\n") <>
        "\nconfig :precompiled, source: #{inspect(F.base_url())}, root: #{inspect(f.root_path)}\n"
    )

    out
  end

  # The deps.loadpaths alias as the child's mix.exs writes it, inline or
  # in a function of its own.
  defp alias_list(proj) do
    ast = proj |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!()

    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:"deps.loadpaths", list} = node, nil when is_list(list) -> {node, list}
        node, acc -> {node, acc}
      end)

    assert is_list(found), "no deps.loadpaths alias in #{proj}/mix.exs"
    found
  end

  # The options of the child's precompiled dependency, as written.
  defp own_dep_opts(proj) do
    ast = proj |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!()

    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:{}, _, [:precompiled, opts]} = node, nil -> {node, opts}
        {:precompiled, opts} = node, nil when is_list(opts) -> {node, opts}
        node, acc -> {node, acc}
      end)

    assert is_list(found), "no precompiled dependency in #{proj}/mix.exs"
    found
  end

  test "plain project: igniter.install sets it up and the next compile installs", %{
    tmp_dir: dir
  } do
    f = F.new(dir)
    F.publish(f, %{}, sequence: 1)
    proj = igniter_project!(dir, f, aliases: "[]")
    install!(proj, f)

    assert alias_list(proj) ==
             ["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"]

    assert Keyword.get(own_dep_opts(proj), :runtime) == false

    # Running it again changes nothing.
    before = File.read!(Path.join(proj, "mix.exs"))
    C.mix!(proj, ["precompiled.install", "--yes"], [], packages: C.lock_packages())
    assert File.read!(Path.join(proj, "mix.exs")) == before

    C.publish_jason!(f, proj)
    out = C.mix!(proj, ["compile"], [], packages: C.lock_packages())
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    refute out =~ "==> jason", out
  end

  test "an existing deps.loadpaths alias keeps its steps after ours", %{tmp_dir: dir} do
    f = F.new(dir)
    F.publish(f, %{}, sequence: 1)

    # A step of the user's own, as nerves_bootstrap's would be. (`mix cmd`:
    # a Mix task defined in mix.exs itself trips Igniter's mix.exs editing.)
    proj =
      igniter_project!(dir, f,
        aliases: ~s(["deps.loadpaths": ["cmd echo user step ran", "deps.loadpaths"]])
      )

    install!(proj, f)

    assert alias_list(proj) == [
             "deps.compile precompiled",
             "precompiled.deps",
             "cmd echo user step ran",
             "deps.loadpaths"
           ]

    C.publish_jason!(f, proj)
    out = C.mix!(proj, ["compile"], [], packages: C.lock_packages())
    assert out =~ "user step ran", out
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, out
    refute out =~ "==> jason", out
  end
end
