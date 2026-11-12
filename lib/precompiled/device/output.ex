# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Output do
  @moduledoc false
  # The lines Precompiled prints, shaped like the host's: one per package
  # and step, then a summary. IO.puts/1 only, never Mix's shell, so the
  # output reads the same in IEx on the console and over ssh. No Mix, no
  # Hex.

  @width 33

  @doc false
  @spec env_line(Precompiled.Device.Env.t()) :: String.t()
  def env_line(env) do
    system =
      case env.system do
        {name, vsn} -> "system #{name} #{vsn}"
        nil -> "system none (pure_elixir builds only)"
      end

    "precompiled: #{system}, OTP #{env.otp}, Elixir #{env.elixir}, #{arch(env.cpu)}"
  end

  defp arch(cpu) when is_binary(cpu), do: cpu |> String.split("-") |> hd()
  defp arch(_), do: "unknown"

  @doc false
  # `tag` is PLAN, OK, NO or WARN.
  @spec line(String.t(), String.t(), String.t()) :: String.t()
  def line(name_vsn, tag, detail) do
    head = "precompiled: #{name_vsn}"
    pad = String.duplicate(" ", max(1, @width - String.length(head)))
    String.trim_trailing("#{head}#{pad}  #{String.pad_trailing(tag, 4)}  #{detail}")
  end

  @doc false
  # An optional dependency a package's build was not given on this device.
  @spec skipped_optional(atom(), atom()) :: String.t()
  def skipped_optional(app, dep),
    do: "precompiled: #{app}: skipped optional #{dep} (not on this device)"

  @doc false
  @spec summary(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def summary(n, bytes, ms),
    do: "precompiled: #{n} installed, #{kb(bytes)}, #{Float.round(ms / 1000, 1)} s"

  @doc false
  @spec kb(non_neg_integer()) :: String.t()
  def kb(bytes), do: "#{round(bytes / 1024)} KB"

  @doc false
  # Prints `line` unless the call is quiet.
  @spec put(String.t(), boolean()) :: :ok
  def put(_line, true), do: :ok
  def put(line, _quiet), do: IO.puts(line)
end
