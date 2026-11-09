# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Device.Plan do
  @moduledoc false
  # The closure walk: each requested package, and every absent runtime
  # dependency its chosen build names, pinned to the exact version and
  # checksum of that build's lock. A worklist, bounded by the builds' own
  # deps and by :max_closure; it chooses no versions for dependencies. The
  # installs come out dependencies first, in load order. Anything that
  # cannot be planned fails the whole call. No Mix, no Hex.

  alias ElixirPrecompiled.Device.Rules

  @type request :: {atom(), nil | String.t()}
  @type manifest_fun ::
          (String.t() ->
             {:ok, map(), %{sha: String.t(), path: String.t()}}
             | {:miss, String.t()}
             | {:fail, String.t()})

  @checksum_differs "package checksum differs from the lock of the build that needs it"

  @spec build([request()], Rules.ctx(), keyword()) ::
          {:ok, Precompiled.Plan.t()} | {:error, term()}
  def build(requests, ctx, opts) do
    state = %{chosen: %{}, order: [], present: [], warnings: []}
    queue = Enum.map(requests, fn {app, req} -> {app, req, nil, :requested} end)

    with {:ok, state} <- walk(queue, ctx, opts, state) do
      installs = state.order |> Enum.reverse() |> Enum.map(&state.chosen[&1])

      {:ok,
       %Precompiled.Plan{
         installs: installs,
         present: Enum.reverse(state.present),
         warnings: state.warnings,
         bytes: installs |> Enum.map(& &1.bytes) |> Enum.sum()
       }}
    end
  end

  # An {:emit, app} marker follows an app's needs in the queue, so the app
  # lands in the order only once everything it needs is there.
  defp walk([], _ctx, _opts, state), do: {:ok, state}

  defp walk([{:emit, app} | rest], ctx, opts, state),
    do: walk(rest, ctx, opts, %{state | order: [app | state.order]})

  defp walk([{app, req, pin, role} | rest], ctx, opts, state) do
    case step(app, req, pin, role, ctx, opts, state) do
      {:next, state} -> walk(rest, ctx, opts, state)
      {:queue, items, state} -> walk(items ++ rest, ctx, opts, state)
      {:error, _} = error -> error
    end
  end

  defp step(app, req, pin, role, ctx, opts, state) do
    want = if pin, do: pin.version, else: req

    with :ok <- allowed(app, opts[:allow]),
         :new <- chosen(app, want, pin, role, state),
         :absent <- present(app, want, ctx) do
      plan_app(app, want, pin, role, ctx, opts, state)
    else
      {:chosen, state} -> {:next, state}
      {:present, vsn} -> {:next, add_present(state, app, vsn)}
      {:error, _} = error -> error
    end
  end

  defp plan_app(app, want, pin, role, ctx, opts, state) do
    name = Atom.to_string(app)

    with {:ok, install, verdict} <- choose(name, app, want, pin, role, ctx, opts[:manifest]),
         :ok <- closure_ok(verdict.needs, Keyword.get(opts, :closure, true)),
         state = record(state, install, verdict),
         :ok <- bound(state, Keyword.get(opts, :max_closure, 25)) do
      needs =
        for n <- verdict.needs,
            do: {n.app, nil, %{version: n.version, checksum: n.checksum}, :dependency}

      {:queue, needs ++ [{:emit, app}], state}
    end
  end

  defp allowed(_app, nil), do: :ok

  defp allowed(app, allow) when is_list(allow),
    do: if(app in allow, do: :ok, else: {:error, {:not_allowed, app}})

  # Already in the plan: the same version is nothing new (a request for an
  # app first planned as a dependency makes it requested); another version,
  # or the same one locked with another checksum, cannot be had at once.
  defp chosen(app, want, pin, role, state) do
    case state.chosen[app] do
      nil ->
        :new

      install ->
        cond do
          not version_ok?(install.version, want) ->
            {:error, {:conflict, app, Enum.sort([install.version, want])}}

          pin && pin.checksum != install.build["build"]["package_checksum"] ->
            {:error, {:no_build, Atom.to_string(app), @checksum_differs}}

          true ->
            {:chosen, promote(state, app, role)}
        end
    end
  end

  defp promote(state, app, :requested),
    do: put_in(state.chosen[app].role, :requested)

  defp promote(state, _app, :dependency), do: state

  # What this tool loaded in this VM is looked at first: the device was
  # read before taking the store's lock, so a concurrent call may have
  # loaded it since. Anything else present is never replaced.
  defp present(app, want, ctx) do
    case {ctx.active[app], ctx.env.present[app]} do
      {vsn, _} when is_binary(vsn) ->
        if version_ok?(vsn, want),
          do: {:present, vsn},
          else: {:error, {:already_present, app, vsn}}

      {nil, nil} ->
        :absent

      {nil, info} ->
        {:error, {:already_present, app, info[:vsn]}}
    end
  end

  defp add_present(state, app, vsn) do
    if {app, vsn} in state.present,
      do: state,
      else: %{state | present: [{app, vsn} | state.present]}
  end

  # A pin is passed to the selection as the exact version: a version the
  # manifest does not offer is a refusal, never another version.
  defp choose(name, app, want, pin, role, ctx, manifest_fun) do
    with {:ok, manifest, ref} <- manifest(manifest_fun, name),
         {:ok, vsn, build, verdict} <- select(manifest, name, want, %{ctx | pin: pin}),
         {:ok, bytes} <- bytes(build, name) do
      {:ok,
       %{
         app: app,
         version: vsn,
         target: build["target"],
         build: build,
         role: role,
         bytes: bytes,
         manifest: ref,
         deferred_env: verdict.deferred_env
       }, verdict}
    end
  end

  defp manifest(fun, name) do
    case fun.(name) do
      {:ok, manifest, %{sha: _, path: _} = ref} -> {:ok, manifest, ref}
      {kind, why} when kind in [:miss, :fail] and is_binary(why) -> no_build(name, why)
      _ -> no_build(name, "manifest unavailable")
    end
  end

  defp select(manifest, name, want, ctx) do
    case Rules.select(manifest, name, want, ctx) do
      {:ok, _vsn, _build, _verdict} = ok -> ok
      {:miss, why} -> no_build(name, why)
    end
  end

  defp bytes(build, name) do
    files = List.wrap(build["ebin"]) ++ List.wrap(build["priv"])
    sizes = for %{"size" => size} <- files, is_integer(size) and size >= 0, do: size

    if length(sizes) == length(files),
      do: {:ok, Enum.sum(sizes)},
      else: no_build(name, "malformed entry")
  end

  defp no_build(name, why), do: {:error, {:no_build, name, why}}

  defp closure_ok([], _closure), do: :ok
  defp closure_ok(_needs, true), do: :ok

  defp closure_ok(needs, false),
    do: {:error, {:needs, Enum.map(needs, &{&1.app, &1.version})}}

  defp record(state, install, verdict) do
    named = Enum.map(verdict.warnings, &"#{install.app} #{install.version}: #{&1}")

    %{
      state
      | chosen: Map.put(state.chosen, install.app, install),
        warnings: state.warnings ++ named
    }
  end

  defp bound(state, max) do
    n = map_size(state.chosen)
    if n > max, do: {:error, {:too_many, n, max}}, else: :ok
  end

  defp version_ok?(_vsn, nil), do: true

  defp version_ok?(vsn, want) when is_binary(want) do
    case {Version.parse(want), Version.parse_requirement(want)} do
      {{:ok, _}, _} -> vsn == want
      {:error, {:ok, req}} -> Version.match?(vsn, req)
      _ -> false
    end
  rescue
    Version.InvalidVersionError -> false
  end
end
