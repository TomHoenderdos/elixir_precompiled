# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.OutcomeTest do
  use ExUnit.Case, async: true
  import Precompiled.DeviceFixture
  alias Precompiled.Device.Outcome
  alias Precompiled.Device.Plan
  alias Precompiled.Device.Store
  alias Precompiled.PortalPayload
  alias Precompiled.Reason

  @moduletag :tmp_dir

  @sum String.duplicate("ab", 32)
  @dep_sum String.duplicate("c", 64)

  defp install(app, vsn, opts \\ []) do
    build =
      build(
        checksum: Keyword.get(opts, :checksum, @sum),
        deps: Keyword.get(opts, :deps, %{}),
        target: Keyword.get(opts, :target, "pure_elixir")
      )

    %{app: app, version: vsn, target: build["target"], build: build}
  end

  defp facts(lines, extra \\ %{}) do
    Map.merge(%{env: env(), lines: lines}, extra)
  end

  describe "lines" do
    test "an applied plan: every install a hit, its checksum and its build's lock" do
      a =
        install(:demo_a, "1.0.0",
          deps: %{"jason" => %{"version" => "1.4.4", "checksum" => @dep_sum}}
        )

      b = install(:demo_b, "2.0.0", checksum: "not-a-checksum")

      {lines, lock} = Outcome.applied([a, b], {:ok, []})

      assert [
               %{"name" => "demo_a", "version" => "1.0.0", "status" => "hit"} = hit,
               %{"name" => "demo_b", "status" => "hit"}
             ] = lines

      assert hit["reason_code"] == "hit" and hit["reason_args"] == []

      # demo_b's checksum is not one: the entry is left out, never guessed.
      assert lock == [
               %{"name" => "demo_a", "version" => "1.0.0", "checksum" => @sum},
               %{"name" => "jason", "version" => "1.4.4", "checksum" => @dep_sum}
             ]
    end

    test "a failed apply: the culprit with its reason, the rest not installed" do
      a = install(:demo_a, "1.0.0")
      b = install(:demo_ssl, "1.0.0")
      libs = Reason.new(:needed_lib_missing, ["libssl.so.3"])

      {lines, _lock} = Outcome.applied([a, b], {:error, {:libs, :demo_ssl, libs}})

      assert [
               %{"name" => "demo_a", "status" => "fail", "reason_code" => "install_failed"},
               %{
                 "name" => "demo_ssl",
                 "status" => "miss",
                 "reason_code" => "needed_lib_missing",
                 "reason_args" => ["libssl.so.3"]
               }
             ] = lines

      {lines, _} = Outcome.applied([a], {:error, {:fetch, "demo_a", "sha256 mismatch"}})
      assert [%{"status" => "fail", "reason_code" => "verify_failed"}] = lines

      {lines, _} = Outcome.applied([a, b], {:error, {:enospc, "/data/precompiled"}})
      assert Enum.all?(lines, &(&1["status"] == "fail" and &1["reason_code"] == "install_failed"))
    end

    test "a miss names the version it tried; a refused batch only exact versions" do
      reason = Reason.new(:toolchain_otp, ["28", "29"])

      assert [%{"status" => "miss", "version" => "1.0.0", "reason_code" => "toolchain_otp"}] =
               Outcome.missed("demo_a", reason, "1.0.0")

      lines = Outcome.refused([{:demo_a, "1.2.0"}, {:demo_b, "~> 1.0"}], "batch unavailable: x")

      assert [
               %{"version" => "1.2.0", "status" => "fail", "reason_code" => "fetch_failed"},
               %{"version" => nil}
             ] = lines
    end
  end

  describe "the plan's coded misses" do
    defp plan(requests, manifests, ctx_opts \\ []) do
      Plan.build_coded(requests, ctx(ctx_opts),
        manifest: fn name ->
          case manifests[name] do
            nil -> {:miss, "not in batch"}
            m -> {:ok, m, %{sha: "s", path: "p"}}
          end
        end
      )
    end

    test "a rule's miss keeps its code and the newest version the request allows" do
      old = build(otp: "28", system_version: nil)

      assert {:error, {:no_build, "demo_a", %Reason{code: :toolchain_otp} = r, "1.1.0"}} =
               plan([{:demo_a, nil}], %{
                 "demo_a" => manifest(%{"1.0.0" => [old], "1.1.0" => [old]})
               })

      assert r.args == ["28", "29"]
      # The text the line prints is unchanged.
      assert {:error, {:no_build, "demo_a", "built on OTP 28, running 29"}} =
               Plan.build([{:demo_a, nil}], ctx(),
                 manifest: fn _ ->
                   {:ok, manifest(%{"1.0.0" => [old]}), %{sha: "s", path: "p"}}
                 end
               )
    end

    test "not in the batch, and nothing to try" do
      assert {:error, {:no_build, "demo_x", %Reason{code: :not_in_batch}, nil}} =
               plan([{:demo_x, nil}], %{})

      assert {:error, {:no_build, "demo_x", %Reason{code: :not_in_batch}, "2.0.0"}} =
               plan([{:demo_x, "2.0.0"}], %{})

      assert {:error, {:no_build, "demo_a", %Reason{code: :not_built_version}, nil}} =
               plan([{:demo_a, "~> 9.0"}], %{"demo_a" => manifest(%{"1.0.0" => [build()]})})
    end

    test "a closure app the firmware lacks, and one at another version" do
      ctx = [app_spec: app_spec([:kernel, :stdlib, :elixir, :demo_gone])]

      assert {:error,
              {:no_build, "demo_a", %Reason{code: :closure_absent, args: ["demo_gone"]}, "1.0.0"}} =
               plan([{:demo_a, nil}], %{"demo_a" => manifest(%{"1.0.0" => [build()]})}, ctx)

      b = build(deps: %{"logger" => %{"version" => "1.0.0", "checksum" => "x"}})
      ctx = [app_spec: app_spec([:kernel, :stdlib, :elixir, :logger])]

      assert {:error,
              {:no_build, "demo_a",
               %Reason{code: :closure_mismatch, args: ["logger", "1.0.0", "1.20.3"]}, "1.0.0"}} =
               plan([{:demo_a, nil}], %{"demo_a" => manifest(%{"1.0.0" => [b]})}, ctx)
    end
  end

  describe "the file" do
    test "record writes the last install; read gives it back; a second replaces it",
         %{tmp_dir: dir} do
      :ok = Store.ensure_root(dir)
      assert {:error, :no_report} = Outcome.read(dir)

      lines = Outcome.missed("demo_a", Reason.new(:toolchain_otp, ["28", "29"]), "1.0.0")
      assert :ok = Outcome.record(dir, facts(lines))
      assert {:ok, %{"lines" => [%{"name" => "demo_a"}], "context" => ctx}} = Outcome.read(dir)
      assert ctx["system"] == "nerves_system_rpi4" and ctx["target"] == "rpi4"

      {hits, lock} = Outcome.applied([install(:demo_b, "1.0.0")], {:ok, []})
      assert :ok = Outcome.record(dir, facts(hits, %{lock: lock}))
      assert {:ok, %{"lines" => [%{"name" => "demo_b"}], "lock" => [_]}} = Outcome.read(dir)

      # Only the file: no temporary names left behind.
      assert dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, ".outcome.")) == []
    end

    test "a sweep and a clean keep it", %{tmp_dir: dir} do
      :ok = Store.ensure_root(dir)
      :ok = Outcome.record(dir, facts([]))
      File.write!(Path.join(dir, ".outcome.123-4"), "partial")
      Store.sweep(dir)
      Store.clean(dir, %{})
      assert {:ok, _} = Outcome.read(dir)
      refute File.exists?(Path.join(dir, ".outcome.123-4"))
    end

    test "an unreadable or malformed file is no report", %{tmp_dir: dir} do
      :ok = Store.ensure_root(dir)
      File.write!(Path.join(dir, ".last-install.json"), "{not json")
      assert {:error, :no_report} = Outcome.read(dir)
      File.write!(Path.join(dir, ".last-install.json"), ~s({"lines": 1}))
      assert {:error, :no_report} = Outcome.read(dir)
    end
  end

  describe "the payload" do
    # Through JSON, as the file holds it.
    defp doc_of(lines, extra \\ %{}) do
      facts(lines, extra)
      |> Outcome.doc()
      |> :json.encode()
      |> IO.iodata_to_binary()
      |> :json.decode()
    end

    test "a known system goes by name, and the body validates as the portal checks it" do
      a =
        install(:demo_a, "1.0.0",
          deps: %{"jason" => %{"version" => "1.4.4", "checksum" => @dep_sum}}
        )

      {lines, lock} = Outcome.applied([a], {:ok, []})
      miss = Outcome.missed("demo_b", Reason.new(:toolchain_otp, ["28", "29"]), "2.0.0")

      doc =
        doc_of(lines ++ miss, %{
          lock: lock,
          systems: %{"nerves_system_rpi4" => %{}}
        })

      body = Outcome.payload(doc, "@me")

      assert %{
               "target" => "rpi4",
               "system" => "nerves_system_rpi4",
               "system_version" => "2.2.1",
               "contact" => "@me",
               "otp" => 29
             } = body

      assert [
               %{"status" => "hit"},
               %{"status" => "miss", "reason" => "built on OTP 28, running 29"}
             ] =
               body["lines"]

      assert Enum.map(body["lock"], & &1["name"]) == ["demo_a"]

      json = body |> :json.encode() |> IO.iodata_to_binary()
      assert {:ok, _} = PortalPayload.validate(:json.decode(json))
      refute json =~ "detail"
    end

    test "a system the source does not know is custom, and so are target arguments" do
      reason = Reason.new(:not_built_target, ["nerves_system_acme", "1.0.0"])

      doc =
        doc_of(Outcome.missed("demo_a", reason, "1.0.0"), %{
          env: env(system: {"nerves_system_acme", "1.0.0"})
        })

      body = Outcome.payload(doc, nil)
      assert body["target"] == "custom" and body["system"] == "custom"
      refute Map.has_key?(body, "system_version")
      assert [%{"reason_args" => ["custom", "custom"]}] = body["lines"]
      refute body |> :json.encode() |> IO.iodata_to_binary() =~ "acme"
      assert {:ok, _} = PortalPayload.validate(body)
    end

    test "a device with no Nerves system sends target custom and no system" do
      doc =
        doc_of(Outcome.missed("demo_a", Reason.new(:not_in_batch, []), "1.0.0"), %{
          env: env(system: nil)
        })

      body = Outcome.payload(doc, nil)
      assert body["target"] == "custom"
      refute Map.has_key?(body, "system")
      assert {:ok, _} = PortalPayload.validate(body)
    end

    test "a line with no version, or a name the portal refuses, is not sent" do
      lines =
        Outcome.refused([{:demo_a, nil}], "batch unavailable") ++
          [Outcome.line("Bad-Name", "1.0.0", :miss, Reason.new(:not_in_batch, []))]

      body = Outcome.payload(doc_of(lines), nil)
      assert body["lines"] == [] and body["lock"] == []
    end

    test "the printed detail is never sent: only the code's own text" do
      reason = Reason.new(:install_failed, [], "eacces at /data/precompiled/demo_a-1.0.0")
      body = Outcome.payload(doc_of(Outcome.missed("demo_a", reason, "1.0.0")), nil)
      assert [%{"reason" => "install failed"}] = body["lines"]
      refute body |> :json.encode() |> IO.iodata_to_binary() =~ "/data"
    end
  end
end
