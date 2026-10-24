# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.Match do
  @moduledoc """
  The key: when a precompiled build may stand in for a local compile. Pure
  functions over the project's lock, the manifest entry and the toolchain,
  so every rule is testable without a network or a build.
  """

  @tooling_prefixes ["nerves_system_", "nerves_toolchain_"]
  # elixir_precompiled itself: the client must never install a portal build
  # of itself.
  @tooling_names ["nerves", "nerves_system_br", "nerves_bootstrap", "elixir_precompiled"]

  @type ctx :: %{
          name: String.t(),
          version: String.t(),
          lock_entry: tuple(),
          lock: map(),
          system: {String.t(), String.t()},
          elixir: String.t(),
          otp: String.t(),
          dep_env: String.t(),
          config: (String.t(), [String.t()] -> {:ok, term()} | :error)
        }

  @spec candidate?(atom(), map(), [atom()]) :: boolean()
  def candidate?(dep, lock, except) do
    name = Atom.to_string(dep)

    with true <- Map.has_key?(lock, dep),
         true <- hex?(lock[dep]),
         false <- dep in except,
         false <- tooling?(name),
         false <- dep in nerves_children(lock) do
      true
    else
      _ -> false
    end
  end

  @spec tooling?(String.t()) :: boolean()
  def tooling?(name),
    do: name in @tooling_names or Enum.any?(@tooling_prefixes, &String.starts_with?(name, &1))

  @doc "Lock-closure children of `nerves`; nerves_bootstrap recompiles them whenever it compiles nerves."
  @spec nerves_children(map()) :: [atom()]
  def nerves_children(lock) do
    closure([:nerves], lock, MapSet.new()) |> MapSet.delete(:nerves) |> MapSet.to_list()
  end

  defp closure([], _lock, seen), do: seen

  defp closure([app | rest], lock, seen) do
    if MapSet.member?(seen, app) do
      closure(rest, lock, seen)
    else
      closure(children(lock[app], lock) ++ rest, lock, MapSet.put(seen, app))
    end
  end

  defp children({:hex, _, _, _, _, deps, _, _}, lock),
    do: for({d, _, _} <- deps, Map.has_key?(lock, d), do: d)

  defp children(_, _), do: []

  defp hex?({:hex, _, _, _, _, _, _, outer}) when is_binary(outer), do: true
  defp hex?(_), do: false

  @spec select(map(), ctx()) :: {:ok, map(), String.t()} | {:miss, String.t()}
  def select(manifest, ctx) do
    {system, system_version} = ctx.system

    case get_in(manifest, ["versions", ctx.version, "builds"]) || [] do
      [] ->
        {:miss, "not built for #{ctx.version}"}

      builds ->
        results = Enum.map(builds, &{&1, check(&1, ctx)})

        case Enum.filter(results, &match?({_, {:ok, _}}, &1)) do
          [] ->
            {:miss, furthest_reason(results, system, system_version)}

          ok ->
            {build, _} = Enum.min_by(ok, fn {b, _} -> rank(b, ctx) end)
            {:ok, build, build["target"]}
        end
    end
  end

  # Smaller is better: exact Elixir patch, then the smallest patch gap below
  # the running one, then pure_elixir before a system build, then the
  # newest run (run ids sort newest-first by inverting the string).
  defp rank(build, ctx) do
    {_, _, built_patch} = parse3(build["build"]["elixir"])
    {_, _, run_patch} = parse3(ctx.elixir)
    pure = if build["target"] == "pure_elixir", do: 0, else: 1
    {run_patch - built_patch, pure, inverted(build["build"]["run_id"])}
  end

  # Negated bytes plus a trailing 1 make a larger id compare smaller,
  # including an id that extends another ("ab" < "abc" gives abc first).
  # A missing run id ranks after every real one.
  defp inverted(id) when is_binary(id), do: for(<<c <- id>>, do: -c) ++ [1]
  defp inverted(_), do: [2]

  # When every build missed on its target and none is pure_elixir or for
  # this system, the version simply was not built here; otherwise the
  # build that passed the most rules explains the miss best (ties keep the
  # first), and a build for another system never explains it.
  defp furthest_reason(results, system, system_version) do
    case Enum.reject(results, &foreign?(&1, system)) do
      [] ->
        String.trim_trailing("not built for #{system} #{system_version}")

      own ->
        {_, {:miss, reason, _}} =
          Enum.reduce(own, fn {_, {:miss, _, n}} = r, {_, {:miss, _, best}} = acc ->
            if n > best, do: r, else: acc
          end)

        reason
    end
  end

  defp foreign?({%{"target" => t}, {:miss, _, 0}}, system),
    do: t not in ["pure_elixir", system]

  defp foreign?(_, _), do: false

  defp check(build, ctx) do
    build
    |> rules(ctx)
    |> Enum.reduce_while({:ok, 0}, fn rule, {:ok, n} ->
      case rule.() do
        :ok -> {:cont, {:ok, n + 1}}
        {:miss, reason} -> {:halt, {:miss, reason, n}}
      end
    end)
  catch
    _, _ -> {:miss, "malformed entry", 0}
  end

  defp rules(build, ctx) do
    b = build["build"] || %{}
    {:hex, _, _, _, _, _, _, outer} = ctx.lock_entry

    [
      fn -> target_ok(build["target"], b["system_version"], ctx.system) end,
      fn -> toolchain_present(b) end,
      fn -> elixir_ok(b["elixir"], ctx.elixir) end,
      fn -> otp_ok(b["otp"], ctx.otp) end,
      fn -> dep_env_ok(b["dep_env"], ctx.dep_env) end,
      fn -> present(b, "package_checksum") end,
      fn ->
        eq(b["package_checksum"], outer, fn _, _ -> "package checksum differs from mix.lock" end)
      end,
      fn -> present(b, "deps") end,
      fn -> deps_ok(b["deps"], ctx.lock) end,
      fn -> declared_deps_ok(ctx.lock_entry, b["deps"], ctx.lock) end,
      fn -> present(b, "compile_env") end,
      fn -> compile_env_ok(b["compile_env"], ctx.config) end
    ]
  end

  defp target_ok("pure_elixir", _, _), do: :ok
  defp target_ok(t, built, {t, project}) when built == project, do: :ok

  defp target_ok(t, built, {t, project}),
    do: {:miss, "built for #{t} #{built}, project has #{project}"}

  defp target_ok(t, _, _), do: {:miss, "not built for this system (#{t})"}

  defp toolchain_present(%{"elixir" => e, "otp" => o}) when is_binary(e) and is_binary(o),
    do: :ok

  defp toolchain_present(_), do: {:miss, "build predates toolchain"}

  # Elixir's promise is backward within a minor: code compiled on x.y.N runs
  # on x.y.M for M >= N. Hex builds its own archive on x.y.0 for the same
  # reason; the portal builds on the oldest patch its audience runs.
  # Compared as versions, not patch integers, so a pre-release runtime
  # (1.21.0-rc.0) is older than the final build (1.21.0) and refused, while
  # a pre-release build is still served to the final release.
  defp elixir_ok(built, running) do
    with {:ok, b} <- parse_version(built),
         {:ok, r} <- parse_version(running),
         true <- b.major > 0 and {b.major, b.minor} == {r.major, r.minor},
         true <- Version.compare(r, b) != :lt do
      :ok
    else
      _ -> {:miss, "built with Elixir #{built}, running #{running}"}
    end
  end

  defp parse_version(v) when is_binary(v), do: Version.parse(v)
  defp parse_version(_), do: :error

  # OTP's forward guarantee covers bytecode, not what compile time inlines:
  # Record.extract from OTP headers bakes in layouts that change between
  # majors (public_key.hrl between 27 and 28), so majors must match.
  defp otp_ok(built, running) when built == running, do: :ok
  defp otp_ok(built, running), do: {:miss, "built on OTP #{built}, running #{running}"}

  # A build made before dep_env was recorded has nothing to compare, so the
  # rule that follows (eq/3) would otherwise read `#{nil}` as an empty env.
  defp dep_env_ok(nil, _running), do: {:miss, "build predates dep_env"}

  defp dep_env_ok(built, running),
    do: eq(built, running, &"built with env #{&1}, dependency compiles as #{&2}")

  # {0, 0, 0} for a value that does not parse; only rank/2 uses it, on
  # builds elixir_ok/2 already accepted.
  defp parse3(v) when is_binary(v) do
    case Version.parse(v) do
      {:ok, %Version{major: maj, minor: min, patch: patch}} -> {maj, min, patch}
      :error -> {0, 0, 0}
    end
  end

  defp parse3(_), do: {0, 0, 0}

  defp eq(a, b, _fmt) when a == b, do: :ok
  defp eq(a, b, fmt), do: {:miss, fmt.(a, b)}

  @field_names %{
    "package_checksum" => "package_checksum",
    "deps" => "deps lock",
    "compile_env" => "compile_env"
  }

  defp present(build, key) do
    case Map.fetch(build, key) do
      {:ok, v} when not is_nil(v) -> :ok
      _ -> {:miss, "build predates #{@field_names[key]}"}
    end
  end

  defp deps_ok(deps, lock) do
    Enum.reduce_while(deps, :ok, fn {name, %{"version" => v, "checksum" => c}}, :ok ->
      atom_name =
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError ->
            nil
        end

      case lock[atom_name] do
        {:hex, _, ^v, _, _, _, _, ^c} ->
          {:cont, :ok}

        {:hex, _, ^v, _, _, _, _, _} ->
          {:halt, {:miss, "built against #{name} #{v} with another checksum"}}

        {:hex, _, lv, _, _, _, _, _} ->
          {:halt, {:miss, "built against #{name} #{v}, lock has #{lv}"}}

        _ ->
          {:halt, {:miss, "built against #{name} #{v}, not in lock"}}
      end
    end)
  end

  # Every dep the package declares (optional ones included) that this
  # project locks must have been in the build: an optional dep changes
  # compile-time branches (`Code.ensure_loaded?/1`), so a build made without
  # it is not the build Mix would make here. Versions and checksums of the
  # ones present were already checked by `deps_ok/2`.
  defp declared_deps_ok({:hex, _, _, _, _, declared, _, _}, built, lock) do
    Enum.reduce_while(declared, :ok, fn {name, _req, _opts}, :ok ->
      case lock[name] do
        nil ->
          {:cont, :ok}

        entry ->
          if Map.has_key?(built, Atom.to_string(name)),
            do: {:cont, :ok},
            else: {:halt, {:miss, "built without #{name}, lock has #{locked_version(entry)}"}}
      end
    end)
  end

  defp locked_version({:hex, _, v, _, _, _, _, _}), do: v
  defp locked_version(_), do: "a non-Hex source"

  @spec compile_env_from_app(Path.t()) :: [map()] | nil
  def compile_env_from_app(app_path) do
    case :file.consult(String.to_charlist(app_path)) do
      {:ok, [{:application, _app, props}]} ->
        for {app, path, value} <- Keyword.get(props, :compile_env, []) do
          %{
            "app" => Atom.to_string(app),
            "path" => Enum.map(List.wrap(path), &to_string/1),
            "value" => Base.url_encode64(:erlang.term_to_binary(value), padding: false)
          }
        end

      _ ->
        nil
    end
  end

  @spec compile_env_ok([map()], (String.t(), [String.t()] -> {:ok, term()} | :error)) ::
          :ok | {:miss, String.t()}
  def compile_env_ok(items, config) do
    mismatches =
      for %{"app" => app, "path" => path, "value" => value} <- items,
          :erlang.binary_to_term(Base.url_decode64!(value, padding: false), [:safe]) !=
            config.(app, path),
          do: "#{app} [:#{Enum.join(path, ", :")}]"

    if mismatches == [],
      do: :ok,
      else: {:miss, "compile_env differs: " <> Enum.join(mismatches, ", ")}
  end
end
