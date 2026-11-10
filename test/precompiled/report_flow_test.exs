# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ReportFlowTest do
  use ExUnit.Case, async: false
  alias Precompiled.Fixture, as: F
  alias Precompiled.Report
  @moduletag :tmp_dir

  @jason {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", String.duplicate("a", 64)}
  @id "5b2c6f0e-8d1a-4c39-9a57-2f0f3f0f9b11"

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    F.clear_reports()

    lib = Path.join(dir, "_build/dev/lib")
    File.mkdir_p!(Path.join(lib, ".precompiled"))

    report = %{
      "format" => 1,
      "built_at" => "2026-11-10T12:00:00Z",
      "context" => %{
        "elixir" => "1.20.3",
        "otp" => "29",
        "target" => "host",
        "system" => nil,
        "system_version" => nil
      },
      "lines" => [
        %{
          "name" => "jason",
          "version" => "1.4.5",
          "status" => "miss",
          "detail" => "not built for 1.4.5",
          "reason_code" => "not_built_version",
          "reason_args" => ["1.4.5"]
        }
      ]
    }

    File.write!(
      Path.join(lib, ".precompiled/report.json"),
      IO.iodata_to_binary(:json.encode(report))
    )

    where = %{
      build_lib: lib,
      lock: %{jason: @jason},
      config: %{source: F.base_url(), content_override: nil, connect_timeout_ms: 5_000},
      project_dir: dir,
      env: "dev",
      target: "host"
    }

    %{where: where, lib: lib}
  end

  defp output(acc \\ []) do
    receive do
      {:mix_shell, _level, [line]} -> output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "--yes sends and prints the id", %{where: where} do
    assert {:sent, @id, false} = Report.run(where, yes: true)
    assert output() =~ "report #{@id}"
    assert [%{content_type: "application/json"}] = F.report_posts()
  end

  test "a duplicate says already received and prints no id", %{where: where} do
    F.set_report_response({200, ~s({"duplicate":true})})
    assert {:sent, nil, true} = Report.run(where, yes: true)
    out = output()
    assert out =~ "already received (the id was printed when it was first sent)"
    refute out =~ "report not sent"
  end

  test "a duplicate answer must say so, and a new report must carry an id", %{where: where} do
    F.set_report_response({200, ~s({"id":"#{@id}"})})
    assert {:error, "unexpected answer"} = Report.run(where, yes: true)

    F.set_report_response({201, ~s({"duplicate":true})})
    assert {:error, "unexpected answer"} = Report.run(where, yes: true)
  end

  test "the question: y sends, anything else and end of input do not", %{where: where} do
    assert {:sent, _, _} =
             Report.run(where,
               gets: fn prompt ->
                 send(self(), {:prompt, prompt})
                 "y\n"
               end
             )

    assert_received {:prompt, "Send this report to 127.0.0.1? [y/N] "}
    assert length(F.report_posts()) == 1

    for answer <- ["\n", "n\n", "yes please\n", :eof, {:error, :interrupted}] do
      assert :cancelled = Report.run(where, gets: fn _ -> answer end)
    end

    assert length(F.report_posts()) == 1
  end

  test "non-interactive stdin counts as no", %{where: where} do
    assert :cancelled = Report.run(where, gets: fn _ -> :eof end)
    assert output() =~ "not sent"
    assert F.report_posts() == []
  end

  test "--dump prints exactly the body --yes would send, and sends nothing", %{where: where} do
    assert :dumped = Report.run(where, dump: :stdout)
    dumped = output() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "{"))
    assert is_binary(dumped)
    assert F.report_posts() == []

    Report.run(where, yes: true)
    assert [%{body: ^dumped}] = F.report_posts()
  end

  test "--dump FILE writes the body to the file, the same body --yes sends",
       %{where: where, tmp_dir: dir} do
    file = Path.join(dir, "report-dump.json")
    assert :dumped = Report.run(where, dump: file)
    written = File.read!(file)
    assert %{"format" => 1, "lines" => [_]} = :json.decode(written)
    assert F.report_posts() == []

    Report.run(where, yes: true)
    assert [%{body: ^written}] = F.report_posts()
  end

  test "the project path and host name in a contact are redacted in the dump and the POST",
       %{where: where, tmp_dir: dir} do
    where = %{where | project_dir: "/srv/acme-app"} |> Map.put(:host_name, "build-box-one")
    contact = "@me from /srv/acme-app/lib on build-box-one"
    expected = "@me from <redacted>/lib on <redacted>"

    file = Path.join(dir, "redacted.json")
    assert :dumped = Report.run(where, contact: contact, dump: file)
    assert %{"contact" => ^expected} = file |> File.read!() |> :json.decode()

    assert :dumped = Report.run(where, contact: contact, dump: :stdout)
    out = output()
    refute out =~ "acme-app"
    refute out =~ "build-box-one"

    assert {:sent, _, false} = Report.run(where, yes: true, contact: contact)
    assert [%{body: body}] = F.report_posts()
    assert %{"contact" => ^expected} = :json.decode(body)
    refute body =~ "acme-app"
    refute body =~ "build-box-one"
  end

  test "a contact over 100 characters sends nothing", %{where: where} do
    assert :invalid = Report.run(where, yes: true, contact: String.duplicate("a", 101))
    assert output() =~ "at most 100"
    assert F.report_posts() == []
    assert {:sent, _, _} = Report.run(where, yes: true, contact: String.duplicate("a", 100))
  end

  test "a contact with a control character sends nothing", %{where: where} do
    assert :invalid = Report.run(where, yes: true, contact: "me\nyou")
    assert F.report_posts() == []
  end

  test "no report, or one from an older client: one line, nothing sent",
       %{where: where, lib: lib} do
    File.write!(Path.join(lib, ".precompiled/report.json"), ~s({"format":1,"lines":[]}))
    assert :no_report = Report.run(where, yes: true)
    File.rm!(Path.join(lib, ".precompiled/report.json"))
    assert :no_report = Report.run(where, yes: true)
    assert output() =~ "run a build first"
    assert F.report_posts() == []
  end

  test "any error is one line, never a raise", %{where: where} do
    F.set_report_response({429, ~s({"error":"Too many requests."})})
    assert {:error, why} = Report.run(where, yes: true)
    assert why =~ "429"

    down = put_in(where, [:config, :source], "http://127.0.0.1:1/precompiled")
    assert {:error, _} = Report.run(down, yes: true)

    F.set_report_response({201, "not json"})
    assert {:error, "unexpected answer"} = Report.run(where, yes: true)

    F.set_report_response(
      {422, ~s({"error":"invalid report","details":["os: os.family must be unix or win32","x"]})}
    )

    assert {:error, "refused (422): os: os.family must be unix or win32"} =
             Report.run(where, yes: true)

    lines = output() |> String.split("\n") |> Enum.filter(&(&1 =~ "report not sent"))
    assert length(lines) == 4
  end

  test "the device API has no report call" do
    Code.ensure_loaded!(Precompiled)
    refute function_exported?(Precompiled, :report, 0)
    refute function_exported?(Precompiled, :report, 1)
  end

  test "Host.report/1 outside a Mix.install/2 runtime says so" do
    assert :no_install = Precompiled.Host.report(yes: true)
    assert output() =~ "Precompiled.Host.install/2 first"
    assert F.report_posts() == []
  end
end
