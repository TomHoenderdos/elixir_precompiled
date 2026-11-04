# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.ConfigTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.Config

  setup do
    old = Application.get_all_env(:elixir_precompiled)
    old_nerves = Application.get_env(:nerves, :precompiled)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:elixir_precompiled),
          do: Application.delete_env(:elixir_precompiled, k)

      Application.put_all_env([{:elixir_precompiled, old}])

      if is_nil(old_nerves) do
        Application.delete_env(:nerves, :precompiled)
      else
        Application.put_env(:nerves, :precompiled, old_nerves)
      end

      System.delete_env("ELIXIR_PRECOMPILED")
      System.delete_env("ELIXIR_PRECOMPILED_HOME")
    end)
  end

  defp configure(opts) do
    for {k, _} <- Application.get_all_env(:elixir_precompiled),
        do: Application.delete_env(:elixir_precompiled, k)

    Application.put_all_env([{:elixir_precompiled, opts}])
  end

  test "no source means nil" do
    configure([])
    assert Config.load() == nil
    configure([])
    assert Config.load() == nil
  end

  test "source enables, with defaults" do
    configure(source: "https://example.test/api/precompiled/")
    c = Config.load()
    assert c.source == "https://example.test/api/precompiled"
    assert c.except == []

    assert c.root_path ==
             Path.join(to_string(:code.priv_dir(:elixir_precompiled)), "precompiled/root.json")

    assert c.home == to_string(:filename.basedir(:user_cache, "elixir_precompiled"))
  end

  test "offline, deadlines, root check interval and content origins" do
    configure(
      source: "https://x",
      deadline_seconds: 30,
      root_check_seconds: 60,
      content: ["https://cdn.example.test/p/", "http://evil.example.test", 7]
    )

    {c, out} = ExUnit.CaptureIO.with_io(fn -> Config.load() end)
    assert out =~ "ignoring content origins that are not https"
    assert %{offline: false, deadline_ms: 30_000, root_check_seconds: 60} = c
    assert c.content_override == ["https://cdn.example.test/p"]

    System.put_env("ELIXIR_PRECOMPILED_OFFLINE", "1")
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_OFFLINE") end)
    configure(source: "https://x")
    assert Config.load().offline
    assert Config.offline?()
    System.delete_env("ELIXIR_PRECOMPILED_OFFLINE")

    assert %{deadline_ms: 300_000, root_check_seconds: 3600, content_override: nil} =
             Config.load()
  end

  test "the cache is bounded: cache_max_mb, default 4096" do
    configure(source: "https://x")
    assert Config.load().cache_max_bytes == 4096 * 1_048_576
    configure(source: "https://x", cache_max_mb: 10)
    assert Config.load().cache_max_bytes == 10 * 1_048_576
    configure(source: "https://x", cache_max_mb: -1)
    assert Config.load().cache_max_bytes == 4096 * 1_048_576
  end

  test "content origins are https, or http on loopback" do
    assert Config.content_origin?("https://cdn.example.test")
    assert Config.content_origin?("http://127.0.0.1:4000")
    refute Config.content_origin?("http://cdn.example.test")
    refute Config.content_origin?("ftp://cdn.example.test")
    refute Config.content_origin?(7)
  end

  test "without the library on the code path its root cannot be found" do
    assert_raise ArgumentError, ~r/no_such_app.*code path/, fn ->
      Config.priv_dir(:no_such_app)
    end
  end

  test "overrides and the kill switch" do
    configure(
      source: "https://x",
      except: [:ash],
      root: "/tmp/root.json"
    )

    System.put_env("ELIXIR_PRECOMPILED_HOME", "/tmp/pc")
    assert %{except: [:ash], root_path: "/tmp/root.json", home: "/tmp/pc"} = Config.load()
    System.put_env("ELIXIR_PRECOMPILED", "0")
    assert Config.load() == nil
  end

  test "except entries that are neither atoms nor strings are ignored" do
    configure(source: "https://x", except: [1, "ash", :jason])

    {config, out} = with_shell(&Config.load/0)
    assert config.except == [:ash, :jason]
    assert out =~ "except"
  end

  test "the nerves config key still works" do
    configure([])
    Application.put_env(:nerves, :precompiled, source: "https://old.test/x")
    assert %{source: "https://old.test/x"} = Config.load()
  end

  test "the two old config keys still work, newest name wins" do
    configure([])
    Application.put_env(:nerves, :precompiled, source: "https://old.test/x")
    assert %{source: "https://old.test/x"} = Config.load()
    Application.put_all_env([{:nerves_precompiled, [source: "https://mid.test/x"]}])
    assert %{source: "https://mid.test/x"} = Config.load()
    configure(source: "https://new.test/x")
    assert %{source: "https://new.test/x"} = Config.load()
  after
    for {k, _} <- Application.get_all_env(:nerves_precompiled),
        do: Application.delete_env(:nerves_precompiled, k)
  end

  test "old env var names are read when the new ones are unset" do
    configure(source: "https://x")
    System.put_env("NERVES_PRECOMPILED_HOME", "/tmp/old-home")
    assert %{home: "/tmp/old-home"} = Config.load()
    System.put_env("ELIXIR_PRECOMPILED_HOME", "/tmp/new-home")
    assert %{home: "/tmp/new-home"} = Config.load()
    System.put_env("NERVES_PRECOMPILED", "0")
    assert Config.load() == nil
  after
    for v <- ~w(NERVES_PRECOMPILED_HOME ELIXIR_PRECOMPILED_HOME NERVES_PRECOMPILED),
        do: System.delete_env(v)
  end

  test "the default cache dir is the user cache" do
    configure(source: "https://x")
    assert Config.load().home == to_string(:filename.basedir(:user_cache, "elixir_precompiled"))
  end

  test "overrides win over config, and home can be given" do
    configure(source: "https://cfg.test/x")
    c = Config.load(source: "https://opt.test/y/", home: "/tmp/h", except: ["ash"])
    assert c.source == "https://opt.test/y"
    assert c.home == "/tmp/h"
    assert c.except == [:ash]
  end

  test "clock_offset_seconds comes from config only, default 0" do
    configure(source: "https://example.org/p")
    assert %{clock_offset_seconds: 0} = Config.load()
    configure(source: "https://example.org/p", clock_offset_seconds: 90)
    assert %{clock_offset_seconds: 90} = Config.load()
    System.put_env("ELIXIR_PRECOMPILED_CLOCK_OFFSET_SECONDS", "999")
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_CLOCK_OFFSET_SECONDS") end)
    configure(source: "https://example.org/p")
    assert %{clock_offset_seconds: 0} = Config.load()
  end

  test "a non-integer clock_offset_seconds is ignored (0)" do
    configure(source: "https://example.org/p", clock_offset_seconds: "90")
    assert %{clock_offset_seconds: 0} = Config.load()
  end

  defp with_shell(fun) do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        stdio = ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, fun.()}) end)
        send(self(), {:stdio, stdio})
      end)

    assert_received {:result, result}
    assert_received {:stdio, stdio}
    {result, stdio <> stderr}
  end

  test "T9: ELIXIR_PRECOMPILED_ROOT and NERVES_PRECOMPILED_ROOT cannot move the root path" do
    configure(source: "https://x")
    System.put_env("ELIXIR_PRECOMPILED_ROOT", "/tmp/x.json")
    System.put_env("NERVES_PRECOMPILED_ROOT", "/tmp/x.json")

    on_exit(fn ->
      System.delete_env("ELIXIR_PRECOMPILED_ROOT")
      System.delete_env("NERVES_PRECOMPILED_ROOT")
    end)

    assert %{root_path: root_path} = Config.load()

    assert root_path ==
             Path.join(to_string(:code.priv_dir(:elixir_precompiled)), "precompiled/root.json")
  end

  test "plain http is refused except on loopback" do
    for source <- ["http://example.test/x", "http://10.0.0.1/x", "ftp://example.test/x", "x"] do
      configure(source: source)
      {config, out} = with_shell(&Config.load/0)
      assert config == nil, source
      assert out =~ "precompiled: source must be https", source
    end

    for source <- [
          "https://example.test/x",
          "http://127.0.0.1:4000/x",
          "http://localhost:4000/x",
          "http://[::1]:4000/x"
        ] do
      configure(source: source)
      assert %{source: ^source} = Config.load()
    end
  end

  test "without HOME or XDG_CACHE_HOME the home is nil, not a crash" do
    saved = for v <- ~w(HOME XDG_CACHE_HOME), do: {v, System.get_env(v)}

    on_exit(fn ->
      for {v, val} <- saved, do: if(val, do: System.put_env(v, val), else: System.delete_env(v))
    end)

    for {v, _} <- saved, do: System.delete_env(v)
    configure(source: "https://x")
    assert %{home: nil} = Config.load()
  end
end
