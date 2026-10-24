# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesPrecompiled do
  @moduledoc """
  Install signed, verified precompiled dependency builds instead of
  compiling them.

  Opt in with `config :nerves_precompiled, source: url`. At build time
  `nerves` calls `run/0` before Mix compiles the dependencies; on a device
  `install/2` wraps `Mix.install/2`. Every candidate dependency prints HIT,
  MISS or FAIL with a reason, and the same list lands in
  `_build/<target>_<env>/lib/.precompiled/report.json`.
  """

  alias NervesPrecompiled.{Check, Config, Env}

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
end
