# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Device.PlanTest do
  use ExUnit.Case, async: true
  import ElixirPrecompiled.DeviceFixture
  alias ElixirPrecompiled.Device.Plan

  @tel %{"telemetry" => %{"version" => "1.3.0", "checksum" => "tsum"}}

  defp manifests(map),
    do: fn name ->
      case map[name] do
        nil -> {:fail, "not in batch"}
        m -> {:ok, m, %{sha: "sha-" <> name, path: "v2/manifests"}}
      end
    end

  defp spec(by_run),
    do: fn b -> {:ok, [applications: Map.get(by_run, b["build"]["run_id"], [:kernel])]} end

  test "a leaf package plans itself" do
    m = manifests(%{"recon" => manifest(%{"2.5.6" => [build(run_id: "r")]})})

    assert {:ok,
            %Precompiled.Plan{
              installs: [
                %{
                  app: :recon,
                  version: "2.5.6",
                  role: :requested,
                  target: "pure_elixir",
                  manifest: %{sha: "sha-recon", path: "v2/manifests"},
                  deferred_env: []
                }
              ]
            }} =
             Plan.build([{:recon, nil}], ctx(), manifest: m)
  end

  test "an absent runtime dependency is planned first, pinned to the lock's version and checksum" do
    m =
      manifests(%{
        "poller" => manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel)]}),
        "telemetry" =>
          manifest(%{
            "1.3.0" => [build(run_id: "t", checksum: "tsum")],
            "1.4.0" => [build(run_id: "t4")]
          })
      })

    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))
    assert {:ok, plan} = Plan.build([{:poller, nil}], ctx, manifest: m)

    assert [
             %{app: :telemetry, version: "1.3.0", role: :dependency},
             %{app: :poller, role: :requested}
           ] = plan.installs
  end

  test "a pinned dependency whose published build has another checksum fails the whole plan" do
    m =
      manifests(%{
        "poller" => manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel)]}),
        "telemetry" => manifest(%{"1.3.0" => [build(run_id: "t", checksum: "different")]})
      })

    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))

    assert {:error,
            {:no_build, "telemetry",
             "package checksum differs from the lock of the build that needs it"}} =
             Plan.build([{:poller, nil}], ctx, manifest: m)
  end

  test "a pinned version the manifest does not offer is refused, never swapped for another" do
    m =
      manifests(%{
        "poller" => manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel)]}),
        "telemetry" =>
          manifest(%{
            "1.2.0" => [build(run_id: "t2", checksum: "tsum")],
            "1.4.0" => [build(run_id: "t4", checksum: "tsum")]
          })
      })

    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))

    assert {:error, {:no_build, "telemetry", "no version matches 1.3.0"}} =
             Plan.build([{:poller, nil}], ctx, manifest: m)
  end

  test "a transitive closure is ordered so every app comes after what it needs" do
    deps = %{
      "telemetry" => %{"version" => "1.3.0", "checksum" => "tsum"},
      "poller" => %{"version" => "1.2.0", "checksum" => "psum"}
    }

    m =
      manifests(%{
        "dash" => manifest(%{"0.1.0" => [build(run_id: "d", deps: deps)]}),
        "poller" => manifest(%{"1.2.0" => [build(run_id: "p", checksum: "psum", deps: @tel)]}),
        "telemetry" => manifest(%{"1.3.0" => [build(run_id: "t", checksum: "tsum")]})
      })

    ctx =
      ctx(app_spec: spec(%{"d" => [:kernel, :poller, :telemetry], "p" => [:kernel, :telemetry]}))

    assert {:ok, plan} = Plan.build([{:dash, nil}], ctx, manifest: m)
    assert [:telemetry, :poller, :dash] = Enum.map(plan.installs, & &1.app)
    assert [:dependency, :dependency, :requested] = Enum.map(plan.installs, & &1.role)
  end

  test "closure: false names what is missing" do
    m = manifests(%{"poller" => manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel)]})})
    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))

    assert {:error, {:needs, [{:telemetry, "1.3.0"}]}} =
             Plan.build([{:poller, nil}], ctx, manifest: m, closure: false)
  end

  test "a manifest that cannot be had is a no_build for that package" do
    m = manifests(%{"poller" => manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel)]})})
    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))

    assert {:error, {:no_build, "telemetry", "not in batch"}} =
             Plan.build([{:poller, nil}], ctx, manifest: m)

    miss = fn _ -> {:miss, "no manifest"} end

    assert {:error, {:no_build, "recon", "no manifest"}} =
             Plan.build([{:recon, nil}], ctx(), manifest: miss)
  end

  test "two requests pinning one dependency to two versions conflict" do
    m =
      manifests(%{
        "a" => manifest(%{"1.0.0" => [build(run_id: "a", deps: @tel)]}),
        "b" =>
          manifest(%{
            "1.0.0" => [
              build(
                run_id: "b",
                deps: %{"telemetry" => %{"version" => "1.2.0", "checksum" => "old"}}
              )
            ]
          }),
        "telemetry" =>
          manifest(%{"1.3.0" => [build(checksum: "tsum")], "1.2.0" => [build(checksum: "old")]})
      })

    ctx = ctx(app_spec: spec(%{"a" => [:kernel, :telemetry], "b" => [:kernel, :telemetry]}))

    assert {:error, {:conflict, :telemetry, ["1.2.0", "1.3.0"]}} =
             Plan.build([{:a, nil}, {:b, nil}], ctx, manifest: m)
  end

  test "two requests sharing one pinned dependency plan it once" do
    m =
      manifests(%{
        "a" => manifest(%{"1.0.0" => [build(run_id: "a", deps: @tel)]}),
        "b" => manifest(%{"1.0.0" => [build(run_id: "b", deps: @tel)]}),
        "telemetry" => manifest(%{"1.3.0" => [build(checksum: "tsum")]})
      })

    ctx = ctx(app_spec: spec(%{"a" => [:kernel, :telemetry], "b" => [:kernel, :telemetry]}))
    assert {:ok, plan} = Plan.build([{:a, nil}, {:b, nil}, {:a, nil}], ctx, manifest: m)
    assert [:telemetry, :a, :b] = Enum.map(plan.installs, & &1.app)

    assert {:ok, plan} = Plan.build([{:a, nil}, {:telemetry, "1.3.0"}], ctx, manifest: m)
    assert [%{app: :telemetry, role: :requested}, %{app: :a}] = plan.installs

    assert {:error, {:conflict, :telemetry, ["1.3.0", "1.4.0"]}} =
             Plan.build([{:a, nil}, {:telemetry, "1.4.0"}], ctx, manifest: m)
  end

  test "the closure bound and the allowlist" do
    m = manifests(%{"recon" => manifest(%{"2.5.6" => [build()]})})

    assert {:error, {:too_many, 1, 0}} =
             Plan.build([{:recon, nil}], ctx(), manifest: m, max_closure: 0)

    assert {:error, {:not_allowed, :recon}} =
             Plan.build([{:recon, nil}], ctx(), manifest: m, allow: [:circuits_gpio])

    assert {:ok, _} = Plan.build([{:recon, nil}], ctx(), manifest: m, allow: [:recon])
  end

  test "the allowlist covers dependencies too" do
    m =
      manifests(%{
        "poller" => manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel)]}),
        "telemetry" => manifest(%{"1.3.0" => [build(checksum: "tsum")]})
      })

    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))

    assert {:error, {:not_allowed, :telemetry}} =
             Plan.build([{:poller, nil}], ctx, manifest: m, allow: [:poller])
  end

  test "present apps: firmware or another version is already_present; our own loaded same version is a no-op" do
    m =
      manifests(%{
        "logger" => manifest(%{"1.20.3" => [build()]}),
        "recon" => manifest(%{"2.5.6" => [build()]})
      })

    assert {:error, {:already_present, :logger, "1.20.3"}} =
             Plan.build([{:logger, nil}], ctx(), manifest: m)

    ours = ctx(env: env(present: %{recon: "2.5.6"}), active: %{recon: "2.5.6"})

    assert {:ok, %{installs: [], present: [{:recon, "2.5.6"}]}} =
             Plan.build([{:recon, nil}], ours, manifest: m)
  end

  test "our own loaded app counts even when the device was read before it was loaded" do
    m = manifests(%{"recon" => manifest(%{"2.5.6" => [build()]})})
    ours = ctx(active: %{recon: "2.5.6"})

    assert {:ok, %{installs: [], present: [{:recon, "2.5.6"}]}} =
             Plan.build([{:recon, "2.5.6"}], ours, manifest: m)

    assert {:ok, %{present: [{:recon, "2.5.6"}]}} =
             Plan.build([{:recon, "~> 2.5"}], ours, manifest: m)

    assert {:error, {:already_present, :recon, "2.5.6"}} =
             Plan.build([{:recon, "2.5.7"}], ours, manifest: m)
  end

  test "bytes add up across the plan" do
    f = fn n ->
      %{
        "path" => "ebin/#{n}.app",
        "sha256" => String.duplicate("a", 64),
        "size" => n,
        "mode" => 420
      }
    end

    m = manifests(%{"recon" => manifest(%{"2.5.6" => [build(ebin: [f.(100)], priv: [])]})})
    assert {:ok, %{bytes: 100}} = Plan.build([{:recon, nil}], ctx(), manifest: m)

    m =
      manifests(%{
        "poller" =>
          manifest(%{"1.2.0" => [build(run_id: "p", deps: @tel, ebin: [f.(100)], priv: [f.(7)])]}),
        "telemetry" => manifest(%{"1.3.0" => [build(checksum: "tsum", ebin: [f.(30)])]})
      })

    ctx = ctx(app_spec: spec(%{"p" => [:kernel, :telemetry]}))

    assert {:ok, %{bytes: 137, installs: [%{bytes: 30}, %{bytes: 107}]}} =
             Plan.build([{:poller, nil}], ctx, manifest: m)
  end

  test "build warnings are carried, named by the package" do
    m = manifests(%{"recon" => manifest(%{"2.5.6" => [build()]})})
    assert {:ok, %{warnings: [warning]}} = Plan.build([{:recon, nil}], ctx(), manifest: m)
    assert warning =~ "recon 2.5.6: build predates declared"
  end
end
