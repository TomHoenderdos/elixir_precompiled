# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule PrecompiledTest do
  # Installs load into this VM, so every test removes what it loaded on exit.
  use ExUnit.Case, async: false
  import ElixirPrecompiled.DeviceFixture
  alias ElixirPrecompiled.Device.Source
  alias ElixirPrecompiled.Device.Store
  alias ElixirPrecompiled.Fixture

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Other suites reset this app's env; the seams (env:, ...) need it.
    Application.put_env(:elixir_precompiled, :test_seams, true)
    start_supervised!(ElixirPrecompiled.TestServer)
    fixture = Fixture.new(dir, offline_key: true)

    host_env =
      env(
        system: nil,
        otp: System.otp_release(),
        elixir: System.version(),
        cpu: to_string(:erlang.system_info(:system_architecture))
      )

    opts = [
      source: Fixture.base_url(),
      root: fixture.root_path,
      dir: Path.join(dir, "store"),
      env: host_env,
      quiet: true
    ]

    on_exit(fn -> unload_all(opts) end)
    %{fixture: fixture, opts: opts}
  end

  defp unload_all(opts) do
    with items when is_list(items) <- Precompiled.list(store(opts)) do
      for %{loaded?: true, app: app} <- items,
          do: Precompiled.uninstall(app, store(opts) ++ [force: true, cascade: true])
    end
  end

  defp store(opts), do: Keyword.take(opts, [:dir, :quiet])

  defp files_requested() do
    for %{path: "/precompiled/files/" <> sha} <- Fixture.requests(), do: sha
  end

  defp app_sha(build),
    do: Enum.find(build["ebin"], &String.ends_with?(&1["path"], ".app"))["sha256"]

  # The code path, the loaded apps and every name in the store but the
  # trust state and the (empty) staging dir.
  defp snapshot(opts) do
    dir = opts[:dir]

    tree =
      for p <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
          rel = Path.relative_to(p, dir),
          not String.starts_with?(rel, ".trust"),
          rel != ".staging",
          do: rel

    {:code.get_path(), Enum.sort(for({a, _, _} <- Application.loaded_applications(), do: a)),
     Enum.sort(tree)}
  end

  # A group leader whose writes fail for the OK line of `name_vsn` and
  # succeed (discarded) for everything else.
  defp failing_io(name_vsn) do
    spawn_link(fn -> io_loop(name_vsn) end)
  end

  defp io_loop(name_vsn) do
    receive do
      {:io_request, from, ref, {:put_chars, _encoding, chars}} ->
        line = IO.chardata_to_string(chars)
        ok_line? = String.contains?(line, name_vsn) and String.contains?(line, " OK ")
        send(from, {:io_reply, ref, if(ok_line?, do: {:error, :closed}, else: :ok)})
        io_loop(name_vsn)

      {:io_request, from, ref, _request} ->
        send(from, {:io_reply, ref, {:error, :request}})
        io_loop(name_vsn)
    end
  end

  defp put_device_env(kw) do
    Application.put_env(:elixir_precompiled, :device, kw)
    on_exit(fn -> Application.delete_env(:elixir_precompiled, :device) end)
  end

  defp new_key() do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{keyid: Fixture.sha(public), public: public, private: private}
  end

  describe "switches and sources" do
    test "available by default; only the firmware's kill switch turns it off", %{opts: opts} do
      put_device_env(enabled: false)
      assert Precompiled.install(:demo_a, opts) == {:error, :disabled}
      assert Fixture.requests() == []
    end

    test "the default source is the official API, checked against the shipped root" do
      assert {:ok,
              %{
                source: "https://compatibility.nerves-project.org/api/precompiled",
                root_path: root
              }} =
               Source.config(dir: System.tmp_dir!())

      assert root == Path.join(ElixirPrecompiled.Config.priv_dir(), "precompiled/root.json")
    end

    test "another source must be named: config or option, never guessed", %{opts: opts} do
      put_device_env(source: "https://mirror.example/api/precompiled")

      assert {:ok, %{source: "https://mirror.example/api/precompiled"}} =
               Source.config(dir: opts[:dir])

      assert {:error, {:bad_source, "ftp://x"}} =
               Source.config(source: "ftp://x", dir: opts[:dir])

      assert {:error, {:bad_source, "http://example.com"}} =
               Source.config(source: "http://example.com")

      assert {:error, {:bad_source, "file://relative"}} = Source.config(source: "file://relative")
    end

    test "a file:// source reads the disk only: never offline-gated, no content origins", %{
      tmp_dir: dir
    } do
      bundle = Path.join(dir, "b")
      File.mkdir_p!(bundle)
      File.ln_s!(bundle, Path.join(dir, "link"))

      assert {:ok, config} =
               Source.config(source: "file://" <> Path.join(dir, "link") <> "/", dir: dir)

      assert config.source == "file://" <> bundle
      assert %{bundle: true, offline: false, cache: false, content: [], by_sha: false} = config
      assert config.state_key == "device"
      assert config.home == Path.join(dir, ".trust")
      assert is_integer(config.deadline_at)
    end

    test "persist: and deps_identity: are not options", %{opts: opts} do
      assert Precompiled.install(:demo_a, opts ++ [persist: true]) ==
               {:error, {:bad_option, :persist}}

      assert Precompiled.install(:demo_a, opts ++ [deps_identity: :version]) ==
               {:error, {:bad_option, :deps_identity}}

      assert Fixture.requests() == []
    end

    test "bad input never raises" do
      assert {:error, {:bad_request, "nope"}} = Precompiled.install("nope", [])
      assert {:error, {:bad_request, {:recon, :x}}} = Precompiled.install({:recon, :x}, [])
      assert {:error, {:bad_request, [1]}} = Precompiled.install([1], [])
      assert {:error, {:bad_request, "x"}} = Precompiled.uninstall("x", [])
    end

    test "a missing network app is named before any request" do
      assert Precompiled.missing_app([:crypto, :no_such_app_here]) ==
               {:error, {:missing_app, :no_such_app_here}}

      assert Precompiled.missing_app([:crypto]) == :ok
    end

    test "an unsynchronized clock refuses an online install before any request", %{opts: opts} do
      assert {:error, {:clock_unsynchronized, %DateTime{}}} =
               Precompiled.install(:demo_a, opts ++ [clock_synchronized?: fn -> false end])

      assert Fixture.requests() == []
    end

    test "an unsafe store is refused before any request", %{opts: opts} do
      File.mkdir_p!(opts[:dir])
      File.chmod!(opts[:dir], 0o777)
      assert {:error, {:unsafe_store, :writable_by_others}} = Precompiled.install(:demo_a, opts)
      assert Fixture.requests() == []
    end

    test "the test seams are refused per call unless the test env enables them", %{opts: opts} do
      Application.delete_env(:elixir_precompiled, :test_seams)
      on_exit(fn -> Application.put_env(:elixir_precompiled, :test_seams, true) end)
      plain = Keyword.drop(opts, [:env, :root])

      assert Precompiled.install(:demo_a, Keyword.drop(opts, [:root])) ==
               {:error, {:bad_option, :env}}

      # A per-call root would swap the trust anchor: firmware config only.
      assert Precompiled.install(:demo_a, Keyword.drop(opts, [:env])) ==
               {:error, {:bad_option, :root}}

      assert Precompiled.install(:demo_a, plain ++ [clock_synchronized?: fn -> true end]) ==
               {:error, {:bad_option, :clock_synchronized?}}

      # Nor through the firmware's config: those keys are not read from it.
      put_device_env(env: opts[:env], clock_synchronized?: fn -> true end, home: "/tmp/x")
      assert Source.device_config() == []
      assert Fixture.requests() == []
    end

    test "a cacerts_path that is not a path is refused", %{opts: opts} do
      assert Precompiled.install(:demo_a, opts ++ [cacerts_path: :system]) ==
               {:error, {:bad_option, :cacerts_path}}

      assert Fixture.requests() == []
    end

    test "a signed priv entry with no mode is a fetch error", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_nm, "1.0.0", priv: [{"priv/data.bin", "x"}])
      build = %{build | "priv" => Enum.map(build["priv"], &Map.delete(&1, "mode"))}
      Fixture.publish(f, %{"demo_nm" => manifest(%{"1.0.0" => [build]})})

      assert {:error, {:fetch, "demo_nm", "unsafe path or mode" <> _}} =
               Precompiled.install(:demo_nm, opts)
    end

    test "a full disk while staging is enospc, not an internal error" do
      assert Precompiled.stage_reason("x", %File.Error{reason: :enospc, action: "write"}, "/d") ==
               {:enospc, "/d"}

      assert Precompiled.stage_reason("x", "install failed: no space left on device", "/d") ==
               {:enospc, "/d"}

      assert Precompiled.stage_reason("x", "size mismatch", "/d") ==
               {:fetch, "x", "size mismatch"}
    end

    test "an unknown option is refused, never ignored", %{opts: opts} do
      assert Precompiled.install(:demo_a, opts ++ [dry_rn: true]) ==
               {:error, {:bad_option, :dry_rn}}

      assert Precompiled.uninstall(:demo_a, store(opts) ++ [cascde: true]) ==
               {:error, {:bad_option, :cascde}}

      assert Precompiled.uninstall(:demo_a, opts) == {:error, {:bad_option, :source}}
      assert Precompiled.list(store(opts) ++ [force: true]) == []
      assert Fixture.requests() == []
    end

    test "the firmware's allowlist cannot be widened or cleared by a call", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      a = publish_app(f, dir, :demo_al, "1.0.0")
      Fixture.publish(f, %{"demo_al" => manifest(%{"1.0.0" => [a]})})
      put_device_env(allow: [:other])

      assert Precompiled.install(:demo_al, opts ++ [allow: nil]) ==
               {:error, {:bad_option, :allow}}

      assert Precompiled.install(:demo_al, opts ++ [allow: [:demo_al]]) ==
               {:error, {:bad_option, :allow}}

      assert Precompiled.install(:demo_al, opts ++ [enabled: true]) ==
               {:error, {:bad_option, :enabled}}

      assert {:error, {:not_allowed, :demo_al}} = Precompiled.install(:demo_al, opts)
    end

    test "uninstall and list check the store like install does", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_us, "1.0.0")
      Fixture.publish(f, %{"demo_us" => manifest(%{"1.0.0" => [build]})})
      assert {:ok, [_]} = Precompiled.install(:demo_us, opts ++ [start: false])
      File.chmod!(opts[:dir], 0o777)

      assert Precompiled.uninstall(:demo_us, store(opts)) ==
               {:error, {:unsafe_store, :writable_by_others}}

      assert Precompiled.list(store(opts)) == {:error, {:unsafe_store, :writable_by_others}}
      File.chmod!(opts[:dir], 0o700)
      assert [%{app: :demo_us}] = Precompiled.list(store(opts))

      assert Precompiled.uninstall(:demo_us, dir: Path.join(dir, "none")) ==
               {:error, {:not_installed, :demo_us}}

      refute File.exists?(Path.join(dir, "none"))
    end

    test "a busy store answers :busy after bounded retries", %{opts: opts} do
      test = self()

      holder =
        spawn(fn ->
          Store.with_lock(fn ->
            send(test, :held)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :held
      assert Precompiled.install(:demo_a, opts ++ [lock_retries: 0]) == {:error, :busy}
      assert Precompiled.uninstall(:demo_a, store(opts) ++ [lock_retries: 0]) == {:error, :busy}
      send(holder, :release)
    end
  end

  describe "online installs" do
    test "installs, loads and starts a pure app; a second call is idempotent", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_a, "1.0.0")
      Fixture.publish(f, %{"demo_a" => manifest(%{"1.0.0" => [build]})})

      assert {:ok,
              [
                %Precompiled.Installed{
                  app: :demo_a,
                  version: "1.0.0",
                  role: :requested,
                  from_cache?: false
                } = i
              ]} =
               Precompiled.install(:demo_a, opts)

      assert i.loaded? and i.batch_sequence == 1 and i.target == "pure_elixir"
      assert i.path == Path.join(opts[:dir], "demo_a-1.0.0")
      assert apply(DemoA, :hello, []) == :hello
      assert {:demo_a, _, _} = List.keyfind(Application.started_applications(), :demo_a, 0)

      assert [
               %Precompiled.Installed{
                 app: :demo_a,
                 loaded?: true,
                 role: :requested,
                 batch_sequence: 1
               }
             ] =
               Precompiled.list(store(opts))

      Fixture.clear_requests()

      loaded = %{
        opts[:env]
        | present: Map.put(opts[:env].present, :demo_a, %{vsn: "1.0.0", loaded?: true})
      }

      assert {:ok, []} = Precompiled.install(:demo_a, Keyword.put(opts, :env, loaded))
      refute Enum.any?(Fixture.requests(), &String.contains?(&1.path, "/files/"))
      assert :ok = Precompiled.uninstall(:demo_a, store(opts))
      assert :code.is_loaded(DemoA) == false
      refute List.keymember?(Application.loaded_applications(), :demo_a, 0)
      assert [%{app: :demo_a, loaded?: false}] = Precompiled.list(store(opts))
    end

    test "an app the firmware has is already_present, before any request", %{opts: opts} do
      assert {:error, {:already_present, :logger, _}} = Precompiled.install(:logger, opts)
      assert Fixture.requests() == []
    end

    test "dry_run fetches manifests and .app files only, writes the report, installs nothing", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_b, "1.0.0")
      Fixture.publish(f, %{"demo_b" => manifest(%{"1.0.0" => [build]})})
      report = Path.join(dir, "report.json")
      File.mkdir_p!(Path.join(opts[:dir], "junk-1.0.0"))
      :ok = Store.ensure_root(opts[:dir])
      before = snapshot(opts)

      assert {:ok, %Precompiled.Plan{installs: [%{app: :demo_b}]}} =
               Precompiled.install(:demo_b, opts ++ [dry_run: true, report: report])

      assert files_requested() == [app_sha(build)]

      assert %{
               "format" => 1,
               "env" => %{"otp" => _},
               "plan" => %{"installs" => [%{"app" => "demo_b"}]}
             } =
               report |> File.read!() |> :json.decode()

      refute File.exists?(Path.join([opts[:dir], "demo_b-1.0.0"]))
      # No sweep on a dry run: the stray dir is still there.
      assert snapshot(opts) == before
    end

    test "a real call sweeps the store under the lock", %{fixture: f, opts: opts, tmp_dir: dir} do
      build = publish_app(f, dir, :demo_sw, "1.0.0")
      Fixture.publish(f, %{"demo_sw" => manifest(%{"1.0.0" => [build]})})
      :ok = Store.ensure_root(opts[:dir])
      File.mkdir_p!(Path.join(opts[:dir], "junk-1.0.0"))
      assert {:ok, [_]} = Precompiled.install(:demo_sw, opts)
      refute File.exists?(Path.join(opts[:dir], "junk-1.0.0"))
    end

    test "a closure: the absent dependency is installed first; uninstall respects dependants", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      dep = publish_app(f, dir, :demo_dep, "1.0.0")
      top = publish_app(f, dir, :demo_top, "1.0.0", deps: [demo_dep: dep])

      Fixture.publish(f, %{
        "demo_dep" => manifest(%{"1.0.0" => [dep]}),
        "demo_top" => manifest(%{"1.0.0" => [top]})
      })

      assert {:error, {:needs, [{:demo_dep, "1.0.0"}]}} =
               Precompiled.install(:demo_top, opts ++ [closure: false])

      assert {:ok, [%{app: :demo_dep, role: :dependency}, %{app: :demo_top, role: :requested}]} =
               Precompiled.install(:demo_top, opts)

      assert {:error, {:in_use_by, [:demo_top]}} = Precompiled.uninstall(:demo_dep, store(opts))
      assert :code.is_loaded(DemoDep) != false
      assert :ok = Precompiled.uninstall(:demo_dep, store(opts) ++ [cascade: true])
      assert :code.is_loaded(DemoDep) == false
      assert :code.is_loaded(DemoTop) == false
    end

    test "uninstall counts an app that only includes it as a dependant", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      dep = publish_app(f, dir, :demo_inc, "1.0.0")
      top = publish_app(f, dir, :demo_incl, "1.0.0", deps: [demo_inc: dep], included: [:demo_inc])

      Fixture.publish(f, %{
        "demo_inc" => manifest(%{"1.0.0" => [dep]}),
        "demo_incl" => manifest(%{"1.0.0" => [top]})
      })

      assert {:ok, [%{app: :demo_inc}, %{app: :demo_incl}]} =
               Precompiled.install(:demo_incl, opts)

      assert Application.spec(:demo_incl, :included_applications) == [:demo_inc]
      assert {:error, {:in_use_by, [:demo_incl]}} = Precompiled.uninstall(:demo_inc, store(opts))
      assert :code.is_loaded(DemoInc) != false
      assert :ok = Precompiled.uninstall(:demo_inc, store(opts) ++ [cascade: true])
      assert :code.is_loaded(DemoIncl) == false
    end

    test "uninstall refuses while another process runs the app's code, and says what changed", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      source = """
      defmodule DemoBusy do
        def wait, do: receive(do: (:stop -> :ok))
      end
      """

      build = publish_app(f, dir, :demo_busy, "1.0.0", source: source)
      Fixture.publish(f, %{"demo_busy" => manifest(%{"1.0.0" => [build]})})
      assert {:ok, [_]} = Precompiled.install(:demo_busy, opts)
      pid = spawn(fn -> apply(DemoBusy, :wait, []) end)
      Process.sleep(50)

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          send(
            self(),
            {:result, Precompiled.uninstall(:demo_busy, Keyword.put(store(opts), :quiet, false))}
          )
        end)

      assert_received {:result, {:error, {:in_use, DemoBusy, [^pid]}}}
      assert out =~ "unchanged; retry with force: true"
      assert List.keymember?(Application.started_applications(), :demo_busy, 0)
      send(pid, :stop)
      assert :ok = Precompiled.uninstall(:demo_busy, store(opts) ++ [force: true])
    end

    test "uninstall of an app that is not ours", %{opts: opts} do
      assert {:error, {:not_installed, :logger}} = Precompiled.uninstall(:logger, store(opts))
    end

    test "uninstall remove: true also drops the cache entry", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_rm, "1.0.0")
      Fixture.publish(f, %{"demo_rm" => manifest(%{"1.0.0" => [build]})})
      assert {:ok, [_]} = Precompiled.install(:demo_rm, opts)
      assert :ok = Precompiled.uninstall(:demo_rm, store(opts) ++ [remove: true])
      refute File.exists?(Path.join(opts[:dir], "demo_rm-1.0.0"))
      assert Precompiled.list(store(opts)) == []
    end

    test "an on_load failure of the second app removes the first too", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      dep = publish_app(f, dir, :demo_ok, "1.0.0")
      bad = publish_app(f, dir, :demo_fail, "1.0.0", deps: [demo_ok: dep], on_load_fails: true)

      Fixture.publish(f, %{
        "demo_ok" => manifest(%{"1.0.0" => [dep]}),
        "demo_fail" => manifest(%{"1.0.0" => [bad]})
      })

      path = :code.get_path()
      loaded = Application.loaded_applications()

      assert {:error, {:on_load_failed, DemoFail.Nif, _}} = Precompiled.install(:demo_fail, opts)
      assert :code.is_loaded(DemoOk) == false
      assert :code.is_loaded(DemoFail) == false
      assert Enum.all?(Precompiled.list(store(opts)), &(not &1.loaded?))
      assert :code.get_path() == path
      assert Enum.sort(Application.loaded_applications()) == Enum.sort(loaded)
    end

    test "a start failure rolls the whole call back", %{fixture: f, opts: opts, tmp_dir: dir} do
      source = """
      defmodule DemoSf do
        use Application
        def start(_type, _args), do: {:error, :nope}
      end
      """

      build = publish_app(f, dir, :demo_sf, "1.0.0", source: source, mod: {DemoSf, []})
      Fixture.publish(f, %{"demo_sf" => manifest(%{"1.0.0" => [build]})})
      path = :code.get_path()

      assert {:error, {:start_failed, :demo_sf, _}} = Precompiled.install(:demo_sf, opts)
      assert :code.is_loaded(DemoSf) == false
      assert :code.get_path() == path
      refute List.keymember?(Application.loaded_applications(), :demo_sf, 0)
    end

    test "a failure after an app activated rolls that app back too", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_late, "1.0.0")
      Fixture.publish(f, %{"demo_late" => manifest(%{"1.0.0" => [build]})})
      path = :code.get_path()
      loaded = Application.loaded_applications()

      # The loader activated the app; printing its OK line then fails.
      io = failing_io("demo_late 1.0.0")
      gl = Process.group_leader()
      Process.group_leader(self(), io)

      result =
        try do
          Precompiled.install(:demo_late, Keyword.put(opts, :quiet, false))
        after
          Process.group_leader(self(), gl)
        end

      assert {:error, {:internal, _}} = result
      assert :code.is_loaded(DemoLate) == false
      assert :code.get_path() == path
      assert Enum.sort(Application.loaded_applications()) == Enum.sort(loaded)
      assert [%{app: :demo_late, loaded?: false}] = Precompiled.list(store(opts))
    end

    test "a call killed mid-activation: the next call copes and uninstall recovers", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      test = self()
      :persistent_term.put(:demo_km_test, test)
      on_exit(fn -> :persistent_term.erase(:demo_km_test) end)

      # start/2 waits for the test while the first call is killed.
      source = """
      defmodule DemoKm do
        use Application

        def start(_type, _args) do
          case :persistent_term.get(:demo_km_test, nil) do
            pid when is_pid(pid) ->
              send(pid, {:starting, self()})
              receive do: (:go -> :ok)

            nil ->
              :ok
          end

          Supervisor.start_link([], strategy: :one_for_one)
        end
      end
      """

      build = publish_app(f, dir, :demo_km, "1.0.0", source: source, mod: {DemoKm, []})
      Fixture.publish(f, %{"demo_km" => manifest(%{"1.0.0" => [build]})})
      ebin = String.to_charlist(Path.join([opts[:dir], "demo_km-1.0.0", "ebin"]))

      {caller, ref} = spawn_monitor(fn -> Precompiled.install(:demo_km, opts) end)
      assert_receive {:starting, starter}, 10_000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
      :persistent_term.erase(:demo_km_test)
      send(starter, :go)
      assert ebin in :code.get_path()

      # The lock died with the caller. The start finished on its own, from
      # the committed entry: the next call finds the app there.
      assert {:ok, []} = Precompiled.install(:demo_km, opts)
      assert [%{app: :demo_km, loaded?: true}] = Precompiled.list(store(opts))

      assert :ok = Precompiled.uninstall(:demo_km, store(opts) ++ [force: true])
      refute ebin in :code.get_path()
      assert :code.is_loaded(DemoKm) == false
      refute List.keymember?(Application.loaded_applications(), :demo_km, 0)

      assert {:ok, [%Precompiled.Installed{app: :demo_km, from_cache?: true}]} =
               Precompiled.install(:demo_km, opts)

      assert {:demo_km, _, _} = List.keyfind(Application.started_applications(), :demo_km, 0)
    end

    test "a file with the wrong bytes fails the install and leaves the device as it was", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_c, "1.0.0")
      [beam | _] = Enum.filter(build["ebin"], &String.ends_with?(&1["path"], ".beam"))
      Fixture.put_in_map(:files, beam["sha256"], "tampered")
      Fixture.publish(f, %{"demo_c" => manifest(%{"1.0.0" => [build]})})
      :ok = Store.ensure_root(opts[:dir])
      before = snapshot(opts)

      assert {:error, {:fetch, "demo_c", "size mismatch" <> _}} =
               Precompiled.install(:demo_c, opts)

      assert File.ls!(Path.join(opts[:dir], ".staging")) == []
      assert snapshot(opts) == before
    end

    test "every install stages into a fresh dir, never one left behind", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_l2, "1.0.0")
      Fixture.publish(f, %{"demo_l2" => manifest(%{"1.0.0" => [build]})})
      :ok = Store.ensure_root(opts[:dir])
      planted = Path.join([opts[:dir], ".staging", "demo_l2-1.0.0"])
      File.mkdir_p!(Path.join(planted, "ebin"))
      File.write!(Path.join([planted, "ebin", "Elixir.Evil.beam"]), "x")

      assert {:ok, [_]} = Precompiled.install(:demo_l2, opts)
      on_disk = File.ls!(Path.join([opts[:dir], "demo_l2-1.0.0", "ebin"])) |> Enum.sort()
      assert on_disk == Enum.sort(for e <- build["ebin"], do: Path.basename(e["path"]))
    end

    test "an ELF built for another CPU is refused before the rename", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      wrong = if String.starts_with?(opts[:env].cpu, "aarch64"), do: :x86_64, else: :aarch64

      build =
        publish_app(f, dir, :demo_so, "1.0.0", priv: [{"priv/demo.so", elf_header(64, wrong)}])

      Fixture.publish(f, %{"demo_so" => manifest(%{"1.0.0" => [build]})})
      :ok = Store.ensure_root(opts[:dir])
      before = snapshot(opts)

      assert {:error, {:elf, "priv/demo.so is " <> _}} = Precompiled.install(:demo_so, opts)
      assert snapshot(opts) == before
    end

    test "a noexec store refuses a plan with a .so before any download", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build =
        publish_app(f, dir, :demo_so2, "1.0.0",
          priv: [{"priv/demo.so", elf_header(64, :aarch64)}]
        )

      Fixture.publish(f, %{"demo_so2" => manifest(%{"1.0.0" => [build]})})
      env = %{opts[:env] | mounts: [{"/", ["rw", "noexec"]}]}

      assert {:error, {:noexec, "/"}} =
               Precompiled.install(:demo_so2, Keyword.put(opts, :env, env))

      assert files_requested() == [app_sha(build)]
    end

    test "too big for max_bytes is refused before any download", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_d, "1.0.0")
      Fixture.publish(f, %{"demo_d" => manifest(%{"1.0.0" => [build]})})
      assert {:error, {:too_big, _, 10}} = Precompiled.install(:demo_d, opts ++ [max_bytes: 10])
      assert files_requested() == [app_sha(build)]
    end

    test "allowlist covers closure members", %{fixture: f, opts: opts, tmp_dir: dir} do
      dep = publish_app(f, dir, :demo_x, "1.0.0")
      top = publish_app(f, dir, :demo_y, "1.0.0", deps: [demo_x: dep])

      Fixture.publish(f, %{
        "demo_x" => manifest(%{"1.0.0" => [dep]}),
        "demo_y" => manifest(%{"1.0.0" => [top]})
      })

      put_device_env(allow: [:demo_y])
      assert {:error, {:not_allowed, :demo_x}} = Precompiled.install(:demo_y, opts)
    end

    test "the .app files read while planning are bounded and fetched once each", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      builds =
        for n <- 1..20 do
          publish_app(f, dir, :demo_many, "1.0.0",
            apps: [:not_in_this_firmware],
            description: ~c"d#{n}"
          )
        end

      Fixture.publish(f, %{"demo_many" => manifest(%{"1.0.0" => builds ++ builds})})

      assert {:error, {:no_build, "demo_many", _}} =
               Precompiled.install(:demo_many, opts ++ [max_closure: 2])

      requested = files_requested()
      assert length(requested) <= 8
      assert requested == Enum.uniq(requested)
    end

    test "idempotence and concurrency: two concurrent calls serialize", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_cc, "1.0.0")
      Fixture.publish(f, %{"demo_cc" => manifest(%{"1.0.0" => [build]})})

      results =
        Task.await_many(
          [
            Task.async(fn -> Precompiled.install(:demo_cc, opts) end),
            Task.async(fn -> Precompiled.install(:demo_cc, opts) end)
          ],
          30_000
        )

      assert Enum.sort(Enum.map(results, &elem(&1, 0))) == [:ok, :ok]
      assert [[], [%{app: :demo_cc}]] = results |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert [%{app: :demo_cc, loaded?: true}] = Precompiled.list(store(opts))
    end

    test "a store dir spelled another way still finds what it loaded", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_m2, "1.0.0")
      Fixture.publish(f, %{"demo_m2" => manifest(%{"1.0.0" => [build]})})
      odd = Keyword.put(opts, :dir, Path.join([dir, "x", "..", "store"]) <> "/")
      File.mkdir_p!(Path.join(dir, "x"))

      assert {:ok, [_]} = Precompiled.install(:demo_m2, odd)
      assert [%{loaded?: true}] = Precompiled.list(store(opts))
      assert {:ok, []} = Precompiled.install(:demo_m2, opts)
      assert Store.remove(opts[:dir], :demo_m2) == {:error, {:in_use, :demo_m2}}
    end
  end

  describe "the activation reasons" do
    test "map to the documented reasons" do
      assert Precompiled.reason({:app_load_failed, :a, :bad}) ==
               {:start_failed, :a, {:load, :bad}}

      assert Precompiled.reason({:fetch, :a, "sha256 mismatch"}) ==
               {:fetch, "a", "sha256 mismatch"}

      assert {:internal, "code path " <> _} =
               Precompiled.reason({:code_path, "/x/ebin", :bad_directory})

      assert {:internal, _} = Precompiled.reason({:bad_option, :files})

      assert Precompiled.reason({:already_present, :a, "1.0.0"}) ==
               {:already_present, :a, "1.0.0"}

      assert Precompiled.reason({:internal, "boom"}) == {:internal, "boom"}
    end
  end

  describe "app_spec_fun" do
    test "a cached .app is used only when its bytes match the build", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_ap, "1.0.0")
      Fixture.publish(f, %{"demo_ap" => manifest(%{"1.0.0" => [build]})})
      assert {:ok, [_]} = Precompiled.install(:demo_ap, opts ++ [start: false])
      {:ok, config} = Source.config(opts)
      Fixture.clear_requests()

      assert {:ok, props} = Source.app_spec_fun(config).(build)
      assert props[:vsn] == ~c"1.0.0"
      assert files_requested() == []

      app = Path.join([opts[:dir], "demo_ap-1.0.0", "ebin", "demo_ap.app"])
      tampered = String.replace(File.read!(app), "kernel", "kernal")
      File.write!(app, tampered)

      assert {:ok, props} = Source.app_spec_fun(config).(build)
      assert :kernel in props[:applications]
      assert files_requested() == [app_sha(build)]
    end

    test "an .app whose bytes are not the build's is refused", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_bad_app, "1.0.0")
      Fixture.put_in_map(:files, app_sha(build), "{application, demo_bad_app, []}.")
      {:ok, config} = Source.config(opts)
      assert {:fail, why} = Source.app_spec_fun(config).(build)
      assert why =~ "mismatch"
    end
  end

  describe "file:// bundles" do
    test "a bundle with offline.json installs with no clock and no network", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_off, "1.0.0")

      bundle =
        write_bundle!(f, dir, %{"demo_off" => manifest(%{"1.0.0" => [build]})}, offline: true)

      opts =
        Keyword.merge(opts, source: "file://" <> bundle, clock_synchronized?: fn -> false end)

      assert {:ok, [%{app: :demo_off, batch_sequence: nil}]} =
               Precompiled.install(:demo_off, opts)

      assert Fixture.requests() == []
      assert [%{app: :demo_off, batch_sequence: nil}] = Precompiled.list(store(opts))

      prov =
        Path.join([opts[:dir], "demo_off-1.0.0", ".precompiled.json"])
        |> File.read!()
        |> :json.decode()

      assert prov["trust"] == "offline" and prov["offline_sequence"] == 1
      refute Map.has_key?(prov, "batch_sequence")
    end

    test "content origins in the bundle's batch are never asked", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_cdn, "1.0.0")

      bundle =
        write_bundle!(f, dir, %{"demo_cdn" => manifest(%{"1.0.0" => [build]})},
          batch_extra: %{"content" => [Fixture.base_url()]}
        )

      assert {:ok, [_]} =
               Precompiled.install(:demo_cdn, Keyword.put(opts, :source, "file://" <> bundle))

      assert Fixture.requests() == []

      batch = %{sequence: 1, manifests: %{}, manifests_v2: %{}, content: ["https://cdn.invalid"]}
      {:ok, file} = Source.config(Keyword.put(opts, :source, "file://" <> bundle))
      assert %{content: [], by_sha: false} = Source.with_batch(file, batch)
      {:ok, net} = Source.config(opts)
      assert %{content: ["https://cdn.invalid"], by_sha: true} = Source.with_batch(net, batch)
    end

    test "the offline sequence never reaches the batch floor", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      online = publish_app(f, dir, :demo_on1, "1.0.0")
      Fixture.publish(f, %{"demo_on1" => manifest(%{"1.0.0" => [online]})}, sequence: 3)
      assert {:ok, [%{batch_sequence: 3}]} = Precompiled.install(:demo_on1, opts)
      [state] = Path.wildcard(Path.join([opts[:dir], ".trust", "*", "state"]))
      assert File.read!(state) == "3"
      cached = File.read!(Path.join(Path.dirname(state), "batch.json"))

      build = publish_app(f, dir, :demo_off2, "1.0.0")

      bundle =
        write_bundle!(f, dir, %{"demo_off2" => manifest(%{"1.0.0" => [build]})},
          offline: true,
          offline_sequence: 1_900_000_000,
          sequence: 4
        )

      assert {:ok, [_]} =
               Precompiled.install(:demo_off2, Keyword.put(opts, :source, "file://" <> bundle))

      assert File.read!(state) == "3"
      assert File.read!(Path.join(Path.dirname(state), "offline_state")) == "1900000000"
      assert File.read!(Path.join(Path.dirname(state), "batch.json")) == cached
    end

    test "a manifest the offline document does not name is refused", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      a = publish_app(f, dir, :demo_in, "1.0.0")
      b = publish_app(f, dir, :demo_out, "1.0.0")

      bundle =
        write_bundle!(
          f,
          dir,
          %{"demo_in" => manifest(%{"1.0.0" => [a]}), "demo_out" => manifest(%{"1.0.0" => [b]})},
          offline: true,
          offline_packages: ["demo_in"]
        )

      opts = Keyword.put(opts, :source, "file://" <> bundle)
      assert {:error, {:no_build, "demo_out", _}} = Precompiled.install(:demo_out, opts)
      assert {:ok, [_]} = Precompiled.install(:demo_in, opts)
    end

    test "a bundle manifest whose bytes changed is refused", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      a = publish_app(f, dir, :demo_tm, "1.0.0")
      bundle = write_bundle!(f, dir, %{"demo_tm" => manifest(%{"1.0.0" => [a]})}, offline: true)
      path = Path.join([bundle, "v2", "manifests", "demo_tm.json"])
      File.write!(path, File.read!(path) <> " ")

      assert {:error, {:no_build, "demo_tm", "manifest hash differs from batch"}} =
               Precompiled.install(:demo_tm, Keyword.put(opts, :source, "file://" <> bundle))
    end

    test "an expired shipped root still verifies an offline bundle, never an online batch", %{
      opts: opts,
      tmp_dir: dir
    } do
      f = Fixture.new(dir, offline_key: true, root_expires: "2020-01-01T00:00:00Z")
      build = publish_app(f, dir, :demo_exp, "1.0.0")
      packages = %{"demo_exp" => manifest(%{"1.0.0" => [build]})}
      opts = Keyword.put(opts, :root, f.root_path)

      assert {:error, {:batch, "root document at " <> _}} = Precompiled.install(:demo_exp, opts)

      bundle = write_bundle!(f, dir, packages, offline: true)

      assert {:ok, [_]} =
               Precompiled.install(:demo_exp, Keyword.put(opts, :source, "file://" <> bundle))
    end

    test "a bundle's newer root brings the offline role to firmware that shipped without it",
         %{tmp_dir: dir} = ctx do
      f = Fixture.new(dir)
      assert f.offline_key == nil
      k2 = new_key()
      offline = new_key()
      root2 = Fixture.root_payload(k2.keyid, k2.public, "2031-01-01T00:00:00Z", 2, offline)
      root2_env = Fixture.sign(root2, [f.key, k2])
      build = publish_app(f, dir, :demo_rot, "1.0.0")

      bundle =
        write_bundle!(f, dir, %{"demo_rot" => manifest(%{"1.0.0" => [build]})},
          offline: true,
          offline_signers: [offline],
          root_env: root2_env
        )

      opts = Keyword.merge(ctx.opts, source: "file://" <> bundle, root: f.root_path)
      assert {:ok, [%{app: :demo_rot}]} = Precompiled.install(:demo_rot, opts)
    end

    test "offline.json is read only as a plain file of the bundle", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_ln, "1.0.0")

      bundle =
        write_bundle!(f, dir, %{"demo_ln" => manifest(%{"1.0.0" => [build]})}, offline: true)

      real = Path.join(dir, "elsewhere.json")
      File.rename!(Path.join(bundle, "offline.json"), real)
      File.ln_s!(real, Path.join(bundle, "offline.json"))

      assert {:error, {:batch, "unsafe file URL"}} =
               Precompiled.install(:demo_ln, Keyword.put(opts, :source, "file://" <> bundle))
    end

    test "a bundle without offline.json is its online batch, expiry and all", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_nooff, "1.0.0")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      issued = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      bundle =
        write_bundle!(f, dir, %{"demo_nooff" => manifest(%{"1.0.0" => [build]})},
          expires: past,
          issued: issued
        )

      assert {:error, {:batch, why}} =
               Precompiled.install(:demo_nooff, Keyword.put(opts, :source, "file://" <> bundle))

      assert why =~ "expired"
    end
  end

  describe "review fixes" do
    test "a store reached through a symlink: clean by the real path keeps what is loaded", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      File.ln_s!(real, Path.join(dir, "data"))
      build = publish_app(f, dir, :demo_sym, "1.0.0")
      Fixture.publish(f, %{"demo_sym" => manifest(%{"1.0.0" => [build]})})
      linked = Keyword.put(opts, :dir, Path.join([dir, "data", "precompiled"]))
      on_exit(fn -> unload_all(linked) end)

      assert {:ok, [_]} = Precompiled.install(:demo_sym, linked)

      assert {:ok, %{removed: [], kept: [:demo_sym]}} =
               Precompiled.clean(dir: Path.join(real, "precompiled"), quiet: true)

      assert apply(DemoSym, :hello, []) == :hello
      assert [%{app: :demo_sym, loaded?: true}] = Precompiled.list(store(linked))

      assert [%{app: :demo_sym, loaded?: true}] =
               Precompiled.list(dir: Path.join(real, "precompiled"), quiet: true)
    end

    test "a stale cache is evicted before staging, so the download has room", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      old = publish_app(f, dir, :demo_stale, "1.0.0")
      new = publish_app(f, dir, :demo_fresh, "1.0.0")
      [beam | _] = Enum.filter(new["ebin"], &String.ends_with?(&1["path"], ".beam"))

      Fixture.publish(f, %{
        "demo_stale" => manifest(%{"1.0.0" => [old]}),
        "demo_fresh" => manifest(%{"1.0.0" => [new]})
      })

      assert {:ok, [_]} = Precompiled.install(:demo_stale, opts)
      assert :ok = Precompiled.uninstall(:demo_stale, store(opts))
      used = Store.used_bytes(opts[:dir])
      plan = Enum.sum(for e <- new["ebin"], do: e["size"])
      # A file that fails to verify: the stale entry is gone by then,
      # because eviction ran before anything was downloaded.
      Fixture.put_in_map(:files, beam["sha256"], "tampered")

      assert {:error, {:fetch, "demo_fresh", _}} =
               Precompiled.install(:demo_fresh, opts ++ [max_bytes: used + plan - 1])

      refute File.exists?(Path.join(opts[:dir], "demo_stale-1.0.0"))
      assert File.ls!(Path.join(opts[:dir], ".staging")) == []
    end

    test "a plan of 60% of max_bytes fits an empty store", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_sixty, "1.0.0")
      Fixture.publish(f, %{"demo_sixty" => manifest(%{"1.0.0" => [build]})})
      plan = Enum.sum(for e <- build["ebin"], do: e["size"])
      :ok = Store.ensure_root(opts[:dir])
      max = Store.used_bytes(opts[:dir]) + div(plan * 10, 6)

      assert {:ok, [_]} = Precompiled.install(:demo_sixty, opts ++ [max_bytes: max])
    end

    test "an offline bundle's expired root does not strand the online path", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      k2 = new_key()
      root2 = Fixture.root_payload(k2.keyid, k2.public, "2020-01-01T00:00:00Z", 2, f.offline_key)
      x1 = publish_app(f, dir, :demo_rx1, "1.0.0")
      x2 = publish_app(f, dir, :demo_rx2, "1.0.0")

      bundle =
        write_bundle!(f, dir, %{"demo_rx1" => manifest(%{"1.0.0" => [x1]})},
          offline: true,
          root_env: Fixture.sign(root2, [f.key, k2])
        )

      assert {:ok, [%{app: :demo_rx1}]} =
               Precompiled.install(:demo_rx1, Keyword.put(opts, :source, "file://" <> bundle))

      # The offline path does not stand in for the online root check.
      assert Path.wildcard(Path.join([opts[:dir], ".trust", "**", "root_checked"])) == []

      # Online, the source serves a fresh root that chains from the
      # expired one, and the batch is signed under it.
      k3 = new_key()
      root3 = Fixture.root_payload(k3.keyid, k3.public, "2031-01-01T00:00:00Z", 3)
      Fixture.serve_root(f, Fixture.sign(root3, [k2, k3]))

      Fixture.publish(f, %{"demo_rx2" => manifest(%{"1.0.0" => [x2]})},
        signers: [k3],
        sequence: 2
      )

      assert {:ok, [%{app: :demo_rx2}]} = Precompiled.install(:demo_rx2, opts)
    end

    test "a bundle is never gated on NTP: its batch's own expiry decides", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_bclk, "1.0.0")
      packages = %{"demo_bclk" => manifest(%{"1.0.0" => [build]})}
      plain = write_bundle!(f, Path.join(dir, "p"), packages)
      unset = [clock_synchronized?: fn -> false end]

      assert {:ok, [_]} =
               Precompiled.install(
                 :demo_bclk,
                 Keyword.put(opts, :source, "file://" <> plain) ++ unset
               )
    end

    test "a native library listed under ebin is a malformed entry, refused before download", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_hide, "1.0.0", priv: [{"priv/x.so", "elf"}])
      build = %{build | "ebin" => build["ebin"] ++ build["priv"], "priv" => []}
      Fixture.publish(f, %{"demo_hide" => manifest(%{"1.0.0" => [build]})})

      assert {:error, {:no_build, "demo_hide", "malformed entry"}} =
               Precompiled.install(:demo_hide, opts)

      assert files_requested() == []
    end

    test "list/1 returns an error, never a silent empty list", %{opts: opts} do
      assert Precompiled.list(store(opts) ++ [bogus: 1]) == {:error, {:bad_option, :bogus}}
      assert Precompiled.list(store(opts)) == []
    end

    test "app_spec_fun reads the cache entries it is given, not the store", %{
      fixture: f,
      opts: opts,
      tmp_dir: dir
    } do
      build = publish_app(f, dir, :demo_ent, "1.0.0")
      Fixture.publish(f, %{"demo_ent" => manifest(%{"1.0.0" => [build]})})
      assert {:ok, [_]} = Precompiled.install(:demo_ent, opts ++ [start: false])
      entries = Store.list(opts[:dir])
      {:ok, config} = Source.config(Keyword.put(opts, :dir, Path.join(dir, "empty")))
      Fixture.clear_requests()

      assert {:ok, _} = Source.app_spec_fun(config, entries: entries).(build)
      assert files_requested() == []
    end

    test "a malformed :modules in a build's .app is refused while planning" do
      assert {:fail, "malformed ebin/demo_m.app"} =
               Source.parse_app(
                 ~s({application, demo_m, [{vsn, "1"}, {modules, [1]}]}.),
                 "demo_m"
               )

      assert {:ok, _} =
               Source.parse_app(~s({application, demo_m, [{vsn, "1"}, {modules, []}]}.), "demo_m")
    end
  end

  describe "output" do
    alias ElixirPrecompiled.Device.Output

    test "the env line" do
      assert Output.env_line(env()) ==
               "precompiled: system nerves_system_rpi4 2.2.1, OTP 29, Elixir 1.20.3, aarch64"

      assert Output.env_line(env(system: nil)) ==
               "precompiled: system none (pure_elixir builds only), OTP 29, Elixir 1.20.3, aarch64"
    end

    test "lines and the summary" do
      assert Output.line("circuits_gpio 2.3.1", "PLAN", "nerves_system_rpi4 2.2.1, 198 KB") ==
               "precompiled: circuits_gpio 2.3.1   PLAN  nerves_system_rpi4 2.2.1, 198 KB"

      assert Output.summary(1, 202_752, 2100) == "precompiled: 1 installed, 198 KB, 2.1 s"
    end
  end
end
