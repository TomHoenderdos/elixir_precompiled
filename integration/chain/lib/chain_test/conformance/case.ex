# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Case do
  @moduledoc """
  One conformance case, as data, and its verdict.

  The case file (`conformance/cases.exs`) evaluates to a list of maps, each
  with exactly these keys:

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
      and each dep the snapshot holds a build of: `deps[dep]`, else
      `default`.
      An expectation is a report status (`:hit`, `:miss`, `:fail`), a status
      with a detail prefix (`{:miss, "batch stale"}`), or `:snapshot`: a hit
      when the snapshot holds a build the client could select, else a miss.
    * `harness` - harness results by `"<step>/<check>"` (as the reports
      print them; step `build`, `integrity` or `compiled`) and the class each
      must have. Every result not named must be `:pass` or `:miss`. A
      `:rerun` is a difference too: the snapshot never moves, so a rerun
      means the client used a batch the mirror never served.

  Whatever the case expects, a report line that calls a dep a hit when the
  snapshot holds no build of it the client could select is a difference:
  the client installed something the portal never served it.

  The case's mirror must show that the client used it: a `GET batch.json`
  and, for every dep the report calls a hit, a `GET` of the snapshot's
  manifest path the mirror answered 200 (or whose response the case's own
  transform changed). Without that, the client may have read another
  source.

  Verdict, one `conformance/<id>` result:

    * `:not_exercised` when the transform is not `ChainTest.Mirror.Identity`
      and the mirror served nothing it changed, or when the transform is
      `ChainTest.Mirror.Identity` and the mirror shows no use by the client;
    * else `:pass` when the client used the mirror and the client and every
      harness result match, `:fail` naming each difference.
  """

  alias ChainTest.{Mirror, Result}
  alias ChainTest.Mirror.Transform

  @type status :: :hit | :miss | :fail
  @type expect :: :snapshot | status() | {status(), String.t()}
  @type t :: %{
          id: String.t(),
          description: String.t(),
          transform: {module(), map()},
          client: %{default: expect(), deps: %{atom() => expect()}},
          harness: %{String.t() => Result.class()}
        }

  @keys [:client, :description, :harness, :id, :transform]
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

    cond do
      Enum.sort(Map.keys(c)) != @keys ->
        {:error, "case #{id}: keys must be #{inspect(@keys)}, got #{inspect(Map.keys(c))}"}

      not id?(c.id) ->
        {:error, "case #{id}: an id is a letter or digit, then letters, digits, . or -"}

      not description?(c.description) ->
        {:error, "case #{id}: description must be a sentence"}

      not Transform.valid?(c.transform) ->
        {:error,
         "case #{id}: transform #{inspect(c.transform)} is not {module, args} with " <>
           "args the module accepts"}

      not client?(c.client) ->
        {:error, "case #{id}: client must be %{default: expect, deps: %{dep => expect}}"}

      not harness?(c.harness) ->
        {:error, "case #{id}: harness must map \"step/check\" to a result class"}

      true ->
        nil
    end
  end

  defp problem(other), do: {:error, "a case must be a map, got #{inspect(other)}"}

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

  @doc "The case's verdict on one run (see the moduledoc)."
  @spec judge(t(), %{
          rows: [Result.t()],
          report: map(),
          requests: [Mirror.request()],
          snapshot: map(),
          hits: [atom()]
        }) :: Result.t()
  def judge(c, %{rows: rows, report: report, requests: requests, snapshot: snap, hits: hits}) do
    unused = unused_mirror(report, requests, snap)
    identity? = match?({@identity, _}, c.transform)

    cond do
      identity? and unused != [] ->
        result(c, :not_exercised, Enum.join(unused, "; "))

      not identity? and not Enum.any?(requests, & &1.mutated) ->
        result(c, :not_exercised, "the mirror never served anything the transform changed")

      true ->
        problems =
          unused ++
            client_problems(c, report, snap, hits) ++
            unheld_hits(report, snap) ++ harness_problems(c, rows)

        case problems do
          [] -> result(c, :pass, "as expected: #{c.description}")
          problems -> result(c, :fail, Enum.join(problems, "; "))
        end
    end
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
  # holds a build of.
  defp client_problems(c, report, snap, hits) do
    lines = lines(report)
    named = Map.new(c.client.deps, fn {dep, want} -> {to_string(dep), want} end)
    held = for {name, _} <- snap.deps, held?(snap, name), do: name

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

  defp result(c, class, detail),
    do: %Result{step: :conformance, check: c.id, class: class, detail: detail}
end
