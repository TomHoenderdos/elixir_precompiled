# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Build do
  @moduledoc """
  Step 2: the precompiled step, through a real `mix firmware` of the fixture.

  The target's `_build/<target>_dev` is removed first and the client gets a
  fresh `ELIXIR_PRECOMPILED_HOME`, so every hit is downloaded and verified
  in this run. The client's `report.json` and its batch `state` file are read
  afterwards, and the build's whole output is kept as `log`.

  `:keep_build` (`true` for a conformance case's second, warm build) keeps
  the target's `_build` as the build before left it; every other build
  removes it first.

  A conformance case changes two things, for its own build only: a home its
  setup prepared (`:home_prepared`, taken as it is), and `:client_config`,
  merged into the fixture's `config :elixir_precompiled` through a config
  file the fixture imports from `CHAIN_CLIENT_CONFIG` (written outside the
  home, removed after the build; without a `:client_config` the variable is
  unset, so nothing reaches the next build). And `:client_env`: a few
  environment variables (`client_env_names/0`, the names a client might
  wrongly read a root path from) set for this build; every allowed name
  not given is unset.

  Two more, for the TLS and transport cases only: `:trust_ca` (a CA
  certificate, DER) makes the build VM trust that CA alone, through
  `:public_key.cacerts_load/1` in the same config file, from a PEM beside
  it (removed with it): the client has no CA option and reads only the OS
  store, so this is how a case shows it a TLS mirror it may trust (TLS-T0,
  N6). And `:http_proxy` (an `http://` URL) sets `HTTP_PROXY` to it and
  unsets `HTTPS_PROXY` for the build, so every plain-http request the
  client makes, to any host, reaches that URL (N2). Without them, neither
  the store nor the proxy variables are touched.

  Checks:

    * `home` - only when a caller-given home is not empty: `:fail`, and
      nothing is built.
    * `firmware` - `mix firmware` exited 0 and left a `.fw` image (or
      `compile`, when `:command` is not `["firmware"]`: that `mix` command
      exited 0; no image needed).
    * `hit:<dep>` per expected hit (`expected.exs`): `:pass` on a hit,
      `:refused` when the client's detail starts with a refusal reason,
      `:miss` with the client's detail on a miss (`:fail` when the miss is
      `manifest unavailable: ...` or `malformed entry`), `:fail` on any other
      client fail or a dep the report does not name.
    * `never:<dep>` per dep that must never be installed precompiled: `:fail`
      when the report calls it a hit.
    * `sequence` - the batch sequence the client recorded equals step 1's;
      `:rerun` when production published another batch in between.
  """

  alias ChainTest.{Cmd, Result}

  @timeout_ms 45 * 60 * 1000

  # Plan 1's refusal reasons: the client would have installed, but refused.
  @refusals [
    "batch stale",
    "clock",
    "batch lifetime",
    "batch malformed",
    "batch expired at",
    "batch sequence",
    "batch signature invalid",
    "revoked:"
  ]

  # Variables that would point the fixture build somewhere else, or turn
  # the client off.
  @unset ~w(ELIXIR_PRECOMPILED NERVES_PRECOMPILED NERVES_PRECOMPILED_HOME MIX_BUILD_PATH
            MIX_BUILD_ROOT MIX_DEPS_PATH MIX_EXS MIX_LOCKFILE)

  # T9 pins today's behaviour: the client reads no root path from the
  # environment. These are the names it would use if it did, by its own
  # pattern (`ELIXIR_PRECOMPILED` or the old `NERVES_PRECOMPILED`, plus
  # `_ROOT`), and deliberately nothing else: a case cannot turn the client
  # off or move its home through this.
  @client_env ~w(ELIXIR_PRECOMPILED_ROOT NERVES_PRECOMPILED_ROOT)

  @type client_config :: %{
          optional(:clock_offset_seconds) => integer(),
          optional(:root) => Path.t(),
          optional(:source) => String.t()
        }

  @type input :: %{
          required(:fixture_dir) => Path.t(),
          required(:target) => String.t(),
          required(:source) => String.t(),
          optional(:home) => Path.t(),
          optional(:home_prepared) => boolean(),
          optional(:keep_build) => boolean(),
          optional(:client_config) => client_config() | nil,
          optional(:client_env) => %{String.t() => Path.t()} | nil,
          optional(:trust_ca) => binary() | nil,
          optional(:http_proxy) => String.t() | nil,
          optional(:trust) => ChainTest.Trust.info() | nil,
          optional(:expected) => %{hits: [atom()], never: [atom()]},
          optional(:target_config) => Path.t(),
          optional(:command) => [String.t()],
          optional(:timeout_ms) => pos_integer()
        }

  @type info :: %{
          report: map(),
          build_lib: Path.t(),
          fw_path: Path.t() | nil,
          sequence: integer() | nil,
          log: String.t()
        }

  @doc "The client's refusal reason prefixes."
  @spec refusals() :: [String.t()]
  def refusals(), do: @refusals

  @doc "The variables the fixture build unsets."
  @spec unset_env() :: [String.t()]
  def unset_env(), do: @unset

  @doc "The variables a case may set for its build through `:client_env`."
  @spec client_env_names() :: [String.t()]
  def client_env_names(), do: @client_env

  @doc "Whether `env` maps allowed names (`client_env_names/0`) to absolute paths."
  @spec client_env?(term()) :: boolean()
  def client_env?(env) when is_map(env) do
    Enum.all?(env, fn {name, path} ->
      name in @client_env and is_binary(path) and Path.type(path) == :absolute
    end)
  end

  def client_env?(_), do: false

  @doc "Whether `config` is a `t:client_config/0`: known keys, each with a value of its type."
  @spec client_config?(term()) :: boolean()
  def client_config?(config) when is_map(config),
    do: Enum.all?(config, fn {k, v} -> client_value?(k, v) end)

  def client_config?(_), do: false

  defp client_value?(:clock_offset_seconds, v), do: is_integer(v)
  defp client_value?(:root, v), do: is_binary(v) and Path.type(v) == :absolute
  defp client_value?(:source, v), do: is_binary(v) and v != ""
  defp client_value?(_, _), do: false

  @doc "Whether a client detail is a refusal."
  @spec refusal?(String.t()) :: boolean()
  def refusal?(detail) when is_binary(detail),
    do: Enum.any?(@refusals, &String.starts_with?(detail, &1))

  def refusal?(_), do: false

  @doc """
  Runs step 2. `home` is the client's `ELIXIR_PRECOMPILED_HOME`: a fresh
  temp dir per run when not given, removed after the run, and refused
  (check `home` fails, nothing runs) when given but not empty, unless
  `home_prepared` says the caller prepared it. `trust` is step 1's info
  (`nil` when the batch could not be trusted, which leaves `sequence` not
  exercised); `expected` defaults to the fixture's `expected.exs`.
  `client_config` must satisfy `client_config?/1` (`root` an absolute
  path), and `home_prepared` needs a `home`, else this raises
  `ArgumentError` before anything runs.
  """
  @spec run(input()) :: {[Result.t()], info()}
  def run(%{fixture_dir: fixture, target: target} = input) do
    validate!(input)

    build_lib = Path.join([fixture, "_build", "#{target}_dev", "lib"])

    given = Map.get(input, :home)
    home = if Map.get(input, :home_prepared, false), do: {:ok, given}, else: fresh_home(given)

    case home do
      {:ok, home} ->
        try do
          build(input, home)
        after
          # A home this run made holds only this run's downloads and state.
          if given == nil, do: File.rm_rf(home)
        end

      {:error, why} ->
        expected = Map.get_lazy(input, :expected, fn -> expected(fixture) end)
        skipped = "the client home is not fresh"

        results =
          [
            result("home", :fail, why),
            result(check_name(Map.get(input, :command, ["firmware"])), :not_exercised, skipped)
          ] ++
            Enum.map(expected.hits, &result("hit:#{&1}", :not_exercised, skipped)) ++
            Enum.map(expected.never, &result("never:#{&1}", :not_exercised, skipped)) ++
            [result("sequence", :not_exercised, skipped)]

        {results, %{report: %{}, build_lib: build_lib, fw_path: nil, sequence: nil, log: ""}}
    end
  end

  defp validate!(input) do
    client = Map.get(input, :client_config)

    unless client == nil or client_config?(client),
      do: raise(ArgumentError, "not a client config: #{inspect(client)}")

    env = Map.get(input, :client_env)

    unless env == nil or client_env?(env),
      do: raise(ArgumentError, "not a client env: #{inspect(env)}")

    if Map.get(input, :home_prepared, false) and not is_binary(Map.get(input, :home)),
      do: raise(ArgumentError, "home_prepared: true needs the prepared :home")

    validate_transport!(input)
  end

  defp validate_transport!(input) do
    trust_ca = Map.get(input, :trust_ca)

    unless trust_ca == nil or is_binary(trust_ca),
      do: raise(ArgumentError, "trust_ca must be a DER certificate")

    unless http_proxy?(Map.get(input, :http_proxy)),
      do: raise(ArgumentError, "http_proxy must be an http:// URL")
  end

  # A fresh home per run, so the client's cache, adopted roots and batch
  # state all come from this run: a caller-given one must be empty.
  defp fresh_home(nil) do
    home = Path.join(System.tmp_dir!(), "chain_test-#{random()}")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    {:ok, home}
  end

  defp fresh_home(home) do
    case File.ls(home) do
      {:ok, []} -> {:ok, home}
      {:ok, _} -> {:error, "client home #{home} is not empty; pass an empty dir or none"}
      {:error, :enoent} -> with :ok <- File.mkdir_p(home), do: {:ok, home}
      {:error, why} -> {:error, "client home #{home}: #{:file.format_error(why)}"}
    end
  end

  defp http_proxy?(nil), do: true

  defp http_proxy?(url) when is_binary(url),
    do: match?(%URI{scheme: "http", host: h} when is_binary(h) and h != "", URI.parse(url))

  defp http_proxy?(_), do: false

  defp random(), do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp build(%{fixture_dir: fixture, target: target, source: source} = input, home) do
    build_dir = Path.join([fixture, "_build", "#{target}_dev"])
    build_lib = Path.join(build_dir, "lib")
    expected = Map.get_lazy(input, :expected, fn -> expected(fixture) end)

    # A warm second build (`:keep_build`, R16) starts from what the first
    # one installed; every other build starts clean.
    unless Map.get(input, :keep_build, false), do: File.rm_rf!(build_dir)

    client = client_config_file(Map.get(input, :client_config), Map.get(input, :trust_ca))

    env =
      [
        {"MIX_TARGET", target},
        {"MIX_ENV", "dev"},
        {"ELIXIR_PRECOMPILED_HOME", home},
        {"CHAIN_SOURCE", source},
        {"CHAIN_CLIENT_CONFIG", client}
      ] ++
        target_config(Map.get(input, :target_config)) ++
        Enum.map(@unset, &{&1, nil}) ++
        client_env(Map.get(input, :client_env) || %{}) ++
        proxy_env(Map.get(input, :http_proxy))

    timeout = Map.get(input, :timeout_ms, @timeout_ms)
    command = Map.get(input, :command, ["firmware"])

    {{status, log}, ms} =
      try do
        Result.timed(fn ->
          Cmd.run("mix", command, cd: fixture, env: env, timeout_ms: timeout)
        end)
      after
        if client, do: File.rm_rf(Path.dirname(client))
      end

    fw = fw_path(build_dir)
    report = read_report(build_lib)
    sequence = client_sequence(home)

    results =
      [build_check(command, status, fw, log, ms)] ++
        hits(expected.hits, report, status) ++
        never(expected.never, report) ++
        [sequence_check(Map.get(input, :trust), sequence)]

    {results,
     %{
       report: report || %{},
       build_lib: build_lib,
       fw_path: fw,
       sequence: sequence,
       log: log
     }}
  end

  @doc false
  # The case's client config as a config file in a private temp dir of its
  # own (never the home, whose contents a case judges), values written with
  # inspect/1 so each is an Elixir literal; with `trust_ca`, the CA as
  # `ca.pem` beside it, loaded as the VM's whole store. The caller removes
  # the dir.
  @spec client_config_file(client_config() | nil, binary() | nil) :: Path.t() | nil
  def client_config_file(nil, nil), do: nil

  def client_config_file(config, trust_ca) do
    dir = Path.join(System.tmp_dir!(), "chain_client_config-#{random()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "client.exs")

    trust =
      if trust_ca do
        pem = Path.join(dir, "ca.pem")
        File.write!(pem, ChainTest.TestCert.pem(trust_ca))

        "# The case's TLS mirror CA, the only one this build trusts.\n" <>
          ":ok = :public_key.cacerts_load(#{inspect(pem)})\n"
      else
        ""
      end

    opts =
      (config || %{})
      |> Enum.sort()
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

    File.write!(
      path,
      "# A conformance case's client config, for one build.\nimport Config\n" <>
        trust <> if(opts == "", do: "", else: "config :elixir_precompiled, #{opts}\n")
    )

    path
  end

  defp proxy_env(nil), do: []
  defp proxy_env(url), do: [{"HTTP_PROXY", url}, {"HTTPS_PROXY", nil}]

  # The case's variables, and every other allowed name unset.
  defp client_env(env) do
    Enum.map(@client_env, &{&1, Map.get(env, &1)})
  end

  # The fixture's config/target.exs imports the operator file named here.
  defp target_config(nil), do: []
  defp target_config(path), do: [{"CHAIN_TARGET_CONFIG", path}]

  @doc "The fixture's `expected.exs`."
  @spec expected(Path.t()) :: %{hits: [atom()], never: [atom()]}
  def expected(fixture) do
    {%{hits: hits, never: never}, _} = Code.eval_file(Path.join(fixture, "expected.exs"))
    %{hits: hits, never: never}
  end

  defp fw_path(build_dir) do
    case Path.wildcard(Path.join([build_dir, "nerves", "images", "*.fw"])) do
      [fw | _] -> fw
      [] -> nil
    end
  end

  defp read_report(build_lib) do
    with {:ok, bytes} <- File.read(Path.join([build_lib, ".precompiled", "report.json"])),
         {:ok, %{"lines" => lines} = report} when is_list(lines) <- JSON.decode(bytes) do
      report
    else
      _ -> nil
    end
  end

  # The client keeps one state dir per source and root; the fresh home has
  # one, but the newest wins should a run leave two.
  defp client_sequence(home) do
    home
    |> Path.join("*/state")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> [{mtime, path}]
        _ -> []
      end
    end)
    |> Enum.max_by(fn {mtime, _} -> mtime end, fn -> nil end)
    |> case do
      nil ->
        nil

      {_, path} ->
        case Integer.parse(String.trim(File.read!(path))) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp check_name(["firmware"]), do: "firmware"
  defp check_name(_command), do: "compile"

  defp build_check(["firmware"], status, fw, log, ms), do: firmware(status, fw, log, ms)

  defp build_check(command, 0, _fw, _log, ms),
    do: result("compile", :pass, "mix #{Enum.join(command, " ")} exit 0", ms)

  defp build_check(command, status, _fw, log, ms),
    do:
      result("compile", :fail, "mix #{Enum.join(command, " ")} exit #{status}; " <> tail(log), ms)

  defp firmware(0, fw, _log, ms) when is_binary(fw),
    do: result("firmware", :pass, "mix firmware exit 0, #{fw}", ms)

  defp firmware(0, nil, log, ms),
    do: result("firmware", :fail, "mix firmware exit 0 but no .fw image; " <> tail(log), ms)

  defp firmware(status, _fw, log, ms),
    do: result("firmware", :fail, "mix firmware exit #{status}; " <> tail(log), ms)

  defp tail(log) do
    lines = log |> String.split("\n", trim: true) |> Enum.take(-5)
    "last lines: " <> Enum.join(lines, " | ")
  end

  defp hits(expected, nil, status) do
    why =
      if status == 0,
        do: "the build wrote no report.json",
        else: "the build failed (exit #{status}) before the client wrote report.json"

    class = if status == 0, do: :fail, else: :not_exercised
    Enum.map(expected, &result("hit:#{&1}", class, why))
  end

  defp hits(expected, report, _status) do
    for dep <- expected, do: hit(dep, line(report, dep))
  end

  defp hit(dep, nil), do: result("hit:#{dep}", :fail, "#{dep} not in report.json")

  defp hit(dep, %{"status" => "hit"} = l),
    do: result("hit:#{dep}", :pass, "#{dep} #{l["version"]} hit (#{l["detail"]})")

  defp hit(dep, %{"status" => status, "detail" => detail} = l) do
    check = "hit:#{dep}"

    cond do
      refusal?(detail) ->
        result(check, :refused, detail)

      status == "miss" and broken_miss?(detail) ->
        result(check, :fail, "#{dep} #{l["version"]} miss: #{detail}")

      status == "miss" ->
        result(check, :miss, detail)

      true ->
        result(check, :fail, "#{dep} #{l["version"]} #{status}: #{detail}")
    end
  end

  defp hit(dep, l), do: result("hit:#{dep}", :fail, "malformed report line #{inspect(l)}")

  # A miss that says the portal served something unusable is an error in
  # the chain, not a dep without a build.
  defp broken_miss?(detail) when is_binary(detail),
    do: String.starts_with?(detail, "manifest unavailable:") or detail == "malformed entry"

  defp broken_miss?(_), do: false

  defp never(deps, nil), do: Enum.map(deps, &result("never:#{&1}", :not_exercised, "no report"))

  defp never(deps, report) do
    for dep <- deps do
      case line(report, dep) do
        %{"status" => "hit"} -> result("never:#{dep}", :fail, "#{dep} installed precompiled")
        _ -> result("never:#{dep}", :pass, "#{dep} not installed precompiled")
      end
    end
  end

  defp line(report, dep) do
    name = to_string(dep)
    Enum.find(report["lines"], &(is_map(&1) and &1["name"] == name))
  end

  defp sequence_check(nil, _),
    do: result("sequence", :not_exercised, "step 1 could not trust a batch to compare with")

  defp sequence_check(_trust, nil),
    do: result("sequence", :not_exercised, "the client recorded no batch sequence")

  defp sequence_check(%{sequence: same}, same),
    do: result("sequence", :pass, "the client used batch #{same}, as step 1 verified")

  defp sequence_check(%{sequence: step1}, client),
    do:
      result(
        "sequence",
        :rerun,
        "step 1 verified batch #{step1}, the client used #{client}: production moved; run again"
      )

  defp result(check, class, detail, ms \\ 0),
    do: %Result{step: :build, check: check, class: class, detail: detail, ms: ms}
end
