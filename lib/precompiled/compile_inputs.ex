# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CompileInputs do
  @moduledoc false
  # A build's compile_inputs: what its compile read that the portal could
  # not settle for us, checked on this side. An environment variable's value
  # is compared and never printed: here it may be the user's secret. Only
  # the variable's name reaches a reason. A config_order item is checked
  # against this project's compile order (CompileOrder): only its app and
  # key names reach a reason. A platform_define item is rebar3's verdict on
  # one platform_define regex against the builder's arch string, checked
  # against this machine's (Rebar3Arch): only the regex reaches a reason.

  alias Precompiled.{CompileOrder, Reason, Rebar3Arch}

  @max_recorded_bytes 65_536

  @no_order %{compile_order: nil, user_config: &__MODULE__.user_config/2}

  # rebar3_arch, when given, stands for this machine's arch string.
  @type order_ctx :: %{
          required(:compile_order) => CompileOrder.t() | nil,
          required(:user_config) => (String.t(), String.t() ->
                                       {:ok, term()}
                                       | :error
                                       | {:loaded, {:ok, term()} | :error}),
          optional(:rebar3_arch) => String.t()
        }

  @spec host(term(), (String.t() -> String.t() | nil)) :: :ok | {:miss, Reason.t()}
  def host(items, getenv), do: host(items, getenv, @no_order)

  @spec host(term(), (String.t() -> String.t() | nil), order_ctx()) :: :ok | {:miss, Reason.t()}
  def host(nil, _getenv, _order), do: :ok

  def host(items, getenv, order) when is_list(items),
    do: first_miss(items, &host_item(&1, getenv, order))

  def host(_items, _getenv, _order), do: malformed()

  # A device has no build environment of its firmware to compare with: an
  # item recorded unset is accepted, one recorded set is a miss that says so.
  # Nor has it the firmware's compile order: a config_order item the caller
  # cannot decide (decidable?) is a miss, and a decidable one is checked as
  # a compile_env item (as_compile_env/2) instead.
  @spec device(term(), (map() -> boolean())) :: :ok | {:miss, Reason.t()}
  def device(items, decidable? \\ fn _ -> false end)
  def device(nil, _decidable?), do: :ok

  def device(items, decidable?) when is_list(items),
    do: first_miss(items, &device_item(&1, decidable?))

  def device(_items, _decidable?), do: malformed()

  @doc false
  # The decidable config_order items as the compile_env items a device
  # checks: the value the reader saw, against the device's config.
  @spec as_compile_env(term(), (map() -> boolean())) :: [map()]
  def as_compile_env(items, decidable?) when is_list(items) do
    for item <- items,
        checkable?(item, decidable?),
        do: %{"app" => item["app"], "path" => item["path"], "value" => item["seen"]}
  end

  def as_compile_env(_items, _decidable?), do: []

  @doc false
  # Whether the app's .app gives the key no value, as the build recorded it.
  @spec no_default?(term()) :: boolean()
  def no_default?(default), do: is_binary(default) and decode(default) == {:ok, :error}

  defp first_miss(items, check) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        miss -> {:halt, miss}
      end
    end)
  end

  defp host_item(
         %{"kind" => "env", "name" => name, "value" => value, "set_by" => "host"},
         getenv,
         _order
       )
       when is_binary(name) and is_binary(value) do
    if recorded?(value, current(getenv.(name))), do: :ok, else: differs(name)
  end

  defp host_item(%{"kind" => "env", "set_by" => "build"} = item, _getenv, _order),
    do: build_set(item, &differs/1)

  # Whether the build's reader saw the app's .app default depends on this
  # project's compile order (CompileOrder); the user's config wins over it.
  defp host_item(
         %{
           "kind" => "config_order",
           "app" => app,
           "path" => [key],
           "reader" => reader,
           "default" => default,
           "seen" => seen
         },
         _getenv,
         order
       )
       when is_binary(app) and is_binary(key) and is_binary(reader) and is_binary(default) and
              is_binary(seen) do
    with {:ok, seen} <- decode(seen),
         {:ok, expected} <- expected(app, key, reader, default, order),
         true <- expected == seen do
      :ok
    else
      _ -> {:miss, Reason.new(:config_order_differs, [app, key])}
    end
  end

  # rebar3 defines the macro only when the regex matches its arch string;
  # here it must decide as it did on the builder. A regex this client cannot
  # evaluate is a miss. Firmware is compiled on this machine too (rebar3 runs
  # on the host's VM when cross-compiling), so this is the check for it.
  defp host_item(%{"kind" => "platform_define", "regex" => regex, "matched" => matched}, _, order)
       when is_binary(regex) and is_boolean(matched) do
    arch = Map.get_lazy(order, :rebar3_arch, &Rebar3Arch.arch/0)

    if Rebar3Arch.match(regex, arch) == matched,
      do: :ok,
      else: platform_define_differs(regex)
  end

  defp host_item(item, _getenv, _order), do: whole(item)

  # What the reader would read here: the user's config when set; otherwise
  # the .app default when the compile order loads the app first, and unset
  # when it does not. Anything the order cannot say is :unknown.
  defp expected(app, key, reader, default, %{compile_order: compile_order, user_config: config}) do
    case config.(app, key) do
      {:ok, _} = set ->
        {:ok, set}

      :error ->
        case CompileOrder.loaded_before?(compile_order, app, reader) do
          true -> decode(default)
          false -> {:ok, :error}
          :unknown -> :unknown
        end

      {:loaded, env} ->
        if decode(default) == {:ok, :error}, do: {:ok, env}, else: :unknown
    end
  end

  @doc false
  # The user's config for {app, key}, read before this project's deps are
  # loaded: config for an unloaded app is the config alone. Once the app is
  # loaded its env may hold the .app default too, so it is marked.
  @spec user_config(String.t(), String.t()) ::
          {:ok, term()} | :error | {:loaded, {:ok, term()} | :error}
  def user_config(app, key) do
    with {:ok, a} <- existing_atom(app),
         {:ok, k} <- existing_atom(key) do
      env = Application.fetch_env(a, k)
      if Application.spec(a, :vsn), do: {:loaded, env}, else: env
    else
      :none -> :error
    end
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :none
  end

  defp device_item(
         %{"kind" => "env", "name" => name, "value" => value, "set_by" => "host"},
         _decidable?
       )
       when is_binary(name) and is_binary(value) do
    if recorded?(value, :error), do: :ok, else: set_at_build(name)
  end

  defp device_item(%{"kind" => "env", "set_by" => "build"} = item, _decidable?),
    do: build_set(item, &set_at_build/1)

  # Checkable ones are checked as compile_env items (as_compile_env/2);
  # any other shape is malformed.
  defp device_item(%{"kind" => "config_order"} = item, decidable?) do
    cond do
      not order_item?(item) -> malformed()
      checkable?(item, decidable?) -> :ok
      true -> {:miss, Reason.new(:config_order_differs, [item["app"], hd(item["path"])])}
    end
  end

  # A device compiles no dependency: firmware is compiled on the build
  # machine, where rebar3 ran and host_item/3 checked this item, and the
  # device API installs builds without compiling anything. Its own arch
  # string is not the one rebar3 would see, so it is never compared.
  defp device_item(%{"kind" => "platform_define", "regex" => regex, "matched" => matched}, _)
       when is_binary(regex) and is_boolean(matched),
       do: :ok

  defp device_item(item, _decidable?), do: whole(item)

  # Decidable, and the value the reader saw was recorded: a seen value the
  # build could not record has nothing to compare the config with.
  defp checkable?(item, decidable?),
    do: order_item?(item) and decidable?.(item) and match?({:ok, _}, decode(item["seen"]))

  # A config_order item in the shape the portal emits.
  defp order_item?(%{
         "kind" => "config_order",
         "app" => app,
         "path" => [key],
         "reader" => reader,
         "default" => default,
         "seen" => seen
       }),
       do:
         is_binary(app) and is_binary(key) and is_binary(reader) and is_binary(default) and
           is_binary(seen)

  defp order_item?(_item), do: false

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

  defp platform_define_differs(regex) do
    text = Reason.render(:platform_define_differs, [inspect(regex)])
    {:miss, Reason.new(:platform_define_differs, [regex], text)}
  end

  defp malformed(), do: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}

  defp current(nil), do: :error
  defp current(value) when is_binary(value), do: {:ok, value}

  defp recorded?(value, current), do: decode(value) == {:ok, current}

  # A recorded value comes from a third-party build: decoded only by
  # SafeTerm, and anything it refuses (`unrecordable` included) is :error.
  defp decode(value) do
    with {:ok, bin} <- Base.url_decode64(value, padding: false),
         {:ok, term} <- Precompiled.SafeTerm.decode(bin, @max_recorded_bytes) do
      {:ok, term}
    else
      _ -> :error
    end
  end
end
