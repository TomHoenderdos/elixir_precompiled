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

  @doc """
  Writes a real app into `<dir>/<app>-<vsn>`: one beam per module the
  sources define and an `ebin/<app>.app`. Returns the app dir.

  Each source is compiled with `Code.compile_string/1` and its modules are
  purged from this VM again. A source that defines a module this VM
  already has (or could load, such as `Logger`) is never compiled here:
  that would replace and then purge the VM's own module. Its modules are
  built as empty Erlang modules with `:compile.forms/2`, which loads
  nothing.

  Options: `:deps` (extra `applications`), `:env`, `:mod`.
  """
  @spec compile_app(Path.t(), atom(), String.t(), [String.t()], keyword()) :: Path.t()
  def compile_app(dir, app, vsn, sources, opts \\ []) do
    root = Path.join(dir, "#{app}-#{vsn}")
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)

    modules =
      for source <- sources, {mod, bin} <- compile_source(source) do
        File.write!(Path.join(ebin, "#{mod}.beam"), bin)
        mod
      end

    props =
      [
        description: String.to_charlist("#{app}"),
        vsn: String.to_charlist(vsn),
        modules: modules,
        registered: [],
        applications: [:kernel, :stdlib, :elixir] ++ Keyword.get(opts, :deps, []),
        env: Keyword.get(opts, :env, [])
      ] ++ if(opts[:mod], do: [mod: opts[:mod]], else: [])

    File.write!(
      Path.join(ebin, "#{app}.app"),
      :io_lib.format(~c"~p.~n", [{:application, app, props}])
    )

    root
  end

  defp compile_source(source) do
    names = source |> Code.string_to_quoted!() |> defined_modules()

    if Enum.any?(names, &known_module?/1) do
      Enum.map(names, &empty_module/1)
    else
      fresh_compile(source)
    end
  end

  defp defined_modules({:__block__, _, forms}), do: Enum.flat_map(forms, &defined_modules/1)
  defp defined_modules({:defmodule, _, [name | _]}), do: [module_name(name)]
  defp defined_modules(_), do: []

  defp module_name({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_name(atom) when is_atom(atom), do: atom

  defp known_module?(mod), do: :code.is_loaded(mod) != false or :code.which(mod) != :non_existing

  defp empty_module(mod) do
    forms = [{:attribute, 1, :module, mod}, {:attribute, 1, :export, []}]
    {:ok, ^mod, bin} = :compile.forms(forms, [:binary])
    {mod, bin}
  end

  defp fresh_compile(source) do
    # A test impl of a protocol this VM consolidated would warn here.
    previous = Code.get_compiler_option(:ignore_already_consolidated)
    Code.put_compiler_option(:ignore_already_consolidated, true)

    try do
      compiled = Code.compile_string(source)
      for {mod, _} <- compiled, do: purge(mod)
      compiled
    after
      Code.put_compiler_option(:ignore_already_consolidated, previous)
    end
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  @doc """
  The file list of an app dir in manifest form (`path`, `sha256`, `size`,
  `mode`), as the loader's `files:` option takes it.
  """
  @spec files(Path.t()) :: [map()]
  def files(root) do
    for file <- Path.wildcard(Path.join(root, "{ebin,priv}/**"), match_dot: true),
        File.regular?(file) do
      bytes = File.read!(file)

      %{
        "path" => Path.relative_to(file, root),
        "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        "size" => byte_size(bytes),
        "mode" => File.stat!(file).mode
      }
    end
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
