# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Rules do
  @moduledoc false
  # Which build of a package a running device may load, and which version.
  # The host's rules where they hold on a device (Match, so the lines read
  # the same), and the device's own for the rest: a system build only for
  # the device's own system, at exactly its version or at another release
  # the systems table says it matches, the nearest release first (a null
  # system version, or a device with no known system, gets pure_elixir
  # only); the package checksum present, and equal to the lock of the build
  # that needs it when it is a closure member; the runtime closure read from
  # the build's .app, matched against the apps present by name and exact
  # version, where an optional dependency (the .app's optional_applications;
  # an app the .app requires stays required whatever declared says) counts
  # only when the device has it or the call asked for it, and is skipped
  # otherwise, never installed because a build was locked with it; declared
  # optional dependencies as ranking, never as a refusal;
  # compile_env compared now for loaded apps and later for the rest.
  # Anything missing or malformed is a miss: nothing here guesses. No Mix,
  # no Hex.
  #
  # The host's build-method rule (rule 9 in the matching guide; this
  # module's own numbering differs) has no device side: a device declares
  # no dependency options and resolves no manager, so it takes the build
  # Mix makes by default, as it takes dep_env "prod". A build's manager is
  # what that default resolved to and is not compared here.

  alias Precompiled.Match
  alias Precompiled.Reason

  @type ctx :: %{
          required(:env) => Precompiled.Device.Env.t(),
          required(:app_spec) => (map() -> {:ok, keyword()} | {:fail, String.t()}),
          required(:installed) => %{atom() => String.t()},
          required(:active) => %{atom() => String.t()},
          required(:config) => (String.t(), [String.t()] -> {:ok, term()} | :error),
          required(:pin) => nil | %{version: String.t(), checksum: String.t()},
          # The apps the call asked for (Plan.build/3 sets it): an optional
          # dependency among them is installed rather than skipped.
          optional(:requested) => [atom()],
          # The batch's systems table (Fetch.systems/2), nil without one.
          optional(:systems) => map() | nil,
          optional(:loaded) => [{atom(), charlist(), charlist()}]
        }

  @type need :: %{app: atom(), version: String.t(), checksum: String.t()}
  @type verdict :: %{
          needs: [need()],
          uncovered: [atom()],
          skipped: [atom()],
          locked_optional: non_neg_integer(),
          warnings: [String.t()],
          deferred_env: [map()]
        }

  @malformed {:miss, "malformed entry"}

  @spec check(map(), String.t(), ctx()) ::
          {:ok, verdict()} | {:miss, String.t(), non_neg_integer()}
  def check(build, name, ctx) do
    b = build["build"] || %{}
    if not is_map(b) or not lists_in_place?(build), do: throw(:malformed)

    acc = %{
      needs: [],
      uncovered: [],
      skipped: [],
      locked_optional: 0,
      warnings: [],
      deferred_env: []
    }

    [
      fn acc -> build["target"] |> target(b, ctx) |> with_acc(acc) end,
      fn acc -> b |> Match.toolchain_present() |> with_acc(acc) end,
      fn acc -> b["elixir"] |> Match.elixir_ok(ctx.env.elixir) |> with_acc(acc) end,
      fn acc -> b["otp"] |> Match.otp_ok(ctx.env.otp) |> with_acc(acc) end,
      fn acc -> b["dep_env"] |> Match.dep_env_ok("prod") |> with_acc(acc) end,
      fn acc -> b |> checksum(ctx) |> with_acc(acc) end,
      fn acc -> runtime_deps(build, name, b, ctx, acc) end,
      fn acc -> declared(b, ctx, acc) end,
      fn acc -> compile_env(b, name, ctx, acc) end
    ]
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, acc}, fn {rule, n}, {:ok, acc} ->
      try do
        case rule.(acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:miss, why} -> {:halt, {:miss, why, n}}
        end
      rescue
        # Catches everything: a rule that raises on an odd manifest entry is
        # a miss for this build, so the install goes on without it.
        _ -> {:halt, {:miss, "check raised", n}}
      catch
        _, _ -> {:halt, {:miss, "check raised", n}}
      end
    end)
  catch
    # Catches everything left, including the throw above: a malformed entry.
    _, _ -> {:miss, "malformed entry", 0}
  end

  defp with_acc(:ok, acc), do: {:ok, acc}
  defp with_acc({:ok, warning}, acc) when is_binary(warning), do: {:ok, warn(acc, warning)}
  defp with_acc({:miss, _} = miss, _acc), do: miss

  defp warn(acc, warning), do: %{acc | warnings: acc.warnings ++ [warning]}

  # Rule 1. A system row without a version matches nothing, and a device
  # whose system is unknown takes pure_elixir builds only. A build for
  # another release of the device's system passes as it does on the host
  # (Match.target_reason/4): through the batch's systems table, which the
  # device has in ctx.systems. A device has no sources to scan, so nothing
  # here reads as a compile-time read of the system. The needed libraries
  # are checked again against the device's own before the install
  # (Device.Libs).
  defp target("pure_elixir", _b, _ctx), do: :ok
  defp target(t, _b, _ctx) when not is_binary(t), do: @malformed

  defp target(t, b, ctx) do
    if is_binary(b["system_version"]),
      do: target_known(t, b, ctx),
      else: {:miss, "build has no system version"}
  end

  defp target_known(t, _b, %{env: %{system: nil}}),
    do: {:miss, "not built for this system (#{t})"}

  defp target_known(t, b, ctx) do
    rule_ctx = %{systems: Map.get(ctx, :systems)}

    case t |> Match.target_reason(b, ctx.env.system, rule_ctx) |> Reason.textual() do
      :ok -> platform_note(t, ctx.env)
      miss -> miss
    end
  end

  defp platform_note("nerves_system_" <> name, %{platform: p}) when is_binary(p) and p != name,
    do: {:ok, "KV platform #{p} is not #{name}; the system name decides"}

  defp platform_note(_, _), do: :ok

  # Rule 6. The device has no lock entry for a package it does not have, so
  # the checksum must be there (it came through the signed chain); a closure
  # member must also be the one the build that needs it was locked against.
  defp checksum(b, ctx) do
    with :ok <- Match.present(b, "package_checksum"),
         :ok <- if(is_binary(b["package_checksum"]), do: :ok, else: @malformed) do
      pinned(b["package_checksum"], ctx[:pin])
    end
  end

  defp pinned(_sum, nil), do: :ok
  defp pinned(sum, %{checksum: sum}) when is_binary(sum), do: :ok

  defp pinned(_sum, _pin), do: {:miss, checksum_differs()}

  @doc false
  @spec checksum_differs() :: String.t()
  def checksum_differs(), do: "package checksum differs from the lock of the build that needs it"

  # Rule 7. The runtime closure comes from the build's own .app; a build-time
  # tool in deps that the .app does not name is already baked into the files.
  # An optional dependency the device lacks and the call did not ask for is
  # skipped: the package runs without that integration, so the build stays
  # installable, whether or not its lock has the dependency.
  defp runtime_deps(build, name, b, ctx, acc) do
    with :ok <- Match.present(b, "deps"),
         :ok <- deps_well_formed(b["deps"]),
         {:ok, props} <- app_props(ctx.app_spec.(build)) do
      {required, skipped, locked_optional} = closure(props, name, b, ctx)
      acc = %{acc | locked_optional: locked_optional}
      Enum.reduce_while(required, {:ok, %{acc | skipped: skipped}}, &walk(&1, &2, b["deps"], ctx))
    end
  end

  defp walk(app, {:ok, acc}, deps, ctx) do
    case closure_app(app, deps, ctx, acc) do
      {:ok, acc} -> {:cont, {:ok, acc}}
      miss -> {:halt, miss}
    end
  end

  defp deps_well_formed(deps) when is_map(deps) do
    if Enum.all?(deps, &dep_entry?/1), do: :ok, else: @malformed
  end

  defp deps_well_formed(_), do: @malformed

  defp dep_entry?({name, %{"version" => v, "checksum" => c}}),
    do: is_binary(name) and is_binary(v) and is_binary(c)

  defp dep_entry?(_), do: false

  defp app_props({:ok, props}) when is_list(props) do
    keys = [:applications, :included_applications, :optional_applications]
    if Enum.all?(keys, &atoms?(Keyword.get(props, &1, []))), do: {:ok, props}, else: @malformed
  end

  defp app_props({:fail, why}) when is_binary(why), do: {:miss, why}
  defp app_props(_), do: @malformed

  defp atoms?(list), do: is_list(list) and Enum.all?(list, &is_atom/1)

  # {apps to check, optional apps skipped, how many locked optional deps
  # this device goes without}. Only the .app's optional_applications makes
  # an app it lists optional: an app it requires stays required whatever
  # the build's declared says. An optional app that is not named in
  # applications, included_applications or the lock was never part of this
  # build and is not reported as skipped. The count, for ranking, adds the
  # locked deps declared optional that the .app does not list at all.
  defp closure(props, name, b, ctx) do
    deps = b["deps"]
    listed = Keyword.get(props, :optional_applications, [])

    named =
      Keyword.get(props, :applications, []) ++ Keyword.get(props, :included_applications, [])

    {keep, skip} =
      (named ++ listed)
      |> Enum.uniq()
      |> Enum.reject(&(Atom.to_string(&1) == name))
      |> Enum.split_with(&(&1 not in listed or wanted?(&1, deps, ctx)))

    skipped = Enum.filter(skip, &(&1 in named or Map.has_key?(deps, Atom.to_string(&1))))
    known = MapSet.new(named ++ listed, &Atom.to_string/1)

    unlisted =
      Enum.count(declared_optional(b), fn app ->
        Map.has_key?(deps, app) and not MapSet.member?(known, app) and
          not wanted?(existing_atom(app), deps, ctx)
      end)

    locked = Enum.count(skipped, &Map.has_key?(deps, Atom.to_string(&1)))
    {keep, skipped, locked + unlisted}
  end

  # An optional app is checked when the device has it, or when the call
  # requested it and the lock has it (pinned to that version). Requested
  # but not locked, it installs on its own, not tied to this build.
  defp wanted?(nil, _deps, _ctx), do: false

  defp wanted?(app, deps, ctx) do
    device_vsn(app, ctx) != nil or
      (app in Map.get(ctx, :requested, []) and Map.has_key?(deps, Atom.to_string(app)))
  end

  # Read leniently here: rule 8 refuses a malformed declared field.
  defp declared_optional(%{"declared" => items}) when is_list(items),
    do: for(%{"app" => app, "optional" => true} when is_binary(app) <- items, do: app)

  defp declared_optional(_b), do: []

  defp closure_app(app, deps, ctx, acc) do
    case {deps[Atom.to_string(app)], device_vsn(app, ctx)} do
      {nil, nil} -> {:miss, "needs #{app}, which this firmware does not include"}
      {nil, _vsn} -> {:ok, acc}
      {entry, vsn} -> present_dep(app, entry, vsn, acc)
    end
  end

  # Name and exact version only, with no checksum (Q1).
  defp present_dep(app, %{"version" => v, "checksum" => c}, nil, acc),
    do: {:ok, %{acc | needs: acc.needs ++ [%{app: app, version: v, checksum: c}]}}

  defp present_dep(_app, %{"version" => v}, v, acc), do: {:ok, acc}

  defp present_dep(app, %{"version" => v}, dv, _acc),
    do: {:miss, "built against #{app} #{v}, device has #{dv}"}

  # What this tool loaded in this VM is the version in use, even when the
  # Env was read before it was loaded.
  defp device_vsn(app, ctx) do
    case ctx.active do
      %{^app => vsn} when is_binary(vsn) -> vsn
      _ -> present_vsn(ctx.env.present[app])
    end
  end

  defp present_vsn(%{vsn: vsn}) when is_binary(vsn), do: vsn
  defp present_vsn(_), do: nil

  # Rule 8. Ranks, never refuses: a build made without an optional
  # dependency the device has is a coherent build without that integration.
  defp declared(%{"declared" => items} = b, ctx, acc) when is_list(items) do
    if Enum.all?(items, &declared_item?/1),
      do: {:ok, Enum.reduce(items, acc, &uncover(&1, &2, b["deps"] || %{}, ctx))},
      else: @malformed
  end

  defp declared(%{"declared" => d}, _ctx, _acc) when not is_nil(d), do: @malformed

  defp declared(b, _ctx, acc) do
    if empty_deps?(b["deps"]),
      do: {:ok, acc},
      else: {:ok, warn(acc, "build predates declared: optional integrations not checked")}
  end

  # A zero-dependency build has no optional integration to miss (the portal
  # stores an empty deps lock as nil, same as "deps" never recorded).
  defp empty_deps?(deps) when deps in [nil, %{}], do: true
  defp empty_deps?(_), do: false

  defp declared_item?(%{"app" => app}) when is_binary(app), do: true
  defp declared_item?(_), do: false

  defp uncover(%{"app" => app, "optional" => true}, acc, deps, ctx) do
    atom = existing_atom(app)

    if atom && device_vsn(atom, ctx) && not Map.has_key?(deps, app),
      do: %{
        warn(acc, "built without #{app} (present here): its #{app} integration is off")
        | uncovered: acc.uncovered ++ [atom]
      },
      else: acc
  end

  defp uncover(_item, acc, _deps, _ctx), do: acc

  # Rule 9. An item for the package itself, for an app still to be
  # installed or for one not loaded yet is checked after application:load/1.
  defp compile_env(b, name, ctx, acc) do
    with :ok <- Match.present(b, "compile_env"),
         :ok <- items_well_formed(b["compile_env"]) do
      later = MapSet.new([name | Enum.map(acc.needs, &Atom.to_string(&1.app))])
      loaded = loaded_apps(ctx)

      skipped = MapSet.new(acc.skipped, &Atom.to_string/1)
      # A skipped app is never loaded here, so its items have nothing to say.
      items = Enum.reject(b["compile_env"], &MapSet.member?(skipped, &1["app"]))

      {deferred, now} =
        Enum.split_with(items, fn %{"app" => app} ->
          MapSet.member?(later, app) or waiting_to_load?(app, loaded, ctx)
        end)

      case Match.compile_env_ok(now, ctx.config) do
        :ok -> {:ok, %{acc | deferred_env: acc.deferred_env ++ deferred}}
        miss -> miss
      end
    end
  end

  defp items_well_formed(items) when is_list(items) do
    if Enum.all?(items, &env_item?/1), do: :ok, else: @malformed
  end

  defp items_well_formed(_), do: @malformed

  defp env_item?(%{"app" => app, "path" => path, "value" => value})
       when is_binary(app) and is_list(path) and is_binary(value),
       do: Enum.all?(path, &is_binary/1) and Base.url_decode64(value, padding: false) != :error

  defp env_item?(_), do: false

  defp loaded_apps(ctx) do
    loaded = Map.get_lazy(ctx, :loaded, &Application.loaded_applications/0)
    MapSet.new(loaded, &elem(&1, 0))
  end

  # An app the device already has on disk, but has not yet loaded, is
  # checked once application:load/1 has run; an app that is not present,
  # not loaded and not planned is never going to be loaded, so there is
  # nothing to wait for and its item is checked now instead.
  defp waiting_to_load?(app, loaded, ctx) do
    atom = existing_atom(app)
    not MapSet.member?(loaded, atom) and device_vsn(atom, ctx) != nil
  end

  defp existing_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  # Every ebin entry under ebin/ and every priv entry under priv/: the ELF
  # and noexec checks walk the priv list, so a .so must not hide in the
  # ebin one.
  defp lists_in_place?(build) do
    in_dir?(build["ebin"], "ebin/") and in_dir?(build["priv"], "priv/")
  end

  defp in_dir?(nil, _dir), do: true

  defp in_dir?(files, dir) when is_list(files),
    do:
      Enum.all?(
        files,
        &(is_map(&1) and is_binary(&1["path"]) and String.starts_with?(&1["path"], dir))
      )

  defp in_dir?(_files, _dir), do: false

  @spec select(map(), String.t(), nil | String.t(), ctx()) ::
          {:ok, String.t(), map(), verdict()} | {:miss, String.t()}
  def select(manifest, name, req, ctx) do
    versions =
      manifest
      |> versions_of()
      |> Map.keys()
      |> Enum.filter(&match_req?(&1, req))
      |> Enum.sort({:desc, Version})

    case versions do
      [] -> {:miss, if(req, do: "no version matches #{req}", else: "no versions published")}
      _ -> first_passing(versions, manifest, name, ctx)
    end
  end

  defp versions_of(%{"versions" => versions}) when is_map(versions), do: versions
  defp versions_of(_), do: %{}

  defp match_req?(v, req) when is_binary(v) do
    case Version.parse(v) do
      {:ok, parsed} -> req_match?(v, parsed, req)
      :error -> false
    end
  end

  defp match_req?(_, _), do: false

  # No requirement at all cannot name a pre-release, so a pre-release never
  # beats a final release (Hex and Mix both exclude it this way).
  defp req_match?(_v, %Version{pre: []}, nil), do: true
  defp req_match?(_v, %Version{pre: pre}, nil) when pre != [], do: false

  defp req_match?(v, _parsed, req) when is_binary(req) do
    case {Version.parse(req), Version.parse_requirement(req)} do
      {{:ok, _}, _} -> v == req
      {:error, {:ok, r}} -> Version.match?(v, r, allow_pre: false)
      _ -> false
    end
  end

  defp req_match?(_, _, _), do: false

  defp first_passing(versions, manifest, name, ctx) do
    Enum.reduce_while(versions, nil, fn v, first_miss ->
      case best_build(builds_of(manifest, v), name, ctx) do
        {:ok, build, verdict} -> {:halt, {:ok, v, build, verdict}}
        {:miss, why} -> {:cont, first_miss || {:miss, why}}
      end
    end)
  end

  defp builds_of(manifest, v) do
    case manifest["versions"][v] do
      %{"builds" => builds} when is_list(builds) -> builds
      _ -> []
    end
  end

  defp best_build([], _name, _ctx), do: {:miss, "no builds published"}

  defp best_build(builds, name, ctx) do
    results = Enum.map(builds, &{&1, check(&1, name, ctx)})

    case for({b, {:ok, verdict}} <- results, do: {b, verdict}) do
      [] ->
        {:miss, furthest(results)}

      ok ->
        {build, verdict} =
          ok
          |> Match.nearest_release(device_release(ctx.env))
          |> Enum.min_by(fn {b, v} -> rank(b, v, name, ctx) end)

        {:ok, build, verdict}
    end
  end

  defp device_release(%{system: {_name, vsn}}), do: vsn
  defp device_release(_env), do: nil

  # The build that passed the most rules explains the miss best; ties keep
  # the first.
  defp furthest(results) do
    {_, {:miss, why, _}} =
      Enum.reduce(results, fn {_, {:miss, _, n}} = r, {_, {:miss, _, best}} = acc ->
        if n > best, do: r, else: acc
      end)

    why
  end

  # Smaller is better (spec 1.3, device order): the build already in the
  # cache (no download, Q5), the fewest optional dependencies locked in but
  # skipped here (a build made without them is the coherent one), the
  # fewest closure installs, rule 8 coverage,
  # exact Elixir patch then the closest older one, a system build over
  # pure_elixir (it was built on this system's own OTP and ERTS, Q6), and
  # the newest run.
  defp rank(build, verdict, name, ctx) do
    {_, _, built_patch} = Match.parse3(build["build"]["elixir"])
    {_, _, run_patch} = Match.parse3(ctx.env.elixir)
    hash = Match.files_hash(build)
    installed = if hash != nil and ctx.installed[existing_atom(name)] == hash, do: 0, else: 1
    system = if build["target"] == "pure_elixir", do: 1, else: 0

    {installed, verdict.locked_optional, length(verdict.needs), length(verdict.uncovered),
     run_patch - built_patch, system, Match.inverted(build["build"]["run_id"])}
  end
end
