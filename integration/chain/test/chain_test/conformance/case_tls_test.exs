# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.CaseTlsTest do
  use ExUnit.Case, async: true

  alias ChainTest.Conformance.Case
  alias ChainTest.{Result, Synthetic}

  @moduletag :tmp_dir

  @no_batch %{
    client: %{default: {:fail, "batch unavailable"}, deps: %{}},
    harness: %{"build/hit:jason" => :fail}
  }

  @n3 Map.merge(@no_batch, %{
        id: "N3-self-signed",
        description: "A self-signed certificate.",
        transform: {ChainTest.Mirror.Identity, %{tls: :self_signed}},
        after: %{tls: :rejected, installed: :none}
      })

  @n2 %{
    id: "N2",
    description: "An http source outside loopback.",
    transform: {ChainTest.Mirror.Identity, %{}},
    proxy: :mirror,
    client_config: %{source: "http://chain-n2.invalid"},
    client: %{default: :none, deps: %{}},
    harness: %{"build/hit:jason" => :fail},
    after: %{proxied: :none, installed: :none}
  }

  @n6 %{
    id: "N6",
    description: "Files downgraded to http on the same host and port.",
    transform: {ChainTest.Mirror.Downgrade, %{paths: :files, tls: :ip, trust_ca: true}},
    client: %{default: {:fail, "file not available:"}, deps: %{}},
    harness: %{"build/hit:jason" => :fail},
    after: %{tls: :clean, installed: :none}
  }

  defp write(tmp, cases) do
    path = Path.join(tmp, "cases.exs")
    File.write!(path, inspect(cases, limit: :infinity, printable_limit: :infinity))
    path
  end

  defp handshake(alert),
    do: %{method: "TLS", path: "handshake", status: 0, mutated: false, tls_alert: alert}

  defp get(path, extra \\ %{}),
    do: Map.merge(%{method: "GET", path: path, status: 200, mutated: false}, extra)

  defp judge(c, requests, opts \\ []) do
    lines = Keyword.get(opts, :lines, [{"jason", "1.4.5", "fail", "batch unavailable"}])

    Case.judge(c, %{
      rows: [%Result{step: :build, check: "hit:jason", class: :fail}],
      report: if(lines, do: Synthetic.report(lines), else: %{}),
      requests: requests,
      second_requests: [],
      snapshot: %{
        sequence: 7,
        deps: %{"jason" => %{builds: 1, manifest: "v2/manifests/jason.json"}}
      },
      hits: [:jason],
      observed: %{
        before: %{states: %{}, cache: %{}, own: {:ok, "abc/state"}},
        after: %{states: %{}, cache: %{}, own: {:ok, "abc/state"}},
        installed: [],
        log: Keyword.get(opts, :log, "")
      }
    })
  end

  describe "load/1" do
    test "accepts the TLS, proxy and no-report-line keys", %{tmp_dir: tmp} do
      assert {:ok, [_, _, _]} = Case.load(write(tmp, [@n3, @n2, @n6]))
    end

    test "refuses them where they mean nothing", %{tmp_dir: tmp} do
      for bad <- [
            # tls post-conditions need a TLS mirror
            put_in(@n2, [:after], %{tls: :rejected}),
            put_in(@n3, [:after, :tls], :other),
            # proxied needs proxy: :mirror
            Map.delete(@n2, :proxy),
            put_in(@n2, [:after, :proxied], :sometimes),
            Map.put(@n3, :proxy, :elsewhere),
            # a TLS case cannot also proxy
            Map.put(@n3, :proxy, :mirror)
          ] do
        assert {:error, _} = Case.load(write(tmp, [bad])), inspect(bad)
      end
    end
  end

  describe "tls: :rejected (N3)" do
    test "passes when every connection was a handshake the client aborted on the certificate" do
      for alert <- [:unknown_ca, :bad_certificate] do
        assert %Result{class: :pass} = judge(@n3, [handshake(alert), handshake(alert)])
      end
    end

    test "is not exercised when the client never connected to the TLS mirror" do
      assert %Result{class: :not_exercised, detail: detail} = judge(@n3, [])
      assert detail =~ "never connected"
    end

    test "fails when a request got through, or a handshake failed for another reason" do
      assert %Result{class: :fail, detail: d1} =
               judge(@n3, [handshake(:unknown_ca), get("batch.json")])

      assert d1 =~ "batch.json"

      assert %Result{class: :fail, detail: d2} = judge(@n3, [handshake(:protocol_version)])
      assert d2 =~ "protocol_version"

      timeout = %{
        method: "TLS",
        path: "handshake",
        status: 0,
        mutated: false,
        tls_error: ":timeout"
      }

      assert %Result{class: :fail} = judge(@n3, [timeout])
    end

    test "still judges the client's lines and the other post-conditions" do
      assert %Result{class: :fail, detail: detail} =
               judge(@n3, [handshake(:unknown_ca)], lines: [{"jason", "1.4.5", "hit", ""}])

      assert detail =~ "client jason"
    end
  end

  describe "tls: :clean (N6)" do
    test "passes a judged case whose every connection completed its handshake" do
      requests = [
        get("batch.json"),
        get("v2/manifests/jason.json"),
        get("files/" <> String.duplicate("a", 64), %{status: 302, mutated: true})
      ]

      assert %Result{class: :pass} =
               judge(@n6, requests, lines: [{"jason", "1.4.5", "fail", "file not available: x"}])
    end

    test "fails when the client followed to plain http on the TLS port" do
      requests = [
        get("batch.json"),
        get("v2/manifests/jason.json"),
        get("files/" <> String.duplicate("a", 64), %{status: 302, mutated: true}),
        handshake(:unexpected_message)
      ]

      assert %Result{class: :fail, detail: detail} =
               judge(@n6, requests, lines: [{"jason", "1.4.5", "fail", "file not available: x"}])

      assert detail =~ "unexpected_message"
    end
  end

  describe "proxied (N2)" do
    test ":none passes with no request at all, and no report line" do
      assert %Result{class: :pass} = judge(@n2, [], lines: nil)
    end

    test ":none fails on any request, a proxied one included" do
      proxied = get("http://chain-n2.invalid/batch.json", %{status: 400, proxied: true})
      assert %Result{class: :fail, detail: detail} = judge(@n2, [proxied], lines: nil)
      assert detail =~ "chain-n2.invalid"
    end

    test "the :none expectation fails on a report line" do
      assert %Result{class: :fail, detail: detail} = judge(@n2, [])
      assert detail =~ "no report line"
    end

    test ":requested passes only when every request came through the proxy" do
      control =
        Map.merge(@no_batch, %{
          id: "N2-proxy",
          description: "The proxy control.",
          transform: {ChainTest.Mirror.Identity, %{}},
          proxy: :mirror,
          client_config: %{source: "http://localhost:1"},
          after: %{proxied: :requested}
        })

      proxied = get("http://localhost:1/batch.json", %{status: 400, proxied: true})
      assert %Result{class: :pass} = judge(control, [proxied])
      assert %Result{class: :fail} = judge(control, [])
      assert %Result{class: :fail} = judge(control, [proxied, get("batch.json")])
    end
  end

  describe "the repository's TLS and transport cases" do
    setup do
      {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
      %{by: Map.new(cases, &{&1.id, &1}), ids: Enum.map(cases, & &1.id)}
    end

    test "every row has its case, real-root (layer 1)", %{by: by} do
      for id <- ~w(N2-proxy N2 TLS-T0 N3-self-signed N3-wrong-host N3-hostname N6 N6-manifest) do
        assert Map.has_key?(by, id), id
        refute Case.layer2?(by[id]), id
      end
    end

    test "no N3 case that tests trust is told to trust the test CA", %{by: by} do
      for id <- ~w(N3-self-signed N3-wrong-host) do
        refute ChainTest.Mirror.Transform.trust_ca?(by[id].transform), id
        assert by[id].after.tls == :rejected, id
      end

      assert ChainTest.Mirror.Transform.tls(by["N3-self-signed"].transform) == :self_signed
      assert ChainTest.Mirror.Transform.tls(by["N3-wrong-host"].transform) == :wrong_host
    end

    test "the cases that trust the test CA are gated on TLS-T0, its control", %{by: by} do
      assert ChainTest.Mirror.Transform.trust_ca?(by["TLS-T0"].transform)
      assert by["TLS-T0"].after.installed == :snapshot

      for id <- ~w(N3-hostname N6 N6-manifest) do
        assert ChainTest.Mirror.Transform.trust_ca?(by[id].transform), id
        assert by[id].gate == "TLS-T0", id
      end

      assert ChainTest.Mirror.Transform.tls(by["N3-hostname"].transform) == :wrong_host
      assert by["N3-hostname"].after.tls == :rejected
    end

    test "N6 refuses the downgrade by its reason and never sends plain http", %{by: by} do
      for id <- ~w(N6 N6-manifest) do
        assert {ChainTest.Mirror.Downgrade, _} = by[id].transform
        assert by[id].after.tls == :clean, id
        assert by[id].after.installed == :none, id
      end

      assert by["N6"].after.log == "redirect to another host refused"

      assert by["N6-manifest"].client.default ==
               {:miss, "manifest unavailable: redirect to another host refused"}
    end

    test "N2 runs through the proxy, after its control, with a source outside loopback",
         %{by: by} do
      assert by["N2"].gate == "N2-proxy"

      for id <- ~w(N2 N2-proxy), do: assert(by[id].proxy == :mirror, id)

      %URI{scheme: "http", host: host} = URI.parse(by["N2"].client_config.source)
      refute host in ["127.0.0.1", "::1", "localhost"]
      assert String.ends_with?(host, ".invalid")
      assert by["N2"].after.proxied == :none
      assert by["N2"].client.default == :none
      assert by["N2"].after.log =~ "source must be https"

      %URI{scheme: "http", host: "localhost"} = URI.parse(by["N2-proxy"].client_config.source)
      assert by["N2-proxy"].after.proxied == :requested
    end
  end

  test "the README's case table names exactly the cases in the file, with their spec ids" do
    {:ok, cases} = Case.load(Path.join(ChainTest.CLI.root(), "conformance/cases.exs"))
    readme = File.read!(Path.join(ChainTest.CLI.root(), "README.md"))
    [_, table] = String.split(readme, "| Case | Spec | Layer | What it shows |", parts: 2)

    rows =
      for line <- String.split(table, "\n"),
          [_, id, spec] <- [Regex.run(~r/^\| `([^`]+)` \| ([^|]*) \|/, line)],
          do: {id, String.trim(spec)}

    assert Enum.map(rows, &elem(&1, 0)) == Enum.map(cases, & &1.id)

    for {id, spec} <- rows,
        do: assert(spec == Enum.join(ChainTest.Report.spec_ids(id), ", "), id)
  end
end
