# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.CheckOverlapTest do
  # A run asks the source whether its batch changed and meanwhile does the
  # local work against the batch it already verified. What it installs is
  # still decided by the batch the source answers with: the cached one on a
  # 304, the new one on a 200, nothing from the cache when a 200 is refused.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias ElixirPrecompiled.{Check, Env}
  alias ElixirPrecompiled.Fixture, as: F
  @moduletag :tmp_dir

  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "JOUTER"}

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      configure([])
      F.delay_batch(nil)

      for var <- ~w(HOME DEBUG OFFLINE CACERTS_PATH),
          do: System.delete_env("ELIXIR_PRECOMPILED_" <> var)
    end)

    f = F.new(dir)
    configure(source: F.base_url(), root: f.root_path)
    System.put_env("ELIXIR_PRECOMPILED_HOME", Path.join(dir, "home"))
    lib = Path.join(dir, "_build/host_dev/lib")

    %{
      f: f,
      lib: lib,
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
    for {k, _} <- Application.get_all_env(:elixir_precompiled),
        do: Application.delete_env(:elixir_precompiled, k)

    Application.put_all_env([{:elixir_precompiled, opts}])
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
  defp config_fun do
    test = self()

    fn "jason", ["k"] ->
      send(test, {:matched_at, System.monotonic_time(:millisecond)})
      {:ok, 1}
    end
  end

  defp run(env, config \\ ElixirPrecompiled.Config.load()) do
    {result, _out} =
      with_io(:stderr, fn ->
        {r, _} = with_io(fn -> Check.check(config, env, config_fun: config_fun()) end)
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

  defp first_match do
    receive do
      {:matched_at, at} -> at
    after
      0 -> nil
    end
  end

  defp drain do
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

  describe "while the source is asked whether the batch changed" do
    test "the per-dep pass runs against the cached batch before the answer arrives", %{
      f: f,
      env: env,
      lib: lib
    } do
      warm(f, env, lib, "beam v1")
      F.delay_batch(600)

      assert {:ok, %{hits: 1}} = run(env)

      matched_at = first_match()
      answered_at = F.get(:batch_answered_at)
      assert is_integer(matched_at), "the pass never matched the build"
      assert matched_at < answered_at, "the pass waited for the batch answer"
      assert installed_beam(lib) == "beam v1"
    end

    test "a 304 installs what the pass found against the cached batch", %{
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
    # the cached batch, so nothing the pass found against it is kept.
    test "a new batch that does not verify installs nothing from the cached one", %{
      f: f,
      env: env,
      lib: lib
    } do
      warm(f, env, lib, "beam v1")
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      keyid = Base.encode16(:crypto.hash(:sha256, public), case: :lower)
      stranger = %{keyid: keyid, public: public, private: private}
      F.publish(f, jason_packages(f, "beam v2"), sequence: 2, signers: [stranger])
      F.delay_batch(300)

      assert {:ok, report} = run(env)
      assert report.hits == 0
      assert installed_beam(lib) == nil
    end
  end

  describe "the OS certificate store" do
    # Loading it costs about 30 ms; it is for a request, and only a request.
    setup %{tmp_dir: dir} do
      broken = Path.join(dir, "broken-ca.pem")
      File.write!(broken, "not a certificate")
      %{broken_ca: broken}
    end

    test "is not loaded by an offline run", %{f: f, env: env, lib: lib, broken_ca: broken} do
      warm(f, env, lib, "beam v1")
      System.put_env("ELIXIR_PRECOMPILED_OFFLINE", "1")
      System.put_env("ELIXIR_PRECOMPILED_CACERTS_PATH", broken)

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
    end

    test "is not loaded by a run with nothing to check", %{env: env, broken_ca: broken} do
      System.put_env("ELIXIR_PRECOMPILED_CACERTS_PATH", broken)
      F.clear_requests()

      assert :nothing_to_do = run(%{env | candidates: [], lock: %{}})
      assert F.requests() == []
    end
  end

  # Whatever a stamp lets a run skip, a cached file that is not the bytes it
  # was verified as is never installed: it is fetched again instead.
  describe "a cached file changed after it was verified" do
    defp cached_beam(dir, bytes),
      do: Path.join([dir, "home", "files", F.sha(bytes)])

    defp refetched?(bytes),
      do: Enum.any?(F.requests(), &(&1.path == "/precompiled/files/" <> F.sha(bytes)))

    test "rewritten in place with its size and mtime put back", %{
      f: f,
      env: env,
      lib: lib,
      tmp_dir: dir
    } do
      warm(f, env, lib, "beam v1")
      path = cached_beam(dir, "beam v1")
      %{mtime: mtime} = File.stat!(path, time: :posix)
      Process.sleep(1_100)
      File.write!(path, "BEAM V1")
      File.touch!(path, mtime)
      F.clear_requests()

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end

    test "replaced by another file of the same size and mtime", %{
      f: f,
      env: env,
      lib: lib,
      tmp_dir: dir
    } do
      warm(f, env, lib, "beam v1")
      path = cached_beam(dir, "beam v1")
      %{mtime: mtime} = File.stat!(path, time: :posix)
      other = path <> ".swap"
      File.write!(other, "BEAM V1")
      File.touch!(other, mtime)
      File.rename!(other, path)
      F.clear_requests()

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end

    test "of another size", %{f: f, env: env, lib: lib, tmp_dir: dir} do
      warm(f, env, lib, "beam v1")
      File.write!(cached_beam(dir, "beam v1"), "beam v1 and more")
      F.clear_requests()

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end

    test "in a home that others can write to", %{f: f, env: env, lib: lib, tmp_dir: dir} do
      warm(f, env, lib, "beam v1")
      File.chmod!(Path.join(dir, "home"), 0o777)
      path = cached_beam(dir, "beam v1")
      %{mtime: mtime} = File.stat!(path, time: :posix)
      Process.sleep(1_100)
      File.write!(path, "BEAM V1")
      File.touch!(path, mtime)
      F.clear_requests()

      assert {:ok, %{hits: 1}} = run(env)
      assert installed_beam(lib) == "beam v1"
      assert refetched?("beam v1")
    end
  end
end
