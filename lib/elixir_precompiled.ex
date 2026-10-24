# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled do
  @moduledoc """
  Install signed, verified precompiled dependency builds instead of
  compiling them.

  Opt in with `config :elixir_precompiled, source: url`. At build time
  `nerves` calls `run/0` before Mix compiles the dependencies; on a device
  `install/2` wraps `Mix.install/2`. Every candidate dependency prints HIT,
  MISS or FAIL with a reason, and the same list lands in
  `_build/<target>_<env>/lib/.precompiled/report.json`.
  """

  alias ElixirPrecompiled.{Check, Config, Env, Install}

  @doc """
  The build-time step: check every dependency Mix is about to compile and
  install the matching builds. `:disabled` without a source or on the host
  target.
  """
  @spec run(keyword()) :: :disabled | :nothing_to_do | {:ok, Check.report()}
  def run(opts \\ []) do
    config = Config.load()

    cond do
      config == nil ->
        :disabled

      Keyword.get(opts, :host?, Mix.target() == :host) ->
        :disabled

      true ->
        Check.check(
          config,
          Keyword.get_lazy(opts, :env, &Env.MixProject.load/0),
          Keyword.take(opts, [:config_fun])
        )
    end
  end

  @doc """
  `Mix.install/2` with precompiled builds: resolves `deps`, installs every
  matching build into the install project, then calls `Mix.install/2`,
  which compiles only the rest. Takes `Mix.install/2`'s options plus
  `:source`, `:except`, `:root` and `:home` (see `ElixirPrecompiled.Config`);
  without a source, configured or given, it is a plain `Mix.install/2`.

  Needs Mix on the device (`:mix` in `extra_applications`), a writable
  `MIX_INSTALL_DIR`, and Hex.
  """
  @spec install([term()], keyword()) :: :ok
  def install(deps, opts \\ []) when is_list(deps) and is_list(opts) do
    {ours, mix_opts} = Keyword.split(opts, [:source, :except, :root, :home])
    Install.run(deps, mix_opts, Config.load(ours))
  end
end
