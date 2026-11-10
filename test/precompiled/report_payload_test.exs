# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ReportPayloadTest do
  # Not async: the config comes from the application env, as in a project.
  use ExUnit.Case, async: false
  alias Precompiled.Report
  @moduletag :tmp_dir

  @jason {:hex, :jason, "1.4.5", "i", [:mix],
          [{:decimal, "~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm",
          "AB" <> String.duplicate("c", 62)}
  @decimal {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", String.duplicate("d", 64)}
  @telemetry {:hex, :telemetry, "1.3.0", "i", [:rebar3], [], "hexpm", String.duplicate("e", 64)}
  @secret {:hex, :acme_secret, "0.1.0", "i", [:mix],
           [{:telemetry, "~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}],
           "hexpm:acme", String.duplicate("f", 64)}
  @gitdep {:git, "https://git.acme.example/x.git", "abc", []}
  @lock %{
    jason: @jason,
    decimal: @decimal,
    telemetry: @telemetry,
    acme_secret: @secret,
    gitdep: @gitdep
  }

  setup do
    saved = Application.get_all_env(:precompiled)
    for {k, _} <- saved, do: Application.delete_env(:precompiled, k)

    Application.put_all_env(
      precompiled: [
        source: "https://pkgs.acme.example/api/precompiled",
        content: ["https://cdn.acme.example"]
      ]
    )

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:precompiled),
          do: Application.delete_env(:precompiled, k)

      Application.put_all_env(precompiled: saved)
    end)
  end

  # The real config map Config.load/0 builds from the project's config.
  defp where(dir, over \\ %{}) do
    project = Path.join([dir, "very", "deep", "client", "acme_secret_app"])

    Map.merge(
      %{
        build_lib: Path.join(project, "_build/rpi4_dev/lib"),
        lock: @lock,
        config: Precompiled.Config.load(),
        project_dir: project,
        env: "dev",
        target: "rpi4",
        host_name: "build-laptop"
      },
      over
    )
  end

  defp report(lines) do
    %{
      "format" => 1,
      "built_at" => "2026-11-10T12:00:00Z",
      "context" => %{
        "elixir" => "1.20.3",
        "otp" => "29",
        "target" => "rpi4",
        "system" => "nerves_system_rpi4",
        "system_version" => "1.31.0"
      },
      "lines" => lines
    }
  end

  defp l(name, status, code, args, detail \\ "x"),
    do: %{
      "name" => name,
      "version" => "1.0.0",
      "status" => status,
      "detail" => detail,
      "reason_code" => code,
      "reason_args" => args
    }

  test "reads a report, refuses a missing or pre-0.4 one", %{tmp_dir: dir} do
    lib = Path.join(dir, "lib")
    assert {:error, :no_report} = Report.read(lib)

    File.mkdir_p!(Path.join(lib, ".precompiled"))
    File.write!(Path.join(lib, ".precompiled/report.json"), ~s({"format":1,"lines":[]}))
    assert {:error, :old_report} = Report.read(lib)

    File.write!(Path.join(lib, ".precompiled/report.json"), "{trunc")
    assert {:error, :no_report} = Report.read(lib)

    File.write!(
      Path.join(lib, ".precompiled/report.json"),
      IO.iodata_to_binary(:json.encode(report([])))
    )

    assert {:ok, %{"built_at" => _}} = Report.read(lib)
  end

  test "the lock closure is the candidates' public Hex entries, then their dependencies" do
    assert [
             %{"name" => "jason", "version" => "1.4.5", "checksum" => jason_sum},
             %{"name" => "decimal", "version" => "2.3.0", "checksum" => _}
           ] = Report.lock_closure(@lock, ["jason"], 1000)

    assert jason_sum == String.downcase(elem(@jason, 7))
    assert Report.lock_closure(@lock, ["acme_secret"], 1000) == []
    assert Report.lock_closure(@lock, ["gitdep", "not_in_lock"], 1000) == []
  end

  test "a public package's private, git or malformed dependencies stay out of the lock" do
    lock = %{
      app:
        {:hex, :app, "1.0.0", "i", [:mix],
         [
           {:acme_secret, "~> 0.1", [hex: :acme_secret, repo: "hexpm:acme"]},
           {:gitdep, "~> 1.0", []},
           {:short, "~> 1.0", []},
           {"not_an_atom", "~> 1.0", []},
           :garbage
         ], "hexpm", String.duplicate("a", 64)},
      acme_secret: @secret,
      gitdep: @gitdep,
      short: {:hex, :short, "1.0.0", "i", [:mix], [], "hexpm", "abc"}
    }

    assert ["app"] = lock |> Report.lock_closure(["app"], 1000) |> Enum.map(& &1["name"])
  end

  test "truncation drops the entries farthest from the candidates" do
    assert ["jason", "telemetry"] =
             @lock |> Report.lock_closure(["jason", "telemetry"], 2) |> Enum.map(& &1["name"])
  end

  test "private and non-Hex lines are dropped; reasons come from templates", %{tmp_dir: dir} do
    rep =
      report([
        l("jason", "miss", "not_built_version", ["1.0.0"]),
        l("acme_secret", "miss", "not_in_batch", []),
        l("gitdep", "miss", "not_in_batch", []),
        l("telemetry", "fail", "install_failed", [], "install failed: /home/me/acme: eacces")
      ])

    payload = Report.payload(where(dir), rep, nil)
    assert Enum.map(payload["lines"], & &1["name"]) == ["jason", "telemetry"]
    assert %{"reason" => "not built for 1.0.0"} = hd(payload["lines"])
    assert %{"reason" => "install failed", "reason_args" => []} = List.last(payload["lines"])
    assert Enum.map(payload["lock"], & &1["name"]) == ["jason", "telemetry", "decimal"]
    refute Map.has_key?(payload, "contact")
  end

  test "context, os and client fields", %{tmp_dir: dir} do
    payload = Report.payload(where(dir), report([]), "@me")

    assert %{
             "format" => 1,
             "elixir" => "1.20.3",
             "otp" => 29,
             "target" => "rpi4",
             "system" => "nerves_system_rpi4",
             "system_version" => "1.31.0",
             "contact" => "@me",
             "built_at" => "2026-11-10T12:00:00Z"
           } = payload

    assert payload["client"] == to_string(Application.spec(:precompiled, :vsn))
    assert payload["os"]["family"] in ["unix", "win32"]
    assert payload["os"]["arch"] =~ ~r/\A[a-z0-9_.-]{1,64}\z/
  end

  test "a host build's null system fields are left out, not sent as null", %{tmp_dir: dir} do
    rep =
      report([])
      |> put_in(["context", "system"], :null)
      |> put_in(["context", "system_version"], :null)
      |> put_in(["context", "target"], "host")

    payload = Report.payload(where(dir), rep, nil)
    refute Map.has_key?(payload, "system")
    refute Map.has_key?(payload, "system_version")
    assert payload["target"] == "host"
    refute IO.iodata_to_binary(:json.encode(payload)) =~ "null"
  end

  test "the source, content origin, project path, home and host name are redacted from contact and reason",
       %{tmp_dir: dir} do
    w = where(dir)
    home = System.user_home() || "/nonexistent-home"
    contact = "me at #{w.project_dir} via #{w.config.source} on #{home} from build-laptop"

    payload =
      w
      |> Report.payload(report([l("jason", "miss", "not_built_version", ["1.0.0"])]), contact)
      |> put_in(
        ["lines", Access.at(0), "reason"],
        "seen at https://cdn.acme.example/f and #{w.project_dir}"
      )
      |> Report.redact_payload(Report.needles(w))

    for field <- [payload["contact"], hd(payload["lines"])["reason"]],
        needle <- [
          w.project_dir,
          w.config.source,
          "pkgs.acme.example",
          "cdn.acme.example",
          "build-laptop",
          home
        ] do
      refute field =~ needle
    end

    assert payload["contact"] =~ "<redacted>"
    assert hd(payload["lines"])["reason"] =~ "<redacted>"
  end

  test "detail text, paths in args and unknown codes never reach the payload", %{tmp_dir: dir} do
    w = where(dir)

    rep =
      report([
        l(
          "telemetry",
          "fail",
          "fetch_failed",
          [w.project_dir, w.config.source],
          "file not available: #{w.project_dir}"
        ),
        %{l("jason", "miss", "not_built_version", ["1.0.0"]) | "reason_code" => w.project_dir}
      ])

    json = w |> Report.payload(rep, nil) |> :json.encode() |> IO.iodata_to_binary()
    refute json =~ w.project_dir
    refute json =~ "pkgs.acme.example"
    assert json =~ ~s("reason_code":"internal")
  end

  for host <- ["jason", "rpi4", "decimal"] do
    test "a host named #{host}, like a package or target, leaves the structured fields alone",
         %{tmp_dir: dir} do
      w = where(dir, %{host_name: unquote(host), target: "rpi4"})
      rep = report([l("jason", "miss", "not_built_target", ["nerves_system_rpi4", "1.31.0"])])

      payload =
        w
        |> Report.payload(rep, "ask #{unquote(host)}")
        |> Report.redact_payload(Report.needles(w))

      assert %{
               "name" => "jason",
               "version" => "1.0.0",
               "reason_code" => "not_built_target",
               "reason_args" => ["nerves_system_rpi4", "1.31.0"]
             } = hd(payload["lines"])

      assert Enum.map(payload["lock"], &{&1["name"], &1["version"]}) ==
               [{"jason", "1.4.5"}, {"decimal", "2.3.0"}]

      assert payload["target"] == "rpi4"
      assert payload["system"] == "nerves_system_rpi4"
      assert payload["system_version"] == "1.31.0"
      assert payload["contact"] == "ask <redacted>"
    end
  end

  test "a home directory named like a package leaves the structured fields alone",
       %{tmp_dir: dir} do
    w = where(dir)
    home = System.user_home()
    rep = report([l("jason", "miss", "not_built_version", ["1.0.0"])])
    payload = Report.payload(w, rep, nil)
    # Even a needle that is a package name itself only touches contact and reason.
    redacted = Report.redact_payload(payload, Enum.reject([home, "jason", "1.0.0"], &is_nil/1))

    assert Map.delete(redacted, "lines") == Map.delete(payload, "lines")

    assert [%{"name" => "jason", "version" => "1.0.0", "reason" => "not built for <redacted>"}] =
             redacted["lines"]
  end

  test "short or root-like needles are ignored", %{tmp_dir: dir} do
    needles = Report.needles(where(dir, %{project_dir: "/", host_name: "a"}))
    refute "/" in needles
    refute "a" in needles
    assert Enum.all?(needles, &(String.length(&1) >= 4))
    assert needles == Enum.sort_by(needles, &(-String.length(&1)))

    payload = %{"contact" => "a / b", "lines" => [%{"name" => "x", "reason" => "a/b"}]}
    assert Report.redact_payload(payload, ["a", "/"]) == payload
  end

  test "lines and lock entries are capped at 500 and 1000", %{tmp_dir: dir} do
    names = for i <- 1..600, do: "p#{i}"

    lock =
      Map.new(names, fn n ->
        app = String.to_atom(n)
        {app, {:hex, app, "1.0.0", "i", [:mix], [], "hexpm", String.duplicate("a", 64)}}
      end)

    rep = report(Enum.map(names, &l(&1, "miss", "not_in_batch", [])))
    payload = Report.payload(where(dir, %{lock: lock}), rep, nil)
    assert length(payload["lines"]) == 500
    assert length(payload["lock"]) <= 1000
  end

  test "the summary counts from the payload and names env, target, every MISS and FAIL, lock size, contact and destination",
       %{tmp_dir: dir} do
    w = where(dir)

    rep =
      report([
        l("jason", "miss", "not_built_version", ["1.0.0"]),
        l("telemetry", "hit", "hit", []),
        l("acme_secret", "miss", "not_in_batch", [])
      ])

    payload = Report.payload(w, rep, "@me")
    text = Enum.join(Report.summary(payload, rep, w), "\n")

    assert text =~ "MIX_ENV=dev MIX_TARGET=rpi4"
    # acme_secret is not sent, so it is not counted.
    assert text =~ "1 hit, 1 miss, 0 fail"
    assert text =~ "MISS  jason 1.0.0  not built for 1.0.0"
    refute text =~ "acme_secret"
    refute text =~ "HIT"
    # jason, its declared decimal, and telemetry.
    assert text =~ "lock entries: 3"
    assert text =~ "contact: @me"
    assert text =~ "https://pkgs.acme.example/api/precompiled/reports"
  end
end
