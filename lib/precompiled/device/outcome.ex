# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Device.Outcome do
  @moduledoc false
  # What the last Precompiled.install/2 found, kept for Precompiled.report/1
  # in the store's .last-install.json (Device.Store.write_outcome/2): one
  # line per candidate with its HIT, MISS or FAIL, reason code, arguments
  # and the printed text, the device facts the install judged by, and the
  # package checksums of the builds it installed. It has the shape of the
  # host's report.json, so Precompiled.Report builds the body from it the
  # same way; the printed text (`detail`) stays on the device. Each install
  # replaces the file; a dry run leaves it alone. No Mix, no Hex.

  alias Precompiled.Device.Env
  alias Precompiled.Device.Store
  alias Precompiled.Reason
  alias Precompiled.Report

  @format 1
  @max_lock 1000
  @custom "custom"
  @package ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @target ~r/\A[a-z0-9_]{1,64}\z/
  @checksum ~r/\A[0-9a-fA-F]{64}\z/

  @type line :: map()
  @type facts :: %{
          required(:env) => Env.t(),
          required(:lines) => [line()],
          optional(:lock) => [map()],
          optional(:systems) => map() | nil,
          optional(:targets) => [String.t()],
          optional(:listed) => [String.t()]
        }

  ## Lines

  @doc false
  # A line for a candidate: `status` is :hit, :miss or :fail.
  @spec line(String.t() | atom(), String.t() | nil, atom(), Reason.t()) :: line()
  def line(name, version, status, %Reason{} = reason) do
    %{
      "name" => to_string(name),
      "version" => version,
      "status" => Atom.to_string(status),
      "reason_code" => Atom.to_string(reason.code),
      "reason_args" => reason.args,
      "detail" => reason.text
    }
  end

  @doc false
  # The lines and lock of a plan that was applied: every install a hit when
  # `result` is {:ok, _}; otherwise the one that failed with its reason and
  # the rest as not installed, since the call installs all or nothing.
  @spec applied([map()], {:ok, term()} | {:error, term()}) :: {[line()], [map()]}
  def applied(installs, {:ok, _installed}) do
    lines = for i <- installs, do: line(i.app, i.version, :hit, Reason.new(:hit, []))
    {lines, lock(installs)}
  end

  def applied(installs, {:error, why}) do
    {culprit, status, reason} = culprit(why)

    lines =
      for i <- installs do
        if culprit != nil and culprit == Atom.to_string(i.app) do
          line(i.app, i.version, status, reason)
        else
          line(i.app, i.version, :fail, not_installed(culprit, reason))
        end
      end

    {lines, lock(installs)}
  end

  defp not_installed(nil, reason), do: reason

  defp not_installed(culprit, _reason),
    do: Reason.new(:install_failed, [], "not installed: #{culprit} failed")

  # The app an apply error names, and how its line reads. A missing native
  # library is a miss, as on the host; a download or check that failed is
  # a fail with its code; anything else is an install that failed.
  defp culprit({:libs, app, %Reason{} = reason}), do: {to_string(app), :miss, reason}

  defp culprit({:fetch, name, why}) when is_binary(why) do
    {:fail, reason} = Reason.of_install({:fail, why})
    {to_string(name), :fail, reason}
  end

  defp culprit({kind, app, _why}) when kind in [:start_failed, :on_load_failed] and is_atom(app),
    do: {Atom.to_string(app), :fail, Reason.new(:install_failed, [], "#{kind}")}

  defp culprit(why), do: {nil, :fail, Reason.new(:install_failed, [], inspect(why))}

  @doc false
  # The line of the package the plan could not find a build for.
  @spec missed(String.t(), Reason.t(), String.t() | nil) :: [line()]
  def missed(name, %Reason{} = reason, version), do: [line(name, version, :miss, reason)]

  @doc false
  # The requests' lines when the batch itself was refused: nothing was
  # planned, so only an exact version is known. A trust check that crashed
  # refused nothing: a MISS naming the crash.
  @spec refused([{atom(), String.t() | nil}], String.t()) :: [line()]
  def refused(requests, why) do
    reason = Reason.of_batch_error(why)
    status = if reason.code == :internal, do: :miss, else: :fail
    for {app, req} <- requests, do: line(app, exact(req), status, reason)
  end

  defp exact(req) when is_binary(req) do
    case Version.parse(req) do
      {:ok, _} -> req
      :error -> nil
    end
  end

  defp exact(_req), do: nil

  # Each install's own package checksum, then its build's lock: the
  # versions and checksums this device knows for what it installed. The
  # first entry for a name wins.
  defp lock(installs) do
    own = for i <- installs, do: entry(Atom.to_string(i.app), i.version, checksum(i.build))

    deps =
      for i <- installs,
          {name, %{"version" => v, "checksum" => c}} <- deps(i.build),
          do: entry(name, v, c)

    (own ++ deps)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["name"])
    |> Enum.take(@max_lock)
  end

  defp checksum(%{"build" => %{"package_checksum" => c}}), do: c
  defp checksum(_build), do: nil

  defp deps(%{"build" => %{"deps" => deps}}) when is_map(deps), do: Enum.sort(deps)
  defp deps(_build), do: []

  defp entry(name, version, checksum) do
    if is_binary(name) and Regex.match?(@package, name) and version?(version) and
         is_binary(checksum) and Regex.match?(@checksum, checksum),
       do: %{"name" => name, "version" => version, "checksum" => String.downcase(checksum)}
  end

  defp version?(v) when is_binary(v), do: match?({:ok, _}, Version.parse(v))
  defp version?(_v), do: false

  ## The file

  @doc false
  # The document for `facts`, as of `now`.
  @spec doc(facts(), DateTime.t()) :: map()
  def doc(facts, now \\ DateTime.utc_now()) do
    env = facts.env
    listed = MapSet.new(Map.get(facts, :listed, []))
    {system, system_version} = env.system || {nil, nil}

    %{
      "format" => @format,
      "built_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "context" => %{
        "elixir" => env.elixir,
        "otp" => env.otp,
        "target" => null(target(system)),
        "system" => null(system),
        "system_version" => null(system_version),
        "system_known" => known?(system, facts)
      },
      "lines" => Enum.map(facts.lines, &recorded(&1, listed)),
      "lock" => Map.get(facts, :lock, [])
    }
  end

  # Each line says whether the source lists its name: only those are ever
  # sent (payload/2), so a private package's name stays on the device.
  defp recorded(line, listed) do
    line
    |> Map.put("listed", MapSet.member?(listed, line["name"]))
    |> Map.new(fn {k, v} -> {k, null(v)} end)
  end

  # `:json` writes nil as the string "nil"; JSON's null is :null.
  defp null(nil), do: :null
  defp null(v), do: v

  # A Nerves system's target is its name without the prefix, as MIX_TARGET
  # names it.
  defp target("nerves_system_" <> t), do: t
  defp target(_system), do: nil

  # The system is sent by name only when the source knows it: its systems
  # table lists it, or one of this install's builds was made for it.
  # Otherwise it may be a private system, and goes as `custom`.
  defp known?(nil, _facts), do: false

  defp known?(system, facts) do
    systems = Map.get(facts, :systems)

    (is_map(systems) and Map.has_key?(systems, system)) or
      system in Map.get(facts, :targets, [])
  end

  @doc false
  # Writes the document for `facts` into the store. Never raises, and
  # never changes what the install returns: a store that cannot take it
  # only means the next report has an older install, or none.
  @spec record(Path.t(), facts()) :: :ok | {:error, term()}
  def record(dir, facts) do
    Store.write_outcome(dir, :json.encode(doc(facts)))
  rescue
    _ -> {:error, :internal}
  end

  @doc false
  # Records that the last install call was refused before it ran, so a
  # later report never sends an older install's outcome. Only into a store
  # that already exists and is safe; never raises.
  @spec record_refusal(Path.t()) :: :ok | {:error, term()}
  def record_refusal(dir) do
    case Store.check_root(dir) do
      :ok -> Store.write_outcome(dir, :json.encode(%{"format" => @format, "no_install" => true}))
      _ -> :ok
    end
  rescue
    _ -> {:error, :internal}
  end

  @doc false
  @spec read(Path.t()) :: {:ok, map()} | {:error, :no_report | :no_install}
  def read(dir) do
    with {:ok, bytes} <- Store.read_outcome(dir),
         %{} = doc <- decode(bytes) do
      case doc do
        %{"no_install" => true} ->
          {:error, :no_install}

        %{"lines" => lines, "context" => ctx} when is_list(lines) and is_map(ctx) ->
          {:ok, doc}

        _ ->
          {:error, :no_report}
      end
    else
      _ -> {:error, :no_report}
    end
  end

  defp decode(bytes) do
    :json.decode(bytes)
  rescue
    _ -> nil
  end

  ## The report

  @doc false
  # The body Precompiled.report/1 sends for `doc`. A line is sent only when
  # the signed batch lists its name, as a package or as a dependency of one
  # of the builds the install planned, as the host sends only the public
  # Hex names of its lock; the system goes by name only when known?/2
  # held, and the target with it.
  @spec payload(map(), String.t() | nil) :: map()
  def payload(doc, contact) do
    ctx = doc["context"]
    lock = valid_lock(doc["lock"])
    listed = listed_names(doc)

    body =
      Report.assemble(doc, contact,
        public?: &(MapSet.member?(listed, &1) and Regex.match?(@package, &1)),
        place: place(ctx),
        lock: fn names -> Enum.filter(lock, &(&1["name"] in names)) end
      )

    if body["lines"] == [], do: Map.put(body, "lock", []), else: body
  end

  defp place(ctx) do
    system = ctx["system"]
    target = ctx["target"]

    if ctx["system_known"] == true and is_binary(system) and is_binary(target) and
         Regex.match?(@package, system) and Regex.match?(@target, target),
       do: {target, system, text(ctx["system_version"])},
       else: {@custom, if(is_binary(system), do: @custom), nil}
  end

  defp text(s) when is_binary(s), do: s
  defp text(_), do: nil

  defp listed_names(doc) do
    for %{"name" => name, "listed" => true} <- doc["lines"],
        is_binary(name),
        into: MapSet.new(),
        do: name
  end

  # The recorded entries, checked again: the file is on a writable disk.
  # One entry per name, the first, and at most @max_lock.
  defp valid_lock(entries) when is_list(entries) do
    for(
      %{"name" => n, "version" => v, "checksum" => c} <- entries,
      e = entry(n, v, c),
      e != nil,
      do: e
    )
    |> Enum.uniq_by(& &1["name"])
    |> Enum.take(@max_lock)
  end

  defp valid_lock(_entries), do: []

  @doc false
  # The summary's first lines: what the report is, and each line kept on
  # the device because the source does not list its name.
  @spec header(map()) :: [String.t()]
  def header(doc) do
    listed = listed_names(doc)

    kept =
      for %{"name" => name} = l <- doc["lines"],
          is_binary(name),
          not MapSet.member?(listed, name) do
        "  #{String.upcase(to_string(l["status"]))}  #{name} #{text(l["version"])}  " <>
          "not sent: not in the public index"
      end

    [
      "precompiled: report of the last Precompiled.install/2 on this device, " <>
        "written #{Report.age(doc["built_at"])}"
      | kept
    ]
  end
end
