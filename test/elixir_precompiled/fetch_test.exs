# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.FetchTest do
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.Fetch
  alias ElixirPrecompiled.Fixture, as: F

  @moduletag :tmp_dir
  @lock_entry {:hex, :ash, "3.5.2", "i", [:mix], [], "hexpm", "OUTER"}

  setup_all do
    start_supervised!(ElixirPrecompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    f = F.new(dir)

    config = %{
      source: F.base_url(),
      except: [],
      root_path: f.root_path,
      home: Path.join(dir, "home")
    }

    %{
      f: f,
      config: config,
      build_lib: Path.join(dir, "_build/rpi4_dev/lib"),
      deps: Path.join(dir, "deps")
    }
  end

  defp entry(files), do: %{"ebin" => files, "priv" => [], "build" => %{}}

  defp file_entry(sha, size, path \\ "ebin/Elixir.Ash.beam", mode \\ 33188),
    do: %{"path" => path, "sha256" => sha, "size" => size, "mode" => mode}

  # The validator requires ebin/<dep>.app; most entries need one alongside the file under test.
  defp with_app(f, files) do
    app = "{application, ash, []}.\n"
    files ++ [file_entry(F.file(f, app), byte_size(app), "ebin/ash.app")]
  end

  test "get_body caps size and refuses cross-host redirects", %{config: config} do
    port = ElixirPrecompiled.TestServer.port()

    assert {:error, "redirect to another host refused"} =
             Fetch.get_body(config.source <> "/redirect/batch.json")

    assert {:error, "response larger than 10 bytes"} =
             Fetch.get_body("http://127.0.0.1:#{port}/binary", max_bytes: 10)

    assert {:error, "Status 404 Not Found"} =
             Fetch.get_body(config.source <> "/manifests/nope.json")
  end

  test "get_body streams the body and assembles it correctly under the cap" do
    port = ElixirPrecompiled.TestServer.port()

    assert {:ok, body} = Fetch.get_body("http://127.0.0.1:#{port}/binary", max_bytes: 2048)
    assert byte_size(body) == 1024
    assert body == :binary.copy(<<0xDE, 0xAD, 0xBE, 0xEF>>, 256)
  end

  test "manifest: miss on 404, fail on hash mismatch, ok when it matches", %{f: f, config: config} do
    F.publish(f, %{"ash" => %{"versions" => %{"3.5.2" => %{}}}}, format: 1)

    sha =
      F.get(:batch)
      |> then(fn env ->
        env["payload"] |> Base.url_decode64!(padding: false) |> :json.decode()
      end)
      |> get_in(["manifests", "ash"])

    assert {:ok, %{"versions" => _}} = Fetch.manifest(config, "ash", sha)
    # The first success cached the sha; clear it so the network paths run.
    File.rm_rf!(Path.join(config.home, "manifests"))
    assert {:miss, "no manifest"} = Fetch.manifest(config, "nope", sha)
    File.rm_rf!(Path.join(config.home, "manifests"))
    F.tamper_manifest(f, "ash")
    assert {:fail, "manifest hash differs from batch"} = Fetch.manifest(config, "ash", sha)
  end

  test "manifest: a manifest larger than the default 8 MB body cap still fetches", %{
    f: f,
    config: config
  } do
    F.publish(
      f,
      %{
        "ash" => %{
          "versions" => %{
            "3.5.2" => %{"pad" => %{"pad" => String.duplicate("a", 9 * 1024 * 1024)}}
          }
        }
      },
      format: 1
    )

    sha =
      F.get(:batch)
      |> then(fn env ->
        env["payload"] |> Base.url_decode64!(padding: false) |> :json.decode()
      end)
      |> get_in(["manifests", "ash"])

    assert {:ok, %{"versions" => _}} = Fetch.manifest(config, "ash", sha)
  end

  test "install downloads, verifies, writes the marker and renames atomically", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    beam = "beam bytes"
    app = "{application, ash, [{vsn, \"3.5.2\"}]}.\n"
    s1 = F.file(f, beam)
    s2 = F.file(f, app)
    e = entry([file_entry(s1, byte_size(beam)), file_entry(s2, byte_size(app), "ebin/ash.app")])
    File.mkdir_p!(Path.join(lib, "ash/ebin"))
    File.write!(Path.join(lib, "ash/ebin/stale.beam"), "old")

    assert {:ok, %{files: 2, cached: 0}} =
             Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)

    assert File.read!(Path.join(lib, "ash/ebin/Elixir.Ash.beam")) == beam
    refute File.exists?(Path.join(lib, "ash/ebin/stale.beam"))
    refute File.exists?(Path.join(lib, ".precompiled/ash"))

    # Elixir 1.17 and 1.18 compile a Hex dep whose build dir lacks
    # compile.fetch, the mark deps.compile leaves (Mix.Dep.Loader's
    # recently_fetched?); 1.19 and later ignore the file.
    assert File.exists?(Path.join(lib, "ash/.mix/compile.fetch"))

    # Mix itself must read the marker as "compiled by this Elixir/OTP with Hex".
    vsn = {System.version(), :erlang.system_info(:otp_release)}

    if Version.match?(System.version(), ">= 1.20.0") do
      assert {:ok, ^vsn, Hex.SCM, @lock_entry} =
               Mix.Dep.ElixirSCM.read(Path.join(lib, "ash/.mix"))
    else
      assert {:ok, ^vsn, Hex.SCM} = Mix.Dep.ElixirSCM.read(Path.join(lib, "ash/.mix"))
    end

    assert File.exists?(Path.join(config.home, "files/#{s1}"))

    # second install hits the cache
    File.rm_rf!(Path.join(lib, "ash"))

    assert {:ok, %{files: 2, cached: 2}} =
             Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
  end

  test "a wrong sha or size fails and leaves _build untouched", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    s = F.file(f, "real")
    e = entry(with_app(f, [file_entry(String.duplicate("0", 64), 4)]))

    assert {:fail, "file not available: " <> _} =
             Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)

    e = entry(with_app(f, [file_entry(s, 99)]))

    assert {:fail, "size mismatch (ebin/Elixir.Ash.beam)"} =
             Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)

    refute File.exists?(Path.join(lib, "ash"))
  end

  test "a cached file that no longer matches its sha is re-downloaded", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    s = F.file(f, "good")
    File.mkdir_p!(Path.join(config.home, "files"))
    File.write!(Path.join(config.home, "files/#{s}"), "")

    assert {:ok, %{cached: 0}} =
             Fetch.install(config, :ash, entry(with_app(f, [file_entry(s, 4)])), @lock_entry, lib,
               deps_path: deps
             )
  end

  test "unsafe path or mode rejects the dependency", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    s = F.file(f, "x")

    for {path, mode} <- [
          {"../x.beam", 33188},
          {"/ebin/x.beam", 33188},
          {"lib/x.beam", 33188},
          {"ebin/x.beam", 0o100777},
          {"ebin/a\0b", 33188},
          {"ebin/..\\x", 33188},
          {"ebin\\x.beam", 33188}
        ] do
      assert {:fail, "unsafe path or mode (" <> _} =
               Fetch.install(
                 config,
                 :ash,
                 entry([file_entry(s, 1, path, mode)]),
                 @lock_entry,
                 lib,
                 deps_path: deps
               ),
             "#{inspect({path, mode})}"
    end

    refute File.exists?(Path.join(lib, "ash"))
  end

  test "verify_app can reject the staged app and nothing is installed", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))
    seen = self()

    verify = fn path ->
      send(seen, {:app, path})
      {:fail, "compile_env differs: ash [:mode]"}
    end

    assert {:fail, "compile_env differs: ash [:mode]"} =
             Fetch.install(config, :ash, e, @lock_entry, lib,
               verify_app: verify,
               deps_path: deps
             )

    assert_received {:app, path}
    assert String.ends_with?(path, ".precompiled/ash/ebin/ash.app")
    refute File.exists?(Path.join(lib, "ash"))
    refute File.exists?(Path.join(lib, ".precompiled/ash"))
  end

  test "a dependency without an .app file fails", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    s = F.file(f, "beam")

    assert {:fail, "no ebin/ash.app in entry"} =
             Fetch.install(config, :ash, entry([file_entry(s, 4)]), @lock_entry, lib,
               deps_path: deps
             )
  end

  test "an exception while staging fails cleanly and leaves _build untouched", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    e = entry(with_app(f, [file_entry(F.file(f, "x"), 1)]))
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, ".precompiled"), "blocking file, not a directory")

    assert {:fail, "install failed: " <> _} =
             Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)

    refute File.exists?(Path.join(lib, "ash"))
  end

  test "include/ and src/ from deps/<dep> are linked into the installed dep", %{
    f: f,
    config: config,
    build_lib: lib,
    tmp_dir: dir
  } do
    deps = Path.join(dir, "deps")
    File.mkdir_p!(Path.join(deps, "ash/include"))
    File.write!(Path.join(deps, "ash/include/x.hrl"), "-record(x, {a}).\n")
    File.mkdir_p!(Path.join(deps, "ash/src"))
    File.write!(Path.join(deps, "ash/src/ash.erl"), "-module(ash).\n")
    File.mkdir_p!(Path.join(deps, "ash/priv"))
    File.write!(Path.join(deps, "ash/priv/data.txt"), "data")

    e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))

    assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
    assert File.read!(Path.join(lib, "ash/include/x.hrl")) == "-record(x, {a}).\n"
    assert File.read!(Path.join(lib, "ash/src/ash.erl")) == "-module(ash).\n"
    # The manifest supplied no priv/, so Mix's own priv link is mirrored.
    assert File.read!(Path.join(lib, "ash/priv/data.txt")) == "data"
  end

  test "install records which signed manifest the build came from", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))
    sha = String.duplicate("ab", 32)

    assert {:ok, _} =
             Fetch.install(config, :ash, e, @lock_entry, lib,
               deps_path: deps,
               provenance: %{sha: sha, path: "v2/manifests", sequence: 7}
             )

    assert %{
             "manifest_sha256" => ^sha,
             "manifest_path" => "v2/manifests",
             "batch_sequence" => 7
           } =
             Path.join(lib, "ash/.mix/elixir_precompiled.json") |> File.read!() |> :json.decode()
  end

  test "install without provenance writes no provenance file", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))
    assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
    refute File.exists?(Path.join(lib, "ash/.mix/elixir_precompiled.json"))
  end

  test "the include/ and src/ links are relative, so a moved project tree keeps working", %{
    f: f,
    config: config,
    build_lib: lib,
    tmp_dir: dir
  } do
    deps = Path.join(dir, "deps")
    File.mkdir_p!(Path.join(deps, "ash/include"))
    File.write!(Path.join(deps, "ash/include/x.hrl"), "-record(x, {a}).\n")

    e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))

    assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)

    link = Path.join(lib, "ash/include")
    assert Path.type(File.read_link!(link)) == :relative
    assert File.dir?(link)
  end

  test "a manifest-supplied priv/ is not replaced by deps/<dep>/priv", %{
    f: f,
    config: config,
    build_lib: lib,
    tmp_dir: dir
  } do
    deps = Path.join(dir, "deps")
    File.mkdir_p!(Path.join(deps, "ash/priv"))
    File.write!(Path.join(deps, "ash/priv/data.txt"), "from deps")

    e =
      entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))
      |> Map.put("priv", [file_entry(F.file(f, "built"), 5, "priv/data.txt")])

    assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
    assert File.read!(Path.join(lib, "ash/priv/data.txt")) == "built"
    refute File.exists?(Path.join(lib, "ash/include"))
  end

  test "marker_term/4 writes the marker format of the running Mix" do
    vsn = {"1.19.5", ~c"28"}

    assert Fetch.marker_term("1.19.5", vsn, Hex.SCM, @lock_entry) == {1, vsn, Hex.SCM}
    assert Fetch.marker_term("1.17.0", vsn, Hex.SCM, @lock_entry) == {1, vsn, Hex.SCM}

    assert Fetch.marker_term("1.20.0", vsn, Hex.SCM, @lock_entry) ==
             {2, vsn, Hex.SCM, @lock_entry}

    assert Fetch.marker_term("1.20.3", vsn, Hex.SCM, @lock_entry) ==
             {2, vsn, Hex.SCM, @lock_entry}
  end

  test "a sha256 or size that could become a bad path or count fails the dependency", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    for {sha, size} <- [{"../x", 1}, {String.duplicate("A", 64), 1}, {nil, 1}, {F.sha("x"), -1}] do
      e = entry(with_app(f, [file_entry(sha, size)]))

      assert {:fail, "unsafe file entry (ebin/Elixir.Ash.beam)"} =
               Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps),
             inspect({sha, size})
    end

    refute File.exists?(Path.join(lib, "ash"))
    refute File.exists?(Path.join(config.home, "files/../x"))
  end

  test "an unsafe path or mode names the offending path", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    e = entry(with_app(f, [file_entry(F.file(f, "x"), 1, "ebin/x.beam", 0o100777)]))

    assert {:fail, ~s|unsafe path or mode ("ebin/x.beam")|} =
             Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
  end

  test "get_body refuses a redirect to another port on the same host", %{config: config} do
    assert {:error, "redirect to another host refused"} =
             Fetch.get_body(config.source <> "/redirect_port/batch.json")
  end

  test "offline: no request at all, whatever the caller", %{config: config, f: f} do
    F.publish(f, %{})
    F.clear_requests()
    offline = Map.put(config, :offline, true)

    assert {:error, {:unreachable, "offline"}} =
             Fetch.get_conditional(offline, config.source <> "/batch.json", nil)

    assert {:error, "offline"} =
             Fetch.get_body(config.source <> "/batch.json", Fetch.content_opts(offline))

    assert {:miss, "offline: manifest not cached"} =
             Fetch.manifest(offline, "ash", String.duplicate("0", 64))

    System.put_env("ELIXIR_PRECOMPILED_OFFLINE", "1")
    on_exit(fn -> System.delete_env("ELIXIR_PRECOMPILED_OFFLINE") end)
    assert {:error, "offline"} = ElixirPrecompiled.HTTP.get(config.source <> "/batch.json")
    assert F.requests() == []
  end

  test "a failure to reach the source is told apart from a refused answer", %{config: config} do
    F.withdraw_batch()

    assert {:error, {:unreachable, "Status 503" <> _}} =
             Fetch.get_conditional(config, config.source <> "/batch.json", nil)

    assert {:error, "Status 404 Not Found"} =
             Fetch.get_conditional(config, config.source <> "/manifests/none.json", nil)

    assert {:error, {:unreachable, _}} =
             Fetch.get_conditional(config, "http://127.0.0.1:1/precompiled/batch.json", nil)

    late = Map.put(config, :deadline_at, System.monotonic_time(:millisecond) - 1)

    assert {:error, {:unreachable, "run deadline passed"}} =
             Fetch.get_conditional(late, config.source <> "/batch.json", nil)
  end

  test "content and metadata requests carry the connect timeout", %{config: config} do
    c = Map.put(config, :connect_timeout_ms, 1234)
    assert Fetch.content_opts(c)[:connect_timeout_ms] == 1234
    assert Fetch.metadata_opts(c)[:connect_timeout_ms] == 1234
  end

  defp batch_sha(name) do
    F.get(:batch)["payload"]
    |> Base.url_decode64!(padding: false)
    |> :json.decode()
    |> get_in(["manifests_v2", name])
  end

  test "a manifest is fetched once, then read from the cache by its sha", %{f: f, config: config} do
    F.publish(f, %{"ash" => %{"versions" => %{}}})
    sha = batch_sha("ash")
    assert {:ok, _} = Fetch.manifest(config, "ash", sha, "v2/manifests")
    assert File.exists?(Path.join([config.home, "manifests", sha <> ".json"]))
    F.clear_requests()
    assert {:ok, %{"versions" => _}} = Fetch.manifest(config, "ash", sha, "v2/manifests")
    assert F.requests() == []

    # A cache entry that no longer hashes to its name is ignored and refetched.
    File.write!(Path.join([config.home, "manifests", sha <> ".json"]), "{}")
    assert {:ok, %{"versions" => _}} = Fetch.manifest(config, "ash", sha, "v2/manifests")
    assert length(F.requests()) == 1
  end

  test "a cached manifest or file that is a symlink is never used", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps,
    tmp_dir: dir
  } do
    F.publish(f, %{"ash" => %{"versions" => %{}}})
    sha = batch_sha("ash")
    elsewhere = Path.join(dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.write!(Path.join(elsewhere, "m"), F.get(:manifests_v2)["ash"])
    cached = Path.join([config.home, "manifests", sha <> ".json"])
    File.mkdir_p!(Path.dirname(cached))
    File.ln_s!(Path.join(elsewhere, "m"), cached)

    F.clear_requests()
    assert {:ok, _} = Fetch.manifest(config, "ash", sha, "v2/manifests")
    assert length(F.requests()) == 1
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(cached)

    beam_sha = F.file(f, "b")
    File.write!(Path.join(elsewhere, "b"), "b")
    File.mkdir_p!(Path.join(config.home, "files"))
    File.ln_s!(Path.join(elsewhere, "b"), Path.join([config.home, "files", beam_sha]))

    F.clear_requests()
    e = entry(with_app(f, [file_entry(beam_sha, 1)]))
    assert {:ok, %{cached: 0}} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
    assert Enum.any?(F.requests(), &(&1.path == "/precompiled/files/" <> beam_sha))

    assert {:ok, %File.Stat{type: :regular}} =
             File.lstat(Path.join([config.home, "files", beam_sha]))
  end

  test "a batch sha that is not 64 hex digits never becomes a file name", %{config: config} do
    assert {:fail, "manifest hash malformed"} =
             Fetch.manifest(config, "ash", "../../x", "v2/manifests")
  end

  test "offline: a manifest or file not in the cache is a miss, with no request", %{
    config: config,
    f: f,
    build_lib: lib,
    deps: deps
  } do
    F.clear_requests()
    offline = Map.put(config, :offline, true)

    assert {:miss, "offline: manifest not cached"} =
             Fetch.manifest(offline, "ash", String.duplicate("a", 64), "v2/manifests")

    e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))

    assert {:fail, "offline: file not cached" <> _} =
             Fetch.install(offline, :ash, e, @lock_entry, lib, deps_path: deps)

    assert F.requests() == []
  end

  test "twenty files of one dep install correctly in parallel", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    files =
      for i <- 1..20,
          do: file_entry(F.file(f, "beam #{i}"), byte_size("beam #{i}"), "ebin/Elixir.M#{i}.beam")

    assert {:ok, %{files: 21}} =
             Fetch.install(config, :ash, entry(with_app(f, files)), @lock_entry, lib,
               deps_path: deps
             )

    for i <- 1..20,
        do: assert(File.read!(Path.join(lib, "ash/ebin/Elixir.M#{i}.beam")) == "beam #{i}")
  end

  test "a failing file among many reports that file and leaves _build untouched", %{
    f: f,
    config: config,
    build_lib: lib,
    deps: deps
  } do
    files =
      for i <- 1..10,
          do: file_entry(F.file(f, "beam #{i}"), byte_size("beam #{i}"), "ebin/Elixir.M#{i}.beam")

    bad = file_entry(String.duplicate("0", 64), 3, "ebin/Elixir.Bad.beam")

    assert {:fail, "file not available: " <> _} =
             Fetch.install(config, :ash, entry(with_app(f, files ++ [bad])), @lock_entry, lib,
               deps_path: deps
             )

    refute File.exists?(Path.join(lib, "ash"))
    refute File.exists?(Path.join(lib, ".precompiled/ash"))
  end

  describe "content origins" do
    setup %{config: config} do
      cdn_port = ElixirPrecompiled.TestServer.port() + 2
      start_supervised!({ElixirPrecompiled.TestServer, port: cdn_port})
      cdn = "http://127.0.0.1:#{cdn_port}/precompiled"
      %{cdn_port: cdn_port, config: Map.put(config, :content, [cdn])}
    end

    test "files and manifests come from the content origin", %{
      f: f,
      config: config,
      cdn_port: p,
      build_lib: lib,
      deps: deps
    } do
      F.publish(f, %{"ash" => %{"versions" => %{}}})
      sha = batch_sha("ash")
      F.clear_requests()
      assert {:ok, _} = Fetch.manifest(config, "ash", sha, "v2/manifests")
      e = entry(with_app(f, [file_entry(F.file(f, "b"), 1)]))
      assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
      assert F.requests() != []
      assert Enum.all?(F.requests(), &(&1.port == p))
    end

    test "a content origin serving wrong bytes falls back to the source", %{
      f: f,
      config: config,
      cdn_port: p,
      build_lib: lib,
      deps: deps
    } do
      F.corrupt_port(p)
      F.publish(f, %{"ash" => %{"versions" => %{}}})
      sha = batch_sha("ash")
      assert {:ok, %{"versions" => _}} = Fetch.manifest(config, "ash", sha, "v2/manifests")
      e = entry(with_app(f, [file_entry(F.file(f, "good"), 4)]))
      assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
      assert File.read!(Path.join(lib, "ash/ebin/Elixir.Ash.beam")) == "good"
      assert Enum.any?(F.requests(), &(&1.port != p))
    end

    test "an unreachable content origin falls back to the source", %{
      f: f,
      config: config,
      build_lib: lib,
      deps: deps
    } do
      config = Map.put(config, :content, ["http://127.0.0.1:1/precompiled"])
      F.publish(f, %{"ash" => %{"versions" => %{}}})
      assert {:ok, _} = Fetch.manifest(config, "ash", batch_sha("ash"), "v2/manifests")
      e = entry(with_app(f, [file_entry(F.file(f, "good"), 4)]))
      assert {:ok, _} = Fetch.install(config, :ash, e, @lock_entry, lib, deps_path: deps)
    end

    test "without by-sha (the batch names no content) manifests use the source's name path", %{
      f: f,
      config: config
    } do
      F.publish(f, %{"ash" => %{"versions" => %{}}})
      F.clear_requests()

      assert {:ok, _} =
               Fetch.manifest(
                 Map.put(config, :by_sha, false),
                 "ash",
                 batch_sha("ash"),
                 "v2/manifests"
               )

      assert [%{path: "/precompiled/v2/manifests/ash.json"}] = F.requests()
    end
  end
end
