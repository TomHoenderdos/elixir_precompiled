# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Preflight do
  @moduledoc """
  Step 0: the checks that run before any build and fail within seconds.

    * `ssh` - the device answers `IO.puts(:ok)` with the pinned host key.
    * `portal` - `GET <source>/root.json` answers 200.
    * `toolchain` - `mix archive` lists nerves_bootstrap and fwup is on `PATH`.
    * `fixture_lock` - the fixture's `mix.lock` names every dependency
      `expected.exs` lists (hits and nevers, but for literal path deps,
      which a lock never names) and the target's system.
    * `target_config` - only when the config names one: the operator's
      fixture config file (network, `nerves_ssh` keys) exists, so a target
      build does not stop on it minutes in.
  """

  alias ChainTest.{Cmd, HTTP, Result}

  @timeout_ms 15_000

  @systems %{"rpi4" => "nerves_system_rpi4", "rpi0_2" => "nerves_system_rpi0_2"}

  @type config :: %{
          required(:target) => String.t(),
          required(:device) => String.t(),
          required(:known_hosts) => Path.t(),
          required(:source) => String.t(),
          required(:fixture_dir) => Path.t(),
          optional(:target_config) => Path.t(),
          optional(:timeout_ms) => pos_integer()
        }

  @doc "The time each network check gets."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @doc "The targets the harness supports."
  @spec targets() :: [String.t()]
  def targets, do: Map.keys(@systems) |> Enum.sort(:desc)

  @doc """
  The dependencies the fixture's `mix.lock` must name for `target`: every
  hit and never in `<fixture>/expected.exs`, without the deps the fixture's
  `mix.exs` declares with a literal `path:` (never in a lock), plus the
  target's system. Raises when `expected.exs` cannot be read.
  """
  @spec expected_deps(Path.t(), String.t()) :: [String.t()]
  def expected_deps(fixture_dir, target) do
    {%{hits: hits, never: never}, _} = Code.eval_file(Path.join(fixture_dir, "expected.exs"))
    names = Enum.map(hits ++ never, &to_string/1)
    Enum.uniq(names -- path_deps(fixture_dir)) ++ [Map.fetch!(@systems, target)]
  end

  defp path_deps(fixture_dir) do
    case File.read(Path.join(fixture_dir, "mix.exs")) do
      {:ok, text} ->
        ~r/\{:([a-z0-9_]+),\s*path:\s*"/
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()

      {:error, _} ->
        []
    end
  end

  @doc """
  The ssh options every harness ssh call uses: no prompts, and the pinned
  `known_hosts` file is the only source of host keys. Never `accept-new`.
  """
  @spec ssh_opts(Path.t()) :: [String.t()]
  def ssh_opts(known_hosts) do
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "UserKnownHostsFile=#{known_hosts}",
      "-o",
      "GlobalKnownHostsFile=/dev/null",
      "-o",
      "KnownHostsCommand=none",
      "-o",
      "VerifyHostKeyDNS=no",
      "-o",
      "UpdateHostKeys=no",
      "-o",
      "ConnectTimeout=10"
    ]
  end

  @spec run(config()) :: [Result.t()]
  def run(cfg) do
    base = [ssh(cfg), portal(cfg), toolchain(cfg), fixture_lock(cfg)]
    if Map.has_key?(cfg, :target_config), do: base ++ [target_config(cfg)], else: base
  end

  @doc false
  @spec target_config(config()) :: Result.t()
  def target_config(cfg) do
    check("target_config", fn ->
      path = cfg.target_config

      if File.regular?(path),
        do: {:pass, "#{path} exists"},
        else:
          {:fail,
           "operator file #{path} not found; the fixture's target build needs its network " <>
             "and nerves_ssh authorized_keys config (see integration/chain/README.md)"}
    end)
  end

  @doc false
  @spec ssh(config()) :: Result.t()
  def ssh(cfg) do
    check("ssh", fn ->
      if File.regular?(cfg.known_hosts) do
        argv = ssh_opts(cfg.known_hosts) ++ [cfg.device, "IO.puts(:ok)"]
        cfg |> run_ssh(argv) |> ssh_verdict(cfg)
      else
        {:fail, "known_hosts file #{cfg.known_hosts} not found; pin the device's host key there"}
      end
    end)
  end

  defp run_ssh(cfg, argv), do: Cmd.run("ssh", argv, timeout_ms: timeout(cfg))

  defp ssh_verdict({0, out}, cfg) do
    if out |> String.split(~r/\r?\n/) |> Enum.any?(&(String.trim(&1) == "ok")),
      do: {:pass, "#{cfg.device} answered with the pinned host key"},
      else: {:fail, "#{cfg.device} did not answer ok: #{Cmd.tail(out)}"}
  end

  defp ssh_verdict({124, out}, cfg),
    do:
      {:fail,
       "#{cfg.device} did not answer within #{timeout(cfg)} ms [timeout]: #{Cmd.tail(out)}"}

  defp ssh_verdict({status, out}, cfg) do
    if out =~ ~r/host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED/i do
      {:fail,
       "host key changed or not pinned: #{cfg.device}'s host key does not match " <>
         "#{cfg.known_hosts} (re-flashed card or a different device?). " <>
         "Update the pinned key by hand; the harness never accepts a new key. ssh: #{Cmd.tail(out)}"}
    else
      {:fail, "ssh to #{cfg.device} exited #{status}: #{Cmd.tail(out)}"}
    end
  end

  @doc false
  @spec portal(config()) :: Result.t()
  def portal(cfg) do
    check("portal", fn ->
      url = String.trim_trailing(cfg.source, "/") <> "/root.json"

      case HTTP.get(url, timeout(cfg)) do
        {:ok, _body} -> {:pass, "GET #{url} 200"}
        {:error, reason} -> {:fail, reason}
      end
    end)
  end

  @doc false
  @spec toolchain(config()) :: Result.t()
  def toolchain(_cfg) do
    check("toolchain", fn ->
      {status, out} = Cmd.run("mix", ["archive"], timeout_ms: 30_000)

      problems =
        Enum.reject(
          [
            unless(status == 0 and out =~ ~r/\bnerves_bootstrap-/,
              do:
                "mix archive does not list nerves_bootstrap (mix archive.install hex nerves_bootstrap)"
            ),
            unless(System.find_executable("fwup"), do: "fwup is not on PATH")
          ],
          &is_nil/1
        )

      case problems do
        [] -> {:pass, "nerves_bootstrap installed, fwup at #{System.find_executable("fwup")}"}
        _ -> {:fail, Enum.join(problems, "; ")}
      end
    end)
  end

  @doc false
  @spec fixture_lock(config()) :: Result.t()
  def fixture_lock(cfg) do
    check("fixture_lock", fn ->
      lock = Path.join(cfg.fixture_dir, "mix.lock")

      with {:ok, expected} <- expected_or_error(cfg),
           {:ok, text} <- File.read(lock) do
        names = Regex.scan(~r/^\s*"([a-z0-9_]+)":/m, text, capture: :all_but_first)
        names = MapSet.new(List.flatten(names))

        case Enum.reject(expected, &MapSet.member?(names, &1)) do
          [] -> {:pass, "#{lock} names every expected dependency"}
          missing -> {:fail, "#{lock} does not name: #{Enum.join(missing, ", ")}"}
        end
      else
        {:expected, why} -> {:fail, why}
        {:error, reason} -> {:fail, "#{lock}: #{:file.format_error(reason)}"}
      end
    end)
  end

  defp expected_or_error(cfg) do
    {:ok, expected_deps(cfg.fixture_dir, cfg.target)}
  rescue
    e ->
      {:expected,
       "#{Path.join(cfg.fixture_dir, "expected.exs")} unreadable: #{Exception.message(e)}"}
  end

  defp check(name, fun) do
    {{class, detail}, ms} = Result.timed(fun)
    %Result{step: :preflight, check: name, class: class, detail: detail, ms: ms}
  end

  defp timeout(cfg), do: Map.get(cfg, :timeout_ms, @timeout_ms)
end
