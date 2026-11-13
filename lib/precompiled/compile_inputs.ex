# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CompileInputs do
  @moduledoc false
  # A build's compile_inputs: what its compile read that the portal could
  # not settle for us, checked on this side. An environment variable's value
  # is compared and never printed: here it may be the user's secret. Only
  # the variable's name reaches a reason.

  alias Precompiled.Reason

  @max_recorded_bytes 65_536

  @spec host(term(), (String.t() -> String.t() | nil)) :: :ok | {:miss, Reason.t()}
  def host(nil, _getenv), do: :ok
  def host(items, getenv) when is_list(items), do: first_miss(items, &host_item(&1, getenv))
  def host(_items, _getenv), do: malformed()

  # A device has no build environment of its firmware to compare with: an
  # item recorded unset is accepted, one recorded set is a miss that says so.
  @spec device(term()) :: :ok | {:miss, Reason.t()}
  def device(nil), do: :ok
  def device(items) when is_list(items), do: first_miss(items, &device_item/1)
  def device(_items), do: malformed()

  defp first_miss(items, check) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        miss -> {:halt, miss}
      end
    end)
  end

  defp host_item(%{"kind" => "env", "name" => name, "value" => value, "set_by" => "host"}, getenv)
       when is_binary(name) and is_binary(value) do
    if recorded?(value, current(getenv.(name))), do: :ok, else: differs(name)
  end

  defp host_item(%{"kind" => "env", "set_by" => "build"} = item, _getenv),
    do: build_set(item, &differs/1)

  defp host_item(item, _getenv), do: whole(item)

  defp device_item(%{"kind" => "env", "name" => name, "value" => value, "set_by" => "host"})
       when is_binary(name) and is_binary(value) do
    if recorded?(value, :error), do: :ok, else: set_at_build(name)
  end

  defp device_item(%{"kind" => "env", "set_by" => "build"} = item),
    do: build_set(item, &set_at_build/1)

  defp device_item(item), do: whole(item)

  # Set by an earlier write in the same build: its value follows from the
  # build's own inputs, which are checked as items of their own.
  defp build_set(%{"name" => name, "value" => value, "inputs" => "recorded"}, _miss)
       when is_binary(name) and is_binary(value),
       do: :ok

  defp build_set(%{"name" => name, "value" => value, "inputs" => "unknown"}, miss)
       when is_binary(name) and is_binary(value),
       do: miss.(name)

  defp build_set(_item, _miss), do: malformed()

  defp whole(%{"kind" => "env_all"}), do: {:miss, Reason.new(:env_all, [])}
  defp whole(%{"kind" => "config_unrecorded"}), do: {:miss, Reason.new(:config_unrecorded, [])}
  defp whole(_item), do: malformed()

  defp differs(name), do: {:miss, Reason.new(:env_differs, [name])}
  defp set_at_build(name), do: {:miss, Reason.new(:env_set_at_build, [name])}
  defp malformed(), do: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}

  defp current(nil), do: :error
  defp current(value) when is_binary(value), do: {:ok, value}

  # A recorded value comes from a third-party build: decoded only by
  # SafeTerm, and anything it refuses (`unrecordable` included) differs.
  defp recorded?(value, current) do
    with {:ok, bin} <- Base.url_decode64(value, padding: false),
         {:ok, term} <- Precompiled.SafeTerm.decode(bin, @max_recorded_bytes) do
      term == current
    else
      _ -> false
    end
  end
end
