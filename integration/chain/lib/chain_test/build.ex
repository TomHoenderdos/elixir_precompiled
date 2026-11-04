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
  afterwards.

  Checks:

    * `home` - only when a caller-given home is not empty: `:fail`, and
      nothing is built.
    * `firmware` - `mix firmware` exited 0 and left a `.fw` image.
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

  @type input :: %{
          required(:fixture_dir) => Path.t(),
          required(:target) => String.t(),
          required(:source) => String.t(),
          optional(:home) => Path.t(),
          optional(:trust) => ChainTest.Trust.info() | nil,
          optional(:expected) => %{hits: [atom()], never: [atom()]},
          optional(:target_config) => Path.t(),
          optional(:timeout_ms) => pos_integer()
        }

  @type info :: %{
          report: map(),
          build_lib: Path.t(),
          fw_path: Path.t() | nil,
          sequence: integer() | nil
        }

  @doc "The client's refusal reason prefixes."
  @spec refusals() :: [String.t()]
  def refusals(), do: @refusals

  @doc "Whether a client detail is a refusal."
  @spec refusal?(String.t()) :: boolean()
  def refusal?(detail) when is_binary(detail),
    do: Enum.any?(@refusals, &String.starts_with?(detail, &1))

  def refusal?(_), do: false

  @doc """
  Runs step 2. `home` is the client's `ELIXIR_PRECOMPILED_HOME`: a fresh
  temp dir per run when not given, removed after the run, and refused
  (check `home` fails, nothing runs) when given but not empty. `trust` is step 1's info (`nil` when the batch could not be
  trusted, which leaves `sequence` not exercised); `expected` defaults to
  the fixture's `expected.exs`.
  """
  @spec run(input()) :: {[Result.t()], info()}
  def run(%{fixture_dir: fixture, target: target} = input) do
    build_lib = Path.join([fixture, "_build", "#{target}_dev", "lib"])

    given = Map.get(input, :home)

    case fresh_home(given) do
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
          [result("home", :fail, why), result("firmware", :not_exercised, skipped)] ++
            Enum.map(expected.hits, &result("hit:#{&1}", :not_exercised, skipped)) ++
            Enum.map(expected.never, &result("never:#{&1}", :not_exercised, skipped)) ++
            [result("sequence", :not_exercised, skipped)]

        {results, %{report: %{}, build_lib: build_lib, fw_path: nil, sequence: nil}}
    end
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

  defp random(), do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp build(%{fixture_dir: fixture, target: target, source: source} = input, home) do
    build_dir = Path.join([fixture, "_build", "#{target}_dev"])
    build_lib = Path.join(build_dir, "lib")
    expected = Map.get_lazy(input, :expected, fn -> expected(fixture) end)

    File.rm_rf!(build_dir)

    env =
      [
        {"MIX_TARGET", target},
        {"MIX_ENV", "dev"},
        {"ELIXIR_PRECOMPILED_HOME", home},
        {"CHAIN_SOURCE", source}
      ] ++
        target_config(Map.get(input, :target_config)) ++ Enum.map(@unset, &{&1, nil})

    timeout = Map.get(input, :timeout_ms, @timeout_ms)

    {{status, log}, ms} =
      Result.timed(fn ->
        Cmd.run("mix", ["firmware"], cd: fixture, env: env, timeout_ms: timeout)
      end)

    fw = fw_path(build_dir)
    report = read_report(build_lib)
    sequence = client_sequence(home)

    results =
      [firmware(status, fw, log, ms)] ++
        hits(expected.hits, report, status) ++
        never(expected.never, report) ++
        [sequence_check(Map.get(input, :trust), sequence)]

    {results,
     %{
       report: report || %{},
       build_lib: build_lib,
       fw_path: fw,
       sequence: sequence
     }}
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
    for dep <- expected do
      check = "hit:#{dep}"

      case line(report, dep) do
        nil ->
          result(check, :fail, "#{dep} not in report.json")

        %{"status" => "hit"} = l ->
          result(check, :pass, "#{dep} #{l["version"]} hit (#{l["detail"]})")

        %{"status" => status, "detail" => detail} = l ->
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

        l ->
          result(check, :fail, "malformed report line #{inspect(l)}")
      end
    end
  end

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
