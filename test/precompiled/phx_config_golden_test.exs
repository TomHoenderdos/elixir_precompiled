# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.PhxConfigGoldenTest do
  # The portal records the compile-time config a build read as compile_env
  # items valued with the project's config (`:error` when unset). These are
  # the items a LiveView-compiling package's default build carries, matched
  # against the config `mix phx.new` (1.8.16) generates, per Mix env, with
  # the client's own rules.
  use ExUnit.Case, async: true

  alias Precompiled.Match

  @moduletag :tmp_dir

  @phx_config """
  import Config
  config :phoenix_live_view, root_tag_attribute: "phx-r"
  config :phoenix, :json_library, Jason
  import_config "\#{config_env()}.exs"
  """
  @phx_dev """
  import Config
  config :phoenix, :stacktrace_depth, 20
  config :phoenix, :plug_init_mode, :runtime
  config :phoenix_live_view,
    debug_heex_annotations: true,
    debug_attributes: true,
    enable_expensive_runtime_checks: true
  """
  @phx_test """
  import Config
  config :phoenix, :plug_init_mode, :runtime
  config :phoenix_live_view, enable_expensive_runtime_checks: true
  config :phoenix,
    sort_verified_routes_query_params: true
  """
  @no_html_config """
  import Config
  config :phoenix, :json_library, Jason
  import_config "\#{config_env()}.exs"
  """
  @empty "import Config\n"

  defp enc(term),
    do: Base.url_encode64(:erlang.term_to_binary(term, [:deterministic]), padding: false)

  defp items(values) do
    for {app, key, value} <- values,
        do: %{"app" => app, "path" => [key], "value" => enc(value)}
  end

  # A LiveView-compiling package's default build: none of the keys set.
  defp default(),
    do:
      items([
        {"phoenix_live_view", "debug_attributes", :error},
        {"phoenix_live_view", "debug_heex_annotations", :error},
        {"phoenix_live_view", "root_tag_attribute", :error}
      ])

  # Its variant built with the root_tag_attribute phx_new sets in every env.
  defp phx_prod(),
    do:
      items([
        {"phoenix_live_view", "debug_attributes", :error},
        {"phoenix_live_view", "debug_heex_annotations", :error},
        {"phoenix_live_view", "root_tag_attribute", {:ok, "phx-r"}}
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

  @lv4 ~w(debug_attributes debug_heex_annotations enable_expensive_runtime_checks root_tag_attribute)

  # What every LiveView-closure build records (reads over the whole closure),
  # valued as each variant's overlay sets them.
  defp closure_env(set) do
    # As production records them (polymorphic_embed 5.0.6): the four
    # LiveView keys, no :phoenix key.
    items(
      for k <- @lv4,
          do: {"phoenix_live_view", k, Map.get(set, {"phoenix_live_view", k}, :error)}
    )
  end

  defp v(name, set), do: put_in(build(name, closure_env(set)), ["build", "config_variant"], name)

  @prod_set %{{"phoenix_live_view", "root_tag_attribute"} => {:ok, "phx-r"}}
  @test_set Map.put(
              @prod_set,
              {"phoenix_live_view", "enable_expensive_runtime_checks"},
              {:ok, true}
            )
  @dev_set Map.merge(@test_set, %{
             {"phoenix_live_view", "debug_heex_annotations"} => {:ok, true},
             {"phoenix_live_view", "debug_attributes"} => {:ok, true}
           })

  defp four(),
    do: [
      put_in(build("default", closure_env(%{})), ["build", "run_id"], "default"),
      v("phx_prod", @prod_set),
      v("phx_test", @test_set),
      v("phx_dev", @dev_set)
    ]

  test "with all four variants listed, every env takes its own, in any order", %{tmp_dir: dir} do
    for builds <- [four(), Enum.reverse(four()), Enum.shuffle(four())] do
      for {env, want} <- [dev: "phx_dev", test: "phx_test", prod: "phx_prod"] do
        assert {:ok, %{"build" => %{"run_id" => ^want}}, _} = select(dir, @phx, env, builds),
               "#{env}"
      end

      assert {:ok, %{"build" => %{"run_id" => "default"}}, _} =
               select(dir, @no_html, :prod, builds)
    end
  end

  test "a dev app without debug_attributes takes no variant", %{tmp_dir: dir} do
    edited =
      List.keyreplace(
        @phx,
        "dev.exs",
        0,
        {"dev.exs", String.replace(@phx_dev, "debug_attributes: true,", "")}
      )

    assert {:miss, "compile_env differs: " <> _} = select(dir, edited, :dev, four())
  end

  test "a value the client cannot decode is a miss, never a hit", %{tmp_dir: dir} do
    bad = [%{"app" => "phoenix_live_view", "path" => ["root_tag_attribute"], "value" => "!!"}]
    assert {:miss, "malformed entry"} = select(dir, @no_html, :prod, [build("bad", bad)])
  end
end
