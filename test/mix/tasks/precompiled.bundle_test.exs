# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.BundleTest do
  # Installs load into this VM, so every test removes what it loaded on exit.
  use ExUnit.Case, async: false
  import ElixirPrecompiled.DeviceFixture
  alias ElixirPrecompiled.Device.Source
  alias ElixirPrecompiled.Fixture
  alias ElixirPrecompiled.Trust
  alias Mix.Tasks.Precompiled.Bundle

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!(ElixirPrecompiled.TestServer)
    Mix.shell(Mix.Shell.Process)
    store = [dir: Path.join(dir, "store"), quiet: true]

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Fixture.corrupt_port(nil)

      for %{loaded?: true, app: app} <- Precompiled.list(store),
          do: Precompiled.uninstall(app, store ++ [force: true, cascade: true])
    end)

    %{store: store}
  end

  defp host_env() do
    env(
      system: nil,
      otp: System.otp_release(),
      elixir: System.version(),
      cpu: to_string(:erlang.system_info(:system_architecture))
    )
  end

  defp pure_args(f, out) do
    [
      "--out",
      out,
      "--pure",
      "--otp",
      System.otp_release(),
      "--elixir",
      System.version(),
      "--source",
      Fixture.base_url(),
      "--root",
      f.root_path
    ]
  end

  defp bundle_files(out), do: out |> Path.join("files") |> File.ls!() |> Enum.sort()

  defp shas(builds), do: builds |> Enum.flat_map(&(&1["ebin"] ++ &1["priv"])) |> shas_of()
  defp shas_of(entries), do: entries |> Enum.map(& &1["sha256"]) |> Enum.uniq() |> Enum.sort()

  defp info_lines() do
    receive_lines([])
  end

  defp receive_lines(acc) do
    receive do
      {:mix_shell, :info, [line]} -> receive_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp payload(envelope_bytes) do
    %{"payload" => p} = :json.decode(envelope_bytes)
    Base.url_decode64!(p, padding: false)
  end

  # What `mix portal.precompiled.sign_offline --bundle DIR --key K --root R`
  # checks and writes (PRECOMPILED_API.md, "Offline bundles"), with the
  # fixture's throwaway offline key: the bundle's root.json has the payload
  # of `--root`, its batch.json verifies under that root's batch role, every
  # held manifest hashes to the batch's entry, and only the held manifests
  # are signed.
  defp sign_offline!(out, f) do
    trusted = File.read!(f.root_path)
    assert payload(File.read!(Path.join(out, "root.json"))) == payload(trusted)
    root = :json.decode(payload(trusted))
    {keys, t} = Trust.root_keys(root, "batch")

    assert {:ok, batch_bytes} =
             Trust.verify_envelope(File.read!(Path.join(out, "batch.json")), keys, t)

    batch = :json.decode(batch_bytes)
    refute File.exists?(Path.join(out, "offline.json"))

    held =
      for {name, sha} <- batch["manifests_v2"],
          {:ok, bytes} <- [File.read(Path.join([out, "v2", "manifests", name <> ".json"]))],
          into: %{} do
        assert Fixture.sha(bytes) == sha, "#{name} does not match the batch"
        {name, sha}
      end

    assert held != %{}
    doc = Fixture.offline_document(f, held, sequence: System.os_time(:second))
    File.write!(Path.join(out, "offline.json"), doc)
    held
  end

  test "a bundle holds exactly what the plan needs and installs offline", %{
    tmp_dir: dir,
    store: store
  } do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_a, "1.0.0")
    other = publish_app(f, dir, :bun_other, "1.0.0")

    Fixture.publish(f, %{
      "bun_a" => manifest(%{"1.0.0" => [a]}),
      "bun_other" => manifest(%{"1.0.0" => [other]})
    })

    out = Path.join(dir, "bundle")
    Bundle.run(["bun_a" | pure_args(f, out)])

    assert File.read!(Path.join(out, "batch.json")) ==
             :json.encode(Fixture.get(:batch)) |> IO.iodata_to_binary()

    assert File.read!(Path.join(out, "root.json")) ==
             :json.encode(Fixture.get(:root)) |> IO.iodata_to_binary()

    assert File.read!(Path.join(out, "v2/manifests/bun_a.json")) ==
             Fixture.get(:manifests_v2)["bun_a"]

    refute File.exists?(Path.join(out, "v2/manifests/bun_other.json"))
    assert bundle_files(out) == shas([a])
    refute File.exists?(Path.join(out, "offline.json"))

    lines = info_lines()

    assert Enum.any?(
             lines,
             &(&1 =~ ~r/\Abundle: 1 packages, #{length(shas([a]))} files, \d+ KB in /)
           )

    assert Enum.any?(
             lines,
             &(&1 =~
                 "sign it: mix portal.precompiled.sign_offline --bundle #{out} --key <offline key>")
           )

    %{"payload" => p} = Fixture.get(:batch)
    issued = :json.decode(Base.url_decode64!(p, padding: false))["issued"]

    assert Enum.any?(
             lines,
             &(&1 =~ "issued #{issued}: sign within 24 h of issued")
           )

    Fixture.clear_requests()

    assert {:ok, [%{app: :bun_a}]} =
             Precompiled.install(
               :bun_a,
               store ++ [source: "file://" <> out, root: f.root_path, env: host_env()]
             )

    assert Fixture.requests() == []
  end

  test "a bundle signed offline is accepted by the offline path and installs with no network",
       %{tmp_dir: dir, store: store} do
    f = Fixture.new(dir, offline_key: true)
    dep = publish_app(f, dir, :bun_dep, "1.0.0")
    top = publish_app(f, dir, :bun_top, "2.0.0", deps: [bun_dep: dep])

    Fixture.publish(f, %{
      "bun_top" => manifest(%{"2.0.0" => [top]}),
      "bun_dep" => manifest(%{"1.0.0" => [dep]})
    })

    out = Path.join(dir, "bundle")
    Bundle.run(["bun_top" | pure_args(f, out)])

    # The closure: both packages' manifests and every file of both builds.
    assert bundle_files(out) == shas([top, dep])
    held = sign_offline!(out, f)
    assert Map.keys(held) |> Enum.sort() == ["bun_dep", "bun_top"]

    {:ok, config} =
      Source.config(
        source: "file://" <> out,
        root: f.root_path,
        dir: Path.join(dir, "verify"),
        home: Path.join(dir, "verify-trust")
      )

    {:ok, root} = Trust.load_root(config, offline: true)
    body = File.read!(Path.join(out, "offline.json"))
    assert {:ok, %{offline: true, manifests_v2: ^held}} = Trust.verify_offline(config, root, body)

    Fixture.clear_requests()

    assert {:ok, installed} =
             Precompiled.install(
               :bun_top,
               store ++ [source: "file://" <> out, root: f.root_path, env: host_env()]
             )

    assert Enum.map(installed, & &1.app) == [:bun_dep, :bun_top]
    # Vouched for by the offline document, not the batch.
    assert Enum.all?(installed, &(&1.batch_sequence == nil))
    assert Fixture.requests() == []
  end

  test "the served root is bundled when it chains from --root", %{tmp_dir: dir, store: store} do
    f = Fixture.new(dir)
    k2 = Fixture.rotate_root(f, version: 2)
    a = publish_app(f, dir, :bun_rot, "1.0.0")
    Fixture.publish(f, %{"bun_rot" => manifest(%{"1.0.0" => [a]})}, signers: [k2])

    out = Path.join(dir, "bundle")
    Bundle.run(["bun_rot" | pure_args(f, out)])

    bundled = File.read!(Path.join(out, "root.json"))
    assert bundled == :json.encode(Fixture.get(:root)) |> IO.iodata_to_binary()
    assert :json.decode(payload(bundled))["version"] == 2

    assert {:ok, [%{app: :bun_rot}]} =
             Precompiled.install(
               :bun_rot,
               store ++ [source: "file://" <> out, root: f.root_path, env: host_env()]
             )
  end

  test "a device report decides the present apps, and the env flags are ignored", %{
    tmp_dir: dir
  } do
    f = Fixture.new(dir)
    dep = publish_app(f, dir, :bun_rdep, "1.0.0")
    top = publish_app(f, dir, :bun_rtop, "1.0.0", deps: [bun_rdep: dep])

    Fixture.publish(f, %{
      "bun_rtop" => manifest(%{"1.0.0" => [top]}),
      "bun_rdep" => manifest(%{"1.0.0" => [dep]})
    })

    report = Path.join(dir, "report.json")

    File.write!(
      report,
      :json.encode(%{
        "format" => 1,
        "env" => %{
          "system" => :null,
          "platform" => :null,
          "arch" => :null,
          "otp" => System.otp_release(),
          "elixir" => System.version(),
          "cpu" => "aarch64-unknown-linux-gnu",
          "present" => %{
            "kernel" => "10.4",
            "stdlib" => "7.0",
            "elixir" => System.version(),
            "logger" => System.version(),
            "crypto" => "5.6",
            "bun_rdep" => "1.0.0"
          }
        },
        "plan" => %{"installs" => [], "present" => [], "warnings" => [], "bytes" => 0}
      })
    )

    out = Path.join(dir, "bundle")

    Bundle.run([
      "bun_rtop",
      "--out",
      out,
      "--device-report",
      report,
      "--system",
      "nerves_system_none@0.0.1",
      "--otp",
      "1",
      "--elixir",
      "0.0.1",
      "--source",
      Fixture.base_url(),
      "--root",
      f.root_path
    ])

    # bun_rdep 1.0.0 is on the device: only bun_rtop is bundled.
    assert bundle_files(out) == shas([top])
    refute File.exists?(Path.join(out, "v2/manifests/bun_rdep.json"))
    assert File.regular?(Path.join(out, "v2/manifests/bun_rtop.json"))
  end

  test "an app the report has at another version is bundled", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_v, "1.0.0")
    Fixture.publish(f, %{"bun_v" => manifest(%{"1.0.0" => [a]})})
    report = Path.join(dir, "report.json")

    File.write!(
      report,
      :json.encode(%{
        "format" => 1,
        "env" => %{
          "system" => %{"name" => "nerves_system_rpi4", "version" => "2.2.1"},
          "otp" => System.otp_release(),
          "elixir" => System.version(),
          "cpu" => "aarch64-unknown-linux-gnu",
          "present" => %{"kernel" => "10.4", "stdlib" => "7.0", "elixir" => System.version()}
        }
      })
    )

    out = Path.join(dir, "bundle")

    Bundle.run([
      "bun_v@~> 1.0",
      "--out",
      out,
      "--device-report",
      report,
      "--source",
      Fixture.base_url(),
      "--root",
      f.root_path
    ])

    assert bundle_files(out) == shas([a])
  end

  test "bytes that do not match the signed hashes are never written", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_bad, "1.0.0")
    Fixture.publish(f, %{"bun_bad" => manifest(%{"1.0.0" => [a]})})
    out = Path.join(dir, "bundle")
    Fixture.corrupt_port(ElixirPrecompiled.TestServer.port())

    assert_raise Mix.Error, fn -> Bundle.run(["bun_bad" | pure_args(f, out)]) end
    refute File.exists?(out)
    assert Path.wildcard(Path.join(dir, "bundle*")) == []
  end

  test "a batch that does not verify under --root is refused", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_sig, "1.0.0")
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    stranger = %{keyid: Fixture.sha(pub), public: pub, private: priv}
    Fixture.publish(f, %{"bun_sig" => manifest(%{"1.0.0" => [a]})}, signers: [stranger])
    out = Path.join(dir, "bundle")

    assert_raise Mix.Error, ~r/batch/, fn -> Bundle.run(["bun_sig" | pure_args(f, out)]) end
    refute File.exists?(out)
  end

  test "a package with no build for the device is refused, naming why", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_none, "1.0.0")
    Fixture.publish(f, %{"bun_none" => manifest(%{"1.0.0" => [a]})})
    out = Path.join(dir, "bundle")
    args = pure_args(f, out) |> List.replace_at(4, "26")

    assert_raise Mix.Error, ~r/bun_none/, fn -> Bundle.run(["bun_none" | args]) end
    refute File.exists?(out)
  end

  test "the options are checked before anything is fetched", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    out = Path.join(dir, "bundle")
    Fixture.clear_requests()
    base = ["--otp", "29", "--elixir", "1.20.3", "--source", Fixture.base_url()]

    for {args, message} <- [
          {["bun_x", "--pure" | base], ~r/--out/},
          {["bun_x", "--out", out | base], ~r/--system NAME@VSN or --pure/},
          {["bun_x", "--out", out, "--pure", "--system", "nerves_system_rpi4@2.2.1" | base],
           ~r/--system NAME@VSN or --pure/},
          {["bun_x", "--out", out, "--system", "nerves_system_rpi4" | base], ~r/NAME@VSN/},
          {["--out", out, "--pure" | base], ~r/package/},
          {["Bad-Name", "--out", out, "--pure" | base], ~r/Bad-Name/},
          {["bun_x@not a version", "--out", out, "--pure" | base], ~r/bun_x@not a version/},
          {["bun_x", "--out", out, "--pure", "--bogus" | base], ~r/--bogus/},
          {["bun_x", "--out", out, "--pure", "--otp", "29"], ~r/--elixir/},
          {["bun_x", "--out", out, "--device-report", Path.join(dir, "missing.json")],
           ~r/missing\.json/}
        ] do
      assert_raise Mix.Error, message, fn -> Bundle.run(args) end
    end

    assert Fixture.requests() == []
    _ = f
  end

  test "an --out that holds anything is refused", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_full, "1.0.0")
    Fixture.publish(f, %{"bun_full" => manifest(%{"1.0.0" => [a]})})
    out = Path.join(dir, "bundle")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "offline.json"), "{}")

    assert_raise Mix.Error, ~r/not empty/, fn -> Bundle.run(["bun_full" | pure_args(f, out)]) end
    assert File.ls!(out) == ["offline.json"]

    # An empty one is used.
    File.rm!(Path.join(out, "offline.json"))
    Bundle.run(["bun_full" | pure_args(f, out)])
    assert bundle_files(out) == shas([a])
  end

  test "a symlink at --out is refused, even to an empty directory", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    a = publish_app(f, dir, :bun_link, "1.0.0")
    Fixture.publish(f, %{"bun_link" => manifest(%{"1.0.0" => [a]})})
    target = Path.join(dir, "elsewhere")
    File.mkdir_p!(target)
    out = Path.join(dir, "bundle")
    File.ln_s!(target, out)
    Fixture.clear_requests()

    assert_raise Mix.Error, ~r/is a symlink/, fn ->
      Bundle.run(["bun_link" | pure_args(f, out)])
    end

    assert File.ls!(target) == []
    assert Fixture.requests() == []

    # A dangling one too.
    File.rm!(out)
    File.ln_s!(Path.join(dir, "nowhere"), out)

    assert_raise Mix.Error, ~r/is a symlink/, fn ->
      Bundle.run(["bun_link" | pure_args(f, out)])
    end

    refute File.exists?(Path.join(dir, "nowhere"))
  end

  test "a temp or staging name that already exists is never reused", %{tmp_dir: dir} do
    target = Path.join(dir, "victim")
    File.mkdir_p!(target)
    # Another user's link and directory at the first two names.
    File.ln_s!(target, Path.join(dir, "precompiled-bundle-aaaa"))
    File.mkdir_p!(Path.join(dir, "precompiled-bundle-bbbb"))
    names = :counters.new(1, [])

    random = fn ->
      :counters.add(names, 1, 1)
      Enum.at(["aaaa", "bbbb", "cccc"], :counters.get(names, 1) - 1)
    end

    made = Bundle.exclusive_dir!(dir, "precompiled-bundle-", random)
    assert made == Path.join(dir, "precompiled-bundle-cccc")
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(made)
    assert Bitwise.band(File.stat!(made).mode, 0o777) == 0o700
    assert File.ls!(target) == []
    assert File.ls!(Path.join(dir, "precompiled-bundle-bbbb")) == []

    # Every name taken: refused, never reused.
    taken = fn -> "aaaa" end

    assert_raise Mix.Error, ~r/no free directory name/, fn ->
      Bundle.exclusive_dir!(dir, "precompiled-bundle-", taken)
    end

    # The real names are random and differ each call.
    one = Bundle.exclusive_dir!(dir, "x-")
    two = Bundle.exclusive_dir!(dir, "x-")
    assert one != two
    assert String.length(Path.basename(one)) == String.length("x-") + 24
  end

  test "a device report of an unknown format is refused", %{tmp_dir: dir} do
    f = Fixture.new(dir)
    report = Path.join(dir, "report.json")

    env = %{
      "otp" => "29",
      "elixir" => "1.20.3",
      "cpu" => "aarch64-unknown-linux-gnu",
      "present" => %{}
    }

    for format <- [2, nil, "1"] do
      body = if format, do: %{"format" => format, "env" => env}, else: %{"env" => env}
      File.write!(report, :json.encode(body))
      out = Path.join(dir, "bundle")

      assert_raise Mix.Error, ~r/unknown report format/, fn ->
        Bundle.run([
          "bun_fmt",
          "--out",
          out,
          "--device-report",
          report,
          "--source",
          Fixture.base_url(),
          "--root",
          f.root_path
        ])
      end
    end
  end

  test "no private key ever lands in a bundle", %{tmp_dir: dir} do
    f = Fixture.new(dir, offline_key: true)
    a = publish_app(f, dir, :bun_keys, "1.0.0")
    Fixture.publish(f, %{"bun_keys" => manifest(%{"1.0.0" => [a]})})
    out = Path.join(dir, "bundle")
    Bundle.run(["bun_keys" | pure_args(f, out)])

    secrets = [f.key.private, f.offline_key.private]

    encodings =
      for s <- secrets,
          e <- [s, Fixture.b64(s), Base.encode64(s), Base.encode16(s, case: :lower)],
          do: e

    for file <- Path.wildcard(Path.join(out, "**"), match_dot: true), File.regular?(file) do
      bytes = File.read!(file)
      for e <- encodings, do: refute(String.contains?(bytes, e), "#{file} holds a private key")
    end
  end
end
