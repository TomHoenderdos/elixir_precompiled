# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.DeviceFixture do
  @moduledoc false
  # Builders for the device layer's tests: format-2 build entries and
  # manifests, a running device (Device.Env) and a Device.Rules context.

  alias ElixirPrecompiled.Device.Env

  @base_present %{
    kernel: "10.4",
    stdlib: "7.0",
    elixir: "1.20.3",
    logger: "1.20.3",
    crypto: "5.6"
  }

  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    opts = Map.new(opts)

    b =
      %{
        "elixir" => Map.get(opts, :elixir, "1.20.3"),
        "otp" => Map.get(opts, :otp, "29"),
        "dep_env" => "prod",
        "system_version" => Map.get(opts, :system_version),
        "deps" => Map.get(opts, :deps, %{}),
        "compile_env" => Map.get(opts, :compile_env, []),
        "package_checksum" => Map.get(opts, :checksum, "pkgsum"),
        "run_id" => Map.get(opts, :run_id, "r1"),
        "mix_target" => "host"
      }
      |> drop_nil(["elixir", "package_checksum"])
      |> then(fn b ->
        if is_nil(opts[:declared]), do: b, else: Map.put(b, "declared", opts[:declared])
      end)

    %{
      "target" => Map.get(opts, :target, "pure_elixir"),
      "ebin" =>
        opts[:ebin] ||
          [
            %{
              "path" => "ebin/app.app",
              "sha256" => String.duplicate("a", 64),
              "size" => 10,
              "mode" => 420
            }
          ],
      "priv" => opts[:priv] || [],
      "build" => b
    }
  end

  defp drop_nil(map, keys) do
    Enum.reduce(keys, map, fn k, acc -> if is_nil(acc[k]), do: Map.delete(acc, k), else: acc end)
  end

  @spec manifest(%{String.t() => [map()]}) :: map()
  def manifest(versions) do
    %{
      "format" => 2,
      "versions" => Map.new(versions, fn {v, builds} -> {v, %{"builds" => builds}} end)
    }
  end

  @spec env(keyword()) :: Env.t()
  def env(overrides \\ []) do
    {present, rest} = Keyword.pop(overrides, :present, %{})

    present =
      @base_present
      |> Map.merge(present)
      |> Map.new(fn {app, vsn} -> {app, %{vsn: vsn, loaded?: true}} end)

    struct!(
      %Env{
        system: {"nerves_system_rpi4", "2.2.1"},
        otp: "29",
        elixir: "1.20.3",
        cpu: "aarch64-unknown-linux-gnu",
        present: present,
        mounts: []
      },
      rest
    )
  end

  @spec app_spec([atom()], keyword()) :: (map() -> {:ok, keyword()})
  def app_spec(apps, opts \\ []) do
    props = [
      description: ~c"fixture",
      vsn: ~c"1.0.0",
      applications: apps,
      included_applications: Keyword.get(opts, :included, []),
      optional_applications: Keyword.get(opts, :optional, [])
    ]

    fn _build -> {:ok, props} end
  end

  @spec ctx(keyword()) :: map()
  def ctx(overrides \\ []) do
    Map.merge(
      %{
        env: env(),
        app_spec: app_spec([:kernel, :stdlib, :elixir]),
        installed: %{},
        active: %{},
        config: fn _, _ -> :error end,
        pin: nil
      },
      Map.new(overrides)
    )
  end

  @spec elf_header(32 | 64, atom()) :: binary()
  def elf_header(class, machine) do
    {em, ^machine} = Enum.find(ElixirPrecompiled.Device.Elf.machines(), &(elem(&1, 1) == machine))
    class_byte = if class == 64, do: 2, else: 1
    # 16-byte identification, e_type 3 (shared object), e_machine, then
    # zeros to the 64-byte header size.
    <<0x7F, "ELF", class_byte, 1, 1, 0, 0::64, 3::little-16, em::little-16, 0::size(44)-unit(8)>>
  end
end
