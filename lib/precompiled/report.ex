# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Report do
  @moduledoc false
  # `mix precompiled.report` and `Precompiled.Host.report/1`: the last
  # build's report.json, sent to `<source>/reports` only when the tester says
  # so. What is sent is built from codes, never from the printed details:
  # each line's code, its name/version arguments and the code's template,
  # the toolchain context, and the public Hex lock entries of the
  # candidates and their closure. Private-organisation, git and path
  # packages are left out, lines included. As a backstop, the two fields
  # that carry text, `contact` and each line's `reason`, have the source,
  # content origins, home, project dir and host name replaced by
  # <redacted>. Names, versions and targets are never rewritten: a host
  # named like a package must not turn that package's line into garbage.

  alias Precompiled.{HTTP, Output, Reason}

  @max_lines 500
  @max_lock 1000
  @response_bytes 16_384
  @timeout_ms 15_000
  @min_needle 4
  @checksum ~r/\A[0-9a-fA-F]{64}\z/

  @type where :: %{
          required(:build_lib) => Path.t(),
          required(:lock) => map(),
          required(:config) => map(),
          required(:project_dir) => Path.t(),
          required(:env) => String.t(),
          required(:target) => String.t(),
          optional(:host_name) => String.t() | nil
        }

  @spec read(Path.t()) :: {:ok, map()} | {:error, :no_report | :old_report}
  def read(build_lib) do
    path = Path.join([build_lib, ".precompiled", "report.json"])

    with {:ok, bytes} <- File.read(path),
         %{} = doc <- decode(bytes) do
      if is_list(doc["lines"]) and is_binary(doc["built_at"]) and is_map(doc["context"]),
        do: {:ok, doc},
        else: {:error, :old_report}
    else
      _ -> {:error, :no_report}
    end
  end

  defp decode(bytes) do
    :json.decode(bytes)
  rescue
    _ -> nil
  end

  @spec payload(where(), map(), String.t() | nil) :: map()
  def payload(where, report, contact) do
    ctx = report["context"]
    public = public_names(where.lock)

    lines =
      report["lines"]
      |> Enum.filter(&(is_map(&1) and MapSet.member?(public, &1["name"])))
      |> Enum.take(@max_lines)
      |> Enum.map(&line/1)

    %{
      "format" => 1,
      "client" => client_version(),
      "built_at" => text(report["built_at"]),
      "elixir" => text(ctx["elixir"]),
      "otp" => otp(ctx["otp"]),
      "os" => os(),
      "target" => text(ctx["target"]),
      "system" => text(ctx["system"]),
      "system_version" => text(ctx["system_version"]),
      "lines" => lines,
      "lock" => lock_closure(where.lock, Enum.map(lines, & &1["name"]), @max_lock),
      "contact" => text(contact)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # `:json` decodes a JSON null as the atom `null`: left out, like nil.
  defp text(s) when is_binary(s), do: s
  defp text(_), do: nil

  defp client_version() do
    case Application.spec(:precompiled, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp line(l) do
    code = Reason.code(l["reason_code"])
    args = Reason.clean_args(l["reason_args"])

    %{
      "name" => l["name"],
      "version" => l["version"],
      "status" => l["status"],
      "reason_code" => Atom.to_string(code),
      "reason_args" => args,
      "reason" => Reason.render(code, args)
    }
  end

  # A line is sent only when its package is a public Hex entry of the lock:
  # a private-organisation, git or path package's name is not ours to send.
  defp public_names(lock) do
    for {app, entry} <- lock, is_atom(app), public_entry(entry) != nil, into: MapSet.new() do
      Atom.to_string(app)
    end
  end

  defp public_entry({:hex, pkg, version, _inner, _managers, deps, "hexpm", outer})
       when is_atom(pkg) and is_binary(version) and is_binary(outer) and is_list(deps) do
    if Regex.match?(@checksum, outer) do
      {%{
         "name" => Atom.to_string(pkg),
         "version" => version,
         "checksum" => String.downcase(outer)
       }, for({dep, _req, _opts} when is_atom(dep) <- deps, do: Atom.to_string(dep))}
    end
  end

  defp public_entry(_), do: nil

  defp otp(otp) when is_integer(otp), do: otp

  defp otp(otp) when is_binary(otp) do
    case Integer.parse(otp) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp otp(_), do: nil

  defp os() do
    family = if match?({:win32, _}, :os.type()), do: "win32", else: "unix"

    arch =
      :erlang.system_info(:system_architecture)
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[0-9.]+$/, "")
      |> String.replace(~r/[^a-z0-9_.-]/, "_")
      |> String.slice(0, 64)

    %{"family" => family, "arch" => if(arch == "", do: "unknown", else: arch)}
  end

  @doc false
  # Breadth first from `names`: the candidates' own entries, then their
  # dependencies, then theirs. At most `max`, so a cut drops the entries
  # farthest from the candidates.
  @spec lock_closure(map(), [String.t()], pos_integer()) :: [map()]
  def lock_closure(lock, names, max) do
    by_name = for {app, entry} <- lock, is_atom(app), into: %{}, do: {Atom.to_string(app), entry}
    walk(:queue.from_list(names), by_name, MapSet.new(), [], max)
  end

  defp walk(_queue, _by_name, _seen, acc, 0), do: Enum.reverse(acc)

  defp walk(queue, by_name, seen, acc, left) do
    case :queue.out(queue) do
      {:empty, _} ->
        Enum.reverse(acc)

      {{:value, name}, rest} ->
        with false <- MapSet.member?(seen, name),
             {entry, children} <- public_entry(Map.get(by_name, name)) do
          rest = Enum.reduce(children, rest, &:queue.in/2)
          walk(rest, by_name, MapSet.put(seen, name), [entry | acc], left - 1)
        else
          _ -> walk(rest, by_name, MapSet.put(seen, name), acc, left)
        end
    end
  end

  @spec needles(where()) :: [String.t()]
  def needles(where) do
    config = where.config
    origins = [Map.get(config, :source) | Map.get(config, :content_override) || []]
    hosts = for o <- origins, is_binary(o), host = URI.parse(o).host, is_binary(host), do: host
    host_name = Map.get_lazy(where, :host_name, &host_name/0)

    ([System.user_home(), where.project_dir, host_name] ++ origins ++ hosts)
    |> long_enough()
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end

  defp long_enough(needles),
    do: Enum.filter(needles, &(is_binary(&1) and String.length(&1) >= @min_needle))

  defp host_name() do
    case :inet.gethostname() do
      {:ok, h} -> to_string(h)
      _ -> nil
    end
  end

  # Only `contact` and each line's `reason` carry free text; every other
  # field is a name, version, code or count and is never rewritten.
  @spec redact_payload(map(), [String.t()]) :: map()
  def redact_payload(payload, needles) do
    needles = long_enough(needles)

    payload =
      case payload do
        %{"contact" => contact} -> Map.put(payload, "contact", scrub(contact, needles))
        _ -> payload
      end

    case payload do
      %{"lines" => lines} when is_list(lines) ->
        Map.put(payload, "lines", Enum.map(lines, &redact_line(&1, needles)))

      _ ->
        payload
    end
  end

  defp redact_line(%{"reason" => reason} = line, needles),
    do: Map.put(line, "reason", scrub(reason, needles))

  defp redact_line(line, _needles), do: line

  defp scrub(s, needles) when is_binary(s),
    do: Enum.reduce(needles, s, &String.replace(&2, &1, "<redacted>"))

  defp scrub(other, _needles), do: other

  # What the tester sees before anything is sent. Every count and line comes
  # from the payload; the report only gives the build's age.
  @spec summary(map(), map(), where()) :: [String.t()]
  def summary(payload, report, where) do
    lines = Map.get(payload, "lines", [])
    count = fn status -> Enum.count(lines, &(&1["status"] == status)) end

    shown =
      for l <- lines, l["status"] in ["miss", "fail"] do
        "  #{String.upcase(l["status"])}  #{l["name"]} #{l["version"]}  #{l["reason"]}"
      end

    [
      "precompiled: report of the build for MIX_ENV=#{where.env} MIX_TARGET=#{where.target}, " <>
        "written #{age(report["built_at"])}; run this with the same env and target as the build",
      "  #{count.("hit")} hit, #{count.("miss")} miss, #{count.("fail")} fail"
    ] ++
      shown ++
      [
        "  lock entries: #{length(Map.get(payload, "lock", []))}",
        "  contact: #{Map.get(payload, "contact") || "none"}",
        "  destination: #{Map.get(where.config, :source)}/reports"
      ]
  end

  defp age(built_at) when is_binary(built_at) do
    case DateTime.from_iso8601(built_at) do
      {:ok, at, _} ->
        minutes = div(DateTime.diff(DateTime.utc_now(), at, :second), 60)

        cond do
          minutes < 1 -> "just now"
          minutes < 120 -> "#{minutes} min ago"
          true -> "#{div(minutes, 60)} h ago"
        end

      _ ->
        "at an unknown time"
    end
  end

  defp age(_), do: "at an unknown time"

  @doc false
  @spec post_report(iodata(), map()) :: {:ok, pos_integer(), binary()} | {:error, term()}
  def post_report(json, config),
    do:
      HTTP.post(Map.get(config, :source) <> "/reports", json,
        max_bytes: @response_bytes,
        deadline_ms: @timeout_ms,
        connect_timeout_ms: Map.get(config, :connect_timeout_ms, 5_000)
      )

  @doc false
  @spec output([String.t()]) :: :ok
  def output(lines), do: Enum.each(lines, &Output.info/1)
end
