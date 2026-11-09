# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Device.LoaderTest do
  # Every load happens in an embedded-mode peer without Mix, never in this
  # VM: the loader adds code paths, loads modules and starts apps.
  use ExUnit.Case, async: false
  import ElixirPrecompiled.DeviceFixture, only: [compile_app: 5, files: 1]
  alias ElixirPrecompiled.Device.Loader
  alias ElixirPrecompiled.TestPeer

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup do
    {peer, _node} = TestPeer.start_embedded()

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  defp call(peer, fun, args), do: :peer.call(peer, Loader, fun, args, 30_000)
  defp rpc(peer, m, f, a), do: :peer.call(peer, m, f, a, 30_000)

  defp activate(peer, app, path, opts \\ []) do
    {deferred, opts} = Keyword.pop(opts, :deferred, [])
    {config, opts} = Keyword.pop(opts, :config, &Loader.no_config/2)
    opts = Keyword.put_new_lazy(opts, :files, fn -> files(path) end)
    call(peer, :activate, [app, path, deferred, config, opts])
  end

  # A fun built inside the peer, so the peer can run it (a fun of this
  # test module would be undefined there).
  defp peer_fun(peer, source) do
    {fun, _binding} = rpc(peer, Code, :eval_string, [source])
    fun
  end

  defp code_path?(peer, path) do
    String.to_charlist(Path.join(path, "ebin")) in rpc(peer, :code, :get_path, [])
  end

  defp loaded?(peer, mod), do: rpc(peer, :code, :is_loaded, [mod]) != false
  defp app_loaded?(peer, app), do: rpc(peer, :application, :get_key, [app, :vsn]) != :undefined

  defp started?(peer, app) do
    rpc(peer, Application, :started_applications, []) |> List.keymember?(app, 0)
  end

  # Nothing of the app is left: not started, not loaded, no module, no path.
  defp gone!(peer, app, path, mods) do
    refute started?(peer, app)
    refute app_loaded?(peer, app)
    for mod <- mods, do: refute(loaded?(peer, mod), "#{inspect(mod)} is still loaded")
    refute code_path?(peer, path)
  end

  defp bytes(path, rel), do: File.read!(Path.join(path, rel))

  test "the peer runs embedded and has no Mix", %{peer: peer} do
    assert rpc(peer, :code, :get_mode, []) == :embedded
    assert rpc(peer, :code, :which, [Mix]) == :non_existing
  end

  describe "activate/5" do
    test "loads a pure app explicitly in embedded mode and starts it temporary", %{
      peer: peer,
      tmp_dir: dir
    } do
      path =
        compile_app(
          dir,
          :demo_pure,
          "1.0.0",
          ["defmodule DemoPure do\n def hi, do: :hi\nend"],
          []
        )

      assert {:ok, []} = activate(peer, :demo_pure, path)
      assert rpc(peer, DemoPure, :hi, []) == :hi

      assert {:demo_pure, _, ~c"1.0.0"} =
               rpc(peer, Application, :started_applications, []) |> List.keyfind(:demo_pure, 0)

      # Appended, with the exact string the store's in-use check compares.
      assert List.last(rpc(peer, :code, :get_path, [])) ==
               String.to_charlist(Path.join(path, "ebin"))

      assert {:file, file} = rpc(peer, :code, :is_loaded, [DemoPure])
      assert to_string(file) == Path.join([path, "ebin", "Elixir.DemoPure.beam"])
      assert rpc(peer, :code, :lib_dir, [:demo_pure]) == String.to_charlist(path)
    end

    test "start: false loads without starting", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_lib, "1.0.0", ["defmodule DemoLib do\nend"], [])
      assert {:ok, []} = activate(peer, :demo_lib, path, start: false)
      assert loaded?(peer, DemoLib)
      assert app_loaded?(peer, :demo_lib)
      refute started?(peer, :demo_lib)
    end

    test "an on_load module loads after the rest; a failing on_load rolls back", %{
      peer: peer,
      tmp_dir: dir
    } do
      src = """
      defmodule DemoNif do
        @on_load :init
        def init, do: if(:persistent_term.get(:demo_nif_fail, false), do: :failed, else: :ok)
        def ok?, do: true
      end
      """

      path =
        compile_app(
          dir,
          :demo_nif,
          "1.0.0",
          [src, "defmodule DemoNif.Helper do\n def x, do: 1\nend"],
          []
        )

      assert {:ok, _} = activate(peer, :demo_nif, path)
      assert rpc(peer, DemoNif, :ok?, []) == true
      assert rpc(peer, DemoNif.Helper, :x, []) == 1

      bad_src = "defmodule DemoBad.Helper do\n def x, do: 1\nend"

      path2 =
        compile_app(
          dir,
          :demo_bad,
          "1.0.0",
          [String.replace(src, "DemoNif", "DemoBad"), bad_src],
          []
        )

      rpc(peer, :persistent_term, :put, [:demo_nif_fail, true])

      assert {:error, {:on_load_failed, DemoBad, _}} = activate(peer, :demo_bad, path2)
      refute Enum.any?(rpc(peer, :code, :get_path, []), &(to_string(&1) =~ "demo_bad"))
      gone!(peer, :demo_bad, path2, [DemoBad, DemoBad.Helper])
      # The earlier install is untouched.
      assert rpc(peer, DemoNif, :ok?, []) == true
    end

    test "deferred compile_env: checked after application:load, mismatch unloads", %{
      peer: peer,
      tmp_dir: dir
    } do
      path =
        compile_app(dir, :demo_env, "1.0.0", ["defmodule DemoEnv do\nend"], env: [mode: :fast])

      item = fn value ->
        %{
          "app" => "demo_env",
          "path" => ["mode"],
          "value" => Base.url_encode64(:erlang.term_to_binary(value), padding: false)
        }
      end

      cfg = &ElixirPrecompiled.CompileEnv.lookup/2

      assert {:error, {:no_build, "demo_env", "compile_env differs: demo_env [:mode]"}} =
               activate(peer, :demo_env, path, deferred: [item.({:ok, :slow})], config: cfg)

      gone!(peer, :demo_env, path, [DemoEnv])

      # The same check passes on the value the app's own env sets.
      assert {:ok, []} =
               activate(peer, :demo_env, path, deferred: [item.({:ok, :fast})], config: cfg)

      assert rpc(peer, Application, :get_env, [:demo_env, :mode]) == :fast
    end

    test "a beam that differs from the file list is refused before anything changes", %{
      peer: peer,
      tmp_dir: dir
    } do
      path = compile_app(dir, :demo_sha, "1.0.0", ["defmodule DemoSha do\nend"], [])
      list = files(path)
      File.write!(Path.join([path, "ebin", "Elixir.DemoSha.beam"]), "not a beam")

      assert {:error, {:fetch, :demo_sha, "sha256 mismatch (ebin/Elixir.DemoSha.beam)"}} =
               activate(peer, :demo_sha, path, files: list)

      gone!(peer, :demo_sha, path, [DemoSha])
    end

    test "a size that differs from the file list is refused", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_size, "1.0.0", ["defmodule DemoSize do\nend"], [])

      list =
        Enum.map(files(path), fn
          %{"path" => "ebin/Elixir.DemoSize.beam"} = f -> %{f | "size" => f["size"] + 1}
          f -> f
        end)

      assert {:error, {:fetch, :demo_size, "sha256 mismatch (ebin/Elixir.DemoSize.beam)"}} =
               activate(peer, :demo_size, path, files: list)

      gone!(peer, :demo_size, path, [DemoSize])
    end

    test "an .app that differs from the file list is refused", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_appsha, "1.0.0", ["defmodule DemoAppSha do\nend"], [])
      list = files(path)
      File.write!(Path.join([path, "ebin", "demo_appsha.app"]), "{application, demo_appsha, []}.")

      assert {:error, {:fetch, :demo_appsha, "sha256 mismatch (ebin/demo_appsha.app)"}} =
               activate(peer, :demo_appsha, path, files: list)

      gone!(peer, :demo_appsha, path, [DemoAppSha])
    end

    test "a module missing from the file list is refused", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_unlisted, "1.0.0", ["defmodule DemoUnlisted do\nend"], [])
      list = Enum.reject(files(path), &(&1["path"] == "ebin/Elixir.DemoUnlisted.beam"))

      assert {:error,
              {:fetch, :demo_unlisted, "not in the file list (ebin/Elixir.DemoUnlisted.beam)"}} =
               activate(peer, :demo_unlisted, path, files: list)

      gone!(peer, :demo_unlisted, path, [DemoUnlisted])
    end

    test "a priv file swapped after staging is refused before anything loads", %{
      peer: peer,
      tmp_dir: dir
    } do
      src =
        "defmodule DemoSo do\n @on_load :init\n def init, do: :persistent_term.put(:demo_so_ran, true)\nend"

      path = compile_app(dir, :demo_so, "1.0.0", [src], [])
      File.mkdir_p!(Path.join(path, "priv"))
      File.write!(Path.join([path, "priv", "demo_nif.so"]), "signed bytes")
      list = files(path)
      assert Enum.any?(list, &(&1["path"] == "priv/demo_nif.so"))
      File.write!(Path.join([path, "priv", "demo_nif.so"]), "evil! bytes!")

      assert {:error, {:fetch, :demo_so, "sha256 mismatch (priv/demo_nif.so)"}} =
               activate(peer, :demo_so, path, files: list)

      gone!(peer, :demo_so, path, [DemoSo])
      assert rpc(peer, :persistent_term, :get, [:demo_so_ran, false]) == false

      # A listed priv file that is gone is refused too.
      File.rm!(Path.join([path, "priv", "demo_nif.so"]))

      assert {:error, {:fetch, :demo_so, "cannot read priv/demo_nif.so: enoent"}} =
               activate(peer, :demo_so, path, files: list)

      gone!(peer, :demo_so, path, [DemoSo])
    end

    test "a matching priv file passes", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_priv, "1.0.0", ["defmodule DemoPriv do\nend"], [])
      File.mkdir_p!(Path.join([path, "priv", "sub"]))
      File.write!(Path.join([path, "priv", "sub", "x.so"]), :crypto.strong_rand_bytes(200_000))
      assert {:ok, []} = activate(peer, :demo_priv, path)
      assert loaded?(peer, DemoPriv)
    end

    test "the record exists before the code path changes", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_rec, "1.0.0", ["defmodule DemoRec do\nend"], [])
      ebin = String.to_charlist(Path.join(path, "ebin"))

      # The activating process is killed between the record and add_pathz.
      hook =
        peer_fun(peer, """
        fn
          :recorded -> Process.exit(self(), :kill)
          _ -> :ok
        end
        """)

      runner =
        peer_fun(peer, """
        fn args ->
          {pid, ref} = spawn_monitor(fn -> apply(ElixirPrecompiled.Device.Loader, :activate, args) end)
          receive do
            {:DOWN, ^ref, _, ^pid, why} -> why
          end
        end
        """)

      args = [:demo_rec, path, [], &Loader.no_config/2, [files: files(path), hook: hook]]
      assert :peer.call(peer, :erlang, :apply, [runner, [args]], 30_000) == :killed

      refute ebin in rpc(peer, :code, :get_path, [])
      assert %{ebin: _} = rpc(peer, :persistent_term, :get, [{Loader, :demo_rec}, nil])

      # The record lets a later rollback clear it.
      assert :ok = call(peer, :rollback, [[{:demo_rec, path}]])
      assert rpc(peer, :persistent_term, :get, [{Loader, :demo_rec}, nil]) == nil
      assert {:ok, []} = activate(peer, :demo_rec, path)
    end

    test "the file list is required", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_nofiles, "1.0.0", ["defmodule DemoNoFiles do\nend"], [])

      assert {:error, {:bad_option, :files}} =
               call(peer, :activate, [:demo_nofiles, path, [], &Loader.no_config/2, []])

      gone!(peer, :demo_nofiles, path, [DemoNoFiles])
    end

    test "files changed on disk after the hash check have no effect", %{
      peer: peer,
      tmp_dir: dir
    } do
      v1 = "defmodule DemoSwap do\n def v, do: 1\nend"
      v2 = "defmodule DemoSwap do\n def v, do: 2\nend"
      path = compile_app(dir, :demo_swap, "1.0.0", [v1], env: [who: :signed])
      other = compile_app(Path.join(dir, "other"), :demo_swap, "1.0.0", [v2], env: [who: :evil])

      # Copies the other build's .app and beam over the verified ones.
      hook =
        peer_fun(peer, """
        fn
          :verified ->
            for f <- ["demo_swap.app", "Elixir.DemoSwap.beam"] do
              File.cp!(Path.join(#{inspect(Path.join(other, "ebin"))}, f), Path.join(#{inspect(Path.join(path, "ebin"))}, f))
            end
          _ ->
            :ok
        end
        """)

      list = files(path)
      assert {:ok, []} = activate(peer, :demo_swap, path, files: list, hook: hook)
      assert bytes(path, "ebin/demo_swap.app") == bytes(other, "ebin/demo_swap.app")
      assert rpc(peer, DemoSwap, :v, []) == 1
      assert rpc(peer, Application, :get_env, [:demo_swap, :who]) == :signed
    end

    test "an app that is already loaded is refused and left alone", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :logger, "9.9.9", ["defmodule NotLogger do\nend"], [])
      vsn = to_string(rpc(peer, Application, :spec, [:logger, :vsn]))

      assert {:error, {:already_present, :logger, ^vsn}} = activate(peer, :logger, path)
      assert started?(peer, :logger)
      assert to_string(rpc(peer, Application, :spec, [:logger, :vsn])) == vsn
      refute loaded?(peer, NotLogger)
      refute code_path?(peer, path)
    end

    test "a module that is already loaded is refused, never replaced", %{
      peer: peer,
      tmp_dir: dir
    } do
      {:file, before} = rpc(peer, :code, :is_loaded, [Logger])

      path =
        compile_app(
          dir,
          :clash,
          "1.0.0",
          ["defmodule Logger.Clash do\n def x, do: 1\nend", "defmodule Logger do\nend"],
          []
        )

      assert {:error, {:module_loaded, Logger, _}} = activate(peer, :clash, path)
      assert rpc(peer, :code, :is_loaded, [Logger]) == {:file, before}
      gone!(peer, :clash, path, [Logger.Clash])
      assert loaded?(peer, Logger)
    end

    test "an app that is already active is refused and stays active", %{
      peer: peer,
      tmp_dir: dir
    } do
      path = compile_app(dir, :demo_twice, "1.0.0", ["defmodule DemoTwice do\nend"], [])
      assert {:ok, []} = activate(peer, :demo_twice, path)

      assert {:error, {:already_present, :demo_twice, "1.0.0"}} =
               activate(peer, :demo_twice, path)

      assert started?(peer, :demo_twice)
      assert loaded?(peer, DemoTwice)
      assert code_path?(peer, path)
    end

    test "a start failure rolls back", %{peer: peer, tmp_dir: dir} do
      src = """
      defmodule DemoNoStart do
        use Application
        def start(_type, _args), do: {:error, :nope}
      end
      """

      path = compile_app(dir, :demo_no_start, "1.0.0", [src], mod: {DemoNoStart, []})

      assert {:error, {:start_failed, :demo_no_start, _}} = activate(peer, :demo_no_start, path)
      gone!(peer, :demo_no_start, path, [DemoNoStart])
    end

    test "a consolidated protocol impl installs with a warning", %{peer: peer, tmp_dir: dir} do
      src =
        "defmodule DemoProto do\n defstruct [:a]\nend\ndefimpl Inspect, for: DemoProto do\n def inspect(_, _), do: \"demo\"\nend"

      path = compile_app(dir, :demo_proto, "1.0.0", [src], [])
      {:ok, warnings} = activate(peer, :demo_proto, path)
      # The peer runs this VM's consolidated protocols, as a release does.
      assert rpc(peer, Protocol, :consolidated?, [Inspect])

      assert warnings == [
               "Inspect impl for DemoProto is not dispatched: protocols are consolidated in this release"
             ]
    end

    test "an impl of an unconsolidated protocol gives no warning", %{peer: peer, tmp_dir: dir} do
      src = """
      defprotocol DemoOwnProto do
        def go(x)
      end

      defimpl DemoOwnProto, for: Atom do
        def go(_), do: :went
      end
      """

      path = compile_app(dir, :demo_own_proto, "1.0.0", [src], [])
      assert {:ok, []} = activate(peer, :demo_own_proto, path)
      assert rpc(peer, DemoOwnProto, :go, [:x]) == :went
    end
  end

  describe "conflicts/3" do
    test "a loaded module, a module on the code path, a present app", %{
      peer: peer,
      tmp_dir: dir
    } do
      path =
        compile_app(
          dir,
          :clash,
          "1.0.0",
          ["defmodule Logger.Clash do\n def x, do: 1\nend", "defmodule Logger do\nend"],
          []
        )

      assert {:error, {:module_loaded, Logger, _}} =
               call(peer, :conflicts, [:clash, "1.0.0", Path.join(path, "ebin")])

      # On the code path but not loaded.
      inets_ebin = :httpc |> :code.which() |> Path.dirname()
      true = rpc(peer, :code, :add_pathz, [String.to_charlist(inets_ebin)])
      refute loaded?(peer, :httpc)
      p3 = compile_app(dir, :clash_httpc, "1.0.0", ["defmodule :httpc do\nend"], [])

      assert {:error, {:module_conflict, :httpc, file}} =
               call(peer, :conflicts, [:clash_httpc, "1.0.0", Path.join(p3, "ebin")])

      assert file == Path.join(inets_ebin, "httpc.beam")

      p2 = compile_app(dir, :logger, "9.9.9", ["defmodule NotLogger do\nend"], [])
      vsn = to_string(rpc(peer, Application, :spec, [:logger, :vsn]))

      assert {:error, {:already_present, :logger, ^vsn}} =
               call(peer, :conflicts, [:logger, "9.9.9", Path.join(p2, "ebin")])

      # Nothing was loaded or added by the checks.
      refute loaded?(peer, Logger.Clash)
      refute code_path?(peer, path)
    end

    test "a fresh app has no conflicts", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_fresh, "1.0.0", ["defmodule DemoFresh do\nend"], [])
      assert :ok = call(peer, :conflicts, [:demo_fresh, "1.0.0", Path.join(path, "ebin")])
    end

    test "an unreadable .app is an error", %{peer: peer, tmp_dir: dir} do
      assert {:error, {:fetch, :demo_none, _}} =
               call(peer, :conflicts, [:demo_none, "1.0.0", Path.join(dir, "ebin")])
    end
  end

  describe "deactivate/3" do
    test "soft purge refuses a module in use unless forced, and the refusal changes nothing", %{
      peer: peer,
      tmp_dir: dir
    } do
      src = "defmodule DemoBusy do\n def loop, do: receive(do: (:stop -> :ok))\nend"
      path = compile_app(dir, :demo_busy, "1.0.0", [src], [])
      {:ok, _} = activate(peer, :demo_busy, path, start: false)
      pid = rpc(peer, :erlang, :spawn, [DemoBusy, :loop, []])

      assert {:error, {:in_use, DemoBusy, [^pid]}} =
               call(peer, :deactivate, [:demo_busy, path, false])

      assert loaded?(peer, DemoBusy)
      assert app_loaded?(peer, :demo_busy)
      assert code_path?(peer, path)
      assert rpc(peer, Process, :alive?, [pid])

      assert :ok = call(peer, :deactivate, [:demo_busy, path, true])
      gone!(peer, :demo_busy, path, [DemoBusy])
      refute rpc(peer, Process, :alive?, [pid])
    end

    test "code deeper than the inspected stack is found by soft_purge; force still works", %{
      peer: peer,
      tmp_dir: dir
    } do
      src = "defmodule DemoDeep do\n def run(f) do\n f.()\n :ok\n end\nend"
      path = compile_app(dir, :demo_deep, "1.0.0", [src], [])
      {:ok, _} = activate(peer, :demo_deep, path)

      {pid, _} =
        rpc(peer, Code, :eval_string, [
          "spawn(fn -> DemoDeep.run(fn -> receive do: (:stop -> :ok) end) end)"
        ])

      # With a backtrace depth of 1 only the receive frame is visible, so
      # DemoDeep.run/1 sits below the inspected stack.
      Process.sleep(100)
      _ = rpc(peer, :erlang, :system_flag, [:backtrace_depth, 1])
      {:current_stacktrace, frames} = rpc(peer, Process, :info, [pid, :current_stacktrace])
      refute Enum.any?(frames, &(elem(&1, 0) == DemoDeep))

      assert {:error, {:in_use, DemoDeep, [^pid]}} =
               call(peer, :deactivate, [:demo_deep, path, false])

      # This refusal comes after the app was stopped and its module deleted.
      refute started?(peer, :demo_deep)
      assert rpc(peer, Process, :alive?, [pid])

      assert :ok = call(peer, :deactivate, [:demo_deep, path, true])
      gone!(peer, :demo_deep, path, [DemoDeep])
      refute rpc(peer, Process, :alive?, [pid])
    end

    test "acts only on what activate loaded, never on what the .app now lists", %{
      peer: peer,
      tmp_dir: dir
    } do
      path = compile_app(dir, :demo_safe, "1.0.0", ["defmodule DemoSafe do\nend"], [])
      {:ok, _} = activate(peer, :demo_safe, path)

      # /data is not trusted at uninstall: a rewritten .app names firmware.
      app_file = Path.join([path, "ebin", "demo_safe.app"])
      props = [vsn: ~c"1.0.0", modules: [DemoSafe, Logger, :application_controller]]
      File.write!(app_file, :io_lib.format(~c"~p.~n", [{:application, :demo_safe, props}]))

      {:file, logger} = rpc(peer, :code, :is_loaded, [Logger])
      assert :ok = call(peer, :deactivate, [:demo_safe, path, true])
      gone!(peer, :demo_safe, path, [DemoSafe])
      assert rpc(peer, :code, :is_loaded, [Logger]) == {:file, logger}
      assert started?(peer, :logger)
    end

    test "an app this module did not activate is left alone", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :logger, "9.9.9", ["defmodule NotLogger do\nend"], [])
      {:file, logger} = rpc(peer, :code, :is_loaded, [Logger])

      assert :ok = call(peer, :deactivate, [:logger, path, true])
      assert started?(peer, :logger)
      assert rpc(peer, :code, :is_loaded, [Logger]) == {:file, logger}
    end

    test "another path of an active app is left alone", %{peer: peer, tmp_dir: dir} do
      path = compile_app(dir, :demo_other, "1.0.0", ["defmodule DemoOther do\nend"], [])
      {:ok, _} = activate(peer, :demo_other, path)

      assert :ok = call(peer, :deactivate, [:demo_other, Path.join(dir, "elsewhere"), true])
      assert started?(peer, :demo_other)
      assert loaded?(peer, DemoOther)
      assert code_path?(peer, path)
    end
  end

  describe "apps started on the way" do
    test "rollback stops the dependencies this activation started", %{
      peer: peer,
      tmp_dir: dir
    } do
      refute started?(peer, :crypto)
      path = compile_app(dir, :demo_dep, "1.0.0", ["defmodule DemoDep do\nend"], deps: [:crypto])
      assert {:ok, []} = activate(peer, :demo_dep, path)
      assert started?(peer, :crypto)

      assert :ok = call(peer, :rollback, [[{:demo_dep, path}]])
      gone!(peer, :demo_dep, path, [DemoDep])
      refute started?(peer, :crypto)
    end

    test "rollback leaves dependencies that were already running", %{peer: peer, tmp_dir: dir} do
      {:ok, _} = rpc(peer, :application, :ensure_all_started, [:crypto])

      path =
        compile_app(dir, :demo_dep2, "1.0.0", ["defmodule DemoDep2 do\nend"], deps: [:crypto])

      assert {:ok, []} = activate(peer, :demo_dep2, path)

      assert :ok = call(peer, :rollback, [[{:demo_dep2, path}]])
      gone!(peer, :demo_dep2, path, [DemoDep2])
      assert started?(peer, :crypto)
      assert started?(peer, :logger)
    end

    test "a start failure leaves no dependency the failed start brought up", %{
      peer: peer,
      tmp_dir: dir
    } do
      # ensure_all_started starts :crypto, then demo_up, then fails on
      # demo_down: OTP (27 and later) stops what it started itself, and the
      # loader's own teardown covers the rest.
      refute started?(peer, :crypto)

      up =
        compile_app(dir, :demo_up, "1.0.0", ["defmodule DemoUp do\nend"], deps: [:crypto])

      {:ok, []} = activate(peer, :demo_up, up, start: false)

      src = """
      defmodule DemoDown do
        use Application
        def start(_type, _args), do: {:error, :nope}
      end
      """

      down =
        compile_app(dir, :demo_down, "1.0.0", [src], mod: {DemoDown, []}, deps: [:demo_up])

      assert {:error, {:start_failed, :demo_down, _}} = activate(peer, :demo_down, down)
      gone!(peer, :demo_down, down, [DemoDown])
      refute started?(peer, :demo_up)
      refute started?(peer, :crypto)
      # Loaded by its own activation, which this failure leaves alone.
      assert app_loaded?(peer, :demo_up)
    end

    test "an uninstall leaves the dependencies it started running", %{peer: peer, tmp_dir: dir} do
      path =
        compile_app(dir, :demo_dep3, "1.0.0", ["defmodule DemoDep3 do\nend"], deps: [:crypto])

      assert {:ok, []} = activate(peer, :demo_dep3, path)
      assert :ok = call(peer, :deactivate, [:demo_dep3, path, true])
      gone!(peer, :demo_dep3, path, [DemoDep3])
      assert started?(peer, :crypto)
    end
  end

  describe "rollback/1" do
    test "undoes each activation in reverse and leaves the rest", %{peer: peer, tmp_dir: dir} do
      keep = compile_app(dir, :demo_keep, "1.0.0", ["defmodule DemoKeep do\nend"], [])
      a = compile_app(dir, :demo_a, "1.0.0", ["defmodule DemoA do\nend"], [])
      b = compile_app(dir, :demo_b, "1.0.0", ["defmodule DemoB do\nend"], deps: [:demo_a])
      {:ok, _} = activate(peer, :demo_keep, keep)
      {:ok, _} = activate(peer, :demo_a, a)
      {:ok, _} = activate(peer, :demo_b, b)
      path_before = rpc(peer, :code, :get_path, []) -- Enum.map([a, b], &ebin_chars/1)

      assert :ok = call(peer, :rollback, [[{:demo_a, a}, {:demo_b, b}]])
      gone!(peer, :demo_a, a, [DemoA])
      gone!(peer, :demo_b, b, [DemoB])
      assert rpc(peer, :code, :get_path, []) == path_before
      assert started?(peer, :demo_keep)
      assert loaded?(peer, DemoKeep)
    end

    test "an empty list is a no-op", %{peer: peer} do
      assert :ok = call(peer, :rollback, [[]])
    end
  end

  defp ebin_chars(path), do: String.to_charlist(Path.join(path, "ebin"))
end
