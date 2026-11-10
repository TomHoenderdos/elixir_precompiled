# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.ReportTest do
  use ExUnit.Case, async: false
  alias Precompiled.Fixture, as: F
  @moduletag :tmp_dir

  setup_all do
    start_supervised!(Precompiled.TestServer)
    :ok
  end

  setup do
    Mix.shell(Mix.Shell.Process)
    F.clear_reports()
    Application.put_all_env(precompiled: [source: F.base_url()])

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      for {k, _} <- Application.get_all_env(:precompiled),
          do: Application.delete_env(:precompiled, k)
    end)
  end

  defp in_project(dir, fun) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule ReportTestProject.MixProject do
      use Mix.Project
      def project, do: [app: :report_test_project, version: "0.1.0"]
    end
    """)

    File.write!(
      Path.join(dir, "mix.lock"),
      ~s(%{"jason": {:hex, :jason, "1.4.5", "i", [:mix], [], "hexpm", "#{String.duplicate("a", 64)}"}}\n)
    )

    saved = for var <- ~w(MIX_BUILD_ROOT MIX_BUILD_PATH), do: {var, System.get_env(var)}
    Enum.each(saved, fn {var, _} -> System.delete_env(var) end)

    try do
      Mix.Project.in_project(:report_test_project, dir, fn _ -> fun.() end)
    after
      for {var, value} <- saved, value != nil, do: System.put_env(var, value)
    end
  end

  defp write_report(dir) do
    lib = Path.join(dir, "_build/test/lib/.precompiled")
    File.mkdir_p!(lib)

    File.write!(
      Path.join(lib, "report.json"),
      ~s({"format":1,"built_at":"2026-11-10T12:00:00Z","context":{"elixir":"1.20.3","otp":"29","target":"host","system":null,"system_version":null},"lines":[{"name":"jason","version":"1.4.5","status":"miss","detail":"x","reason_code":"not_built_version","reason_args":["1.4.5"]}]})
    )
  end

  defp output(acc \\ []) do
    receive do
      {:mix_shell, _, [line]} -> output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "--yes --contact sends and prints the id", %{tmp_dir: dir} do
    write_report(dir)

    assert :ok =
             in_project(dir, fn ->
               Mix.Tasks.Precompiled.Report.run(["--yes", "--contact", "@me"])
             end)

    assert output() =~ "report 5b2c6f0e"
    assert [%{body: body}] = F.report_posts()
    assert %{"contact" => "@me", "target" => "host"} = :json.decode(body)
  end

  test "an error from the source still exits 0", %{tmp_dir: dir} do
    write_report(dir)
    F.set_report_response({500, "boom"})
    assert :ok = in_project(dir, fn -> Mix.Tasks.Precompiled.Report.run(["--yes"]) end)
    assert output() =~ "report not sent"
  end

  test "a bare --dump prints, --dump FILE writes", %{tmp_dir: dir} do
    write_report(dir)
    in_project(dir, fn -> Mix.Tasks.Precompiled.Report.run(["--dump"]) end)
    assert output() =~ ~s("format":1)

    in_project(dir, fn ->
      Mix.Tasks.Precompiled.Report.run(["--dump", "out.json", "--contact", "x"])
    end)

    assert File.exists?(Path.join(dir, "out.json"))
    assert F.report_posts() == []
  end

  test "--dump before another flag still prints" do
    assert Mix.Tasks.Precompiled.Report.dump_arg(["--dump", "--yes"]) == ["--dump", "-", "--yes"]
    assert Mix.Tasks.Precompiled.Report.dump_arg(["--dump"]) == ["--dump", "-"]
    assert Mix.Tasks.Precompiled.Report.dump_arg(["--dump", "f.json"]) == ["--dump", "f.json"]
  end

  test "no report: one line naming the env and target, exit 0", %{tmp_dir: dir} do
    assert :ok = in_project(dir, fn -> Mix.Tasks.Precompiled.Report.run(["--yes"]) end)
    assert output() =~ "test/host"
  end

  test "off sends nothing", %{tmp_dir: dir} do
    write_report(dir)
    System.put_env("PRECOMPILED", "0")

    try do
      in_project(dir, fn -> Mix.Tasks.Precompiled.Report.run(["--yes"]) end)
    after
      System.delete_env("PRECOMPILED")
    end

    assert output() =~ "nothing to report"
    assert F.report_posts() == []
  end
end
