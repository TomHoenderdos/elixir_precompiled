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
  # packages are left out, lines included, and a Nerves system that is not
  # a public Hex package is sent as `custom`, with its target. As a
  # backstop, the two fields that carry text, `contact` and each line's
  # `reason`, have the source, content origins, home, project dir and host
  # name replaced by <redacted>, ignoring case; `contact` also loses the
  # app, project directory and user names. Names, versions and targets are
  # never rewritten: a host named like a package must not turn that
  # package's line into garbage.

  alias Precompiled.{HTTP, Output, Reason}

  @max_lines 500
  @max_lock 1000
  @max_contact 100
  @response_bytes 16_384
  @timeout_ms 15_000
  @min_needle 4
  @min_contact_needle 3
  @statuses ["hit", "miss", "fail"]
  @custom "custom"
  # Codes whose arguments name the target or the Nerves system.
  @target_codes [:not_built_target, :rule8_target]

  # How many arguments each code's template shows: the rest are not sent.
  @arity Map.new(Reason.codes(), fn code ->
           marks = for i <- 0..7, do: "\u0001#{i}\u0001"
           text = Reason.render(code, marks)

           shown =
             if String.contains?(text, Enum.join(marks, ", ")),
               do: 8,
               else: Enum.count(marks, &String.contains?(text, &1))

           {code, shown}
         end)
  @checksum ~r/\A[0-9a-fA-F]{64}\z/

  @type where :: %{
          required(:build_lib) => Path.t(),
          required(:lock) => map(),
          required(:config) => map(),
          required(:project_dir) => Path.t(),
          required(:env) => String.t(),
          required(:target) => String.t(),
          optional(:host_name) => String.t() | nil,
          optional(:app) => atom() | String.t() | nil
        }

  @type outcome ::
          {:sent, String.t() | nil, boolean()}
          | :dumped
          | :cancelled
          | :no_report
          | :invalid
          | {:error, String.t() | :internal}

  @doc false
  # Shows the redacted payload, then dumps it or asks and sends it. The id
  # of `{:sent, id, false}` is the report's retract capability; a duplicate
  # (`{:sent, nil, true}`) gets none, because the source hands an id out
  # only once. Never raises: an unexpected exception is one line naming
  # only its module (its message could carry a path) and
  # `{:error, :internal}`. With `dump: :stdout` everything but the JSON goes
  # to stderr, so the output can be redirected into a file.
  @spec run(where(), keyword()) :: outcome()
  def run(where, opts \\ []) do
    do_run(where, opts)
  rescue
    e ->
      line = "precompiled: report not sent: internal error (#{inspect(e.__struct__)})"
      if dump_stdout?(opts), do: Output.put(:error, line), else: Output.warning(line)
      {:error, :internal}
  end

  defp do_run(where, opts) do
    contact = Keyword.get(opts, :contact)

    with :ok <- contact_ok(contact),
         {:ok, report} <- read(where.build_lib),
         body = where |> payload(report, contact) |> redact(where),
         :ok <- contact_length_ok(body) do
      Enum.each(summary(body, report, where), &say(opts, &1))
      deliver(body, where, opts)
    else
      {:error, :contact} ->
        say(
          opts,
          "precompiled: --contact is at most #{@max_contact} printable characters, " <>
            "counted after paths and names in it become <redacted>; nothing sent"
        )

        :invalid

      {:error, _no_or_old} ->
        say(
          opts,
          "precompiled: no report for #{where.env}/#{where.target}; run a build first " <>
            "(with precompiled 0.4.0 or later, and the same MIX_ENV and MIX_TARGET)"
        )

        :no_report
    end
  end

  defp dump_stdout?(opts), do: Keyword.get(opts, :dump) == :stdout

  # Lines for the person, kept off stdout while stdout carries the JSON.
  defp say(opts, line) do
    if dump_stdout?(opts), do: Output.put(:error, line), else: Output.info(line)
  end

  # Printable text only; the length is checked on the redacted contact,
  # since that is what the source counts.
  defp contact_ok(nil), do: :ok

  defp contact_ok(c) when is_binary(c) do
    if String.valid?(c) and String.printable?(c) and
         not String.contains?(c, ["\n", "\r", "\t"]),
       do: :ok,
       else: {:error, :contact}
  end

  defp contact_ok(_), do: {:error, :contact}

  defp contact_length_ok(%{"contact" => c}) do
    if String.length(c) <= @max_contact, do: :ok, else: {:error, :contact}
  end

  defp contact_length_ok(_body), do: :ok

  defp deliver(body, where, opts) do
    json = body |> :json.encode() |> IO.iodata_to_binary()

    case Keyword.get(opts, :dump) do
      nil -> confirm_and_send(json, where, opts)
      :stdout -> dump_stdout(json)
      path when is_binary(path) -> dump_file(json, path)
    end
  end

  defp dump_stdout(json) do
    Output.info(json)
    :dumped
  end

  defp dump_file(json, path) do
    case File.write(path, json) do
      :ok ->
        Output.info("precompiled: report written to #{path}; nothing sent")
        :dumped

      {:error, reason} ->
        Output.warning("precompiled: could not write #{path}: #{:file.format_error(reason)}")
        {:error, "could not write #{path}"}
    end
  end

  defp confirm_and_send(json, where, opts) do
    host = URI.parse(Map.get(where.config, :source)).host

    if Keyword.get(opts, :yes, false) or yes?(opts, "Send this report to #{host}? [y/N] ") do
      json |> post_report(where.config) |> answer() |> announce()
    else
      Output.info("precompiled: not sent")
      :cancelled
    end
  end

  # Anything but y or yes is a no; so is non-interactive stdin (IO.gets
  # answering :eof) and a read error.
  defp yes?(opts, prompt) do
    gets = Keyword.get(opts, :gets, &IO.gets/1)

    case gets.(prompt) do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _ -> false
    end
  end

  # 201 carries the new report's id; 200 is a duplicate and carries none.
  defp answer({:ok, 201, body}) do
    case decode(body) do
      %{"id" => id} when is_binary(id) and id != "" -> {:sent, id, false}
      _ -> {:error, "unexpected answer"}
    end
  end

  defp answer({:ok, 200, body}) do
    case decode(body) do
      %{"duplicate" => true} -> {:sent, nil, true}
      _ -> {:error, "unexpected answer"}
    end
  end

  defp answer({:ok, 429, _body}), do: {:error, "rate limited (429); try again later"}

  # The source names each refused field; the first one says enough.
  defp answer({:ok, 422, body}) do
    case decode(body) do
      %{"details" => [first | _]} when is_binary(first) ->
        {:error, "refused (422): #{String.slice(first, 0, 200)}"}

      _ ->
        {:error, "refused (status 422)"}
    end
  end

  defp answer({:ok, status, _body}), do: {:error, "refused (status #{status})"}
  defp answer({:error, {:too_large, n}}), do: {:error, "answer larger than #{n} bytes"}
  defp answer({:error, :redirect}), do: {:error, "the source answered with a redirect"}
  defp answer({:error, why}) when is_binary(why), do: {:error, why}
  defp answer({:error, why}), do: {:error, inspect(why)}

  defp announce({:sent, nil, true} = sent) do
    Output.info("precompiled: already received (the id was printed when it was first sent)")
    sent
  end

  defp announce({:sent, id, false} = sent) do
    Output.info("precompiled: report #{id}")
    sent
  end

  defp announce({:error, why} = error) do
    Output.warning("precompiled: report not sent: #{why}")
    error
  end

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

    {target, system, system_version} = place(ctx, public)

    lines =
      report["lines"]
      |> Enum.filter(&(well_formed?(&1) and MapSet.member?(public, &1["name"])))
      |> Enum.take(@max_lines)
      |> Enum.map(&line(&1, system == @custom))

    %{
      "format" => 1,
      "client" => client_version(),
      "built_at" => text(report["built_at"]),
      "elixir" => text(ctx["elixir"]),
      "otp" => otp(ctx["otp"]),
      "os" => os(),
      "target" => target,
      "system" => system,
      "system_version" => system_version,
      "lines" => lines,
      "lock" => lock_closure(where.lock, Enum.map(lines, & &1["name"]), @max_lock),
      "contact" => text(contact)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The target and Nerves system are sent only when the system is a public
  # Hex package of the lock; a private or local system would be named by
  # them. A host build (no system, target host) has nothing to hide.
  defp place(ctx, public) do
    target = text(ctx["target"])
    system = text(ctx["system"])

    cond do
      system == nil and target in [nil, "host"] ->
        {target, nil, nil}

      system != nil and MapSet.member?(public, system) ->
        {target, system, text(ctx["system_version"])}

      true ->
        {@custom, @custom, nil}
    end
  end

  # A line the portal would refuse, or `:json` would write as "nil", is
  # not sent: name and version non-empty strings, a known status.
  defp well_formed?(%{"name" => name, "version" => version, "status" => status})
       when is_binary(name) and name != "" and is_binary(version) and version != "",
       do: status in @statuses

  defp well_formed?(_), do: false

  # `:json` decodes a JSON null as the atom `null`: left out, like nil.
  defp text(s) when is_binary(s), do: s
  defp text(_), do: nil

  defp client_version() do
    case Application.spec(:precompiled, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp line(l, custom?) do
    code = Reason.code(l["reason_code"])
    args = l["reason_args"] |> Reason.clean_args() |> Enum.take(Map.fetch!(@arity, code))

    args =
      if custom? and code in @target_codes, do: Enum.map(args, fn _ -> @custom end), else: args

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

  defp long_enough(needles, min \\ @min_needle),
    do: Enum.filter(needles, &(is_binary(&1) and String.length(&1) >= min))

  # Names that are also package and target names: `contact` is the only
  # free text they are removed from.
  @spec contact_needles(where()) :: [String.t()]
  def contact_needles(where) do
    app = Map.get_lazy(where, :app, &mix_app/0)
    user = System.get_env("USER") || System.get_env("USERNAME")
    names = [app && to_string(app), Path.basename(where.project_dir), user]

    (needles(where) ++ long_enough(names, @min_contact_needle))
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end

  defp mix_app() do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil,
      do: Mix.Project.config()[:app]
  end

  @doc false
  # The redaction `run/2` applies: every needle in each line's reason, and
  # the contact-only names in `contact` as well.
  @spec redact(map(), where()) :: map()
  def redact(payload, where),
    do: redact_payload(payload, needles(where), contact_needles(where))

  defp host_name() do
    case :inet.gethostname() do
      {:ok, h} -> to_string(h)
      _ -> nil
    end
  end

  # Only `contact` and each line's `reason` carry free text; every other
  # field is a name, version, code or count and is never rewritten.
  @spec redact_payload(map(), [String.t()], [String.t()] | nil) :: map()
  def redact_payload(payload, needles, contact_needles \\ nil) do
    contact_needles = long_enough(contact_needles || needles, @min_contact_needle)
    needles = long_enough(needles)

    payload =
      case payload do
        %{"contact" => contact} -> Map.put(payload, "contact", scrub(contact, contact_needles))
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

  defp scrub(s, needles) when is_binary(s) do
    Enum.reduce(needles, s, fn needle, acc ->
      Regex.replace(Regex.compile!(Regex.escape(needle), "iu"), acc, "<redacted>")
    end)
  end

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
