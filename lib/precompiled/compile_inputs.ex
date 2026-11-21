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
  # against this machine's (Rebar3Arch): only the regex reaches a reason. An
  # endian item is the byte order the build's compile read (nx's float
  # layouts), checked against this machine's System.endianness/0. An os_type
  # item is the :os.type/0 the build's compile read (kino's asset hook),
  # checked against this machine's: both elements, or the family alone when
  # the item carries no name. A
  # set_by "nerves" env item is a firmware build's read of a variable that
  # holds where the Nerves toolchain or system lives (CROSSCOMPILE): its
  # value cut at those two paths (split/2), compared with this project's
  # value cut at its own; only the name reaches a reason. A mix_target item
  # is the target a firmware build's compile read through Mix.target/0. A
  # config_all item is the builder's whole config of one app, which the
  # build's compile read with Application.get_all_env/1 (tz): this project's
  # config of that app must be the same map; only the app reaches a reason.

  alias Precompiled.{CompileOrder, Reason, Rebar3Arch}

  @max_recorded_bytes 65_536
  @os_families ["unix", "win32"]
  # An :os.type/0 name as it renders: linux, darwin, freebsd, nt.
  @os_name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @no_order %{compile_order: nil, user_config: &__MODULE__.user_config/2}

  @nerves_roots ["NERVES_TOOLCHAIN", "NERVES_SYSTEM"]
  @max_segments 64
  @max_segment_bytes 4096

  # rebar3_arch, when given, stands for this machine's arch string; endian
  # for its byte order; os_type for its :os.type/0.
  @type order_ctx :: %{
          required(:compile_order) => CompileOrder.t() | nil,
          required(:user_config) => (String.t(), String.t() ->
                                       {:ok, term()}
                                       | :error
                                       | {:loaded, {:ok, term()} | :error}
                                       | :unreadable),
          optional(:rebar3_arch) => String.t(),
          optional(:endian) => :little | :big,
          optional(:os_type) => {atom(), atom()},
          optional(:mix_target) => String.t(),
          optional(:user_config_all) => (String.t() -> {:ok, map()} | :unknown)
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
  # on the host's VM when cross-compiling), so this is the check for it; a
  # device cannot make it and misses (device_item/2).
  defp host_item(%{"kind" => "platform_define", "regex" => regex, "matched" => matched}, _, order)
       when is_binary(regex) and is_boolean(matched) do
    arch = Map.get_lazy(order, :rebar3_arch, &Rebar3Arch.arch/0)

    if Rebar3Arch.match(regex, arch) == matched,
      do: :ok,
      else: platform_define_differs(regex)
  end

  # The byte order a compile-time System.endianness/0 read returned on the
  # builder must be this machine's: Mix compiles the dependency here, on the
  # host's VM for firmware too.
  defp host_item(%{"kind" => "endian", "value" => built} = item, _getenv, order)
       when built in ["little", "big"] and map_size(item) == 2 do
    here = order |> Map.get_lazy(:endian, &System.endianness/0) |> Atom.to_string()
    if built == here, do: :ok, else: {:miss, Reason.new(:endian_differs, [built, here])}
  end

  # The OS type a compile-time :os.type/0 read returned on the builder must
  # be this machine's: both elements, or the family alone when only the
  # family could reach the build (the item has no name).
  defp host_item(%{"kind" => "os_type"} = item, _getenv, order) do
    case os_type_item(item) do
      {:ok, built} ->
        {family, name} = Map.get_lazy(order, :os_type, &:os.type/0)
        here = [Atom.to_string(family), Atom.to_string(name)]
        here = Enum.take(here, length(built))

        if built == here,
          do: :ok,
          else:
            {:miss, Reason.new(:os_type_differs, [Enum.join(built, ":"), Enum.join(here, ":")])}

      :error ->
        malformed()
    end
  end

  # Nerves sets the variable for a target's compile from where its toolchain
  # and system sit on this machine: cut at those paths, the value must be
  # the build's. The paths themselves never reach a reason.
  defp host_item(
         %{"kind" => "env", "name" => name, "set_by" => "nerves", "value" => segments} = item,
         getenv,
         _order
       )
       when is_binary(name) and map_size(item) == 4 do
    cond do
      not segments?(segments) -> malformed()
      nerves_value(getenv, name) == segments -> :ok
      true -> differs(name)
    end
  end

  # The target the build's compile read must be the one Mix compiles for here.
  defp host_item(%{"kind" => "mix_target", "value" => built} = item, _getenv, order)
       when is_binary(built) and built != "" and map_size(item) == 2 do
    running = Map.get(order, :mix_target, "host")
    if built == running, do: :ok, else: {:miss, Reason.new(:rule8_target, [built, running])}
  end

  # The build's compile read the app's whole env, which held the builder's
  # config of it: this project's must be the same keys with the same values.
  defp host_item(%{"kind" => "config_all", "app" => app} = item, _getenv, order)
       when is_binary(app) and map_size(item) == 3 do
    with {:ok, recorded} <- config_entries(item["entries"]) do
      here = Map.get(order, :user_config_all, &user_config_all/1).(app)
      # Exact: `1` and `1.0` are `==` but compile to other code.
      if here === {:ok, recorded}, do: :ok, else: config_all_differs(app)
    end
  end

  defp host_item(item, _getenv, _order), do: whole(item)

  defp nerves_value(getenv, name) do
    case getenv.(name) do
      value when is_binary(value) ->
        roots = for root <- @nerves_roots, path = getenv.(root), is_binary(path), do: {root, path}
        split(value, roots)

      _ ->
        :unset
    end
  end

  @doc false
  # `value` cut at every occurrence of a root's path, leftmost first and, of
  # two that start at the same byte, the longer: each cut is
  # %{"root" => name}, the text between cuts a literal string, no literal
  # empty. An empty path cuts nothing. The portal cuts the same way
  # (Compatibility.CompileInputs.split/2).
  @spec split(String.t(), [{String.t(), String.t()}]) :: [String.t() | map()]
  def split(value, roots) when is_binary(value) do
    roots =
      roots
      |> Enum.filter(fn {_name, path} -> is_binary(path) and path != "" end)
      |> Enum.sort_by(fn {_name, path} -> -byte_size(path) end)

    do_split(value, roots, "", [])
  end

  defp do_split(<<>>, _roots, literal, acc), do: Enum.reverse(push_literal(acc, literal))

  defp do_split(<<byte, rest::binary>> = value, roots, literal, acc) do
    case Enum.find(roots, fn {_name, path} -> String.starts_with?(value, path) end) do
      {name, path} ->
        rest = binary_part(value, byte_size(path), byte_size(value) - byte_size(path))
        do_split(rest, roots, "", [%{"root" => name} | push_literal(acc, literal)])

      nil ->
        do_split(rest, roots, literal <> <<byte>>, acc)
    end
  end

  defp push_literal(acc, ""), do: acc
  defp push_literal(acc, literal), do: [literal | acc]

  # One canonical cut, in the shape the portal emits: at least one root,
  # every literal a non-empty, NUL-free UTF-8 string, no two literals in a
  # row.
  defp segments?(segments) when is_list(segments) and length(segments) in 1..@max_segments do
    Enum.all?(segments, &segment?/1) and Enum.any?(segments, &is_map/1) and
      not Enum.any?(Enum.chunk_every(segments, 2, 1, :discard), fn [a, b] ->
        is_binary(a) and is_binary(b)
      end)
  end

  defp segments?(_segments), do: false

  defp segment?(%{"root" => root} = segment), do: map_size(segment) == 1 and root in @nerves_roots

  defp segment?(literal) when is_binary(literal) do
    byte_size(literal) in 1..@max_segment_bytes and String.valid?(literal) and
      not String.contains?(literal, <<0>>)
  end

  defp segment?(_segment), do: false

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

      :unreadable ->
        :unknown
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

  @doc false
  # The project's whole config of `app`, read before this project's deps
  # are loaded, as key name => value: {:ok, %{}} for an app no config names.
  # A loaded app's env may hold its .app defaults too, which the build's
  # read of an app it compiles did not see: it is read whole only when that
  # .app declares no env, else :unknown.
  @spec user_config_all(String.t()) :: {:ok, map()} | :unknown
  def user_config_all(app) do
    case existing_atom(app) do
      {:ok, a} ->
        if Application.spec(a, :vsn) == nil or app_env_defaults(a) == [],
          do: {:ok, Map.new(Application.get_all_env(a), fn {k, v} -> {Atom.to_string(k), v} end)},
          else: :unknown

      :none ->
        {:ok, %{}}
    end
  end

  defp app_env_defaults(app) do
    with file when is_list(file) <- :code.where_is_file(~c"#{app}.app"),
         {:ok, [{:application, ^app, props}]} when is_list(props) <- :file.consult(file) do
      Keyword.get(props, :env, [])
    else
      _ -> :unknown
    end
  end

  # A config_all item's entries as key => decoded value: strictly sorted by
  # key, each a %{"key", "value"} of strings. A value that does not decode
  # to {:ok, term} (unrecordable) stands for nothing this project can hold.
  defp config_entries(entries) when is_list(entries) do
    keys = for %{"key" => key} <- entries, do: key

    if Enum.all?(entries, &config_entry?/1) and keys == Enum.sort(Enum.uniq(keys)) and
         length(keys) == length(entries),
       do: {:ok, Map.new(entries, &{&1["key"], recorded_config(&1["value"])})},
       else: malformed()
  end

  defp config_entries(_entries), do: malformed()

  defp config_entry?(%{"key" => key, "value" => value} = entry),
    do: map_size(entry) == 2 and is_binary(key) and key != "" and is_binary(value)

  defp config_entry?(_entry), do: false

  defp recorded_config(value) do
    case decode(value) do
      {:ok, {:ok, term}} -> term
      _ -> make_ref()
    end
  end

  defp config_all_differs(app), do: {:miss, Reason.new(:config_all_differs, [app])}

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

  # The device's firmware was compiled on some build machine whose arch
  # string the device cannot know (a Mac defines what the builder did not),
  # and its own is not the one rebar3 saw there. As with an env item
  # recorded set, there is nothing here to compare with: a miss.
  defp device_item(%{"kind" => "platform_define", "regex" => regex, "matched" => matched}, _)
       when is_binary(regex) and is_boolean(matched) do
    text =
      "built with rebar3 platform_define #{inspect(regex)} decided on its build machine; " <>
        "a device cannot check its firmware's build machine"

    {:miss, Reason.new(:platform_define_differs, [regex], text)}
  end

  # The device cannot know the byte order of the machine its firmware was
  # compiled on: as with platform_define, a miss.
  defp device_item(%{"kind" => "endian", "value" => built} = item, _decidable?)
       when built in ["little", "big"] and map_size(item) == 2 do
    text =
      "built on a #{built}-endian machine; a device cannot check its firmware's build machine"

    {:miss, Reason.new(:endian_differs, [built], text)}
  end

  # The device cannot know the OS of the machine its firmware was compiled
  # on: as with endian, a miss.
  defp device_item(%{"kind" => "os_type"} = item, _decidable?) do
    case os_type_item(item) do
      {:ok, built} ->
        shown = Enum.join(built, ":")
        text = "built on #{shown}; a device cannot check its firmware's build machine"
        {:miss, Reason.new(:os_type_differs, [shown], text)}

      :error ->
        malformed()
    end
  end

  # Nothing of the firmware's build environment is here: as with an env item
  # recorded set, a miss.
  defp device_item(
         %{"kind" => "env", "name" => name, "set_by" => "nerves", "value" => segments} = item,
         _decidable?
       )
       when is_binary(name) and map_size(item) == 4 do
    if segments?(segments), do: set_at_build(name), else: malformed()
  end

  defp device_item(%{"kind" => "mix_target", "value" => built} = item, _decidable?)
       when is_binary(built) and built != "" and map_size(item) == 2 do
    text =
      "reads Mix.target() at compile time; built for target #{built}, " <>
        "a device cannot check its firmware's"

    {:miss, Reason.new(:rule8_target, [built, "unknown"], text)}
  end

  # The firmware's config at its compile is not the device's to check: a
  # miss, as for a set env item.
  defp device_item(%{"kind" => "config_all", "app" => app} = item, _decidable?)
       when is_binary(app) and map_size(item) == 3 do
    with {:ok, _recorded} <- config_entries(item["entries"]) do
      text =
        "built reading the whole compile-time config of #{app}; " <>
          "a device cannot check its firmware's"

      {:miss, Reason.new(:config_all_differs, [app], text)}
    end
  end

  defp device_item(item, _decidable?), do: whole(item)

  # An os_type item's recorded elements, [family, name] or [family]; any
  # other shape is malformed.
  defp os_type_item(%{"family" => family, "name" => name} = item)
       when family in @os_families and is_binary(name) and map_size(item) == 3 do
    if Regex.match?(@os_name, name), do: {:ok, [family, name]}, else: :error
  end

  defp os_type_item(%{"family" => family} = item)
       when family in @os_families and map_size(item) == 2,
       do: {:ok, [family]}

  defp os_type_item(_item), do: :error

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
