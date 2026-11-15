# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.DeviceReportTest do
  # Installs into this VM and POSTs to the local test server: an install
  # on a device, then Precompiled.report/1 of it.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Precompiled.DeviceFixture
  alias Precompiled.Fixture
  alias Precompiled.PortalPayload

  @moduletag :tmp_dir
  @id "5b2c6f0e-8d1a-4c39-9a57-2f0f3f0f9b11"
  @sum String.duplicate("ab", 32)

  setup %{tmp_dir: dir} do
    Application.put_env(:precompiled, :test_seams, true)
    start_supervised!(Precompiled.TestServer)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    fixture = Fixture.new(dir)
    Fixture.clear_reports()

    device =
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
      env: device,
      quiet: true
    ]

    report_opts = [source: Fixture.base_url(), dir: opts[:dir]]
    on_exit(fn -> unload_all(opts) end)
    %{fixture: fixture, opts: opts, report_opts: report_opts}
  end

  defp unload_all(opts) do
    store = Keyword.take(opts, [:dir, :quiet])

    with items when is_list(items) <- Precompiled.list(store) do
      for %{loaded?: true, app: app} <- items,
          do: Precompiled.uninstall(app, store ++ [force: true, cascade: true])
    end
  end

  defp output(acc \\ []) do
    receive do
      {:mix_shell, _level, [line]} -> output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  # One app the device can install, and one built on another OTP that it
  # cannot.
  defp publish(f, dir) do
    good = put_in(publish_app(f, dir, :demo_rep, "1.0.0"), ["build", "package_checksum"], @sum)
    other = build(otp: "20", elixir: System.version())

    Fixture.publish(f, %{
      "demo_rep" => manifest(%{"1.0.0" => [good]}),
      "demo_old" => manifest(%{"0.9.0" => [other], "1.0.0" => [other]})
    })
  end

  defp sent_body() do
    assert [%{body: body, content_type: "application/json"}] = Fixture.report_posts()
    decoded = :json.decode(body)
    assert {:ok, _} = PortalPayload.validate(decoded)
    {body, decoded}
  end

  test "an install's hits and a miss, sent with yes: true, validate as the portal checks them",
       %{fixture: f, opts: opts, report_opts: ropts, tmp_dir: dir} do
    publish(f, dir)
    assert {:ok, [%{app: :demo_rep}]} = Precompiled.install(:demo_rep, opts)

    assert {:sent, @id, false} = Precompiled.report([yes: true] ++ ropts)
    assert output() =~ "report #{@id}"
    {body, decoded} = sent_body()

    assert %{
             "format" => 1,
             "target" => "custom",
             "os" => %{"family" => _, "arch" => _},
             "lines" => [%{"name" => "demo_rep", "version" => "1.0.0", "status" => "hit"}],
             "lock" => [%{"name" => "demo_rep", "version" => "1.0.0", "checksum" => @sum}]
           } = decoded

    refute Map.has_key?(decoded, "system")
    refute body =~ dir

    # The next install replaces it: a miss, with its code and version.
    Fixture.clear_reports()

    assert {:error, {:no_build, "demo_old", "built on OTP 20, " <> _}} =
             Precompiled.install(:demo_old, opts)

    assert {:sent, _, false} = Precompiled.report([yes: true, contact: "@me"] ++ ropts)
    {_body, decoded} = sent_body()

    assert %{
             "contact" => "@me",
             "lines" => [
               %{
                 "name" => "demo_old",
                 "version" => "1.0.0",
                 "status" => "miss",
                 "reason_code" => "toolchain_otp",
                 "reason_args" => ["20", _]
               }
             ],
             "lock" => []
           } = decoded
  end

  test "the question: y sends, anything else does not",
       %{fixture: f, opts: opts, report_opts: ropts, tmp_dir: dir} do
    publish(f, dir)
    {:ok, _} = Precompiled.install(:demo_rep, opts)
    ask = ropts ++ [interactive?: true]

    assert {:sent, _, _} =
             Precompiled.report(
               ask ++
                 [
                   gets: fn prompt ->
                     send(self(), {:prompt, prompt})
                     "y\n"
                   end
                 ]
             )

    host = URI.parse(Fixture.base_url()).host
    assert_received {:prompt, prompt}
    assert prompt == "Send this report to #{host}? [y/N] "
    assert output() =~ "1 hit, 0 miss, 0 fail"

    for answer <- ["\n", "n\n", "N\n", :eof] do
      assert :cancelled = Precompiled.report(ask ++ [gets: fn _ -> answer end])
    end

    assert length(Fixture.report_posts()) == 1
  end

  test "no terminal: the summary, then cancelled; yes: true still sends",
       %{fixture: f, opts: opts, report_opts: ropts, tmp_dir: dir} do
    publish(f, dir)
    {:ok, _} = Precompiled.install(:demo_rep, opts)
    asked = fn _ -> flunk("asked without a terminal") end

    out =
      capture_io(fn ->
        assert :cancelled = Precompiled.report(ropts ++ [interactive?: false, gets: asked])
      end)

    assert out =~ "no terminal to ask on; pass yes: true to send"
    assert output() =~ "last Precompiled.install/2 on this device"
    assert Fixture.report_posts() == []

    assert {:sent, _, false} =
             Precompiled.report(ropts ++ [interactive?: false, gets: asked, yes: true])
  end

  test "dump prints the body yes: true sends, and sends nothing",
       %{fixture: f, opts: opts, report_opts: ropts, tmp_dir: dir} do
    publish(f, dir)
    {:ok, _} = Precompiled.install(:demo_rep, opts)
    assert :dumped = Precompiled.report(ropts ++ [dump: true])
    dumped = output() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "{"))
    assert Fixture.report_posts() == []

    Precompiled.report(ropts ++ [yes: true])
    assert [%{body: ^dumped}] = Fixture.report_posts()
  end

  test "a dry run records nothing; no install is no report",
       %{fixture: f, opts: opts, report_opts: ropts, tmp_dir: dir} do
    publish(f, dir)
    {:ok, _} = Precompiled.install(:demo_rep, opts ++ [dry_run: true])
    assert :no_report = Precompiled.report(ropts ++ [yes: true])
    assert output() =~ "run Precompiled.install/2 first"
    assert Fixture.report_posts() == []
  end

  test "the source comes from config: a per-call network source only as a seam, never file://",
       %{opts: opts, report_opts: ropts, tmp_dir: dir} do
    Application.put_env(:precompiled, :test_seams, false)

    try do
      assert {:error, {:source_not_allowed, _}} = Precompiled.report(ropts ++ [yes: true])
      assert {:error, {:bad_option, :gets}} = Precompiled.report(gets: fn _ -> "y" end)
    after
      Application.put_env(:precompiled, :test_seams, true)
    end

    capture_io(fn ->
      assert {:error, :bundle_source} =
               Precompiled.report(source: "file://" <> dir, dir: opts[:dir], yes: true)
    end)

    assert Fixture.report_posts() == []
  end

  test "the firmware's kill switch turns reporting off too", %{report_opts: ropts} do
    Application.put_env(:precompiled, :device, enabled: false)
    on_exit(fn -> Application.delete_env(:precompiled, :device) end)
    capture_io(fn -> assert :off = Precompiled.report(ropts ++ [yes: true]) end)
  end

  test "bad options and a refused answer are outcomes, never a raise",
       %{fixture: f, opts: opts, report_opts: ropts, tmp_dir: dir} do
    assert {:error, {:bad_option, :nope}} = Precompiled.report(nope: 1)
    assert {:error, {:bad_option, :yes}} = Precompiled.report(yes: "y")
    assert {:error, {:bad_option, _}} = Precompiled.report(:nope)

    publish(f, dir)
    {:ok, _} = Precompiled.install(:demo_rep, opts)
    Fixture.set_report_response({429, ~s({"error":"Too many requests."})})
    assert {:error, why} = Precompiled.report(ropts ++ [yes: true])
    assert why =~ "429"
  end
end
