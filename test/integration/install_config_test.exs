# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Integration.InstallConfigTest do
  # Mix.install/2's config: and config_path: are what its deps compile
  # with, so install/2 checks a build's compile-time config against them:
  # a build that recorded a key unset misses when config: sets it, and one
  # that recorded the value config: sets hits.
  use ExUnit.Case, async: false
  alias Precompiled.ChildProject, as: C
  alias Precompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @script """
  [source, root, mode] = System.argv()
  Application.put_env(:precompiled, :source, source)
  Application.put_env(:precompiled, :root, root)

  opts =
    case mode do
      "none" -> []
      "config" -> [config: [precompiled_probe: [k: 1]]]
      "config_path" -> [config_path: Path.join(__DIR__, "probe_config.exs")]
      "both" -> [config: [precompiled_probe: [k: 1]], config_path: Path.join(__DIR__, "probe_config.exs")]
      "unreadable" -> [config_path: Path.join(__DIR__, "broken_config.exs")]
    end

  Precompiled.Host.install([{:jason, "1.4.5"}], opts)
  IO.puts("mix_dir=" <> Mix.install_project_dir())
  """

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    f = F.new(dir)
    File.write!(Path.join(dir, "install.exs"), @script)

    File.write!(Path.join(dir, "probe_config.exs"), """
    import Config
    config :precompiled_probe, k: 2
    """)

    File.write!(
      Path.join(dir, "broken_config.exs"),
      "import Config\nconfig :precompiled_probe,\n"
    )

    # Real jason beams, compiled by a plain Mix.install/2, published as the
    # portal's build with the compile-time config read given per test.
    F.publish(f, %{}, sequence: 1)
    {out, 0} = child(dir, f, "none", [{"PRECOMPILED", "0"}])
    mix_dir = line!(out, "mix_dir")
    lib = Path.join(mix_dir, "_build/dev/lib/jason")
    entry = C.jason_entry(f, lib, mix_dir)
    File.rm_rf!(lib)
    %{f: f, entry: entry}
  end

  defp publish(f, entry, recorded) do
    item = %{"app" => "precompiled_probe", "path" => ["k"], "value" => rec(recorded)}
    entry = put_in(entry, ["build", "compile_env"], [item])
    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}, sequence: 2)
  end

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  @hit ~r/precompiled: jason 1\.4\.5\s+HIT/
  @differs ~r/precompiled: jason 1\.4\.5\s+MISS\s+compile_env differs: precompiled_probe \[:k\]/

  test "config: sets a key the build recorded unset: miss", %{tmp_dir: dir, f: f, entry: entry} do
    publish(f, entry, :error)
    {out, 0} = child(dir, f, "config")
    assert out =~ @differs, out

    # The same build with no config: the key is unset here too.
    {out, 0} = child(dir, f, "none")
    assert out =~ @hit, out
  end

  test "config: sets the value the build saw: hit", %{tmp_dir: dir, f: f, entry: entry} do
    publish(f, entry, {:ok, 1})
    {out, 0} = child(dir, f, "config")
    assert out =~ @hit, out

    {out, 0} = child(dir, f, "none")
    assert out =~ @differs, out
  end

  # The file is read as Mix.install/2 reads it, and its keys replace
  # config:'s, as Mix.install/2 applies config: first.
  test "config_path: is read and wins over config:", %{tmp_dir: dir, f: f, entry: entry} do
    publish(f, entry, {:ok, 2})
    {out, 0} = child(dir, f, "config_path")
    assert out =~ @hit, out
    {out, 0} = child(dir, f, "both")
    assert out =~ @hit, out
    {out, 0} = child(dir, f, "config")
    assert out =~ @differs, out
  end

  # Mix.install/2 then fails on the same file; the check must not have
  # placed a build it could not check first.
  test "an unreadable config_path: misses every build that reads config", %{
    tmp_dir: dir,
    f: f,
    entry: entry
  } do
    publish(f, entry, :error)
    {out, status} = child(dir, f, "unreadable")
    assert status != 0, out
    assert out =~ ~r/precompiled: config_path ".*broken_config\.exs" could not be read/, out
    assert out =~ ~r/precompiled: jason 1\.4\.5\s+MISS\s+compile_env differs/, out
    refute out =~ @hit, out
  end

  # cmd!/3 raises on a non-zero exit; the unreadable case expects one.
  defp child(dir, f, mode, env \\ []) do
    argv = [
      "elixir",
      "-pa",
      C.own_ebin(),
      Path.join(dir, "install.exs"),
      F.base_url(),
      f.root_path,
      mode
    ]

    env =
      [
        {"MIX_INSTALL_DIR", Path.join(dir, "installs")},
        {"PRECOMPILED_HOME", Path.join(dir, "home")},
        {"MIX_ENV", nil},
        {"MIX_TARGET", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_BUILD_ROOT", nil},
        {"MIX_DEPS_PATH", nil}
      ] ++ env

    try do
      {C.cmd!(argv, dir, env: env), 0}
    rescue
      e in ExUnit.AssertionError ->
        {e.message, 1}
    end
  end

  defp line!(out, key) do
    case Regex.run(~r/^#{key}=(.+)$/m, out, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("no #{key}= line in the child's output:\n" <> out)
    end
  end
end
