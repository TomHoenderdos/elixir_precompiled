# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Case do
  @moduledoc """
  One conformance case, as data, and its verdict.

  The case file (`conformance/cases.exs`) evaluates to a list of maps, each
  with these keys (and, optionally, `setup`, `client_config` and `after`,
  below):

      %{
        id: "T0",
        description: "One plain sentence.",
        transform: {ChainTest.Mirror.Identity, %{}},
        client: %{default: :snapshot, deps: %{jason: {:miss, "manifest unavailable:"}}},
        harness: %{"build/hit:jason" => :fail}
      }

    * `id` - unique; a letter or digit, then letters, digits, `.` or `-`
      (at most 32). Use the ids of the attack-vector table in README.md.
    * `transform` - `{module, args}`: a `ChainTest.Mirror.Transform` and its
      args map (checked with the module's `valid_args?/1` when it has one),
      applied to every response of the case's mirror.
    * `client` - what the client's `report.json` must say for each of the
      fixture's expected hits (`expected.exs`), each dep named in `deps`
      and each dep the snapshot holds a build of, except the deps `nerves`
      pulls in (`ChainTest.Lock.nerves_children/2`), which the client
      never considers: `deps[dep]`, else `default`.
      An expectation is a report status (`:hit`, `:miss`, `:fail`), a status
      with a detail prefix (`{:miss, "batch stale"}`), or one the snapshot
      decides per dep: `:snapshot`, a hit when the snapshot holds a build
      the client could select, else a miss; `:older_manifest` (M3), a
      hash failure for a dep served an older batch's manifest
      (`ChainTest.Snapshot.older_manifests/1`), else `:snapshot`;
      `:recheck` (R16, `runs: 2` only), from `ChainTest.Snapshot.recheck/1`:
      a hash failure for a held dep the previous batch names another
      manifest for, `revoked: no longer in the current batch` for one it
      names none for, no report line for any other (the install kept). A
      dep the last two make anything but a hit has no fixed `build/hit:`
      row class; its client line is judged instead. `:none`: no report
      line at all (a client that never ran: N2).
    * `harness` - harness results by `"<step>/<check>"` (as the reports
      print them; step `build`, `integrity` or `compiled`) and the class each
      must have. Every result not named must be `:pass` or `:miss`. A
      `:rerun` is a difference too: the snapshot never moves, so a rerun
      means the client used a batch the mirror never served.

  Optional keys, each absent by default:

    * `runs` - `2`: a cold build first (served unchanged by the reference
      mirror, in a throwaway home; every check must pass), then the case's
      own build over that warm `_build` (R16).
    * `setup` - `{module, args}`: a `ChainTest.Conformance.Setup` and its
      args (checked like a transform's), run against the case's fresh client
      home before the build.
    * `client_config` - merged into the fixture's `config
      :precompiled` for this case's build only
      (`ChainTest.Build.client_config?/1`): `clock_offset_seconds`
      (integer, or `{:age, seconds}`: the client's clock that long after
      the snapshot batch's `issued`, `ChainTest.Conformance.Clock`),
      `root` (an absolute path, or `{:test_root, name}`, below), `source`
      (URL).
    * `proxy` - `:mirror`: the build's `HTTP_PROXY` is the case mirror
      (`HTTPS_PROXY` unset), so a plain-http request to any host shows in
      its log as a proxied request (N2). Not with a `tls` transform.
    * `client_env` - environment variables for this case's build only, from
      the few `ChainTest.Build.client_env_names/0` allows (the names a
      client might wrongly take a root path from: T9): each an absolute
      path or `{:home, rel}`, a path under the case's client home (written
      by its setup, say). The build unsets every allowed name it is not
      given.
    * `after` - post-conditions on the client home and `_build` after the
      build, a non-empty map of:
      * `state_sequence` - the client's state file for the case's source
        and root under the case home (`ChainTest.Conformance.Setup.state_dir/3`):
        an integer it must hold, `:snapshot` (the snapshot batch's
        sequence), `:previous` (the snapshot's previous batch's sequence),
        `:absent` (no such file), or `:unchanged` (every state file in the
        home, this one included, as setup left it).
      * `other_states` - `:unchanged`: every state file in the home other
        than that one as setup left it (a second source's, R19).
      * `log` - a non-empty string, or a non-empty list of them, the
        build's output must contain (a warning the client must print, R4).
      * `installed` - `:none` (no `.mix/precompiled.json` anywhere
        in the target's `_build`), `:snapshot` (one for exactly the deps
        the snapshot holds a build of, the Nerves tooling aside), or those
        but some: `{:without, [dep]}`, `:older_manifest`, `:recheck` (the
        deps the matching `client` expectation fails).
      * `cache` - the client cache (`files/` under the home), by
        `t:fingerprint/0`: `:untouched`, every entry as setup left it
        (bytes, link target, kind; nothing gained or removed);
        `:verified`, every entry a regular file directly in `files/` whose
        bytes hash to its name, except one setup planted that is as setup
        left it and whose name no installed file hashes to (a build the
        client never selected).
      * `outside` - `:untouched`: what setup planted under
        `ChainTest.Conformance.Setup.outside_dir/0` (symlink targets, C2)
        as it left it; a setup that planted nothing there fails it.
      * `second_mirror` - only with a transform that asks for `mirrors: 2`:
        `:requested` (the client asked the second mirror for something, a
        redirect it followed, say) or `:untouched` (it asked nothing).
      * `root_version` - the `root_version` file in the client's state dir
        for the case's source and root: `:absent` (no root adopted), or the
        integer it must hold (an adopted root's version, R17).
      * `tls` - only with a `tls` transform: `{:rejected, alert}`, the
        client opened at least one connection to the case mirror and
        aborted every handshake with `alert`, a certificate alert
        (`:bad_certificate`, `:unknown_ca`, ...), and no request got
        through (N3; the alert says why: an unknown CA is `:unknown_ca`, a
        self-signed or wrong-host certificate `:bad_certificate`); `:clean`, no
        handshake failed at all, so the client never sent plain http to
        the TLS port (N6).
      * `proxied` - only with `proxy: :mirror`: `:none`, neither mirror
        logged anything at all (N2: the client made no request, through
        the proxy or to the mirror); `:requested`, at least one request,
        each of them proxied (the control, N2-proxy, showing the route
        works).
      * `unrequested` - a non-empty list of snapshot paths
        (`"v2/manifests/chain_path_dep.json"`) the client must never have
        asked either mirror for (P5-path, P9: a manifest it must not even
        consider): no logged target, decoded, its query dropped, in any
        case, may end in a listed path's base name.

  `gate` (optional) - the id of an earlier case in the file, of the same
  layer (both real-root, or both layer 2): this case runs only after that
  one passed, else it is `:not_exercised` naming it. A refusal whose
  positive control did not pass says nothing (T7 on T7-chained,
  T3-duplicated on T3-pair). `--only` brings a case's gates along.

  Layer 2, test-key cases: a case whose `client_config` gives `root:
  {:test_root, name}` (`ChainTest.TestKey.root_names/0`) is pinned to that
  throwaway test root, and runs against the test-signed copy of the
  snapshot (`ChainTest.TestKey`): `layer2?/1`. A transform or setup module
  that exports `test_root_only?/0` (it signs with the test keys) is only
  accepted in such a case. A file with a layer-2 case must hold the
  control `L2-T0`: `ChainTest.Mirror.Identity` under `{:test_root, :v1}`,
  the test-signed copy unchanged; the runner judges every other layer-2
  case only after it passed.

  Whatever the case expects, a report line that calls a dep a hit when the
  snapshot holds no build of it the client could select is a difference:
  the client installed something the portal never served it.

  A case whose `after` has `tls: {:rejected, alert}` or `proxied` is judged by the
  mirror's log alone, as those say, instead of the two checks below: the
  client cannot have used a mirror it refused, or never asked (N3, N2).
  For `tls: {:rejected, alert}` a log without a single handshake is
  `:not_exercised`: the client never connected.

  The case's mirror must show that the client used it: a `GET batch.json`
  and, for every dep the report calls a hit, a `GET` of the snapshot's
  manifest path the mirror answered 200 (or whose response the case's own
  transform changed). Without that, the client may have read another
  source.

  Verdict, one `conformance/<id>` result:

    * `:fail` when either of the case's mirrors logged a `transform_error`
      (the transform crashed or answered a malformed shape), naming each;
    * `:not_exercised` when the transform is neither
      `ChainTest.Mirror.Identity` nor a trap (`ChainTest.Mirror.Transform.trap?/1`)
      and the mirror served nothing it changed, or when the transform is
      `ChainTest.Mirror.Identity` and the mirror shows no use by the client;
    * else `:pass` when the client used the mirror and the client and every
      harness result match, `:fail` naming each difference. The runner's
      `isolation` problems (a real-root case whose home or config shows a
      test root, or a layer-2 case's showing the real one) are differences
      too.
  """

  alias ChainTest.{Build, Mirror, Result, Snapshot}
  alias ChainTest.Conformance.{Clock, Setup}
  alias ChainTest.Conformance.Setup.PlantRoot
  alias ChainTest.Mirror.Transform

  @type status :: :hit | :miss | :fail
  @type expect ::
          :snapshot | :recheck | :older_manifest | :none | status() | {status(), String.t()}
  @type post :: %{
          optional(:state_sequence) => integer() | :snapshot | :previous | :absent | :unchanged,
          optional(:other_states) => :unchanged,
          optional(:log) => String.t() | [String.t()],
          optional(:installed) => :none | :snapshot | :recheck | {:without, [String.t()]},
          optional(:cache) => :untouched | :verified,
          optional(:outside) => :untouched,
          optional(:second_mirror) => :requested | :untouched,
          optional(:root_version) => :absent | non_neg_integer(),
          optional(:unrequested) => [String.t()],
          optional(:tls) => {:rejected, atom()} | :clean,
          optional(:proxied) => :none | :requested
        }
  @type t :: %{
          required(:id) => String.t(),
          required(:description) => String.t(),
          required(:transform) => {module(), map()},
          required(:client) => %{default: expect(), deps: %{atom() => expect()}},
          required(:harness) => %{String.t() => Result.class()},
          optional(:setup) => {module(), map()},
          optional(:client_config) => ChainTest.Build.client_config(),
          optional(:client_env) => %{String.t() => Path.t() | {:home, Path.t()}},
          optional(:runs) => 2,
          optional(:proxy) => :mirror,
          optional(:gate) => String.t(),
          optional(:after) => post()
        }

  @typedoc """
  What the runner saw of the case home, right after setup (`before`) and
  after the build (`after`): every client state file (`"<dir>/state" =>
  contents`), the cache entries (paths under the home), and the case
  source's own state file (`{:ok, "<dir>/state"}`, or why it has none); and
  the deps `_build` holds a provenance file for (a stray one by its path).
  """
  @type observed :: %{
          required(:before) => home_view(),
          required(:after) => home_view(),
          required(:installed) => [String.t()],
          optional(:installed_files) => MapSet.t(String.t()),
          optional(:log) => String.t()
        }
  @type home_view :: %{
          required(:states) => %{String.t() => binary()},
          required(:cache) => %{String.t() => fingerprint()},
          optional(:outside) => %{String.t() => fingerprint()},
          required(:own) => {:ok, String.t()} | {:error, String.t()},
          optional(:root_versions) => %{String.t() => binary()}
        }
  @typedoc """
  One entry under the home, never following a symlink: a directory, a
  regular file by the sha256 (lowercase hex) of its bytes, a symlink by its
  target, or anything else by its type.
  """
  @type fingerprint ::
          :dir | {:file, String.t()} | {:link, String.t()} | {:other, atom()}

  @keys [:client, :description, :harness, :id, :transform]
  @optional [:after, :client_config, :client_env, :gate, :proxy, :runs, :setup]
  @post_keys [
    :cache,
    :installed,
    :log,
    :other_states,
    :outside,
    :proxied,
    :root_version,
    :second_mirror,
    :state_sequence,
    :tls,
    :unrequested
  ]
  # The alerts a TLS client sends when it refuses the server's certificate.
  @cert_alerts [
    :bad_certificate,
    :unknown_ca,
    :certificate_unknown,
    :unsupported_certificate,
    :certificate_expired,
    :certificate_revoked
  ]
  @control "L2-T0"
  @statuses [:hit, :miss, :fail]
  @benign [:pass, :miss]
  @identity ChainTest.Mirror.Identity

  @doc "Evaluates and validates a case file."
  @spec load(Path.t()) :: {:ok, [t()]} | {:error, String.t()}
  def load(path) do
    {cases, _binding} = Code.eval_file(path)

    with :ok <- list(cases),
         :ok <- Enum.find_value(cases, :ok, &problem/1),
         :ok <- unique(cases),
         :ok <- control(cases),
         :ok <- gates(cases) do
      {:ok, cases}
    end
  rescue
    e -> {:error, "#{path}: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "#{path}: #{kind} #{inspect(reason)}"}
  end

  defp list(cases) when is_list(cases) and cases != [], do: :ok
  defp list(_), do: {:error, "a case file is a non-empty list of case maps"}

  defp unique(cases) do
    case cases |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] -> :ok
      dups -> {:error, "duplicate case ids: #{Enum.map_join(dups, ", ", &elem(&1, 0))}"}
    end
  end

  # A file with a layer-2 case holds its control: the test-signed copy,
  # unchanged, under the test root v1.
  defp control(cases) do
    cond do
      not Enum.any?(cases, &layer2?/1) ->
        :ok

      Enum.any?(cases, &control?/1) ->
        :ok

      true ->
        {:error,
         "a layer-2 case (client_config root {:test_root, name}) needs the #{@control} " <>
           "control: ChainTest.Mirror.Identity under root {:test_root, :v1}"}
    end
  end

  # Each gate names an earlier case of the same layer.
  defp gates(cases) do
    cases
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {c, i} ->
      case Map.fetch(c, :gate) do
        :error -> nil
        {:ok, gate} -> gate_problem(c, gate, Enum.take(cases, i))
      end
    end)
  end

  defp gate_problem(c, gate, earlier) do
    target = Enum.find(earlier, &(&1.id == gate))

    cond do
      target == nil ->
        {:error,
         "case #{inspect(c.id)}: gate #{inspect(gate)} must name an earlier case in the file"}

      layer2?(target) != layer2?(c) ->
        {:error,
         "case #{inspect(c.id)}: gate #{inspect(gate)} is of the other layer; a gate runs " <>
           "in the same layer as the case it gates"}

      true ->
        nil
    end
  end

  @doc "The id of the case `c` is gated on, or `nil`."
  @spec gate(map()) :: String.t() | nil
  def gate(c), do: Map.get(c, :gate)

  @doc "Whether `c` is the layer-2 control, `L2-T0` (see the moduledoc)."
  @spec control?(map()) :: boolean()
  def control?(%{
        id: @control,
        transform: {@identity, _},
        client_config: %{root: {:test_root, :v1}}
      }),
      do: true

  def control?(_c), do: false

  @doc "The layer-2 control's id."
  @spec control_id() :: String.t()
  def control_id(), do: @control

  @doc "Whether `c` is pinned to a test root: a layer-2 case."
  @spec layer2?(map()) :: boolean()
  def layer2?(%{client_config: %{root: {:test_root, _}}}), do: true
  def layer2?(_c), do: false

  # nil when the case is valid, else {:error, why}.
  defp problem(%{} = c) do
    id = inspect(Map.get(c, :id))

    case required_problem(c) || optional_problem(c) do
      nil -> nil
      why -> {:error, "case #{id}: " <> why}
    end
  end

  defp problem(other), do: {:error, "a case must be a map, got #{inspect(other)}"}

  defp required_problem(c) do
    keys = Map.keys(c)

    cond do
      Enum.sort(keys -- @optional) != @keys or keys -- (@keys ++ @optional) != [] ->
        "keys must be #{inspect(@keys)}, optionally #{inspect(@optional)}, got #{inspect(keys)}"

      not id?(c.id) ->
        "an id is a letter or digit, then letters, digits, . or -"

      not description?(c.description) ->
        "description must be a sentence"

      not Transform.valid?(c.transform) ->
        "transform #{inspect(c.transform)} is not {module, args} with args the module accepts"

      not client?(c.client) ->
        "client must be %{default: expect, deps: %{dep => expect}}"

      not harness?(c.harness) ->
        "harness must map \"step/check\" to a result class"

      true ->
        nil
    end
  end

  defp optional_problem(c),
    do: runs_problem(c) || setup_problem(c) || test_root_problem(c) || trap_setup_problem(c)

  # A files_of trap (C0) answers its dep's files with an error, so only a
  # cache that holds them can make that dep a hit: the case's setup must
  # plant exactly those files.
  defp trap_setup_problem(%{transform: {ChainTest.Mirror.Status, %{files_of: dep}}} = c) do
    case Map.get(c, :setup) do
      {ChainTest.Conformance.Setup.Cache, %{plant: :all_files, deps: deps}} when is_list(deps) ->
        unless dep in deps,
          do:
            "files_of #{inspect(dep)} needs a Cache setup whose deps name it, got #{inspect(deps)}"

      other ->
        "files_of #{inspect(dep)} needs setup {ChainTest.Conformance.Setup.Cache, " <>
          "%{plant: :all_files, deps: [#{inspect(dep)}, ...]}}, got #{inspect(other)}"
    end
  end

  defp trap_setup_problem(_c), do: nil

  # A transform or setup that signs with the test keys runs only where the
  # client is pinned to the test root.
  defp test_root_problem(c) do
    only =
      for {module, _} <- [c.transform, Map.get(c, :setup)],
          is_atom(module),
          Code.ensure_loaded?(module),
          function_exported?(module, :test_root_only?, 0),
          do: inspect(module)

    if only != [] and not layer2?(c),
      do:
        "#{Enum.join(only, ", ")} signs with the test keys: it needs a test root " <>
          "(client_config root {:test_root, name})"
  end

  defp runs_problem(c) do
    cond do
      Map.has_key?(c, :runs) and c.runs != 2 ->
        "runs must be 2 (a warm build first), got #{inspect(c.runs)}"

      recheck?(c.client) and runs(c) != 2 ->
        "the :recheck client expectation needs runs: 2"

      runs(c) == 2 and layer2?(c) ->
        "runs: 2 is not for a layer-2 case: its warm build is served the real snapshot"

      true ->
        nil
    end
  end

  defp setup_problem(c) do
    cond do
      Map.has_key?(c, :setup) and not Setup.valid?(c.setup) ->
        "setup #{inspect(c.setup)} is not {module, args} with a " <>
          "ChainTest.Conformance.Setup and args it accepts"

      Map.has_key?(c, :client_config) and not Clock.case_config?(c.client_config) ->
        "client_config must map clock_offset_seconds to an integer or {:age, integer}, " <>
          "root to an absolute path and source to a non-empty string, got " <>
          inspect(c.client_config)

      Map.has_key?(c, :client_env) and not client_env?(c.client_env) ->
        "client_env must map names from #{inspect(Build.client_env_names())} to an " <>
          "absolute path or {:home, relative path}, got #{inspect(c.client_env)}"

      true ->
        proxy_problem(c) || post_problem(c)
    end
  end

  defp proxy_problem(c) do
    cond do
      not Map.has_key?(c, :proxy) -> nil
      c.proxy != :mirror -> "proxy must be :mirror, got #{inspect(c.proxy)}"
      Transform.tls(c.transform) != nil -> "proxy: :mirror is plain http, not for a tls transform"
      true -> nil
    end
  end

  defp post_problem(%{after: post} = c),
    do: after_problem(post, c.transform) || log_post_problem(c)

  defp post_problem(_c), do: nil

  defp log_post_problem(c) do
    cond do
      Map.has_key?(c.after, :tls) and Transform.tls(c.transform) == nil ->
        "after tls needs a transform with tls"

      Map.has_key?(c.after, :proxied) and Map.get(c, :proxy) != :mirror ->
        "after proxied needs proxy: :mirror"

      true ->
        nil
    end
  end

  defp after_problem(post, transform) do
    cond do
      not post?(post) ->
        "after must be a non-empty map of state_sequence (integer, :snapshot, " <>
          ":previous, :absent, :unchanged), other_states (:unchanged), installed " <>
          "(:none, :snapshot, :recheck, {:without, [dep name]}), cache (:untouched, " <>
          ":verified), outside (:untouched), log (non-empty strings), " <>
          "second_mirror (:requested, :untouched), root_version (:absent, integer), " <>
          "unrequested ([path]), tls ({:rejected, certificate alert}, :clean), proxied (:none, :requested), got " <>
          inspect(post)

      Map.has_key?(post, :second_mirror) and Transform.mirrors(transform) != 2 ->
        "after second_mirror needs a transform with mirrors: 2"

      true ->
        nil
    end
  end

  defp client_env?(env) when is_map(env) and map_size(env) > 0 do
    Enum.all?(env, fn {name, value} ->
      name in Build.client_env_names() and client_env_value?(value)
    end)
  end

  defp client_env?(_env), do: false

  defp client_env_value?({:home, rel}), do: PlantRoot.inside?(rel)
  defp client_env_value?(path), do: is_binary(path) and Path.type(path) == :absolute

  defp id?(id), do: is_binary(id) and id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9.-]{0,31}\z/

  defp description?(description), do: is_binary(description) and description != ""

  defp client?(%{default: default, deps: deps} = client)
       when map_size(client) == 2 and is_map(deps),
       do: expect?(default) and Enum.all?(deps, fn {k, v} -> is_atom(k) and expect?(v) end)

  defp client?(_), do: false

  defp expect?(:snapshot), do: true
  defp expect?(:recheck), do: true
  defp expect?(:older_manifest), do: true
  defp expect?(:none), do: true
  defp expect?(s) when s in @statuses, do: true
  defp expect?({s, prefix}) when s in @statuses and is_binary(prefix), do: true
  defp expect?(_), do: false

  defp harness?(h) when is_map(h) do
    Enum.all?(h, fn {k, v} ->
      is_binary(k) and String.contains?(k, "/") and v in Result.classes()
    end)
  end

  defp harness?(_), do: false

  defp post?(post) when is_map(post) and map_size(post) > 0,
    do: Enum.all?(post, fn {k, v} -> k in @post_keys and post_value?(k, v) end)

  defp post?(_), do: false

  defp post_value?(:state_sequence, v),
    do: is_integer(v) or v in [:snapshot, :previous, :absent, :unchanged]

  defp post_value?(:other_states, v), do: v == :unchanged
  defp post_value?(:log, v) when is_list(v), do: v != [] and Enum.all?(v, &post_value?(:log, &1))
  defp post_value?(:log, v), do: is_binary(v) and v != ""

  defp post_value?(:installed, {:without, [_ | _] = deps}),
    do: Enum.all?(deps, &(is_binary(&1) and &1 != ""))

  defp post_value?(:installed, v), do: v in [:none, :snapshot, :recheck, :older_manifest]
  defp post_value?(:cache, v), do: v in [:untouched, :verified]
  defp post_value?(:outside, v), do: v == :untouched
  defp post_value?(:second_mirror, v), do: v in [:requested, :untouched]
  defp post_value?(:root_version, v), do: v == :absent or (is_integer(v) and v >= 0)

  defp post_value?(:unrequested, [_ | _] = paths),
    do: Enum.all?(paths, &(is_binary(&1) and &1 != ""))

  defp post_value?(:unrequested, _v), do: false
  defp post_value?(:tls, {:rejected, alert}), do: alert in @cert_alerts
  defp post_value?(:tls, v), do: v == :clean
  defp post_value?(:proxied, v), do: v in [:none, :requested]

  @doc "How many builds the case runs: 2 with `runs: 2` (a warm build first), else 1."
  @spec runs(t()) :: 1 | 2
  def runs(c), do: Map.get(c, :runs, 1)

  defp recheck?(%{default: default, deps: deps}),
    do: default == :recheck or Enum.any?(deps, fn {_, v} -> v == :recheck end)

  defp recheck?(_client), do: false

  @doc "The case's verdict on one run (see the moduledoc)."
  @spec judge(t(), %{
          required(:rows) => [Result.t()],
          required(:report) => map(),
          required(:requests) => [Mirror.request()],
          required(:snapshot) => map(),
          required(:hits) => [atom()],
          optional(:tooling) => [String.t()],
          optional(:second_requests) => [Mirror.request()],
          optional(:observed) => observed() | nil,
          optional(:isolation) => [String.t()]
        }) :: Result.t()
  def judge(
        c,
        %{rows: rows, report: report, requests: requests, snapshot: snap, hits: hits} = input
      ) do
    unused = unused_mirror(report, requests, snap)
    identity? = match?({@identity, _}, c.transform)

    broken =
      transform_errors(requests, "mirror") ++
        transform_errors(Map.get(input, :second_requests, []), "second mirror")

    post = Map.get(c, :after, %{})

    cond do
      broken != [] ->
        result(c, :fail, Enum.join(broken, "; "))

      match?({:rejected, _}, post[:tls]) or Map.has_key?(post, :proxied) ->
        by_log(c, input)

      identity? and unused != [] ->
        result(c, :not_exercised, Enum.join(unused, "; "))

      not identity? and not changed_or_trap?(c, requests) ->
        result(c, :not_exercised, "the mirror never served anything the transform changed")

      true ->
        verdict(
          c,
          unused ++ client_problems(c, report, snap, hits, input) ++ judged(c, rows, snap, input)
        )
    end
  end

  # The mirror changed a response the client asked for, or the transform is
  # a trap, whose changing nothing is the expected outcome (C0).
  defp changed_or_trap?(c, requests),
    do: ChainTest.Mirror.Transform.trap?(c.transform) or Enum.any?(requests, & &1.mutated)

  # N3, N2: the client cannot have used a mirror it refused or never asked;
  # the mirror's log, as the case's `after` says, is the evidence.
  defp by_log(c, %{rows: rows, report: report, requests: requests, snapshot: snap} = input) do
    if match?({:rejected, _}, c.after[:tls]) and not Enum.any?(requests, &handshake?/1) do
      result(
        c,
        :not_exercised,
        "the client never connected to the case's TLS mirror: no handshake to judge"
      )
    else
      verdict(
        c,
        client_problems(c, report, snap, input.hits, input) ++ judged(c, rows, snap, input)
      )
    end
  end

  defp judged(c, rows, snap, input) do
    unheld_hits(input.report, snap) ++
      harness_problems(c, rows, snap) ++
      post_problems(c, input, snap) ++ Map.get(input, :isolation, [])
  end

  defp verdict(c, []), do: result(c, :pass, "as expected: #{c.description}")
  defp verdict(c, problems), do: result(c, :fail, Enum.join(problems, "; "))

  defp handshake?(%{method: "TLS"}), do: true
  defp handshake?(_request), do: false

  # A transform that crashed or answered a malformed shape was never the
  # mutation the case meant: the client saw only the mirror's 500.
  defp transform_errors(requests, which) do
    for %{transform_error: why, path: path} <- requests,
        do: "#{which}: transform error on #{path}: #{why}"
  end

  # What the mirror's log lacks to show that the client read the batch and
  # every manifest it reports a hit from through the case's mirror. A hit's
  # manifest must have been answered 200, unless the case's own transform
  # changed that response.
  defp unused_mirror(report, requests, snap) do
    asked = MapSet.new(for %{method: "GET", path: path} <- requests, do: path)

    served =
      MapSet.new(
        for %{method: "GET", path: path} = r <- requests,
            r.status == 200 or r.mutated,
            do: path
      )

    batch =
      if MapSet.member?(asked, "batch.json"),
        do: [],
        else: ["mirror: the client never asked the case's mirror for batch.json"]

    manifests =
      for {name, %{"status" => "hit"}} <- Enum.sort(lines(report)),
          path = manifest_path(snap, name),
          is_binary(path),
          not MapSet.member?(served, path),
          do:
            "mirror: the client reports #{name} a hit but the case's mirror never " <>
              "answered #{path} with 200"

    batch ++ manifests
  end

  defp manifest_path(snap, name) do
    case Map.get(snap.deps, name) do
      %{manifest: path} -> path
      _ -> nil
    end
  end

  defp lines(report) do
    for %{"name" => n} = l <- Map.get(report || %{}, "lines", []),
        is_binary(n),
        into: %{},
        do: {n, l}
  end

  # Every expected hit, every dep the case names and every dep the snapshot
  # holds a build of, except the Nerves tooling the client never considers
  # (`ChainTest.Lock.nerves_children/2`, given as `:tooling`).
  defp client_problems(c, report, snap, hits, input) do
    lines = lines(report)
    named = Map.new(c.client.deps, fn {dep, want} -> {to_string(dep), want} end)
    tooling = Map.get(input, :tooling, [])
    held = for {name, _} <- snap.deps, held?(snap, name), name not in tooling, do: name

    (Enum.map(hits, &to_string/1) ++ Map.keys(named) ++ Enum.sort(held))
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      want = resolve(Map.get(named, name, c.client.default), snap, name)
      got = lines[name]

      if matches?(want, got),
        do: [],
        else: ["client #{name}: expected #{describe(want)}, got #{describe_line(got)}"]
    end)
  end

  defp resolve(:snapshot, snap, name), do: if(held?(snap, name), do: :hit, else: :miss)

  # R16, the second build over a warm `_build`: a dep the previous batch
  # names another manifest for is matched again and fails that manifest's
  # hash (the mirror serves only N's bytes); one it names no manifest for is
  # revoked; any other installed build is kept, without a report line.
  defp resolve(:recheck, snap, name) do
    case Map.get(Snapshot.recheck(snap), name) do
      :differs -> {:fail, "manifest hash differs from batch"}
      :unnamed -> {:miss, "revoked: no longer in the current batch"}
      nil -> :kept
    end
  end

  # M3: a dep served the manifest an older batch names fails its hash; the
  # others are as the snapshot holds them.
  defp resolve(:older_manifest, snap, name) do
    if name in older_manifest_deps(snap),
      do: {:fail, "manifest hash differs from batch"},
      else: resolve(:snapshot, snap, name)
  end

  defp resolve(expect, _snap, _name), do: expect

  defp older_manifest_deps(snap),
    do: snap |> Snapshot.older_manifests() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  # Whether the snapshot holds a build of `name` the client could select.
  defp held?(snap, name) do
    case Map.get(snap.deps, name) do
      %{builds: n} when is_integer(n) and n > 0 -> true
      _ -> false
    end
  end

  defp unheld_hits(report, snap) do
    for {name, %{"status" => "hit"}} <- Enum.sort(lines(report)),
        not held?(snap, name),
        do: "client #{name}: a hit, but the snapshot holds no build of it"
  end

  defp matches?(:kept, got), do: got == nil
  defp matches?(:none, got), do: got == nil
  defp matches?(_want, nil), do: false

  defp matches?({status, prefix}, %{"status" => got, "detail" => detail}) when is_binary(detail),
    do: Atom.to_string(status) == got and String.starts_with?(detail, prefix)

  defp matches?({_status, _prefix}, _line), do: false
  defp matches?(status, %{"status" => got}), do: Atom.to_string(status) == got
  defp matches?(_want, _line), do: false

  defp describe(:kept), do: "no report line (the installed build kept)"
  defp describe(:none), do: "no report line (the client never ran)"
  defp describe({status, prefix}), do: "#{status} (#{inspect(prefix)}...)"
  defp describe(status), do: to_string(status)

  defp describe_line(nil), do: "no report line"
  defp describe_line(l), do: "#{l["status"]} (#{inspect(l["detail"])})"

  # A warm second build (`runs: 2`) keeps installs the cold build made and
  # its step 3 and 4 checked: the integrity `unreported:` row of a dep it
  # kept (no report line this time), and step 4's `compiled_here`, which
  # lists the deps the cold build compiled and this one did not report.
  # Kept installs are still judged: by their client line (none) and by
  # `installed`.
  defp carried_over(c, snap) do
    if runs(c) == 2 do
      named = Map.new(c.client.deps, fn {dep, want} -> {to_string(dep), want} end)

      kept =
        for {name, _} <- snap.deps,
            resolve(Map.get(named, name, c.client.default), snap, name) == :kept,
            do: "integrity/unreported:#{name}"

      ["compiled/compiled_here" | kept]
    else
      []
    end
  end

  defp derived_misses(c, snap) do
    named = Map.new(c.client.deps, fn {dep, want} -> {to_string(dep), want} end)

    for {name, _} <- snap.deps,
        want = Map.get(named, name, c.client.default),
        want in [:recheck, :older_manifest],
        resolve(want, snap, name) != :hit,
        do: "hit:#{name}"
  end

  defp harness_problems(c, rows, snap) do
    keyed = Map.new(rows, &{key(&1), &1})

    named =
      c.harness
      |> Enum.sort()
      |> Enum.flat_map(fn {key, class} ->
        case keyed[key] do
          nil -> ["harness #{key}: expected #{class}, there is no such result"]
          %Result{class: ^class} -> []
          r -> ["harness #{key}: expected #{class}, got #{r.class} (#{r.detail})"]
        end
      end)

    # A dep whose expectation the snapshot decides (`:recheck`,
    # `:older_manifest`) and that is no hit has no fixed `hit:` row class to
    # name; its client line, judged above, says what the row would.
    derived = derived_misses(c, snap)

    carried = carried_over(c, snap)

    unnamed =
      for r <- rows,
          not Map.has_key?(c.harness, key(r)),
          not (r.step == :build and r.check in derived),
          key(r) not in carried,
          r.class not in @benign,
          do: "unexpected #{r.class} #{key(r)}: #{r.detail}"

    named ++ unnamed
  end

  defp key(%Result{step: step, check: check}), do: "#{step}/#{check}"

  # The case's `after`, against what the runner observed.
  defp post_problems(c, input, snap) do
    case {Map.get(c, :after), Map.get(input, :observed)} do
      {nil, _} ->
        []

      {_post, nil} ->
        ["after: the runner observed nothing to check the post-conditions against"]

      {post, seen} ->
        post
        |> Enum.sort()
        |> Enum.flat_map(fn {key, want} -> post_problem(key, want, seen, snap, input) end)
    end
  end

  defp post_problem(:state_sequence, :unchanged, seen, _snap, _input) do
    before = seen.before.states
    now = seen.after.states

    for rel <- Enum.sort(Enum.uniq(Map.keys(before) ++ Map.keys(now))),
        before[rel] != now[rel],
        do:
          "after state_sequence: expected the state unchanged, #{rel} was " <>
            "#{state(before[rel])}, is #{state(now[rel])}"
  end

  defp post_problem(:log, want, seen, _snap, _input) do
    log = Map.get(seen, :log)

    if is_binary(log) do
      for s <- List.wrap(want),
          not String.contains?(log, s),
          do: "after log: the build's output never says #{inspect(s)}"
    else
      ["after log: the runner kept no build output to check"]
    end
  end

  defp post_problem(:other_states, :unchanged, seen, _snap, _input) do
    case seen.after.own do
      {:error, why} ->
        ["after other_states: cannot name the client's state dir: #{why}"]

      {:ok, own} ->
        before = Map.delete(seen.before.states, own)
        now = Map.delete(seen.after.states, own)

        for rel <- Enum.sort(Enum.uniq(Map.keys(before) ++ Map.keys(now))),
            before[rel] != now[rel],
            do:
              "after other_states: expected every other state unchanged, #{rel} was " <>
                "#{state(before[rel])}, is #{state(now[rel])}"
    end
  end

  defp post_problem(:state_sequence, want, seen, snap, _input) do
    case seen.after.own do
      {:error, why} ->
        ["after state_sequence: cannot name the client's state dir: #{why}"]

      {:ok, rel} ->
        got = seen.after.states[rel]

        case {want, got} do
          {:absent, nil} -> []
          {:absent, got} -> ["after state_sequence: expected no #{rel}, it holds #{state(got)}"]
          {n, got} -> sequence_problem(sequence(n, snap), got, rel)
        end
    end
  end

  defp post_problem(:installed, :none, seen, _snap, _input) do
    case seen.installed do
      [] -> []
      found -> ["after installed: expected nothing installed, found #{Enum.join(found, ", ")}"]
    end
  end

  defp post_problem(:installed, want, seen, snap, input) do
    tooling = Map.get(input, :tooling, [])
    held = for {name, _} <- snap.deps, held?(snap, name), name not in tooling, do: name

    left_out =
      case want do
        :snapshot -> []
        {:without, deps} -> deps
        :recheck -> Map.keys(Snapshot.recheck(snap))
        :older_manifest -> older_manifest_deps(snap)
      end

    want = Enum.sort(held -- left_out)
    got = Enum.sort(seen.installed)

    if got == want,
      do: [],
      else: [
        "after installed: expected exactly #{inspect(want)} installed, found #{inspect(got)}"
      ]
  end

  defp post_problem(:second_mirror, want, _seen, _snap, input) do
    asked = for %{path: path} <- Map.get(input, :second_requests, []), do: path

    case {want, asked} do
      {:requested, []} ->
        ["after second_mirror: expected the client to ask the second mirror, it asked nothing"]

      {:untouched, [_ | _]} ->
        [
          "after second_mirror: expected the second mirror untouched, the client asked it for " <>
            Enum.join(asked, ", ")
        ]

      _ ->
        []
    end
  end

  defp post_problem(:tls, {:rejected, alert}, _seen, _snap, input) do
    for r <- input.requests,
        why = rejected_problem(r, alert),
        do: "after tls: expected every connection refused with #{inspect(alert)}, " <> why
  end

  defp post_problem(:tls, :clean, _seen, _snap, input) do
    for %{method: "TLS"} = r <- input.requests,
        do: "after tls: expected every handshake to complete, one failed: #{tls_why(r)}"
  end

  defp post_problem(:proxied, :none, _seen, _snap, input) do
    case input.requests ++ Map.get(input, :second_requests, []) do
      [] ->
        []

      asked ->
        [
          "after proxied: expected no request at all, the mirror logged " <>
            Enum.map_join(asked, ", ", &"#{&1.method} #{&1.path}")
        ]
    end
  end

  defp post_problem(:proxied, :requested, _seen, _snap, input) do
    {proxied, direct} = Enum.split_with(input.requests, &(Map.get(&1, :proxied) == true))

    cond do
      proxied == [] ->
        ["after proxied: expected a request through the proxy, the mirror logged none"]

      direct != [] ->
        [
          "after proxied: expected every request through the proxy, these came direct: " <>
            Enum.map_join(direct, ", ", &"#{&1.method} #{&1.path}")
        ]

      true ->
        []
    end
  end

  defp post_problem(:root_version, want, seen, _snap, _input) do
    case seen.after.own do
      {:error, why} ->
        ["after root_version: cannot name the client's state dir: #{why}"]

      {:ok, own} ->
        rel = Path.join(Path.dirname(own), "root_version")
        got = Map.get(Map.get(seen.after, :root_versions, %{}), rel)

        case {want, got} do
          {:absent, nil} ->
            []

          {:absent, got} ->
            ["after root_version: expected no adopted root, #{rel} holds #{state(got)}"]

          {n, got} ->
            if is_binary(got) and Integer.parse(String.trim(got)) == {n, ""},
              do: [],
              else: ["after root_version: expected #{rel} to hold #{n}, it holds #{state(got)}"]
        end
    end
  end

  defp post_problem(:unrequested, paths, _seen, _snap, input) do
    asked =
      for {which, key} <- [
            {"the case's mirror", :requests},
            {"the second mirror", :second_requests}
          ],
          %{path: target} <- Map.get(input, key, []),
          is_binary(target),
          do: {which, target, normalized(target)}

    for path <- paths,
        base = String.downcase(Path.basename(path)),
        {which, target, norm} <- asked,
        norm == base or String.ends_with?(norm, "/" <> base),
        do: "after unrequested: the client asked #{which} for #{inspect(target)} (#{path})"
  end

  defp post_problem(:cache, :untouched, seen, _snap, _input),
    do: tree_changes("cache", "the cache untouched", seen.before.cache, seen.after.cache)

  # No mutated or stray bytes stayed in the cache: every entry below
  # `files/` is a regular file named by the sha256 its bytes hash to. A
  # file setup planted (C1) may stay as setup left it only when no install
  # used its sha256; one an install used must have been fetched again.
  defp post_problem(:cache, :verified, seen, _snap, _input) do
    used = Map.get(seen, :installed_files, MapSet.new())

    for {rel, fp} <- Enum.sort(seen.after.cache),
        why = unverified(rel, fp),
        not left_unused?(rel, fp, seen.before.cache, used),
        do: "after cache: expected only verified files, #{rel} #{why}"
  end

  defp post_problem(:outside, :untouched, seen, _snap, _input) do
    before = Map.get(seen.before, :outside, %{})

    if before == %{},
      do: ["after outside: the case's setup planted nothing outside the cache to watch"],
      else:
        tree_changes(
          "outside",
          "everything outside the cache as setup left it",
          before,
          Map.get(seen.after, :outside, %{})
        )
  end

  # A logged target as the name it asks for: percent-decoded, without its
  # query, lower case.
  defp normalized(target) do
    target
    |> String.split("?", parts: 2)
    |> hd()
    |> URI.decode()
    |> String.downcase()
  rescue
    ArgumentError -> String.downcase(target)
  end

  defp left_unused?(rel, fp, before, used),
    do: before[rel] == fp and not MapSet.member?(used, Path.basename(rel))

  defp unverified("files", :dir), do: nil
  defp unverified("files", {:link, to}), do: "is a symlink to #{to}"
  defp unverified(_rel, {:link, to}), do: "is a symlink to #{to}"
  defp unverified(_rel, :dir), do: "is a directory"
  defp unverified(_rel, {:other, type}), do: "is a #{type}"

  defp unverified(rel, {:file, sha}) do
    case Path.split(rel) do
      ["files", ^sha] -> nil
      ["files", name] -> if sha256?(name), do: "does not hash to its name", else: "is no sha256"
      _ -> "is not directly in files/"
    end
  end

  defp sha256?(name), do: name =~ ~r/\A[0-9a-f]{64}\z/

  # Every entry gained, removed or changed (bytes, link target, type)
  # between two fingerprinted trees.
  defp tree_changes(key, wanted, before, now) do
    for rel <- Enum.sort(Enum.uniq(Map.keys(before) ++ Map.keys(now))),
        why = tree_change(before[rel], now[rel], rel),
        do: "after #{key}: expected #{wanted}, #{why}"
  end

  defp tree_change(same, same, _rel), do: nil
  defp tree_change(nil, _now, rel), do: "it gained #{rel}"
  defp tree_change(_before, nil, rel), do: "#{rel} was removed"

  defp tree_change(before, now, rel),
    do: "#{rel} changed from #{fingerprint(before)} to #{fingerprint(now)}"

  defp fingerprint(:dir), do: "a directory"
  defp fingerprint({:file, sha}), do: "a file (sha256 #{String.slice(sha, 0, 12)})"
  defp fingerprint({:link, to}), do: "a symlink to #{to}"
  defp fingerprint({:other, type}), do: "a #{type}"

  defp sequence(:snapshot, snap), do: {:ok, snap.sequence}

  defp sequence(:previous, snap) do
    case Snapshot.older(snap, :previous) do
      {:ok, %{sequence: n}} -> {:ok, n}
      {_kind, why} -> {:error, "the snapshot has no previous batch: #{why}"}
    end
  end

  defp sequence(n, _snap), do: {:ok, n}

  defp sequence_problem({:error, why}, _got, _rel), do: ["after state_sequence: #{why}"]

  defp sequence_problem({:ok, n}, got, rel) do
    if is_binary(got) and Integer.parse(String.trim(got)) == {n, ""},
      do: [],
      else: ["after state_sequence: expected #{rel} to hold #{n}, it holds #{state(got)}"]
  end

  defp state(nil), do: "absent"
  defp state(bytes), do: inspect(bytes, limit: 8, printable_limit: 32)

  defp rejected_problem(%{method: "TLS", tls_alert: alert}, alert), do: nil

  defp rejected_problem(%{method: "TLS"} = r, _alert),
    do: "a handshake failed with #{tls_why(r)}"

  defp rejected_problem(r, _alert),
    do: "a request got through: #{r.method} #{r.path} (#{r.status})"

  defp tls_why(%{tls_alert: alert}), do: inspect(alert)
  defp tls_why(%{tls_error: why}), do: why
  defp tls_why(_r), do: "no reason logged"

  defp result(c, class, detail),
    do: %Result{step: :conformance, check: c.id, class: class, detail: detail}
end
