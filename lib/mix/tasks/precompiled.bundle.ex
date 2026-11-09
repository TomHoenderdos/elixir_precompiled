# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.Bundle do
  @shortdoc "Writes an offline bundle of precompiled builds for a device"

  @moduledoc """
  Writes a bundle a device installs from with no network:
  `Precompiled.install(:recon, source: "file:///media/usb/precompiled")`.
  It plans on this host exactly as the device would, from the device's
  facts, and copies only what that plan needs.

      mix precompiled.bundle PKG[@REQ]... --out DIR (--system NAME@VSN | --pure) \\
        --otp N --elixir V [--cpu C] [--source URL] [--root FILE]
      mix precompiled.bundle PKG[@REQ]... --out DIR --device-report FILE \\
        [--source URL] [--root FILE]

  `DIR` (new, or empty) gets the API's own layout:

    * `root.json` - the root the batch verified under: the source's served
      root when it chains from the trusted one, else the trusted root
      itself (`--root`, or the root this library ships);
    * `batch.json` - the signed batch, byte for byte as verified;
    * `v2/manifests/<pkg>.json` - for each planned package, the exact bytes
      the batch's hash names (`manifests/<pkg>.json` for a format-1 one);
    * `files/<sha256>` - every file of every planned build.

  Every byte is checked against its signed hash before it is written, and
  the bundle appears in `DIR` only once all of it has been. No key, and
  nothing that is not in the plan, is ever written.

  The device facts come from the flags: `--system` (or `--pure` for a
  device with no Nerves system, which takes `pure_elixir` builds only),
  `--otp`, `--elixir` and `--cpu` (default `aarch64-unknown-linux-gnu`),
  with `kernel`, `stdlib`, `elixir`, `logger` and `crypto` present. Or they
  come from `--device-report FILE`, the JSON that
  `Precompiled.install(..., dry_run: true, report: path)` writes on the
  device: its system, OTP, Elixir, CPU and present apps, so the bundle
  holds what that device would fetch. With it, `--system`, `--pure`,
  `--otp`, `--elixir` and `--cpu` are ignored. Apps the device has, by
  name and exact version, are not bundled. The device checks everything
  again when it installs.

  `--source` is the API root (default the official one) and `--root` the
  trust anchor (default the shipped `root.json`).

  A bundle's `batch.json` expires 24 hours after it was issued. For a
  device that stays offline longer, the holder of the root's `offline` key
  signs the bundle with `mix portal.precompiled.sign_offline`, within a day
  of the batch's issue, passing the current production `root.json` as
  `--root`: the bundle's `root.json` must be that root.
  """
  use Mix.Task

  alias ElixirPrecompiled.Device.Env
  alias ElixirPrecompiled.Device.Output
  alias ElixirPrecompiled.Device.Plan
  alias ElixirPrecompiled.Device.Source
  alias ElixirPrecompiled.Fetch
  alias ElixirPrecompiled.Trust

  @switches [
    out: :string,
    system: :string,
    pure: :boolean,
    otp: :string,
    elixir: :string,
    cpu: :string,
    device_report: :string,
    source: :string,
    root: :string
  ]
  @env_flags [:system, :pure, :otp, :elixir, :cpu]
  @default_cpu "aarch64-unknown-linux-gnu"
  @base_apps [:kernel, :stdlib, :elixir, :logger, :crypto]
  @package ~r/\A[a-z][a-z0-9_]*\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  @manifest_paths ["v2/manifests", "manifests"]
  @max_manifest_bytes 67_108_864
  @max_report_bytes 1_048_576
  @max_closure 25

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, requests} = parse!(args)
    out = Path.expand(opts[:out])
    check_out!(out)
    {env, report_present} = device!(opts)
    {:ok, _} = Application.ensure_all_started(:crypto)
    tmp = tmp_dir!()

    try do
      config = config!(opts, tmp)
      %{root: root_bytes, batch: batch_bytes, batch_map: batch} = trust!(config)
      config = Source.with_batch(config, batch)
      plan = plan!(requests, env, report_present, config, batch)
      written = write_bundle!(out, root_bytes, batch_bytes, plan, config)
      report(out, plan, written, batch_bytes)
    after
      File.rm_rf(tmp)
    end
  end

  ## Arguments

  defp parse!(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [],
      do: Mix.raise("precompiled.bundle: unknown option #{invalid |> hd() |> elem(0)}")

    if opts[:out] in [nil, ""], do: Mix.raise("precompiled.bundle: --out DIR is required")
    if rest == [], do: Mix.raise("precompiled.bundle: name at least one package")
    {opts, Enum.map(rest, &request!/1)}
  end

  defp request!(arg) do
    {name, req} =
      case String.split(arg, "@", parts: 2) do
        [name] -> {name, nil}
        [name, req] -> {name, req}
      end

    cond do
      not (name =~ @package) ->
        Mix.raise("precompiled.bundle: #{arg} is not a package name")

      req != nil and not requirement?(req) ->
        Mix.raise("precompiled.bundle: #{arg}: not a version or requirement")

      true ->
        # An operator's package name, checked against the Hex name rule
        # above; never manifest or device input.
        {String.to_atom(name), req}
    end
  end

  defp requirement?(req),
    do: match?({:ok, _}, Version.parse(req)) or match?({:ok, _}, Version.parse_requirement(req))

  defp check_out!(out) do
    case File.ls(out) do
      {:ok, []} -> :ok
      {:ok, _} -> Mix.raise("precompiled.bundle: #{out} is not empty; give a new directory")
      {:error, :enoent} -> :ok
      {:error, why} -> Mix.raise("precompiled.bundle: #{out}: #{:file.format_error(why)}")
    end
  end

  ## The device

  # {env, nil} from the flags, or {env, report's present apps} from a
  # device report: names whose atom does not exist yet are matched again
  # once planning has made them exist (see plan!/5).
  defp device!(opts) do
    case opts[:device_report] do
      nil -> {flags_env!(opts), nil}
      path -> report_env!(path, opts)
    end
  end

  defp flags_env!(opts) do
    system = system!(opts[:system], opts[:pure])
    otp = opts[:otp] || Mix.raise("precompiled.bundle: --otp N is required")
    elixir = opts[:elixir] || Mix.raise("precompiled.bundle: --elixir V is required")

    present =
      Map.new(@base_apps, fn
        app when app in [:elixir, :logger] -> {app, %{vsn: elixir, loaded?: true}}
        app -> {app, %{vsn: host_vsn(app), loaded?: true}}
      end)

    %Env{
      system: system,
      otp: otp,
      elixir: elixir,
      cpu: opts[:cpu] || @default_cpu,
      present: present,
      mounts: []
    }
  end

  defp system!(nil, true), do: nil

  defp system!(system, pure) when is_binary(system) and pure != true do
    case String.split(system, "@", parts: 2) do
      [name, vsn] when name != "" and vsn != "" -> {name, vsn}
      _ -> Mix.raise("precompiled.bundle: --system takes NAME@VSN, got #{system}")
    end
  end

  defp system!(_, _), do: Mix.raise("precompiled.bundle: give one of --system NAME@VSN or --pure")

  defp host_vsn(app) do
    _ = Application.load(app)
    to_string(Application.spec(app, :vsn) || "0.0.0")
  end

  defp report_env!(path, opts) do
    ignored = for k <- @env_flags, Keyword.has_key?(opts, k), do: "--#{k}"

    if ignored != [] do
      Mix.shell().info(
        "precompiled.bundle: #{Enum.join(ignored, ", ")} ignored: the device report decides"
      )
    end

    with {:ok, body} <- read_report(path),
         {:ok, %{"env" => env}} <- decode(body),
         {:ok, %Env{} = parsed} <- report_fields(env) do
      {%Env{parsed | present: present_atoms(parsed.present)}, parsed.present}
    else
      {:error, why} -> Mix.raise("precompiled.bundle: device report #{path}: #{why}")
      _ -> Mix.raise("precompiled.bundle: device report #{path}: not a device report")
    end
  end

  defp read_report(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_report_bytes ->
        with {:error, why} <- File.read(path), do: {:error, :file.format_error(why)}

      {:ok, _} ->
        {:error, "not a regular file of at most #{@max_report_bytes} bytes"}

      {:error, why} ->
        {:error, :file.format_error(why)}
    end
  end

  defp decode(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> {:error, "not JSON"}
  end

  defp report_fields(%{"otp" => otp, "elixir" => elixir, "cpu" => cpu, "present" => present} = e)
       when is_binary(otp) and is_binary(elixir) and is_binary(cpu) and is_map(present) do
    with {:ok, system} <- report_system(e["system"]),
         true <- Enum.all?(present, &present_item?/1) || {:error, "malformed present apps"} do
      {:ok,
       %Env{
         system: system,
         platform: string_or_nil(e["platform"]),
         arch: string_or_nil(e["arch"]),
         otp: otp,
         elixir: elixir,
         cpu: cpu,
         present: present,
         mounts: []
       }}
    end
  end

  defp report_fields(_), do: {:error, "not a device report"}

  defp report_system(%{"name" => n, "version" => v}) when is_binary(n) and is_binary(v),
    do: {:ok, {n, v}}

  defp report_system(none) when none in [nil, :null], do: {:ok, nil}
  defp report_system(_), do: {:error, "malformed system"}

  defp present_item?({name, vsn}), do: is_binary(name) and is_binary(vsn) and name =~ @package

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil

  # The report's present apps whose atom exists. Device input never makes
  # an atom; an app's atom exists once a .app that names it was read.
  defp present_atoms(present) do
    for {name, vsn} <- present, atom = existing_atom(name), atom != nil, into: %{} do
      {atom, %{vsn: vsn, loaded?: false}}
    end
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  ## Trust: the root and the batch, recorded byte for byte

  defp tmp_dir!() do
    dir = Path.join(System.tmp_dir!(), "precompiled-bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # No device store and no /data on a host: the trust state of this one
  # run lives in a temp dir, so nothing earlier can stand in for the source.
  # A bundle may be large, so the run gets half an hour.
  defp config!(opts, tmp) do
    source_opts =
      [home: Path.join(tmp, "trust"), dir: Path.join(tmp, "store"), deadline_seconds: 1800] ++
        Keyword.take(opts, [:source, :root])

    case Source.config(source_opts) do
      {:ok, config} -> config
      {:error, why} -> Mix.raise("precompiled.bundle: #{inspect(why)}")
    end
  end

  defp trust!(config) do
    with {:ok, root} <- Trust.load_root(config),
         served = record(:root, &Fetch.get_body(&1, Fetch.metadata_opts(config))),
         {:ok, root_in_use} <- Trust.update_root(config, root, served),
         fetch = record(:batch, &Fetch.get_conditional(config, &1, &2)),
         {:ok, batch} <- Trust.fetch_batch_cached(config, root_in_use, fetch),
         {:ok, batch_bytes} <- recorded(:batch) do
      %{root: root_bytes!(config, root, root_in_use), batch: batch_bytes, batch_map: batch}
    else
      {:error, why} -> Mix.raise("precompiled.bundle: batch: #{why}")
    end
  end

  # Wraps a fetch so the bytes Trust verifies are the bytes the bundle
  # holds: whatever it returned last is kept in this process.
  defp record(:root, fetch) do
    fn url ->
      result = fetch.(url)
      with {:ok, body} <- result, do: Process.put({__MODULE__, :root}, body)
      result
    end
  end

  defp record(:batch, fetch) do
    fn url, etag ->
      result = fetch.(url, etag)
      with {:ok, body, _etag} <- result, do: Process.put({__MODULE__, :batch}, body)
      result
    end
  end

  defp recorded(key) do
    case Process.delete({__MODULE__, key}) do
      nil -> {:error, "no #{key} was read"}
      body -> {:ok, body}
    end
  end

  # The served root when Trust adopted it (newer, chained); else the trusted
  # root file itself, which the batch then verified under.
  defp root_bytes!(config, trusted, in_use) do
    served = recorded(:root)

    if in_use != trusted,
      do: elem(served, 1),
      else: File.read!(config.root_path)
  end

  ## The plan

  defp plan!(requests, env, report_present, config, batch) do
    for {app, _} <- requests, info = env.present[app], info != nil do
      Mix.raise("precompiled.bundle: #{app} #{info.vsn} is already on the device")
    end

    memo = :ets.new(__MODULE__, [:set, :private])

    try do
      plan_stable(requests, env, report_present, config, batch, memo)
    after
      :ets.delete(memo)
    end
  end

  # Planning reads each candidate's .app, which makes the atoms of the apps
  # it names. A report's present app whose atom did not exist before is
  # matched now, and the plan made again until the present apps stop
  # growing: the result is the plan the device, which has those atoms,
  # makes.
  defp plan_stable(requests, env, report_present, config, batch, memo) do
    ctx = %{
      env: env,
      app_spec: Source.app_spec_fun(config, memo: memo, budget: 4 * @max_closure),
      installed: %{},
      active: %{},
      # The device's application env is not known here: compile_env items
      # of present apps are left to the device (nothing counts as loaded),
      # and an app that is neither present nor planned has none set.
      config: fn _app, _path -> :error end,
      loaded: [],
      pin: nil
    }

    opts = [
      manifest: Source.manifest_fun(config, batch),
      closure: true,
      max_closure: @max_closure
    ]

    result = Plan.build(requests, ctx, opts)
    grown = if report_present, do: present_atoms(report_present), else: env.present

    cond do
      map_size(grown) > map_size(env.present) ->
        plan_stable(requests, %{env | present: grown}, report_present, config, batch, memo)

      match?({:ok, _}, result) ->
        elem(result, 1)

      true ->
        Mix.raise("precompiled.bundle: " <> refusal(elem(result, 1)))
    end
  end

  defp refusal({:no_build, pkg, why}), do: "#{pkg}: #{why}"
  defp refusal({:needs, needs}), do: "needs #{inspect(needs)}"
  defp refusal(other), do: inspect(other)

  ## Writing

  defp write_bundle!(out, root_bytes, batch_bytes, plan, config) do
    staging = "#{out}.partial-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(staging, "files"))

    try do
      write!(staging, "root.json", root_bytes)
      write!(staging, "batch.json", batch_bytes)
      manifests = for i <- plan.installs, do: manifest!(staging, i, config)
      files = files!(staging, plan.installs, config)
      move!(staging, out)
      %{manifests: manifests, files: files}
    after
      File.rm_rf(staging)
    end
  end

  defp write!(dir, rel, bytes) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    byte_size(bytes)
  end

  # The bytes whose sha256 the batch names for this package: by its hash
  # where the source has by-sha paths, else by its name; any other bytes
  # are refused.
  defp manifest!(staging, %{app: app, manifest: %{sha: sha, path: path}}, config) do
    name = Atom.to_string(app)

    if path not in @manifest_paths or not (name =~ @package) or not (sha =~ @sha),
      do: Mix.raise("precompiled.bundle: #{name}: unexpected manifest reference")

    by_sha =
      if config.by_sha,
        do: for(o <- config.content ++ [config.source], do: "#{o}/#{path}/by-sha/#{sha}.json"),
        else: []

    urls = by_sha ++ ["#{config.source}/#{path}/#{name}.json"]
    opts = [max_bytes: @max_manifest_bytes] ++ Fetch.content_opts(config)

    case first_verified(urls, opts, sha, nil) do
      {:ok, bytes} -> write!(staging, "#{path}/#{name}.json", bytes)
      {:fail, why} -> Mix.raise("precompiled.bundle: manifest #{name}: #{why}")
    end
  end

  defp files!(staging, installs, config) do
    installs
    |> Enum.flat_map(&((&1.build["ebin"] || []) ++ (&1.build["priv"] || [])))
    |> Enum.uniq_by(& &1["sha256"])
    |> Enum.map(&file!(staging, &1, config))
  end

  defp file!(staging, %{"sha256" => sha, "size" => size, "path" => rel}, config)
       when is_binary(sha) and is_integer(size) and size >= 0 do
    if not (sha =~ @sha), do: Mix.raise("precompiled.bundle: #{rel}: malformed sha256")
    urls = for o <- config.content ++ [config.source], do: "#{o}/files/#{sha}"
    opts = [max_bytes: size] ++ Fetch.content_opts(config)

    case first_verified(urls, opts, sha, size) do
      {:ok, bytes} -> write!(staging, "files/#{sha}", bytes)
      {:fail, why} -> Mix.raise("precompiled.bundle: #{rel}: #{why}")
    end
  end

  defp file!(_staging, entry, _config),
    do: Mix.raise("precompiled.bundle: malformed file entry #{inspect(entry)}")

  defp first_verified(urls, opts, sha, size) do
    Enum.reduce_while(urls, {:fail, "not available"}, fn url, _ ->
      with {:ok, bytes} <- Fetch.get_body(url, opts),
           :ok <- verify(bytes, sha, size) do
        {:halt, {:ok, bytes}}
      else
        {:fail, why} -> {:cont, {:fail, why}}
        {:error, why} -> {:cont, {:fail, "not available: #{why}"}}
      end
    end)
  end

  defp verify(bytes, sha, size) do
    cond do
      size != nil and byte_size(bytes) != size ->
        {:fail, "size mismatch"}

      Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) != sha ->
        {:fail, "sha256 mismatch"}

      true ->
        :ok
    end
  end

  defp move!(staging, out) do
    # check_out!/1 allowed only a missing or empty out.
    _ = File.rmdir(out)
    File.mkdir_p!(Path.dirname(out))

    case File.rename(staging, out) do
      :ok -> :ok
      {:error, why} -> Mix.raise("precompiled.bundle: #{out}: #{:file.format_error(why)}")
    end
  end

  ## Report

  defp report(out, plan, written, batch_bytes) do
    bytes = Enum.sum(written.manifests) + Enum.sum(written.files)

    Mix.shell().info(
      "bundle: #{length(plan.installs)} packages, #{length(written.files)} files, " <>
        "#{Output.kb(bytes)} in #{out}"
    )

    Mix.shell().info(
      "To use it beyond the batch's expiry (#{expires(batch_bytes)}), sign it: " <>
        "mix portal.precompiled.sign_offline --bundle #{out} --key <offline key> " <>
        "--root <current root.json>"
    )

    :ok
  end

  # From the batch Trust already verified.
  defp expires(batch_bytes) do
    with {:ok, %{"payload" => p}} <- decode(batch_bytes),
         {:ok, payload} <- b64(p),
         {:ok, %{"expires" => e}} when is_binary(e) <- decode(payload) do
      e
    else
      _ -> "unknown"
    end
  end

  defp b64(p) when is_binary(p) do
    Enum.find_value(
      [&Base.url_decode64(&1, padding: false), &Base.decode64(&1, padding: false)],
      :error,
      fn dec ->
        case dec.(p) do
          {:ok, bin} -> {:ok, bin}
          :error -> nil
        end
      end
    )
  end

  defp b64(_), do: :error
end
