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
      (at most 32). Use the spec's case IDs.
    * `transform` - `{module, args}`: a `ChainTest.Mirror.Transform` and its
      args map (checked with the module's `valid_args?/1` when it has one),
      applied to every response of the case's mirror.
    * `client` - what the client's `report.json` must say for each of the
      fixture's expected hits (`expected.exs`), each dep named in `deps`
      and each dep the snapshot holds a build of, except the deps `nerves`
      pulls in (`ChainTest.Lock.nerves_children/2`), which the client
      never considers: `deps[dep]`, else `default`.
      An expectation is a report status (`:hit`, `:miss`, `:fail`), a status
      with a detail prefix (`{:miss, "batch stale"}`), or `:snapshot`: a hit
      when the snapshot holds a build the client could select, else a miss.
    * `harness` - harness results by `"<step>/<check>"` (as the reports
      print them; step `build`, `integrity` or `compiled`) and the class each
      must have. Every result not named must be `:pass` or `:miss`. A
      `:rerun` is a difference too: the snapshot never moves, so a rerun
      means the client used a batch the mirror never served.

  Optional keys, each absent by default:

    * `setup` - `{module, args}`: a `ChainTest.Conformance.Setup` and its
      args (checked like a transform's), run against the case's fresh client
      home before the build.
    * `client_config` - merged into the fixture's `config
      :elixir_precompiled` for this case's build only
      (`ChainTest.Build.client_config?/1`): `clock_offset_seconds`
      (integer, or `{:age, seconds}`: the client's clock that long after
      the snapshot batch's `issued`, `ChainTest.Conformance.Clock`), `root` (an absolute path), `source` (URL).
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
      * `installed` - `:none` (no `.mix/elixir_precompiled.json` anywhere
        in the target's `_build`) or `:snapshot` (one for exactly the deps
        the snapshot holds a build of, the Nerves tooling aside).
      * `cache` - `:untouched`: no entry in the client cache (`files/`
        under the home) beyond what setup wrote.
      * `second_mirror` - only with a transform that asks for `mirrors: 2`:
        `:requested` (the client asked the second mirror for something, a
        redirect it followed, say) or `:untouched` (it asked nothing).

  Whatever the case expects, a report line that calls a dep a hit when the
  snapshot holds no build of it the client could select is a difference:
  the client installed something the portal never served it.

  The case's mirror must show that the client used it: a `GET batch.json`
  and, for every dep the report calls a hit, a `GET` of the snapshot's
  manifest path the mirror answered 200 (or whose response the case's own
  transform changed). Without that, the client may have read another
  source.

  Verdict, one `conformance/<id>` result:

    * `:fail` when either of the case's mirrors logged a `transform_error`
      (the transform crashed or answered a malformed shape), naming each;
    * `:not_exercised` when the transform is not `ChainTest.Mirror.Identity`
      and the mirror served nothing it changed, or when the transform is
      `ChainTest.Mirror.Identity` and the mirror shows no use by the client;
    * else `:pass` when the client used the mirror and the client and every
      harness result match, `:fail` naming each difference.
  """

  alias ChainTest.{Build, Mirror, Result, Snapshot}
  alias ChainTest.Conformance.{Clock, Setup}
  alias ChainTest.Conformance.Setup.PlantRoot
  alias ChainTest.Mirror.Transform

  @type status :: :hit | :miss | :fail
  @type expect :: :snapshot | status() | {status(), String.t()}
  @type post :: %{
          optional(:state_sequence) => integer() | :snapshot | :previous | :absent | :unchanged,
          optional(:other_states) => :unchanged,
          optional(:installed) => :none | :snapshot,
          optional(:cache) => :untouched,
          optional(:second_mirror) => :requested | :untouched
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
          before: home_view(),
          after: home_view(),
          installed: [String.t()]
        }
  @type home_view :: %{
          states: %{String.t() => binary()},
          cache: MapSet.t(String.t()),
          own: {:ok, String.t()} | {:error, String.t()}
        }

  @keys [:client, :description, :harness, :id, :transform]
  @optional [:after, :client_config, :client_env, :setup]
  @post_keys [:cache, :installed, :other_states, :second_mirror, :state_sequence]
  @statuses [:hit, :miss, :fail]
  @benign [:pass, :miss]
  @identity ChainTest.Mirror.Identity

  @doc "Evaluates and validates a case file."
  @spec load(Path.t()) :: {:ok, [t()]} | {:error, String.t()}
  def load(path) do
    {cases, _binding} = Code.eval_file(path)

    with :ok <- list(cases),
         :ok <- Enum.find_value(cases, :ok, &problem/1),
         :ok <- unique(cases) do
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

  defp optional_problem(c) do
    cond do
      Map.has_key?(c, :setup) and not Setup.valid?(c.setup) ->
        "setup #{inspect(c.setup)} is not {module, args} with a " <>
          "ChainTest.Conformance.Setup and args it accepts"

      Map.has_key?(c, :client_config) and not Clock.case_config?(c.client_config) ->
        "client_config must map clock_offset_seconds to an integer or {:age, integer}, root to an absolute " <>
          "path and source to a non-empty string, got #{inspect(c.client_config)}"

      Map.has_key?(c, :client_env) and not client_env?(c.client_env) ->
        "client_env must map names from #{inspect(Build.client_env_names())} to an " <>
          "absolute path or {:home, relative path}, got #{inspect(c.client_env)}"

      Map.has_key?(c, :after) ->
        after_problem(c.after, c.transform)

      true ->
        nil
    end
  end

  defp after_problem(post, transform) do
    cond do
      not post?(post) ->
        "after must be a non-empty map of state_sequence (integer, :snapshot, :previous, " <>
          ":absent, :unchanged), other_states (:unchanged), installed (:none, :snapshot), cache (:untouched), second_mirror " <>
          "(:requested, :untouched), got " <> inspect(post)

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

  defp post_value?(:installed, v), do: v in [:none, :snapshot]
  defp post_value?(:cache, v), do: v == :untouched
  defp post_value?(:second_mirror, v), do: v in [:requested, :untouched]

  @doc "The case's verdict on one run (see the moduledoc)."
  @spec judge(t(), %{
          required(:rows) => [Result.t()],
          required(:report) => map(),
          required(:requests) => [Mirror.request()],
          required(:snapshot) => map(),
          required(:hits) => [atom()],
          optional(:tooling) => [String.t()],
          optional(:second_requests) => [Mirror.request()],
          optional(:observed) => observed() | nil
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

    cond do
      broken != [] ->
        result(c, :fail, Enum.join(broken, "; "))

      identity? and unused != [] ->
        result(c, :not_exercised, Enum.join(unused, "; "))

      not identity? and not Enum.any?(requests, & &1.mutated) ->
        result(c, :not_exercised, "the mirror never served anything the transform changed")

      true ->
        problems =
          unused ++
            client_problems(c, report, snap, hits, input) ++
            unheld_hits(report, snap) ++
            harness_problems(c, rows) ++ post_problems(c, input, snap)

        case problems do
          [] -> result(c, :pass, "as expected: #{c.description}")
          problems -> result(c, :fail, Enum.join(problems, "; "))
        end
    end
  end

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

  defp resolve(expect, _snap, _name), do: expect

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

  defp matches?(_want, nil), do: false

  defp matches?({status, prefix}, %{"status" => got, "detail" => detail}) when is_binary(detail),
    do: Atom.to_string(status) == got and String.starts_with?(detail, prefix)

  defp matches?({_status, _prefix}, _line), do: false
  defp matches?(status, %{"status" => got}), do: Atom.to_string(status) == got
  defp matches?(_want, _line), do: false

  defp describe({status, prefix}), do: "#{status} (#{inspect(prefix)}...)"
  defp describe(status), do: to_string(status)

  defp describe_line(nil), do: "no report line"
  defp describe_line(l), do: "#{l["status"]} (#{inspect(l["detail"])})"

  defp harness_problems(c, rows) do
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

    unnamed =
      for r <- rows,
          not Map.has_key?(c.harness, key(r)),
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

  defp post_problem(:installed, :snapshot, seen, snap, input) do
    tooling = Map.get(input, :tooling, [])
    want = for {name, _} <- snap.deps, held?(snap, name), name not in tooling, do: name
    want = Enum.sort(want)
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

  defp post_problem(:cache, :untouched, seen, _snap, _input) do
    case seen.after.cache |> MapSet.difference(seen.before.cache) |> Enum.sort() do
      [] -> []
      new -> ["after cache: expected the cache untouched, it gained #{Enum.join(new, ", ")}"]
    end
  end

  defp sequence(:snapshot, snap), do: {:ok, snap.sequence}

  defp sequence(:previous, snap) do
    case Snapshot.older(snap, :previous) do
      {:ok, %{sequence: n}} -> {:ok, n}
      {:missing, why} -> {:error, "the snapshot has no previous batch: #{why}"}
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

  defp result(c, class, detail),
    do: %Result{step: :conformance, check: c.id, class: class, detail: detail}
end
