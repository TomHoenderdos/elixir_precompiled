# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Match do
  @moduledoc """
  The key: when a precompiled build may stand in for a local compile. Pure
  functions over the project's lock, the manifest entry and the toolchain,
  so every rule is testable without a network or a build.
  """

  alias Precompiled.Reason

  @typep reason :: Reason.t()

  @tooling_prefixes ["nerves_system_", "nerves_toolchain_"]
  # precompiled itself: the client must never install a portal build
  # of itself.
  @tooling_names ["nerves", "nerves_system_br", "nerves_bootstrap", "precompiled"]

  @type ctx :: %{
          optional(:manager) => String.t() | nil,
          optional(:overrides) => [atom()],
          optional(:build_method_unknown) => String.t() | nil,
          # The batch's systems table (Fetch.systems/2), nil without one.
          optional(:systems) => map() | nil,
          # The environment a compile here sees (System.get_env/1 when absent).
          optional(:getenv) => (String.t() -> String.t() | nil),
          optional(:compile_order) => Precompiled.Env.compile_order() | nil,
          # The package's transitive deps as Mix loads them in the current
          # env (Env.closure/2), nil when unknown: then the lock decides.
          optional(:env_closure) => [atom()] | nil,
          optional(:user_config) => (String.t(), String.t() -> term()),
          name: String.t(),
          version: String.t(),
          lock_entry: tuple(),
          lock: map(),
          system: {String.t(), String.t()},
          elixir: String.t(),
          otp: String.t(),
          dep_env: String.t(),
          config: (String.t(), [String.t()] -> {:ok, term()} | :error),
          prefer: String.t() | nil
        }

  @spec candidate?(atom(), map(), [atom()], [atom()] | nil) :: boolean()
  def candidate?(dep, lock, except, tooling \\ nil) do
    name = Atom.to_string(dep)

    with true <- Map.has_key?(lock, dep),
         true <- hex?(lock[dep]),
         false <- dep in except,
         false <- tooling?(name),
         false <- dep in (tooling || []),
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
  def select(manifest, ctx), do: manifest |> select_reason(ctx) |> Reason.textual()

  @doc """
  `select/2` with the reason of a miss as a reason struct: the code
  and arguments a miss report sends, beside the text the line prints.
  """
  @spec select_reason(map(), ctx()) :: {:ok, map(), String.t()} | {:miss, reason()}
  def select_reason(manifest, ctx) do
    {system, system_version} = ctx.system

    case builds(manifest, ctx.version) do
      [] ->
        {:miss, Reason.new(:not_built_version, [ctx.version], "not built for #{ctx.version}")}

      builds ->
        results = Enum.map(builds, &{&1, check(&1, ctx)})

        case Enum.filter(results, &match?({_, {:ok, _}}, &1)) do
          [] ->
            {:miss, furthest_reason(results, system, system_version)}

          ok ->
            {build, _} =
              ok |> nearest_release(system_version) |> Enum.min_by(fn {b, _} -> rank(b, ctx) end)

            {:ok, build, build["target"]}
        end
    end
  end

  # Both lists: builds_with_inputs holds the builds whose compile_inputs need
  # a check here, which clients before 0.6.0 never see.
  defp builds(manifest, version) do
    v = get_in(manifest, ["versions", version]) || %{}
    List.wrap(v["builds"]) ++ List.wrap(v["builds_with_inputs"])
  end

  # The passing builds made for the release closest to the project's: the
  # exact release (and pure_elixir builds, which have none), else the
  # highest release below it, else the lowest above it, else one whose
  # release does not parse, in manifest order. Builds for another release
  # pass only through cross_release/4, so without one this keeps them all.
  # `ok` is a list of `{build, result}` pairs; the device's rules use it too.
  @doc false
  @spec nearest_release([{map(), term()}, ...], term()) :: [{map(), term()}, ...]
  def nearest_release(ok, project) do
    keyed = ok |> Enum.with_index() |> Enum.map(fn {r, i} -> {release_key(r, project, i), r} end)
    {best, _} = Enum.min_by(keyed, &elem(&1, 0), &key_le?/2)
    for {key, r} <- keyed, key_eq?(key, best), do: r
  end

  defp release_key({%{"target" => "pure_elixir"}, _}, _project, _i), do: {0, nil}

  defp release_key({build, _}, project, i) do
    built = (build["build"] || %{})["system_version"]

    with false <- built == project,
         {:ok, b} <- parse_version(built),
         {:ok, p} <- parse_version(project) do
      if Version.compare(b, p) == :lt, do: {1, b}, else: {2, b}
    else
      true -> {0, nil}
      _ -> {3, i}
    end
  end

  defp key_le?({g, a}, {g, b}) when g in [1, 2] do
    order = Version.compare(a, b)
    if g == 1, do: order != :lt, else: order != :gt
  end

  defp key_le?(a, b), do: a <= b

  defp key_eq?({g, a}, {g, b}) when g in [1, 2], do: Version.compare(a, b) == :eq
  defp key_eq?(a, b), do: a == b

  @doc """
  The identity of a build's bytes: sha256 over its files' path, sha256 and
  mode, in path order. Two manifest entries with the same hash install the
  same files. nil for an entry with a malformed file list, or a path with a
  NUL or newline, which could pass one file off as another's line.
  """
  @spec files_hash(map()) :: String.t() | nil
  def files_hash(entry) do
    lines =
      ((entry["ebin"] || []) ++ (entry["priv"] || []))
      |> Enum.map(&file_line/1)
      |> Enum.sort()

    Base.encode16(:crypto.hash(:sha256, lines), case: :lower)
  rescue
    _ -> nil
  end

  defp file_line(%{"path" => p, "sha256" => s, "mode" => m})
       when is_binary(p) and is_binary(s) and is_integer(m) do
    if String.contains?(p, [<<0>>, "\n"]) or String.contains?(s, [<<0>>, "\n"]),
      do: raise(ArgumentError, "unsafe file entry")

    IO.iodata_to_binary([p, 0, s, 0, Integer.to_string(m), ?\n])
  end

  # Smaller is better: the build already installed (when it still passes),
  # then exact Elixir patch, the closest older patch, pure_elixir before a
  # system build, and the newest run (run ids sort newest-first by
  # inverting the string). The installed build is only preferred among
  # builds that pass every rule; it is never a reason to pass.
  defp rank(build, ctx) do
    {_, _, built_patch} = parse3(build["build"]["elixir"])
    {_, _, run_patch} = parse3(ctx.elixir)
    pure = if build["target"] == "pure_elixir", do: 0, else: 1
    prefer = Map.get(ctx, :prefer)
    installed = if is_binary(prefer) and files_hash(build) == prefer, do: 0, else: 1
    {installed, run_patch - built_patch, pure, inverted(build["build"]["run_id"])}
  end

  # Negated bytes plus a trailing 1 make a larger id compare smaller,
  # including an id that extends another ("ab" < "abc" gives abc first).
  # A missing run id ranks after every real one.
  @doc false
  @spec inverted(term()) :: [integer()]
  def inverted(id) when is_binary(id), do: for(<<c <- id>>, do: -c) ++ [1]
  def inverted(_), do: [2]

  # When every build missed on its target and none is pure_elixir or for
  # this system, the version simply was not built here; otherwise the
  # build that passed the most rules explains the miss best (ties keep the
  # first), and a build for another system never explains it.
  defp furthest_reason(results, system, system_version) do
    case Enum.reject(results, &foreign?(&1, system)) do
      [] ->
        Reason.new(
          :not_built_target,
          [system, system_version],
          String.trim_trailing("not built for #{system} #{system_version}")
        )

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
    # Catches everything: a rule that fails on an odd manifest entry makes
    # that build a miss, so the dependency compiles from source instead.
    _, _ -> {:miss, Reason.new(:malformed_entry, [], "malformed entry"), 0}
  end

  defp rules(build, ctx) do
    b = build["build"] || %{}
    {:hex, _, _, _, _, _, _, outer} = ctx.lock_entry

    [
      fn -> target_reason(build["target"], b, ctx.system, ctx) end,
      fn -> build_method_ok(b, ctx) end,
      fn -> compile_inputs_ok(build["target"], b, ctx) end,
      fn -> toolchain_reason(b) end,
      fn -> elixir_reason(b["elixir"], ctx.elixir) end,
      fn -> otp_reason(b["otp"], ctx.otp) end,
      fn -> dep_env_reason(b["dep_env"], ctx.dep_env) end,
      fn -> present_reason(b, "package_checksum") end,
      fn ->
        if b["package_checksum"] == outer,
          do: :ok,
          else:
            {:miss, Reason.new(:checksum_differs, [], "package checksum differs from mix.lock")}
      end,
      fn -> present_reason(b, "deps") end,
      fn -> deps_ok(b["deps"], ctx.lock) end,
      fn -> closure_ok(ctx.lock_entry, b["deps"], ctx.lock, Map.get(ctx, :env_closure)) end,
      fn -> present_reason(b, "compile_env") end,
      fn -> compile_env_reason(b["compile_env"], ctx.config) end,
      fn ->
        Precompiled.CompileInputs.host(
          b["compile_inputs"],
          Map.get(ctx, :getenv, &System.get_env/1),
          %{
            compile_order: Map.get(ctx, :compile_order),
            user_config: Map.get(ctx, :user_config, &Precompiled.CompileInputs.user_config/2)
          }
        )
      end
    ]
  end

  # Rules 1 to 5 are shared with the device layer (Precompiled.Device.Rules), so both print the same text.
  @doc false
  @spec target_ok(String.t(), term(), {String.t(), term()}) :: :ok | {:miss, String.t()}
  def target_ok(t, built, system), do: t |> target_reason(built, system) |> Reason.textual()

  # On the host a build for another release of the same system may still
  # stand in: one with no native code unless its sources read the system at
  # compile time, and a portable native one whose toolchain, OTP and needed
  # libraries the project's release (in the batch's systems table) provides.
  # Anything else is judged exactly as before: the exact release only. The
  # device's rules call this too, with the same systems table.
  @doc false
  @spec target_reason(term(), map(), term(), map()) :: :ok | {:miss, reason()}
  def target_reason(t, b, {t, project} = system, ctx) when t != "pure_elixir" do
    if b["system_version"] == project,
      do: :ok,
      else: cross_release(t, b, system, ctx)
  end

  def target_reason(t, b, system, _ctx), do: target_reason(t, b["system_version"], system)

  defp cross_release(t, b, {t, project}, ctx) do
    cond do
      b["native"] == false ->
        # No scan result (reads nil) is accepted, as compile_inputs_ok/3 does.
        if match?(%{system: true}, Map.get(ctx, :reads)),
          do: {:miss, Reason.new(:system_bound_compile, [])},
          else: :ok

      b["native"] == true and b["portable"] == true and is_map(ctx[:systems]) ->
        abi_match(t, b, project, ctx.systems)

      true ->
        target_reason(t, b["system_version"], {t, project})
    end
  end

  # A release the portal knows only from Hex (its toolchain requirement's
  # series, no OTP or library table yet) is not known well enough to judge,
  # whatever its series: unknown, before the series and OTP are compared.
  defp abi_match(t, b, project, systems) do
    case get_in(systems, [t, project]) do
      %{"otp" => otp, "libs" => libs} = proj when not is_nil(otp) and not is_nil(libs) ->
        with :ok <- same_series(t, b, project, proj),
             :ok <- otp_minor(b["otp_full"], proj["otp"]) do
          libs(b, proj, t, project)
        end

      _ ->
        {:miss, Reason.new(:system_unknown, [t, project])}
    end
  end

  defp same_series(t, b, project, proj) do
    {built_pkg, built_series} = toolchain_series(b["toolchain"])
    proj_pkg = get_in(proj, ["toolchain", "package"])
    proj_series = get_in(proj, ["toolchain", "series"])

    if is_binary(built_pkg) and built_pkg == proj_pkg and is_binary(built_series) and
         built_series == proj_series,
       do: :ok,
       else:
         {:miss,
          Reason.new(:system_version_abi, [
            t,
            b["system_version"],
            built_series || "?",
            project,
            proj_series || "?"
          ])}
  end

  defp toolchain_series(%{"package" => pkg, "version" => v}) when is_binary(v),
    do: {pkg, Precompiled.Elf.series_from_version(v)}

  defp toolchain_series(%{"package" => pkg}), do: {pkg, nil}
  defp toolchain_series(_), do: {nil, nil}

  # The OTP the build was made on must be the release's major, at or below
  # its version: newer OTP releases load older code, not the reverse. OTP
  # maintenance releases have four parts (27.3.4.1), so versions compare as
  # integer lists padded with zeros to the same length.
  defp otp_minor(built, running) do
    with {:ok, [bmaj | _] = b} <- otp_parts(built),
         {:ok, [rmaj | _] = r} <- otp_parts(running),
         true <- bmaj == rmaj,
         {b, r} = pad(b, r),
         true <- b <= r do
      :ok
    else
      _ -> {:miss, Reason.new(:toolchain_otp_minor, [built || "?", running || "?"])}
    end
  end

  defp otp_parts(v) when is_binary(v) do
    parts = String.split(v, ".")

    if Enum.all?(parts, &(&1 =~ ~r/\A\d+\z/)),
      do: {:ok, Enum.map(parts, &String.to_integer/1)},
      else: :error
  end

  defp otp_parts(_), do: :error

  defp pad(a, b) do
    n = max(length(a), length(b))
    {a ++ List.duplicate(0, n - length(a)), b ++ List.duplicate(0, n - length(b))}
  end

  # A release without a library table is not known well enough to judge.
  # A native build with no ELF facts says nothing about the libraries it
  # needs, so it cannot be judged against another release either: a miss,
  # as for any other field a build predates. An empty `needs` is a fact (it
  # needs nothing) and passes.
  defp libs(b, proj, t, project) do
    case {proj, b["elf"]} do
      {%{"libs" => libs}, %{} = elf} when is_map(libs) -> needs_met(elf["needs"] || %{}, libs)
      {%{"libs" => libs}, _} when is_map(libs) -> {:miss, Reason.new(:build_predates, ["elf"])}
      _ -> {:miss, Reason.new(:system_unknown, [t, project])}
    end
  end

  defp needs_met(needs, libs) do
    Enum.reduce_while(needs, :ok, fn {soname, versions}, :ok ->
      case Map.fetch(libs, soname) do
        :error ->
          {:halt, {:miss, Reason.new(:needed_lib_missing, [soname])}}

        {:ok, defined} ->
          case Precompiled.Elf.satisfied?(versions, defined) do
            :ok -> {:cont, :ok}
            {:missing, v} -> {:halt, {:miss, Reason.new(:symbol_version_missing, [soname, v])}}
          end
      end
    end)
  end

  defp target_reason("pure_elixir", _, _), do: :ok
  defp target_reason(t, built, {t, project}) when built == project, do: :ok

  defp target_reason(t, built, {t, project}),
    do:
      {:miss,
       Reason.new(
         :not_built_target,
         [t, project],
         "built for #{t} #{built}, project has #{project}"
       )}

  defp target_reason(t, _, {system, project}),
    do:
      {:miss,
       Reason.new(:not_built_target, [system, project], "not built for this system (#{t})")}

  defp target_reason(t, _, _),
    do: {:miss, Reason.new(:not_built_target, [], "not built for this system (#{t})")}

  # Rule 9: the build must have been made the way Mix builds the dep here.
  # A declaration with :manager, :compile or :system_env builds it another
  # way than the portal did, so nothing matches it. A build that records
  # its manager must name the one Mix resolved here; one that records none
  # predates the field and is judged by the other rules alone.
  # When Mix could not load the deps, how they are built here is unknown
  # and nothing matches.
  defp build_method_ok(build, ctx) do
    case {Map.get(ctx, :build_method_unknown), Map.get(ctx, :overrides, [])} do
      {why, _} when is_binary(why) ->
        {:miss,
         Reason.new(:build_method_unknown, [], "build method unknown (deps did not load: #{why})")}

      {_, [opt | _]} ->
        {:miss,
         Reason.new(
           :build_method_override,
           [Atom.to_string(opt)],
           "project sets #{inspect(opt)} for this dependency"
         )}

      {_, []} ->
        manager_ok(build["manager"], Map.get(ctx, :manager))
    end
  end

  defp manager_ok(nil, _running), do: :ok
  defp manager_ok(built, built) when is_binary(built), do: :ok

  defp manager_ok(built, nil) when is_binary(built),
    do:
      {:miss,
       Reason.new(
         :build_method_mismatch,
         [built, "unknown"],
         "built with #{built}, project's manager for it is unknown"
       )}

  defp manager_ok(built, running) when is_binary(built),
    do:
      {:miss,
       Reason.new(
         :build_method_mismatch,
         [built, running],
         "built with #{built}, project builds with #{running}"
       )}

  defp manager_ok(_built, _running),
    do: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}

  # What the build key does not record (G6): a dep whose own sources read
  # an env var at module level could have been compiled with any value of
  # it; one that reads Mix.target() must have been built for this project's
  # target name: the one the build records, else its system's conventional
  # name (nerves_system_rpi4 -> rpi4; pure_elixir builds are made on host).
  # Sources that could not be scanned could read anything. A build that
  # carries compile_inputs recorded its env reads itself: the env scan does
  # not apply to it (the compile_inputs rule does).
  defp compile_inputs_ok(target, build, ctx) do
    inputs = build["compile_inputs"]

    case Map.get(ctx, :reads) do
      {:unscannable, why} ->
        {:miss, Reason.new(:rule8_unscannable, [], "source not scannable: #{why}")}

      %{env: [var | _]} when not is_list(inputs) ->
        {:miss,
         Reason.new(:rule8_env, [], "reads #{var} at compile time, which no build records")}

      %{target: true} ->
        target_name_ok(target, build, Map.get(ctx, :mix_target, "host"))

      _ ->
        :ok
    end
  end

  defp target_name_ok(target, build, running) do
    built =
      case build["mix_target"] do
        t when is_binary(t) -> t
        _ -> conventional_target(target)
      end

    if built == running,
      do: :ok,
      else:
        {:miss,
         Reason.new(
           :rule8_target,
           [built, running],
           "reads Mix.target() at compile time; built for target #{built}, project targets #{running}"
         )}
  end

  defp conventional_target("pure_elixir"), do: "host"
  defp conventional_target("nerves_system_" <> name), do: name
  defp conventional_target(other), do: to_string(other)

  @doc false
  @spec toolchain_present(map()) :: :ok | {:miss, String.t()}
  def toolchain_present(build), do: build |> toolchain_reason() |> Reason.textual()

  defp toolchain_reason(%{"elixir" => e, "otp" => o}) when is_binary(e) and is_binary(o), do: :ok

  defp toolchain_reason(_),
    do: {:miss, Reason.new(:build_predates, ["toolchain"], "build predates toolchain")}

  # Elixir's promise is backward within a minor: code compiled on x.y.N runs
  # on x.y.M for M >= N. Hex builds its own archive on x.y.0 for the same
  # reason; the portal builds on the oldest patch its audience runs.
  # Compared as versions, not patch integers, so a pre-release runtime
  # (1.21.0-rc.0) is older than the final build (1.21.0) and refused, while
  # a pre-release build is still served to the final release.
  @doc false
  @spec elixir_ok(term(), term()) :: :ok | {:miss, String.t()}
  def elixir_ok(built, running), do: built |> elixir_reason(running) |> Reason.textual()

  defp elixir_reason(built, running) do
    with {:ok, b} <- parse_version(built),
         {:ok, r} <- parse_version(running),
         true <- b.major > 0 and {b.major, b.minor} == {r.major, r.minor},
         true <- Version.compare(r, b) != :lt do
      :ok
    else
      _ ->
        {:miss,
         Reason.new(
           :toolchain_elixir,
           [built, running],
           "built with Elixir #{built}, running #{running}"
         )}
    end
  end

  defp parse_version(v) when is_binary(v), do: Version.parse(v)
  defp parse_version(_), do: :error

  # OTP's forward guarantee covers bytecode, not what compile time inlines:
  # Record.extract from OTP headers bakes in layouts that change between
  # majors (public_key.hrl between 27 and 28), so majors must match.
  @doc false
  @spec otp_ok(term(), term()) :: :ok | {:miss, String.t()}
  def otp_ok(built, running), do: built |> otp_reason(running) |> Reason.textual()

  defp otp_reason(built, running) when built == running, do: :ok

  defp otp_reason(built, running),
    do:
      {:miss,
       Reason.new(:toolchain_otp, [built, running], "built on OTP #{built}, running #{running}")}

  # A build made before dep_env was recorded has nothing to compare, so the
  # comparison would otherwise read `#{nil}` as an empty env.
  @doc false
  @spec dep_env_ok(term(), term()) :: :ok | {:miss, String.t()}
  def dep_env_ok(built, running), do: built |> dep_env_reason(running) |> Reason.textual()

  defp dep_env_reason(nil, _running),
    do: {:miss, Reason.new(:build_predates, ["dep_env"], "build predates dep_env")}

  defp dep_env_reason(built, built), do: :ok

  defp dep_env_reason(built, running),
    do:
      {:miss,
       Reason.new(
         :dep_env_differs,
         [built, running],
         "built with env #{built}, dependency compiles as #{running}"
       )}

  # {0, 0, 0} for a value that does not parse; only rank/2 uses it, on
  # builds elixir_ok/2 already accepted.
  @doc false
  @spec parse3(term()) :: {integer(), integer(), integer()}
  def parse3(v) when is_binary(v) do
    case Version.parse(v) do
      {:ok, %Version{major: maj, minor: min, patch: patch}} -> {maj, min, patch}
      :error -> {0, 0, 0}
    end
  end

  def parse3(_), do: {0, 0, 0}

  @field_names %{
    "package_checksum" => "package_checksum",
    "deps" => "deps lock",
    "compile_env" => "compile_env"
  }

  @doc false
  @spec present(map(), String.t()) :: :ok | {:miss, String.t()}
  def present(build, key), do: build |> present_reason(key) |> Reason.textual()

  defp present_reason(build, key) do
    case Map.fetch(build, key) do
      {:ok, v} when not is_nil(v) -> :ok
      _ -> {:miss, Reason.new(:build_predates, [key], "build predates #{@field_names[key]}")}
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
          {:halt,
           {:miss,
            Reason.new(
              :closure_checksum,
              [name, v],
              "built against #{name} #{v} with another checksum"
            )}}

        {:hex, _, lv, _, _, _, _, _} ->
          {:halt,
           {:miss,
            Reason.new(
              :closure_mismatch,
              [name, v, lv],
              "built against #{name} #{v}, lock has #{lv}"
            )}}

        _ ->
          {:halt,
           {:miss,
            Reason.new(:closure_absent, [name, v], "built against #{name} #{v}, not in lock")}}
      end
    end)
  end

  # The build's closure must be the one Mix compiles the package with
  # here: an optional dep changes compile-time branches
  # (`Code.ensure_loaded?/1`), so a build made with or without it is not
  # the build Mix would make. Versions and checksums of the deps built
  # were already checked by `deps_ok/2`, against the lock.
  #
  # On a build machine `env_closure` is the package's transitive deps as
  # Mix loads them in this env (Env.closure/2), and the build's `deps`, its
  # whole closure, must name exactly those. The lock, shared by every env,
  # cannot say this: it has a project's `only: :test` dep in dev too, at
  # any depth, and lacks a path dep Mix loads all the same. A dep in the
  # env's closure the build lacks misses, one in the build Mix leaves out
  # misses.
  #
  # Where no Mix project was loaded (Mix.install) `env_closure` is nil and
  # the lock decides: every dep the package declares that the lock has must
  # be in the build, and nothing deeper is compared. The device layer does
  # not use this rule (Precompiled.Device.Rules).
  defp closure_ok(_lock_entry, built, lock, env_closure) when is_list(env_closure) do
    built = built |> Map.keys() |> MapSet.new()
    wanted = MapSet.new(env_closure, &Atom.to_string/1)

    case {Enum.sort(MapSet.difference(built, wanted)),
          Enum.sort(MapSet.difference(wanted, built))} do
      {[name | _], _} ->
        {:miss,
         Reason.new(
           :closure_env_absent,
           [name],
           "built with #{name}, which Mix leaves out of it in this env"
         )}

      {[], [name | _]} ->
        {:miss, without(name, lock[String.to_existing_atom(name)])}

      {[], []} ->
        :ok
    end
  end

  defp closure_ok({:hex, _, _, _, _, declared, _, _}, built, lock, nil) do
    Enum.reduce_while(declared, :ok, fn {name, _req, _opts}, :ok ->
      entry = lock[name]

      if entry == nil or Map.has_key?(built, Atom.to_string(name)),
        do: {:cont, :ok},
        else: {:halt, {:miss, without(Atom.to_string(name), entry)}}
    end)
  end

  defp without(name, nil),
    do:
      Reason.new(
        :closure_without,
        [name, "non_hex"],
        "built without #{name}, which is not a Hex dependency here"
      )

  defp without(name, entry),
    do:
      Reason.new(
        :closure_without,
        [name, locked_arg(entry)],
        "built without #{name}, lock has #{locked_version(entry)}"
      )

  defp locked_version({:hex, _, v, _, _, _, _, _}), do: v
  defp locked_version(_), do: "a non-Hex source"

  defp locked_arg({:hex, _, v, _, _, _, _, _}), do: v
  defp locked_arg(_), do: "non_hex"

  @spec compile_env_from_app(Path.t()) :: [map()] | nil
  def compile_env_from_app(app_path) do
    case :file.consult(String.to_charlist(app_path)) do
      {:ok, [{:application, _app, props}]} -> compile_env_items(props)
      _ -> nil
    end
  end

  @doc false
  # The compile_env items of a parsed .app's properties, in manifest form.
  @spec compile_env_items(keyword()) :: [map()]
  def compile_env_items(props) do
    for {app, path, value} <- Keyword.get(props, :compile_env, []) do
      %{
        "app" => Atom.to_string(app),
        "path" => Enum.map(List.wrap(path), &to_string/1),
        "value" => Base.url_encode64(:erlang.term_to_binary(value), padding: false)
      }
    end
  end

  @spec compile_env_ok([map()], (String.t(), [String.t()] -> {:ok, term()} | :error)) ::
          :ok | {:miss, String.t()}
  def compile_env_ok(items, config), do: items |> compile_env_reason(config) |> Reason.textual()

  @doc false
  @spec compile_env_reason([map()], (String.t(), [String.t()] -> {:ok, term()} | :error)) ::
          :ok | {:miss, reason()}
  def compile_env_reason(items, config) do
    if is_list(items) and Enum.all?(items, &well_formed_item?/1),
      do: compare_compile_env(items, config),
      else: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}
  end

  # An item missing a field would otherwise be skipped, never compared.
  defp well_formed_item?(%{"app" => app, "path" => path, "value" => value})
       when is_binary(app) and is_list(path) and is_binary(value),
       do: Base.url_decode64(value, padding: false) != :error

  defp well_formed_item?(_), do: false

  defp compare_compile_env(items, config) do
    mismatches =
      for %{"app" => app, "path" => path, "value" => value} <- items,
          not recorded_equals?(value, config.(app, path)),
          do: {app, "#{app} [:#{Enum.join(path, ", :")}]"}

    if mismatches == [],
      do: :ok,
      else:
        {:miss,
         Reason.new(
           :compile_env_differs,
           mismatches |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
           "compile_env differs: " <> Enum.map_join(mismatches, ", ", &elem(&1, 1))
         )}
  end

  # The recorded value comes from a build of a third-party package, which
  # can put any term in its app env; the manifest signature only says the
  # portal served it. A value SafeTerm refuses (compressed, over the cap,
  # holding a fun, pid, port or reference, or naming an atom this VM has
  # never seen) differs from the project's: no config here can hold it.
  #
  # 64 KiB of decoded ETF, after base64. The portal refuses the same. The
  # recorded values seen so far are at most 124 base64 characters (p99 104,
  # over 6,094 values), so the cap leaves over 500 times the largest.
  @max_recorded_bytes 65_536

  defp recorded_equals?(value, current) do
    with {:ok, bin} <- Base.url_decode64(value, padding: false),
         {:ok, term} <- Precompiled.SafeTerm.decode(bin, @max_recorded_bytes) do
      term == current
    else
      _ -> false
    end
  end
end
