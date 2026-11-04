# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.BuildTest do
  # FakeBin changes the global PATH.
  use ExUnit.Case, async: false

  alias ChainTest.{Build, FakeBin, Result, Synthetic}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    fixture = Path.join(tmp, "fixture")
    File.mkdir_p!(fixture)

    File.write!(
      Path.join(fixture, "expected.exs"),
      "%{hits: [:jason, :exqlite, :ash], never: [:nerves]}\n"
    )

    %{fixture: fixture, home: Path.join(tmp, "home"), tmp: tmp}
  end

  # A fake `mix firmware`: copies `report` into the build's report.json,
  # writes a .fw unless `fw: false`, records its environment, writes the
  # client's batch state with `sequence`, and exits with `exit`.
  defp fake_mix(ctx, lines, opts) do
    report = Path.join(ctx.tmp, "report.json")
    File.write!(report, JSON.encode!(Synthetic.report(lines)))
    env = Path.join(ctx.tmp, "mix.env")

    fw =
      if Keyword.get(opts, :fw, true),
        do: "mkdir -p \"$b/nerves/images\" && echo fw > \"$b/nerves/images/chain_fixture.fw\"",
        else: ":"

    state =
      case Keyword.get(opts, :sequence) do
        nil ->
          ":"

        seq ->
          "mkdir -p \"$ELIXIR_PRECOMPILED_HOME/0123456789abcdef\" && " <>
            "printf #{seq} > \"$ELIXIR_PRECOMPILED_HOME/0123456789abcdef/state\""
      end

    """
    env > '#{env}'
    pwd >> '#{env}'
    b="_build/${MIX_TARGET}_${MIX_ENV}"
    mkdir -p "$b/lib/.precompiled"
    cp '#{report}' "$b/lib/.precompiled/report.json"
    #{fw}
    #{state}
    echo 'precompiled: building'
    exit #{Keyword.get(opts, :exit, 0)}
    """
  end

  @hits [
    {"jason", "1.4.5", "hit", "0.3 MB"},
    {"exqlite", "0.42.0", "hit", "1.7 MB"},
    {"ash", "3.37.2", "hit", "20.1 MB"}
  ]

  defp run(ctx, trust \\ Synthetic.info(7, %{})) do
    Build.run(%{
      fixture_dir: ctx.fixture,
      target: "rpi4",
      source: "http://127.0.0.1:1/api/precompiled",
      home: ctx.home,
      trust: trust
    })
  end

  defp find(results, check), do: Enum.find(results, &(&1.check == check))

  test "a clean build with every expected hit passes", ctx do
    stale = Path.join(ctx.fixture, "_build/rpi4_dev/stale")
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "old")

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn dir ->
      {results, info} = run(ctx)

      assert FakeBin.argv(dir, "mix") == ["firmware"]
      refute File.exists?(stale)

      assert %Result{step: :build, class: :pass} = find(results, "firmware")

      for dep <- ~w(jason exqlite ash),
          do: assert(%Result{class: :pass} = find(results, "hit:#{dep}"))

      assert %Result{class: :pass} = find(results, "sequence")
      assert %Result{class: :pass} = find(results, "never:nerves")

      assert info.sequence == 7
      assert info.build_lib == Path.join(ctx.fixture, "_build/rpi4_dev/lib")

      assert info.fw_path ==
               Path.join(ctx.fixture, "_build/rpi4_dev/nerves/images/chain_fixture.fw")

      refute Map.has_key?(info, :log)
      refute Map.has_key?(info, :home)
      assert length(info.report["lines"]) == 3

      env = File.read!(Path.join(ctx.tmp, "mix.env"))
      assert env =~ "MIX_TARGET=rpi4\n"
      assert env =~ "MIX_ENV=dev\n"
      assert env =~ "ELIXIR_PRECOMPILED_HOME=#{ctx.home}\n"
      assert env =~ "CHAIN_SOURCE=http://127.0.0.1:1/api/precompiled\n"
      assert env =~ ctx.fixture
    end)
  end

  describe "client_config" do
    defp client_run(ctx, extra) do
      copy = Path.join(ctx.tmp, "client.exs")
      grab = "[ -n \"$CHAIN_CLIENT_CONFIG\" ] && cp \"$CHAIN_CLIENT_CONFIG\" '#{copy}'\n"

      FakeBin.with_stubs(%{"mix" => grab <> fake_mix(ctx, @hits, sequence: 7)}, fn _ ->
        Build.run(
          Map.merge(
            %{
              fixture_dir: ctx.fixture,
              target: "rpi4",
              source: "http://127.0.0.1:1/api/precompiled",
              home: ctx.home,
              trust: Synthetic.info(7, %{})
            },
            extra
          )
        )

        {File.read!(Path.join(ctx.tmp, "mix.env")), File.read(copy)}
      end)
    end

    test "is passed to the fixture as a config file for this build only", ctx do
      config = %{clock_offset_seconds: 90_000, root: "/r/root.json", source: "http://127.0.0.1:2"}
      {env, {:ok, file}} = client_run(ctx, %{client_config: config})

      [_, path] = Regex.run(~r/^CHAIN_CLIENT_CONFIG=(.*)$/m, env)
      refute File.exists?(path), "the client config file outlives the build"
      refute String.starts_with?(path, ctx.home)

      path = Path.join(ctx.tmp, "client_config.exs")
      File.write!(path, file)

      assert Config.Reader.read!(path) == [
               elixir_precompiled: [
                 clock_offset_seconds: 90_000,
                 root: "/r/root.json",
                 source: "http://127.0.0.1:2"
               ]
             ]
    end

    test "without one, CHAIN_CLIENT_CONFIG is unset, even when the caller has it", ctx do
      System.put_env("CHAIN_CLIENT_CONFIG", "/leftover.exs")

      try do
        {env, copied} = client_run(ctx, %{})
        refute env =~ ~r/^CHAIN_CLIENT_CONFIG=/m
        assert {:error, :enoent} = copied
      after
        System.delete_env("CHAIN_CLIENT_CONFIG")
      end
    end

    test "the fixture's config merges the file over its own source", ctx do
      client = Path.join(ctx.tmp, "client.exs")
      File.write!(client, "import Config\nconfig :elixir_precompiled, clock_offset_seconds: 5\n")
      System.put_env("CHAIN_SOURCE", "http://127.0.0.1:3")
      System.put_env("CHAIN_CLIENT_CONFIG", client)

      try do
        config = Config.Reader.read!(Path.join(ChainTest.CLI.root(), "fixture/config/config.exs"))

        assert config[:elixir_precompiled] == [
                 source: "http://127.0.0.1:3",
                 clock_offset_seconds: 5
               ]
      after
        System.delete_env("CHAIN_SOURCE")
        System.delete_env("CHAIN_CLIENT_CONFIG")
      end
    end

    test "the case's file is imported after the site config, so a site file cannot override it",
         ctx do
      site = Path.join(ctx.tmp, "site.exs")

      File.write!(
        site,
        "import Config\nconfig :elixir_precompiled, source: \"http://127.0.0.1:4\", clock_offset_seconds: 1\n"
      )

      client = Path.join(ctx.tmp, "client.exs")
      File.write!(client, "import Config\nconfig :elixir_precompiled, clock_offset_seconds: 5\n")
      System.put_env("CHAIN_TARGET_CONFIG", site)
      System.put_env("CHAIN_CLIENT_CONFIG", client)
      Mix.target(:rpi4)

      try do
        config = Config.Reader.read!(Path.join(ChainTest.CLI.root(), "fixture/config/config.exs"))
        assert config[:elixir_precompiled][:clock_offset_seconds] == 5
        assert config[:elixir_precompiled][:source] == "http://127.0.0.1:4"
      after
        Mix.target(:host)
        System.delete_env("CHAIN_TARGET_CONFIG")
        System.delete_env("CHAIN_CLIENT_CONFIG")
      end
    end

    test "an unknown key or a bad value raises" do
      for bad <- [
            %{other: 1},
            %{clock_offset_seconds: "1"},
            %{root: :x},
            %{root: "relative/root.json"},
            %{source: ""}
          ] do
        assert_raise ArgumentError, fn ->
          Build.run(%{
            fixture_dir: "/nonexistent",
            target: "rpi4",
            source: "x",
            client_config: bad
          })
        end
      end
    end
  end

  test "home_prepared without a home is refused before anything runs" do
    assert_raise ArgumentError, ~r/home_prepared/, fn ->
      Build.run(%{fixture_dir: "/nonexistent", target: "rpi4", source: "x", home_prepared: true})
    end
  end

  test "a prepared home that is not empty is used as it is", ctx do
    planted = Path.join(ctx.home, "files/abc")
    File.mkdir_p!(Path.dirname(planted))
    File.write!(planted, "x")

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn dir ->
      {results, _info} =
        Build.run(%{
          fixture_dir: ctx.fixture,
          target: "rpi4",
          source: "http://127.0.0.1:1/api/precompiled",
          home: ctx.home,
          home_prepared: true,
          trust: Synthetic.info(7, %{})
        })

      assert FakeBin.argv(dir, "mix") != nil
      refute find(results, "home")
      assert File.read!(planted) == "x"
    end)
  end

  test "a target config is passed to the fixture build as CHAIN_TARGET_CONFIG", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn _ ->
      Build.run(%{
        fixture_dir: ctx.fixture,
        target: "rpi4",
        source: "http://127.0.0.1:1/api/precompiled",
        home: ctx.home,
        trust: Synthetic.info(7, %{}),
        target_config: "/op/target.exs"
      })

      assert File.read!(Path.join(ctx.tmp, "mix.env")) =~ "CHAIN_TARGET_CONFIG=/op/target.exs\n"
    end)
  end

  test "a batch stale refusal is refused, a benign miss is a miss", ctx do
    lines = [
      {"jason", "1.4.5", "fail", "batch stale: issued 2026-11-01T00:00:00Z"},
      {"exqlite", "0.42.0", "miss", "built against elixir_make 0.10.0, lock has 0.10.1"},
      {"ash", "3.37.2", "miss", "revoked: no longer in the current batch"}
    ]

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, lines, sequence: 7)}, fn _ ->
      {results, _} = run(ctx)

      assert %Result{class: :refused, detail: "batch stale" <> _} = find(results, "hit:jason")

      assert %Result{class: :miss, detail: "built against elixir_make" <> _} =
               find(results, "hit:exqlite")

      assert %Result{class: :refused} = find(results, "hit:ash")
    end)
  end

  test "a miss because the manifest was unavailable or malformed fails", ctx do
    lines = [
      {"jason", "1.4.5", "miss", "manifest unavailable: GET .../jason.json answered 500"},
      {"exqlite", "0.42.0", "miss", "malformed entry"},
      {"ash", "3.37.2", "miss", "no build for this Elixir"}
    ]

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, lines, sequence: 7)}, fn _ ->
      {results, _} = run(ctx)
      assert %Result{class: :fail, detail: d1} = find(results, "hit:jason")
      assert d1 =~ "manifest unavailable"
      assert %Result{class: :fail} = find(results, "hit:exqlite")
      assert %Result{class: :miss} = find(results, "hit:ash")
    end)
  end

  test "a caller-given home is kept after the run", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn _ ->
      run(ctx)
      assert File.dir?(ctx.home)
    end)
  end

  test "a client fail that is not a refusal fails", ctx do
    lines = [{"jason", "1.4.5", "fail", "manifest hash differs from batch"} | tl(@hits)]

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, lines, sequence: 7)}, fn _ ->
      {results, _} = run(ctx)
      assert %Result{class: :fail} = find(results, "hit:jason")
    end)
  end

  test "an expected hit the report does not name fails", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, tl(@hits), sequence: 7)}, fn _ ->
      {results, _} = run(ctx)
      assert %Result{class: :fail, detail: detail} = find(results, "hit:jason")
      assert detail =~ "not in report.json"
    end)
  end

  test "a never dep reported as a hit fails", ctx do
    lines = [{"nerves", "2.0.0", "hit", ""} | @hits]

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, lines, sequence: 7)}, fn _ ->
      {results, _} = run(ctx)
      assert %Result{class: :fail} = find(results, "never:nerves")
    end)
  end

  test "a client batch sequence other than the one step 1 verified is a rerun", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 8)}, fn _ ->
      {results, info} = run(ctx)
      assert %Result{class: :rerun, detail: detail} = find(results, "sequence")
      assert detail =~ "7"
      assert detail =~ "8"
      assert info.sequence == 8
    end)
  end

  test "an untrusted step 1 leaves the sequence check not exercised", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn _ ->
      {results, _} = run(ctx, nil)
      assert %Result{class: :not_exercised} = find(results, "sequence")
      assert %Result{class: :pass} = find(results, "hit:jason")
    end)
  end

  test "no client state is a not exercised sequence", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, [])}, fn _ ->
      {results, info} = run(ctx)
      assert %Result{class: :not_exercised} = find(results, "sequence")
      assert info.sequence == nil
    end)
  end

  test "a caller-given home that is not empty is refused without building", ctx do
    stale = Path.join(ctx.home, "fedcba9876543210/state")
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "7")

    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn dir ->
      {results, info} = run(ctx)
      assert FakeBin.argv(dir, "mix") == nil
      assert %Result{class: :fail, detail: detail} = find(results, "home")
      assert detail =~ ctx.home
      assert %Result{class: :not_exercised} = find(results, "firmware")
      assert %Result{class: :not_exercised} = find(results, "sequence")
      assert info.sequence == nil
    end)
  end

  test "without a home, each run gets its own fresh temp home", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7)}, fn _ ->
      input = %{
        fixture_dir: ctx.fixture,
        target: "rpi4",
        source: "http://127.0.0.1:1/api/precompiled",
        trust: Synthetic.info(7, %{})
      }

      home_of = fn ->
        [_, home] =
          Regex.run(
            ~r/^ELIXIR_PRECOMPILED_HOME=(.*)$/m,
            File.read!(Path.join(ctx.tmp, "mix.env"))
          )

        home
      end

      {_, a} = Build.run(input)
      a_home = home_of.()
      {_, _b} = Build.run(input)
      b_home = home_of.()

      assert a_home != b_home
      assert String.starts_with?(a_home, Path.join(System.tmp_dir!(), "chain_test-"))
      assert a.sequence == 7
      # A home the run made is removed after it; the sequence was read first.
      refute File.exists?(a_home)
      refute File.exists?(b_home)
    end)
  end

  test "a failed build fails firmware and leaves unreported hits not exercised", ctx do
    stub = "echo 'compile error' ; exit 1"

    FakeBin.with_stubs(%{"mix" => stub}, fn _ ->
      {results, info} = run(ctx)
      assert %Result{class: :fail, detail: detail} = find(results, "firmware")
      assert detail =~ "exit 1"
      assert %Result{class: :not_exercised} = find(results, "hit:jason")
      assert info.report == %{}
      assert detail =~ "compile error"
    end)
  end

  test "exit 0 without a .fw fails firmware", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7, fw: false)}, fn _ ->
      {results, _} = run(ctx)
      assert %Result{class: :fail, detail: detail} = find(results, "firmware")
      assert detail =~ ".fw"
    end)
  end

  test "another command runs instead of firmware and needs no .fw", ctx do
    FakeBin.with_stubs(%{"mix" => fake_mix(ctx, @hits, sequence: 7, fw: false)}, fn dir ->
      {results, info} =
        Build.run(%{
          fixture_dir: ctx.fixture,
          target: "rpi4",
          source: "http://127.0.0.1:1",
          home: ctx.home,
          trust: Synthetic.info(7, %{}),
          command: ["compile"]
        })

      assert FakeBin.argv(dir, "mix") == ["compile"]
      assert %Result{class: :pass, detail: detail} = find(results, "compile")
      assert detail =~ "mix compile exit 0"
      assert find(results, "firmware") == nil
      assert info.fw_path == nil
      assert %Result{class: :pass} = find(results, "hit:jason")
    end)
  end

  test "a failing other command fails its compile check", ctx do
    FakeBin.with_stubs(%{"mix" => "echo 'compile error' ; exit 1"}, fn _ ->
      {results, _} =
        Build.run(%{
          fixture_dir: ctx.fixture,
          target: "rpi4",
          source: "http://127.0.0.1:1",
          home: ctx.home,
          command: ["compile"]
        })

      assert %Result{class: :fail, detail: detail} = find(results, "compile")
      assert detail =~ "mix compile exit 1"
      assert detail =~ "compile error"
    end)
  end

  test "a home that is not fresh names the other command's check", ctx do
    File.mkdir_p!(Path.join(ctx.home, "stale"))

    {results, _} =
      Build.run(%{
        fixture_dir: ctx.fixture,
        target: "rpi4",
        source: "http://127.0.0.1:1",
        home: ctx.home,
        command: ["compile"]
      })

    assert %Result{class: :not_exercised} = find(results, "compile")
    assert find(results, "firmware") == nil
  end

  test "unset_env/0 names the variables the build unsets" do
    assert "ELIXIR_PRECOMPILED" in Build.unset_env()
    assert "MIX_BUILD_PATH" in Build.unset_env()
  end
end
