# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.CompileInputsTest do
  use ExUnit.Case, async: false

  alias Precompiled.CompileInputs

  @name "PRECOMPILED_TEST_COMPILE_INPUT"

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  setup do
    on_exit(fn -> System.delete_env(@name) end)
  end

  # The end-to-end shape of `GITHUB_ACTIONS=true mix deps.loadpaths`: the
  # host check reads the running VM's environment.
  test "the host check reads the real environment" do
    items = [%{"kind" => "env", "name" => @name, "value" => rec(:error), "set_by" => "host"}]
    assert :ok = CompileInputs.host(items, &System.get_env/1)

    System.put_env(@name, "true")

    assert {:miss, %{code: :env_differs, args: [@name]}} =
             CompileInputs.host(items, &System.get_env/1)
  end

  test "no field is no rule" do
    assert :ok = CompileInputs.host(nil, fn _ -> raise "never called" end)
    assert :ok = CompileInputs.device(nil)
  end

  describe "on a device" do
    defp env_item(value),
      do: %{"kind" => "env", "name" => @name, "value" => value, "set_by" => "host"}

    defp dev_order(default, seen \\ rec({:ok, 1})),
      do: %{
        "kind" => "config_order",
        "app" => "a",
        "path" => ["k"],
        "reader" => "r",
        "default" => default,
        "seen" => seen
      }

    test "an env item recorded unset is accepted, whatever this VM's environment holds" do
      assert :ok = CompileInputs.device([env_item(rec(:error))])

      System.put_env(@name, "here")
      assert :ok = CompileInputs.device([env_item(rec(:error))])
    end

    test "an env item recorded set misses with env_set_at_build, naming only the variable" do
      assert {:miss, %{code: :env_set_at_build, args: [@name]}} =
               CompileInputs.device([env_item(rec({:ok, "builder-value"}))])

      System.put_env(@name, "builder-value")

      assert {:miss, %{code: :env_set_at_build, args: [@name]}} =
               CompileInputs.device([env_item(rec({:ok, "builder-value"}))])
    end

    test "a config_order item misses unless the caller can decide it" do
      item = dev_order(rec(:error))

      assert {:miss, %{code: :config_order_differs, args: ["a", "k"]}} =
               CompileInputs.device([item])

      assert {:miss, %{code: :config_order_differs, args: ["a", "k"]}} =
               CompileInputs.device([item], fn _ -> false end)

      assert :ok = CompileInputs.device([item], fn ^item -> true end)
    end

    test "decidable config_order items become compile_env items with the value seen" do
      seen = rec({:ok, 1})
      yes = dev_order(rec(:error), seen)
      no = %{dev_order(rec({:ok, 2}), seen) | "app" => "b"}
      decidable? = &CompileInputs.no_default?(&1["default"])

      assert [%{"app" => "a", "path" => ["k"], "value" => ^seen}] =
               CompileInputs.as_compile_env([env_item(rec(:error)), yes, no], decidable?)

      assert [] = CompileInputs.as_compile_env(nil, decidable?)
      assert [] = CompileInputs.as_compile_env([%{yes | "seen" => 1}], decidable?)
    end

    test "a config_order item missing a field is malformed, and never a compile_env item" do
      decidable? = fn _ -> true end

      for bad <- [
            Map.delete(dev_order(rec(:error)), "default"),
            %{dev_order(rec(:error)) | "reader" => 1}
          ] do
        assert {:miss, %{code: :malformed_entry}} = CompileInputs.device([bad], decidable?)
        assert [] = CompileInputs.as_compile_env([bad], decidable?)
      end
    end

    test "a decidable config_order item with an unrecordable seen value misses" do
      item = dev_order(rec(:error), "unrecordable")

      assert {:miss, %{code: :config_order_differs, args: ["a", "k"]}} =
               CompileInputs.device([item], fn _ -> true end)

      assert [] = CompileInputs.as_compile_env([item], fn _ -> true end)
    end

    test "no_default? holds only for a recorded unset default" do
      assert CompileInputs.no_default?(rec(:error))
      refute CompileInputs.no_default?(rec({:ok, 1}))
      refute CompileInputs.no_default?("unrecordable")
      refute CompileInputs.no_default?(nil)
    end
  end

  describe "config_order on the host" do
    alias Precompiled.CompileOrder

    defp mdep(app, children \\ []),
      do: %Mix.Dep{
        app: app,
        deps: Enum.map(children, &%Mix.Dep{app: &1}),
        manager: :mix,
        opts: []
      }

    defp order_item(default, seen) do
      %{
        "kind" => "config_order",
        "app" => "a",
        "path" => ["k"],
        "reader" => "r",
        "default" => default,
        "seen" => seen
      }
    end

    defp octx(deps, config \\ fn _, _ -> :error end, count \\ nil),
      do: %{compile_order: CompileOrder.from_deps(deps, count), user_config: config}

    defp check(item, octx), do: CompileInputs.host([item], fn _ -> nil end, octx)

    @differs {:miss, %{code: :config_order_differs, args: ["a", "k"]}}

    test "app compiled before R: R saw the default, a hit" do
      assert :ok = check(order_item(rec({:ok, 1}), rec({:ok, 1})), octx([mdep(:a), mdep(:r)]))
    end

    test "app compiled after R: R would see unset, a miss unless it saw unset" do
      assert @differs =
               check(order_item(rec({:ok, 1}), rec({:ok, 1})), octx([mdep(:r), mdep(:a)]))

      assert :ok = check(order_item(rec({:ok, 1}), rec(:error)), octx([mdep(:r), mdep(:a)]))
    end

    test "the user's config wins over the order, by value" do
      after_r = [mdep(:r), mdep(:a)]

      assert :ok =
               check(
                 order_item(rec({:ok, 1}), rec({:ok, 1})),
                 octx(after_r, fn "a", "k" -> {:ok, 1} end)
               )

      assert @differs =
               check(
                 order_item(rec({:ok, 1}), rec({:ok, 1})),
                 octx(after_r, fn _, _ -> {:ok, 2} end)
               )
    end

    test "an app loaded here stands only without a .app default" do
      loaded = fn _, _ -> {:loaded, {:ok, 1}} end

      assert :ok =
               check(order_item(rec(:error), rec({:ok, 1})), octx([mdep(:r), mdep(:a)], loaded))

      assert @differs =
               check(order_item(rec({:ok, 1}), rec({:ok, 1})), octx([mdep(:a), mdep(:r)], loaded))
    end

    test "R not in the lock: a miss" do
      assert @differs = check(order_item(rec({:ok, 1}), rec({:ok, 1})), octx([mdep(:a)]))
      assert @differs = check(order_item(rec({:ok, 1}), rec(:error)), octx([mdep(:a)]))
    end

    # An app the project does not depend on never loads here: R reads it
    # unset, and the .app default (unrecordable when the app was outside
    # the build's closure, e.g. phoenix_view) is never needed.
    test "app not in the lock: expected unset, compared, not a miss of its own" do
      assert :ok = check(order_item(rec({:ok, 1}), rec(:error)), octx([mdep(:r)]))
      assert :ok = check(order_item("unrecordable", rec(:error)), octx([mdep(:r)]))
      assert @differs = check(order_item(rec({:ok, 1}), rec({:ok, 1})), octx([mdep(:r)]))
      assert @differs = check(order_item("unrecordable", rec({:ok, 1})), octx([mdep(:r)]))
    end

    test "a partitioned order: an app not in the lock is still unset" do
      item = %{order_item("unrecordable", rec(:error)) | "app" => "precompiled_no_such_view"}
      assert :ok = check(item, octx([mdep(:r)], fn _, _ -> :error end, "2"))

      set = %{order_item("unrecordable", rec({:ok, 1})) | "app" => "precompiled_no_such_view"}

      assert {:miss, %{code: :config_order_differs}} =
               check(set, octx([mdep(:r)], fn _, _ -> :error end, "2"))
    end

    test "an ambiguous order, or none, is a miss" do
      item = order_item(rec({:ok, 1}), rec({:ok, 1}))
      assert @differs = check(item, octx([mdep(:a), mdep(:r)], fn _, _ -> :error end, "4"))
      assert @differs = CompileInputs.host([item], fn _ -> nil end)
    end

    test "an unrecordable value is a miss where it is needed, and values are never in the text" do
      assert @differs =
               check(order_item("unrecordable", rec({:ok, 1})), octx([mdep(:a), mdep(:r)]))

      assert :ok = check(order_item("unrecordable", rec(:error)), octx([mdep(:r), mdep(:a)]))

      assert @differs =
               check(order_item(rec({:ok, 1}), "unrecordable"), octx([mdep(:a), mdep(:r)]))

      item = order_item(rec({:ok, "builder-value"}), rec({:ok, "builder-value"}))

      assert {:miss, %{text: text}} =
               check(item, octx([mdep(:r), mdep(:a)], fn _, _ -> {:ok, "user-secret-123"} end))

      assert text == "compile-time config a k would differ in this project"
    end

    test "user_config reads config for an unloaded app, and says when the app is loaded" do
      assert CompileInputs.user_config("precompiled_no_such_app_x", "k") == :error
      Application.put_env(:precompiled_cfg_test_app, :k, 1)
      on_exit(fn -> Application.delete_env(:precompiled_cfg_test_app, :k) end)
      assert CompileInputs.user_config("precompiled_cfg_test_app", "k") == {:ok, 1}
      assert {:loaded, _} = CompileInputs.user_config("logger", "level")
    end

    test "a list misses on its first differing item, after a matching one" do
      matching = order_item(rec({:ok, 1}), rec({:ok, 1}))
      differing = %{order_item(rec({:ok, 1}), rec({:ok, 1})) | "app" => "b", "path" => ["j"]}
      # a is compiled before r, b after it: r saw a's default, not b's.
      ctx = octx([mdep(:a), mdep(:r), mdep(:b)])

      assert :ok = CompileInputs.host([matching], fn _ -> nil end, ctx)

      assert {:miss, %{code: :config_order_differs, args: ["b", "j"]}} =
               CompileInputs.host([matching, differing], fn _ -> nil end, ctx)
    end
  end

  describe "recorded values are decoded only by SafeTerm" do
    # Large enough that term_to_binary does compress it.
    @big String.duplicate("a", 4096)

    defp compressed(term),
      do: term |> :erlang.term_to_binary(compressed: 9) |> Base.url_encode64(padding: false)

    defp trailing(term),
      do:
        (:erlang.term_to_binary(term, [:deterministic]) <> <<0>>)
        |> Base.url_encode64(padding: false)

    test "a compressed value never decodes" do
      bin = :erlang.term_to_binary({:ok, @big}, compressed: 9)
      assert <<131, 80, _::binary>> = bin

      env = fn value ->
        [%{"kind" => "env", "name" => @name, "value" => value, "set_by" => "host"}]
      end

      System.put_env(@name, @big)
      assert :ok = CompileInputs.host(env.(rec({:ok, @big})), &System.get_env/1)

      assert {:miss, %{code: :env_differs}} =
               CompileInputs.host(env.(compressed({:ok, @big})), &System.get_env/1)

      octx = %{
        compile_order: Precompiled.CompileOrder.from_deps([mdep(:r), mdep(:a)], nil),
        user_config: fn _, _ -> {:ok, @big} end
      }

      assert :ok =
               CompileInputs.host(
                 [order_item(rec(:error), rec({:ok, @big}))],
                 fn _ -> nil end,
                 octx
               )

      assert {:miss, %{code: :config_order_differs}} =
               CompileInputs.host(
                 [order_item(rec(:error), compressed({:ok, @big}))],
                 fn _ -> nil end,
                 octx
               )
    end

    test "a value with bytes after the term never decodes" do
      env = fn value ->
        [%{"kind" => "env", "name" => @name, "value" => value, "set_by" => "host"}]
      end

      assert :ok = CompileInputs.host(env.(rec(:error)), fn _ -> nil end)

      assert {:miss, %{code: :env_differs}} =
               CompileInputs.host(env.(trailing(:error)), fn _ -> nil end)

      octx = %{
        compile_order: Precompiled.CompileOrder.from_deps([mdep(:a), mdep(:r)], nil),
        user_config: fn _, _ -> :error end
      }

      assert :ok =
               CompileInputs.host(
                 [order_item(rec({:ok, 1}), rec({:ok, 1}))],
                 fn _ -> nil end,
                 octx
               )

      for item <- [
            order_item(rec({:ok, 1}), trailing({:ok, 1})),
            order_item(trailing({:ok, 1}), rec({:ok, 1}))
          ] do
        assert {:miss, %{code: :config_order_differs}} =
                 CompileInputs.host([item], fn _ -> nil end, octx)
      end
    end
  end
end
