# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.DeviceFixture do
  @moduledoc false
  # Builders for the device layer's tests: format-2 build entries and
  # manifests, a running device (Device.Env) and a Device.Rules context.

  alias Precompiled.Device.Env

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

  @doc """
  Compiles a real app with `compile_app/5` into `<dir>/src`, stores its
  files with `Fixture.file/2`, and returns a format-2 `pure_elixir` build
  for it on this VM's Elixir and OTP, with package checksum `sum-<app>`.

  Options:
    * `:deps` - `[app: build]`: each becomes a `build["deps"]` entry and an
      `applications` item of the `.app`;
    * `:apps` - extra `applications` with no deps entry;
    * `:priv` - `[{path, bytes}]` priv files;
    * `:on_load_fails` - adds a `<Camel>.Nif` module whose `-on_load`
      returns `failed`;
    * `:mod` - the `.app`'s `mod`, with `:source` replacing the default
      module source;
    * `:description` - the `.app`'s description (to get distinct bytes).
    * `:included` - dependency apps listed as `included_applications`
      rather than `applications`.
  """
  @spec publish_app(map(), Path.t(), atom(), String.t(), keyword()) :: map()
  def publish_app(fixture, dir, app, vsn, opts \\ []) do
    camel = Macro.camelize(Atom.to_string(app))
    source = opts[:source] || "defmodule #{camel} do\n  def hello, do: :hello\nend\n"
    deps = Keyword.get(opts, :deps, [])

    root =
      compile_app(Path.join(dir, "src"), app, vsn, [source],
        deps: Keyword.keys(deps) ++ Keyword.get(opts, :apps, []),
        mod: opts[:mod]
      )

    if opts[:on_load_fails], do: add_failing_nif(root, app, Module.concat([camel, "Nif"]))

    if opts[:description],
      do: rewrite_app(root, app, &Keyword.put(&1, :description, opts[:description]))

    if included = opts[:included] do
      rewrite_app(root, app, fn props ->
        props
        |> Keyword.update!(:applications, &(&1 -- included))
        |> Keyword.put(:included_applications, included)
      end)
    end

    for {path, bytes} <- Keyword.get(opts, :priv, []) do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
    end

    entries = for e <- files(root), do: %{e | "mode" => 420}

    for e <- entries,
        do: Precompiled.Fixture.file(fixture, File.read!(Path.join(root, e["path"])))

    {ebin, priv} = Enum.split_with(entries, &String.starts_with?(&1["path"], "ebin/"))

    dep_map =
      Map.new(deps, fn {dep, dep_build} ->
        {Atom.to_string(dep),
         %{"version" => app_vsn(dep_build), "checksum" => dep_build["build"]["package_checksum"]}}
      end)

    build(
      elixir: System.version(),
      otp: System.otp_release(),
      checksum: "sum-#{app}",
      deps: dep_map,
      run_id: "r-#{app}-#{vsn}",
      ebin: ebin,
      priv: priv
    )
  end

  defp add_failing_nif(root, app, mod) do
    forms = [
      {:attribute, 1, :module, mod},
      {:attribute, 1, :export, [init: 0]},
      {:attribute, 1, :on_load, {:init, 0}},
      {:function, 1, :init, 0, [{:clause, 1, [], [], [{:atom, 1, :failed}]}]}
    ]

    {:ok, ^mod, bin} = :compile.forms(forms, [:binary])
    File.write!(Path.join([root, "ebin", "#{mod}.beam"]), bin)
    rewrite_app(root, app, &Keyword.update!(&1, :modules, fn mods -> mods ++ [mod] end))
  end

  defp rewrite_app(root, app, fun) do
    path = Path.join([root, "ebin", "#{app}.app"])
    {:ok, [{:application, ^app, props}]} = :file.consult(String.to_charlist(path))
    File.write!(path, :io_lib.format(~c"~p.~n", [{:application, app, fun.(props)}]))
  end

  # The version a build's .app names, read back from the fixture's files.
  defp app_vsn(build) do
    app = Enum.find(build["ebin"], &String.ends_with?(&1["path"], ".app"))
    bytes = Precompiled.Fixture.get(:files)[app["sha256"]]
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(bytes))
    {:ok, {:application, _, props}} = :erl_parse.parse_term(tokens)
    to_string(props[:vsn])
  end

  @doc """
  Publishes `packages` (`%{name => manifest}`) on the fixture and copies
  root.json, batch.json, those manifests and every file their builds name
  out of the fixture into `<dir>/bundle`, in the API layout. Returns the
  bundle dir.

  Options: those of `Fixture.publish/3`, plus `offline: true` to add an
  `offline.json` (`:offline_packages` names what it signs, all of
  `packages` by default; `:offline_sequence`, `:offline_signers`), and
  `:root_env` for the bundle's root.json (the fixture's served root by
  default).
  """
  @spec write_bundle!(map(), Path.t(), map(), keyword()) :: Path.t()
  def write_bundle!(fixture, dir, packages, opts \\ []) do
    alias Precompiled.Fixture

    {own, publish_opts} =
      Keyword.split(opts, [
        :offline,
        :offline_packages,
        :offline_sequence,
        :offline_signers,
        :root_env
      ])

    Fixture.publish(fixture, packages, publish_opts)
    bundle = Path.join(dir, "bundle")
    File.mkdir_p!(Path.join([bundle, "v2", "manifests"]))
    File.mkdir_p!(Path.join(bundle, "files"))
    write_json!(Path.join(bundle, "root.json"), own[:root_env] || Fixture.get(:root))
    write_json!(Path.join(bundle, "batch.json"), Fixture.get(:batch))
    stored = Fixture.get(:manifests_v2)
    files = Fixture.get(:files)

    for {name, manifest} <- packages do
      File.write!(Path.join([bundle, "v2", "manifests", name <> ".json"]), stored[name])

      for {_v, %{"builds" => builds}} <- manifest["versions"],
          b <- builds,
          f <- b["ebin"] ++ b["priv"] do
        File.write!(Path.join([bundle, "files", f["sha256"]]), files[f["sha256"]])
      end
    end

    if own[:offline] do
      names = own[:offline_packages] || Map.keys(packages)
      signed = Map.new(names, &{&1, Fixture.sha(stored[&1])})

      doc =
        Fixture.offline_document(fixture, signed,
          sequence: own[:offline_sequence] || 1,
          signers: own[:offline_signers]
        )

      File.write!(Path.join(bundle, "offline.json"), doc)
    end

    bundle
  end

  defp write_json!(path, term), do: File.write!(path, :json.encode(term))

  @spec elf_header(32 | 64, atom()) :: binary()
  def elf_header(class, machine) do
    {em, ^machine} = Enum.find(Precompiled.Device.Elf.machines(), &(elem(&1, 1) == machine))
    class_byte = if class == 64, do: 2, else: 1
    # 16-byte identification, e_type 3 (shared object), e_machine, then
    # zeros to the 64-byte header size.
    <<0x7F, "ELF", class_byte, 1, 1, 0, 0::64, 3::little-16, em::little-16, 0::size(44)-unit(8)>>
  end
end
