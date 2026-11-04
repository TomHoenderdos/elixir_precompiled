# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Device do
  @moduledoc """
  Step 6: the fixture's probe on the device, over ssh.

  Runs `ChainFixture.Probe.run([...])` and parses only the block between the
  `-----BEGIN CHAIN PROBE-----` and `-----END CHAIN PROBE-----` lines;
  everything around it (an IEx banner, log lines, the `:ok` return value) is
  ignored, and `\\r` line ends are trimmed. No block, a second block, or a
  block that is not one JSON object fails `probe` and leaves every other
  check not exercised.

  Checks:

    * `probe` - exactly one block, decoded.
    * `app:<app>` - the app started.
    * `modules` - every module of the probed apps loaded.
    * `smoke:<name>` - each smoke call the probe makes answered `ok`.
    * `files:<app>` - every file under the app's `ebin/` and `priv/` on the
      device has the sha256 of the same file in the locally built release
      image, `<release_dir>/lib/<app>-<vsn>/`, and neither side has a file
      the other lacks. Any difference is a `:disagreement`. The comparison
      is with the release, not the manifest: a Nerves release strips beams,
      rewrites `.app` files and strips `.so` files, and step 3 already tied
      `_build` to the manifest.
    * `firmware_uuid` - when `expected_uuid` is given: the probe's active
      firmware UUID equals it.
    * `nerves_system` - when `system` (`{name, version}`) is given: the
      device reports that system; a report the probe could not read is
      `:not_exercised`.
  """

  alias ChainTest.{Cmd, Preflight, Result}

  @begin "-----BEGIN CHAIN PROBE-----"
  @finish "-----END CHAIN PROBE-----"
  @timeout_ms 120_000
  @shown_problems 5
  @max_depth 16

  @type input :: %{
          required(:device) => String.t(),
          required(:known_hosts) => Path.t(),
          required(:apps) => [atom() | String.t()],
          required(:release_dir) => Path.t(),
          optional(:expected_uuid) => String.t() | nil,
          optional(:system) => {String.t(), String.t()} | nil,
          optional(:timeout_ms) => pos_integer()
        }

  @doc "Runs step 6. Raises `ArgumentError` on an app name that is not a plain atom name."
  @spec run(input()) :: [Result.t()]
  def run(%{device: device, known_hosts: known_hosts, apps: apps} = input) do
    apps = Enum.map(apps, &app_name!/1)
    argv = Preflight.ssh_opts(known_hosts) ++ [device, expression(apps)]
    timeout = Map.get(input, :timeout_ms, @timeout_ms)

    {{status, out}, ms} = Result.timed(fn -> Cmd.run("ssh", argv, timeout_ms: timeout) end)

    case parse(out) do
      {:ok, doc} ->
        note = if status == 0, do: "", else: " (ssh exit #{status})"

        [result("probe", :pass, "one probe block from #{device}#{note}", ms)] ++
          checks(doc, apps, input)

      {:error, why} ->
        probe = result("probe", :fail, "#{why}; ssh exit #{status}: #{Cmd.tail(out)}", ms)
        [probe | Enum.map(check_names(apps, input), &result(&1, :not_exercised, "no probe"))]
    end
  end

  @doc """
  The JSON object between the only BEGIN and END marker lines of `out`.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(out) do
    lines = out |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))
    begins = for {l, i} <- Enum.with_index(lines), String.trim(l) == @begin, do: i
    ends = for {l, i} <- Enum.with_index(lines), String.trim(l) == @finish, do: i

    case {begins, ends} do
      {[b], [e]} when b < e ->
        json = lines |> Enum.slice((b + 1)..(e - 1)//1) |> Enum.join("\n")

        case JSON.decode(json) do
          {:ok, doc} when is_map(doc) -> {:ok, doc}
          _ -> {:error, "the probe block is not one JSON object"}
        end

      {[], []} ->
        {:error, "no probe block in the output"}

      _ ->
        {:error,
         "#{length(begins)} BEGIN and #{length(ends)} END markers: expected exactly one block"}
    end
  end

  @doc "Whether `app` is a plain OTP app name (safe to put into the probe's expression)."
  @spec app_name?(atom() | String.t()) :: boolean()
  def app_name?(app) when is_atom(app) or is_binary(app),
    do: to_string(app) =~ ~r/\A[a-z][a-z0-9_]*\z/

  def app_name?(_), do: false

  defp app_name!(app) do
    if app_name?(app),
      do: to_string(app),
      else: raise(ArgumentError, "not an app name: #{inspect(app)}")
  end

  defp expression(apps) do
    list = Enum.map_join(apps, ", ", &~s|"#{&1}"|)
    "ChainFixture.Probe.run([#{list}])"
  end

  # Names the checks a failed probe leaves not exercised (smoke names are
  # the probe's own, so unknown without it).
  defp check_names(apps, input) do
    Enum.map(apps, &"app:#{&1}") ++
      ["modules", "smoke"] ++
      Enum.map(apps, &"files:#{&1}") ++
      if(Map.get(input, :expected_uuid), do: ["firmware_uuid"], else: []) ++
      if(Map.get(input, :system), do: ["nerves_system"], else: [])
  end

  defp checks(doc, apps, input) do
    Enum.map(apps, &app(doc, &1)) ++
      [modules(doc["modules"])] ++
      smoke(doc["smoke"]) ++
      Enum.map(apps, &files(doc, &1, input.release_dir)) ++
      firmware_uuid(doc["firmware_uuid"], Map.get(input, :expected_uuid)) ++
      nerves_system(doc["nerves_system"], Map.get(input, :system))
  end

  defp app(doc, app) do
    case get_in_map(doc, ["apps", app]) do
      "ok" -> result("app:#{app}", :pass, "#{app} started")
      nil -> result("app:#{app}", :fail, "the probe does not report #{app}")
      other -> result("app:#{app}", :fail, "#{app} did not start: #{to_text(other)}")
    end
  end

  defp modules(%{"loaded" => loaded, "failed" => []}) when is_integer(loaded) and loaded > 0,
    do: result("modules", :pass, "#{loaded} modules loaded")

  defp modules(%{"loaded" => loaded, "failed" => failed}) when is_list(failed) do
    shown = failed |> Enum.take(@shown_problems) |> Enum.map_join("; ", &to_text/1)

    result(
      "modules",
      :fail,
      "#{inspect(loaded)} loaded, #{length(failed)} failed to load" <>
        if(shown == "", do: "", else: ": " <> shown)
    )
  end

  defp modules(other), do: result("modules", :fail, "malformed modules report: #{to_text(other)}")

  defp smoke(%{} = smoke) when map_size(smoke) > 0 do
    for {name, value} <- Enum.sort(smoke) do
      case value do
        "ok" -> result("smoke:#{name}", :pass, "ok")
        other -> result("smoke:#{name}", :fail, to_text(other))
      end
    end
  end

  defp smoke(other), do: [result("smoke", :fail, "no smoke results: #{to_text(other)}")]

  defp files(doc, app, release_dir) do
    check = "files:#{app}"

    with {:ok, local} <- release_files(release_dir, app),
         {:ok, device} <- device_files(get_in_map(doc, ["files", app])) do
      missing =
        for p <- Map.keys(local) -- Map.keys(device), do: "#{inspect(p)}: missing on the device"

      extra =
        for p <- Map.keys(device) -- Map.keys(local), do: "#{inspect(p)}: on the device only"

      differ =
        for {p, sha} <- device, Map.has_key?(local, p), local[p] != sha do
          "#{inspect(p)}: sha256 #{inspect(sha)} on the device, #{local[p]} in the release image"
        end

      case Enum.sort(missing ++ extra ++ differ) do
        [] ->
          result(check, :pass, "#{map_size(local)} files match the release image")

        problems ->
          shown = Enum.take(problems, @shown_problems)
          more = length(problems) - length(shown)

          result(
            check,
            :disagreement,
            "#{length(problems)} differences from the release image: " <>
              Enum.join(shown, "; ") <> if(more > 0, do: "; #{more} more", else: "")
          )
      end
    else
      {:local, why} -> result(check, :not_exercised, why)
      {:device, why} -> result(check, :disagreement, why)
    end
  end

  defp device_files(list) when is_list(list) do
    pairs =
      for entry <- list do
        case entry do
          %{"path" => p, "sha256" => s} when is_binary(p) and is_binary(s) -> {p, s}
          _ -> :bad
        end
      end

    map = if :bad in pairs, do: nil, else: Map.new(pairs)

    cond do
      map == nil ->
        {:device, "the probe's file list has a malformed entry"}

      map_size(map) != length(pairs) ->
        dups =
          pairs
          |> Enum.frequencies_by(&elem(&1, 0))
          |> Enum.filter(fn {_, n} -> n > 1 end)
          |> Enum.map_join(", ", &inspect(elem(&1, 0)))

        {:device, "the probe lists a path more than once: #{dups}"}

      true ->
        {:ok, map}
    end
  end

  defp device_files(nil), do: {:device, "the probe lists no files for the app"}
  defp device_files(_), do: {:device, "the probe's file list is not a list"}

  @doc """
  `%{relative path => sha256}` of every regular file under the release
  image's `lib/<app>-<vsn>/{ebin,priv}`, symlinks followed as the probe
  follows them.
  """
  @spec release_files(Path.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:local, String.t()}
  def release_files(release_dir, app) do
    lib = Path.join(release_dir, "lib")

    case Path.wildcard(Path.join(lib, app <> "-*")) |> Enum.filter(&File.dir?/1) do
      [dir] ->
        files =
          for sub <- ["ebin", "priv"],
              path <- walk(Path.join(dir, sub), 0),
              into: %{},
              do: {Path.relative_to(path, dir), sha256(path)}

        unreadable = for {p, {:error, why}} <- files, do: "#{inspect(p)} (#{why})"

        cond do
          unreadable != [] ->
            {:local,
             "the release image #{dir} has unreadable files: #{Enum.join(unreadable, ", ")}"}

          files == %{} ->
            {:local, "#{dir} has no ebin or priv files to compare with"}

          true ->
            {:ok, files}
        end

      [] ->
        {:local, "the release image has no #{Path.join(lib, app <> "-*")}"}

      dirs ->
        {:local, "the release image has #{length(dirs)} #{app} dirs: #{Enum.join(dirs, ", ")}"}
    end
  end

  defp walk(_path, depth) when depth > @max_depth, do: []

  defp walk(path, depth) do
    cond do
      File.dir?(path) ->
        case File.ls(path) do
          {:ok, names} -> Enum.flat_map(names, &walk(Path.join(path, &1), depth + 1))
          {:error, _} -> []
        end

      File.regular?(path) ->
        [path]

      true ->
        []
    end
  end

  defp firmware_uuid(_got, nil), do: []

  defp firmware_uuid(expected, expected),
    do: [result("firmware_uuid", :pass, "the probe runs on firmware #{expected}")]

  defp firmware_uuid(got, expected) do
    [
      result(
        "firmware_uuid",
        :fail,
        "expected firmware #{expected}, the probe reports #{to_text(got)}"
      )
    ]
  end

  defp nerves_system(_got, nil), do: []

  defp nerves_system(got, {name, vsn}) do
    want = "#{name} #{vsn}"

    cond do
      got == want ->
        [result("nerves_system", :pass, "the device runs #{want}")]

      is_binary(got) and String.starts_with?(got, "nerves_system_") ->
        [result("nerves_system", :fail, "expected #{want}, the device runs #{got}")]

      true ->
        [
          result(
            "nerves_system",
            :not_exercised,
            "the device reports its system as #{to_text(got)}; expected #{want}"
          )
        ]
    end
  end

  defp get_in_map(m, [k | rest]) when is_map(m), do: get_in_map(m[k], rest)
  defp get_in_map(v, []), do: v
  defp get_in_map(_, _), do: nil

  defp to_text(v) when is_binary(v), do: v
  defp to_text(v), do: inspect(v)

  defp sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      {:error, why} -> {:error, :file.format_error(why)}
    end
  end

  defp result(check, class, detail, ms \\ 0),
    do: %Result{step: :device, check: check, class: class, detail: detail, ms: ms}
end
