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
    * `fixture_lock` - the fixture's `mix.lock` names every expected dependency.
  """

  alias ChainTest.{Cmd, Result}

  @timeout_ms 15_000

  # Path deps (nerves, elixir_precompiled) never appear in a mix.lock.
  @fixture_deps ~w(exqlite argon2_elixir circuits_gpio jason ash nerves_pack nerves_ssh)
  @systems %{"rpi4" => "nerves_system_rpi4", "rpi0_2" => "nerves_system_rpi0_2"}

  @type config :: %{
          required(:target) => String.t(),
          required(:device) => String.t(),
          required(:known_hosts) => Path.t(),
          required(:source) => String.t(),
          required(:fixture_dir) => Path.t(),
          optional(:timeout_ms) => pos_integer()
        }

  @doc "The time each network check gets."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @doc "The targets the harness supports."
  @spec targets() :: [String.t()]
  def targets, do: Map.keys(@systems) |> Enum.sort(:desc)

  @doc "The dependencies the fixture's `mix.lock` must name for `target`."
  @spec expected_deps(String.t()) :: [String.t()]
  def expected_deps(target), do: @fixture_deps ++ [Map.fetch!(@systems, target)]

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
      "ConnectTimeout=10"
    ]
  end

  @spec run(config()) :: [Result.t()]
  def run(cfg), do: [ssh(cfg), portal(cfg), toolchain(cfg), fixture_lock(cfg)]

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
      else: {:fail, "#{cfg.device} did not answer ok: #{tail(out)}"}
  end

  defp ssh_verdict({124, out}, cfg),
    do: {:fail, "#{cfg.device} did not answer within #{timeout(cfg)} ms [timeout]: #{tail(out)}"}

  defp ssh_verdict({status, out}, cfg) do
    if out =~ ~r/host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED/i do
      {:fail,
       "host key changed or not pinned: #{cfg.device}'s host key does not match " <>
         "#{cfg.known_hosts} (re-flashed card or a different device?). " <>
         "Update the pinned key by hand; the harness never accepts a new key. ssh: #{tail(out)}"}
    else
      {:fail, "ssh to #{cfg.device} exited #{status}: #{tail(out)}"}
    end
  end

  @doc false
  @spec portal(config()) :: Result.t()
  def portal(cfg) do
    check("portal", fn ->
      url = String.trim_trailing(cfg.source, "/") <> "/root.json"
      t = timeout(cfg)
      http_opts = [timeout: t, connect_timeout: t] ++ ssl_opts(url)

      case :httpc.request(:get, {to_charlist(url), []}, http_opts, body_format: :binary) do
        {:ok, {{_, 200, _}, _, _}} -> {:pass, "GET #{url} 200"}
        {:ok, {{_, status, _}, _, _}} -> {:fail, "GET #{url} answered #{status}"}
        {:error, reason} -> {:fail, "GET #{url} failed: #{inspect(reason)}"}
      end
    end)
  end

  defp ssl_opts("https://" <> _) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp ssl_opts(_), do: []

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

      case File.read(lock) do
        {:ok, text} ->
          names = Regex.scan(~r/^\s*"([a-z0-9_]+)":/m, text, capture: :all_but_first)
          names = MapSet.new(List.flatten(names))

          case Enum.reject(expected_deps(cfg.target), &MapSet.member?(names, &1)) do
            [] -> {:pass, "#{lock} names every expected dependency"}
            missing -> {:fail, "#{lock} does not name: #{Enum.join(missing, ", ")}"}
          end

        {:error, reason} ->
          {:fail, "#{lock}: #{:file.format_error(reason)}"}
      end
    end)
  end

  defp check(name, fun) do
    {{class, detail}, ms} = Result.timed(fun)
    %Result{step: :preflight, check: name, class: class, detail: detail, ms: ms}
  end

  defp timeout(cfg), do: Map.get(cfg, :timeout_ms, @timeout_ms)

  defp tail(out) do
    out
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.take(-5)
    |> Enum.join(" / ")
  end
end
