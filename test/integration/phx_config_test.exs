# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Integration.PhxConfigTest do
  # A real child project in dev, test and prod, whose config is phx_new's
  # (1.8.16) or a --no-html app's, against a build whose compile_env records
  # LiveView's compile-time keys as the portal does for a LiveView-compiling
  # package's default build. jason carries the list: the client checks
  # compile_env items generically, whatever package they come on.
  use ExUnit.Case, async: false

  alias ElixirPrecompiled.ChildProject, as: C
  alias ElixirPrecompiled.Fixture, as: F

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  @keys ["debug_attributes", "debug_heex_annotations", "root_tag_attribute"]

  defp enc(term),
    do: Base.url_encode64(:erlang.term_to_binary(term, [:deterministic]), padding: false)

  defp default_items(),
    do:
      for(
        key <- @keys,
        do: %{"app" => "phoenix_live_view", "path" => [key], "value" => enc(:error)}
      )

  defp write_config!(proj, f, phx?) do
    head = """
    import Config
    config :elixir_precompiled, source: #{inspect(F.base_url())}, root: #{inspect(f.root_path)}
    """

    lv = if phx?, do: ~s(config :phoenix_live_view, root_tag_attribute: "phx-r"\n), else: ""

    File.write!(
      Path.join(proj, "config/config.exs"),
      head <> lv <> ~s|import_config "\#{config_env()}.exs"\n|
    )

    dev =
      if phx?,
        do: """
        config :phoenix_live_view,
          debug_heex_annotations: true,
          debug_attributes: true,
          enable_expensive_runtime_checks: true
        """,
        else: ""

    test =
      if phx?, do: "config :phoenix_live_view, enable_expensive_runtime_checks: true\n", else: ""

    for {env, body} <- [{"dev", dev}, {"test", test}, {"prod", ""}],
        do: File.write!(Path.join(proj, "config/#{env}.exs"), "import Config\n" <> body)
  end

  defp compile!(proj, env) do
    File.rm_rf!(Path.join(proj, "_build/#{env}/lib/jason"))
    out = C.mix!(proj, ["compile"], [{"MIX_ENV", env}])

    assert File.dir?(Path.join(proj, "_build/#{env}/lib/jason")),
           "#{env}: no _build/#{env}\n" <> out

    out
  end

  test "phx_new config misses in every env with the keys it sets; --no-html hits",
       %{tmp_dir: dir} do
    f = F.new(dir)
    proj = C.plain!(dir, f)
    entry = C.publish_jason!(f, proj)
    lv_build = put_in(entry, ["build", "compile_env"], default_items())

    F.publish(f, %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [lv_build]}}}},
      sequence: 3
    )

    write_config!(proj, f, true)

    assert compile!(proj, "dev") =~
             ~r/precompiled: jason 1\.4\.5\s+MISS\s+compile_env differs: phoenix_live_view \[:debug_attributes\], phoenix_live_view \[:debug_heex_annotations\], phoenix_live_view \[:root_tag_attribute\]/

    for env <- ["test", "prod"] do
      out = compile!(proj, env)

      assert out =~
               ~r/precompiled: jason 1\.4\.5\s+MISS\s+compile_env differs: phoenix_live_view \[:root_tag_attribute\]\n/,
             "#{env}:\n" <> out
    end

    write_config!(proj, f, false)

    for env <- ["dev", "test", "prod"] do
      out = compile!(proj, env)
      assert out =~ ~r/precompiled: jason 1\.4\.5\s+HIT/, "#{env}:\n" <> out
    end
  end
end
