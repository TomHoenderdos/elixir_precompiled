# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.PhxConfigGoldenTest do
  # The portal records the compile-time config a build read as compile_env
  # items valued with the project's config (`:error` when unset). These are
  # the items a LiveView-compiling package's default build carries, matched
  # against the config `mix phx.new` (1.8.16) generates, per Mix env, with
  # the client's own rules.
  use ExUnit.Case, async: true

  alias ElixirPrecompiled.Match

  @moduletag :tmp_dir

  @phx_config """
  import Config
  config :phoenix_live_view, root_tag_attribute: "phx-r"
  import_config "\#{config_env()}.exs"
  """
  @phx_dev """
  import Config
  config :phoenix_live_view,
    debug_heex_annotations: true,
    debug_attributes: true,
    enable_expensive_runtime_checks: true
  """
  @phx_test """
  import Config
  config :phoenix_live_view, enable_expensive_runtime_checks: true
  """
  @no_html_config """
  import Config
  import_config "\#{config_env()}.exs"
  """
  @empty "import Config\n"

  defp enc(term),
    do: Base.url_encode64(:erlang.term_to_binary(term, [:deterministic]), padding: false)

  defp items(values) do
    for {key, value} <- values,
        do: %{"app" => "phoenix_live_view", "path" => [key], "value" => enc(value)}
  end

  # A LiveView-compiling package's default build: none of the keys set.
  defp default(),
    do:
      items([
        {"debug_attributes", :error},
        {"debug_heex_annotations", :error},
        {"root_tag_attribute", :error}
      ])

  # Its variant built with the root_tag_attribute phx_new sets in every env.
  defp phx_prod(),
    do:
      items([
        {"debug_attributes", :error},
        {"debug_heex_annotations", :error},
        {"root_tag_attribute", {:ok, "phx-r"}}
      ])

  @outer "outer-checksum"

  defp build(run_id, compile_env) do
    %{
      "target" => "pure_elixir",
      "ebin" => [],
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "dep_env" => "prod",
        "deps" => %{},
        "compile_env" => compile_env,
        "package_checksum" => @outer,
        "run_id" => run_id
      }
    }
  end

  defp manifest(builds), do: %{"versions" => %{"1.0.0" => %{"builds" => builds}}}

  defp config(dir, files, env) do
    for {name, body} <- files, do: File.write!(Path.join(dir, name), body)
    Config.Reader.read!(Path.join(dir, "config.exs"), env: env)
  end

  # What CompileEnv.lookup/2 answers in a project whose loaded config is
  # `config`, for the one-key paths the portal records.
  defp lookup(config) do
    fn app, [key] ->
      with {_, kw} <- Enum.find(config, fn {a, _} -> Atom.to_string(a) == app end),
           {_, value} <- Enum.find(kw, fn {k, _} -> Atom.to_string(k) == key end) do
        {:ok, value}
      else
        _ -> :error
      end
    end
  end

  defp ctx(config) do
    entry = {:hex, :lib, "1.0.0", "inner", [:mix], [], "hexpm", @outer}

    %{
      name: "lib",
      version: "1.0.0",
      lock_entry: entry,
      lock: %{lib: entry},
      system: {"pure_elixir", nil},
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      dep_env: "prod",
      config: lookup(config),
      prefer: nil
    }
  end

  defp select(dir, files, env, builds),
    do: Match.select(manifest(builds), ctx(config(dir, files, env)))

  @phx [
    {"config.exs", @phx_config},
    {"dev.exs", @phx_dev},
    {"test.exs", @phx_test},
    {"prod.exs", @empty}
  ]
  @no_html [
    {"config.exs", @no_html_config},
    {"dev.exs", @empty},
    {"test.exs", @empty},
    {"prod.exs", @empty}
  ]

  test "a --no-html app takes the default build in every env", %{tmp_dir: dir} do
    for env <- [:dev, :test, :prod] do
      assert {:ok, %{"build" => %{"run_id" => "default"}}, "pure_elixir"} =
               select(dir, @no_html, env, [build("default", default())]),
             "#{env}"
    end
  end

  test "a phx_new app misses the default build, naming the keys its config sets",
       %{tmp_dir: dir} do
    assert {:miss,
            "compile_env differs: phoenix_live_view [:debug_attributes], " <>
              "phoenix_live_view [:debug_heex_annotations], phoenix_live_view [:root_tag_attribute]"} =
             select(dir, @phx, :dev, [build("default", default())])

    for env <- [:test, :prod] do
      assert {:miss, "compile_env differs: phoenix_live_view [:root_tag_attribute]"} =
               select(dir, @phx, env, [build("default", default())]),
             "#{env}"
    end
  end

  # Config variants of one version side by side, in either order. The
  # released client picks the one whose recorded values equal the project's
  # config, never just the first listed.
  test "with a phx_prod variant listed, each app takes its own build", %{tmp_dir: dir} do
    variants = [build("default", default()), build("phx_prod", phx_prod())]

    for builds <- [variants, Enum.reverse(variants)] do
      order = Enum.map_join(builds, ",", & &1["build"]["run_id"])

      for env <- [:test, :prod] do
        assert {:ok, %{"build" => %{"run_id" => "phx_prod"}}, _} =
                 select(dir, @phx, env, builds),
               "#{order} #{env}"
      end

      assert {:miss, "compile_env differs: " <> _} = select(dir, @phx, :dev, builds), order

      assert {:ok, %{"build" => %{"run_id" => "default"}}, _} =
               select(dir, @no_html, :prod, builds),
             order
    end
  end

  test "a value the client cannot decode is a miss, never a hit", %{tmp_dir: dir} do
    bad = [%{"app" => "phoenix_live_view", "path" => ["root_tag_attribute"], "value" => "!!"}]
    assert {:miss, "malformed entry"} = select(dir, @no_html, :prod, [build("bad", bad)])
  end
end
