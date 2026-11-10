# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CheckOverlapTest do
  # A run asks the source whether its batch changed and meanwhile matches
  # its dependencies against the batch it already verified, from the cache
  # only and without writing anything. What it installs is still decided by
  # the batch the source answers with: the cached one on a 304, the new one
  # on a 200, nothing at all when the answer is refused. Nothing is
  # installed or removed before that answer is verified.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Precompiled.{Check, Env, FileStamp}
  alias Precompiled.Fixture, as: F
  @moduletag :tmp_dir

  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      configure([])
      for var <- ~w(HOME DEBUG OFFLINE CACERTS_PATH), do: System.delete_env("PRECOMPILED_" <> var)
    end)

    f = F.new(dir)
    configure(source: F.base_url(), root: f.root_path)
    home = Path.join(dir, "home")
    System.put_env("PRECOMPILED_HOME", home)
    lib = Path.join(dir, "_build/host_dev/lib")

    %{
      f: f,
      lib: lib,
      home: home,
      env: %Env{
        candidates: [%{name: :jason, version: "1.4.5", lock_entry: @jason}],
        lock: %{jason: @jason},
        system: {"host", ""},
        build_lib: lib,
        deps_path: Path.join(dir, "deps")
      }
    }
  end

  defp configure(opts) do
    for {k, _} <- Application.get_all_env(:precompiled),
        do: Application.delete_env(:precompiled, k)

    Application.put_all_env([{:precompiled, opts}])
  end

  defp b64(term), do: Base.url_encode64(:erlang.term_to_binary(term), padding: false)

  # A pure_elixir jason build whose beam is `beam` and which recorded one
  # compile_env key, so matching it asks the project's config once.
  defp jason_packages(f, beam) do
    app =
      "{application, jason, [{vsn, \"1.4.5\"}, {modules, ['Elixir.X']}, " <>
        "{compile_env, [{jason, [k], {ok, 1}}]}]}.\n"

    entry = %{
      "target" => "pure_elixir",
      "ebin" => [
        %{
          "path" => "ebin/Elixir.X.beam",
          "sha256" => F.file(f, beam),
          "size" => byte_size(beam),
          "mode" => 33188
        },
        %{
          "path" => "ebin/jason.app",
          "sha256" => F.file(f, app),
          "size" => byte_size(app),
          "mode" => 33188
        }
      ],
      "priv" => [],
      "build" => %{
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "run_id" => "r",
        "image_digest" => "d",
        "deps" => %{},
        "compile_env" => [%{"app" => "jason", "path" => ["k"], "value" => b64({:ok, 1})}],
        "package_checksum" => "JOUTER",
        "dep_env" => "prod"
      }
    }

    %{"jason" => %{"versions" => %{"1.4.5" => %{"builds" => [entry]}}}}
  end

  # Each lookup of the recorded key reports when it ran.
  defp config_fun() do
    test = self()

    fn "jason", ["k"] ->
      send(test, {:matched_at, System.monotonic_time(:millisecond)})
      {:ok, 1}
    end
  end

  defp run(env) do
    {result, _out} =
      with_io(:stderr, fn ->
        {r, _} =
          with_io(fn ->
            Check.check(Precompiled.Config.load(), env, config_fun: config_fun())
          end)

        r
      end)

    result
  end

  defp installed_beam(lib) do
    case File.read(Path.join([lib, "jason", "ebin", "Elixir.X.beam"])) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  defp first_match() do
    receive do
      {:matched_at, at} -> at
    after
      0 -> nil
    end
  end

  defp drain() do
    receive do
      {:matched_at, _} -> drain()
    after
      0 -> :ok
    end
  end

  # Warm: an earlier run verified the batch and cached its manifest and files.
  defp warm(f, env, lib, beam) do
    F.publish(f, jason_packages(f, beam), sequence: 1)
    assert {:ok, %{hits: 1}} = run(env)
    assert installed_beam(lib) == beam
    File.rm_rf!(lib)
    drain()
  end

  # Every file under the home with its mtime and ctime: what a run wrote.
  # Not `root_checked`: a batch that fails its signature makes the run
  # check the root once more, as it always has, and that check is recorded.
  defp snapshot(home) do
    for path <- Path.wildcard(Path.join(home, "**"), match_dot: true),
        Path.basename(path) != "root_checked",
        {:ok, %File.Stat{type: :regular} = s} <- [File.lstat(path, time: :posix)],
        into: %{},
        do: {path, {s.size, s.mtime, s.ctime, s.inode}}
  end

  describe "while the source is asked whether the batch changed" do
    test "the dependencies are matched against the cached batch before the answer", %{
      f: f,
      env: env,
      lib: lib
    } do
      warm(f, env, lib, "beam v1")
      F.delay_batch(600)

      assert {:ok, %{hits: 1}} = run(env)

      matched_at = first_match()
      answered_at = F.get(:batch_answered_at)
      assert is_integer(matched_at), "the run never matched the build"
      assert matched_at < answered_at, "the run waited for the batch answer"
      assert installed_beam(lib) == "beam v1"
    end

    test "nothing is installed before the answer", %{f: f, env: env, lib: lib} do
      warm(f, env, lib, "beam v1")
      F.delay_batch(600)
      test = self()

      watcher =
        spawn(fn ->
          receive do
            :go -> watch(test, lib)
          end
        end)

      send(watcher, :go)
      assert {:ok, %{hits: 1}} = run(env)
      send(watcher, :stop)

      assert_receive {:first_install_at, installed_at}, 2_000
      assert installed_at >= F.get(:batch_answered_at)
    end

    test "a 304 installs what was matched against the cached batch", %{
      f: f,
      env: env,
      lib: lib
    } do
      warm(f, env, lib, "beam v1")
      F.clear_requests()

      assert {:ok, %{hits: 1}} = run(env)
      assert [%{path: "/precompiled/batch.json", if_none_match: etag}] = F.requests()
      assert is_binary(etag)
      assert installed_beam(lib) == "beam v1"
    end
  end

  # Polls for the installed dir; reports the first moment it is seen there
  # (at the latest when told to stop).
  defp watch(test, lib) do
    receive do
      :stop ->
        if File.dir?(Path.join(lib, "jason")),
          do: send(test, {:first_install_at, System.monotonic_time(:millisecond)})
    after
      2 ->
        if File.dir?(Path.join(lib, "jason")),
          do: send(test, {:first_install_at, System.monotonic_time(:millisecond)}),
          else: watch(test, lib)
    end
  end

  describe "when the source answers with a new batch" do
    test "what is installed follows the new batch, not the cached one", %{
      f: f,
      env: env,
      lib: lib
    } do
      warm(f, env, lib, "beam v1")
      F.publish(f, jason_packages(f, "beam v2"), sequence: 2)
      F.delay_batch(300)

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v2"
    end

    test "a new batch that no longer names the build installs nothing", %{
      f: f,
      env: env,
      lib: lib
    } do
      warm(f, env, lib, "beam v1")
      F.publish(f, %{}, sequence: 2)
      F.delay_batch(300)

      assert {:ok, report} = run(env)
      assert report.hits == 0
      assert installed_beam(lib) == nil
    end

    # A 200 the source did give and that does not verify never falls back to
    # the cached batch, so nothing matched against it is installed, and the
    # matching itself left nothing behind in the home.
    test "a new batch that does not verify installs nothing and writes nothing", %{
      f: f,
      env: env,
      lib: lib,
      home: home
    } do
      warm(f, env, lib, "beam v1")
      before = snapshot(home)

      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      keyid = Base.encode16(:crypto.hash(:sha256, public), case: :lower)
      stranger = %{keyid: keyid, public: public, private: private}
      F.publish(f, jason_packages(f, "beam v2"), sequence: 2, signers: [stranger])
      F.delay_batch(300)
      Process.sleep(1_100)

      assert {:ok, report} = run(env)
      assert report.hits == 0
      assert report.fails == 1
      assert installed_beam(lib) == nil
      assert snapshot(home) == before
    end

    test "an installed build is not removed before the answer", %{
      f: f,
      env: env,
      lib: lib
    } do
      F.publish(f, jason_packages(f, "beam v1"), sequence: 1)
      assert {:ok, %{hits: 1}} = run(env)
      env = %{env | candidates: [], installed: [:jason], installed_envs: %{}}
      F.publish(f, %{}, sequence: 2)
      F.delay_batch(600)
      test = self()

      watcher =
        spawn(fn ->
          wait = fn wait ->
            if File.dir?(Path.join(lib, "jason")) do
              Process.sleep(2)
              wait.(wait)
            else
              send(test, {:removed_at, System.monotonic_time(:millisecond)})
            end
          end

          wait.(wait)
        end)

      assert {:ok, %{misses: 1}} = run(env)
      assert_receive {:removed_at, removed_at}, 2_000
      Process.exit(watcher, :kill)
      assert removed_at >= F.get(:batch_answered_at)
      assert installed_beam(lib) == nil
    end
  end

  describe "the OS certificate store" do
    setup %{tmp_dir: dir} do
      broken = Path.join(dir, "broken-ca.pem")
      File.write!(broken, "not a certificate")
      %{broken_ca: broken}
    end

    test "is not needed by an offline run", %{f: f, env: env, lib: lib, broken_ca: broken} do
      warm(f, env, lib, "beam v1")
      System.put_env("PRECOMPILED_OFFLINE", "1")
      System.put_env("PRECOMPILED_CACERTS_PATH", broken)
      F.clear_requests()

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert F.requests() == []
    end

    test "is not needed by a run with nothing to check", %{env: env, broken_ca: broken} do
      System.put_env("PRECOMPILED_CACERTS_PATH", broken)
      F.clear_requests()

      assert :nothing_to_do = run(%{env | candidates: [], lock: %{}})
      assert F.requests() == []
    end
  end

  # Whatever a stamp lets a run skip, a cached file that is not the bytes it
  # was verified as is never installed: it is fetched again instead. Each
  # case first makes sure the file really is stamped, so the stamp is what
  # is under test, not a first-time hash.
  describe "a cached file changed after it was verified and stamped" do
    defp cached_beam(home, bytes), do: Path.join([home, "files", F.sha(bytes)])

    defp refetched?(bytes),
      do: Enum.any?(F.requests(), &(&1.path == "/precompiled/files/" <> F.sha(bytes)))

    # Warm, then (a second later, so the cached file is settled) a second
    # run that hashes and stamps it. Returns the stamped stat.
    defp stamped(f, env, lib, home, beam) do
      File.mkdir_p!(home)
      File.chmod!(home, 0o700)
      warm(f, env, lib, beam)
      Process.sleep(1_100)
      F.clear_requests()
      assert {:ok, %{hits: 1}} = run(env)
      File.rm_rf!(lib)
      refute refetched?(beam)

      path = cached_beam(home, beam)
      stat = File.stat!(path, time: :posix)
      table = FileStamp.open(home)
      assert FileStamp.match?(FileStamp.lookup(table, F.sha(beam)), stat, F.sha(beam))
      FileStamp.close(table, home)
      F.clear_requests()
      stat
    end

    test "a stamped file that did not change is not fetched again", ctx do
      %{f: f, env: env, lib: lib, home: home} = ctx
      stamped(f, env, lib, home, "beam v1")

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      refute refetched?("beam v1")
    end

    # The change lands right after the stamp, in the same second or the
    # next: no sleep. ctime still differs.
    test "rewritten in place with its size and mtime put back", ctx do
      %{f: f, env: env, lib: lib, home: home} = ctx
      before = stamped(f, env, lib, home, "beam v1")
      path = cached_beam(home, "beam v1")
      File.write!(path, "BEAM V1")
      File.touch!(path, before.mtime)
      assert %{size: size, mtime: mtime} = File.stat!(path, time: :posix)
      assert {size, mtime} == {before.size, before.mtime}

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end

    test "replaced by another file of the same size and mtime", ctx do
      %{f: f, env: env, lib: lib, home: home} = ctx
      before = stamped(f, env, lib, home, "beam v1")
      path = cached_beam(home, "beam v1")
      other = path <> ".swap"
      File.write!(other, "BEAM V1")
      File.touch!(other, before.mtime)
      File.rename!(other, path)

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end

    test "of another size", ctx do
      %{f: f, env: env, lib: lib, home: home} = ctx
      stamped(f, env, lib, home, "beam v1")
      File.write!(cached_beam(home, "beam v1"), "beam v1 and more")

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end

    # Stamps were recorded while the home was owner-only; once others can
    # enter it, they are not believed.
    test "in a home that others can enter", ctx do
      %{f: f, env: env, lib: lib, home: home} = ctx
      before = stamped(f, env, lib, home, "beam v1")
      File.chmod!(home, 0o755)
      path = cached_beam(home, "beam v1")
      File.write!(path, "BEAM V1")
      File.touch!(path, before.mtime)

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end
  end
end
