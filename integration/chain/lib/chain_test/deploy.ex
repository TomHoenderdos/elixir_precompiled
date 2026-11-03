# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Deploy do
  @moduledoc """
  Step 5: the fixture's firmware goes onto the device, and the device comes
  back running it.

  Checks:

    * `metadata` - `fwup -m -i <fw>` names a `meta-uuid` (the expected
      firmware UUID) and, when a target is given, a `meta-platform` equal to
      it. Nothing is uploaded otherwise.
    * `upload` - `ssh <opts> -s <device> fwup`, the image as stdin, exits 0
      within 10 minutes.
    * `reboot` - polled every 5 s for up to 5 minutes after the upload, the
      device answers with a VM uptime shorter than the time since the upload
      began. An answer from before the reboot does not count: Nerves'
      firmware KV already names the new slot before the reboot.
    * `active_uuid` - after the reboot, `Nerves.Runtime.KV.get_active("nerves_fw_uuid")`
      equals the expected UUID. Anything else (a fwup revert to the old
      firmware) fails naming both.

  Every ssh call uses `ChainTest.Preflight.ssh_opts/1`: the pinned
  known_hosts file, `StrictHostKeyChecking=yes`, `BatchMode=yes`.
  """

  alias ChainTest.{Cmd, Preflight, Result}

  @metadata_timeout_ms 60_000
  @upload_timeout_ms 10 * 60 * 1000
  @reboot_timeout_ms 5 * 60 * 1000
  @poll_ms 5_000
  @answer_timeout_ms 20_000

  # One line the poll parses, on its own: an IEx banner, log lines or an
  # echo of the expression around it never match the whole-line pattern.
  @query ~S|IO.puts(["chain-deploy uuid=", to_string(Nerves.Runtime.KV.get_active("nerves_fw_uuid")), " uptime_ms=", Integer.to_string(elem(:erlang.statistics(:wall_clock), 0))])|
  @answer ~r/\Achain-deploy uuid=(\S*) uptime_ms=(\d+)\z/

  @checks ~w(metadata upload reboot active_uuid)

  @type input :: %{
          required(:device) => String.t(),
          required(:known_hosts) => Path.t(),
          required(:fw_path) => Path.t() | nil,
          optional(:target) => String.t(),
          optional(:upload_timeout_ms) => pos_integer(),
          optional(:reboot_timeout_ms) => pos_integer(),
          optional(:poll_ms) => pos_integer()
        }

  @doc "The Elixir expression the poll runs on the device."
  @spec query() :: String.t()
  def query, do: @query

  @doc "Runs step 5; `expected_uuid` is `nil` when the image names none."
  @spec run(input()) :: {[Result.t()], %{expected_uuid: String.t() | nil}}
  def run(%{fw_path: nil}) do
    {Enum.map(@checks, &result(&1, :not_exercised, "no firmware image to deploy")),
     %{expected_uuid: nil}}
  end

  def run(%{fw_path: fw} = input) do
    case metadata(fw, Map.get(input, :target)) do
      {:ok, uuid, meta} ->
        {upload, started, ok?} = upload(input)

        rest =
          if ok?,
            do: await(input, uuid, started),
            else: not_exercised(~w(reboot active_uuid), "the upload failed")

        {[meta, upload | rest], %{expected_uuid: uuid}}

      {:error, uuid, meta} ->
        {[
           meta
           | not_exercised(~w(upload reboot active_uuid), "the image failed its metadata check")
         ], %{expected_uuid: uuid}}
    end
  end

  # metadata

  defp metadata(fw, target) do
    {{status, out}, ms} =
      Result.timed(fn -> Cmd.run("fwup", ["-m", "-i", fw], timeout_ms: @metadata_timeout_ms) end)

    meta = parse_meta(out)
    uuid = meta["meta-uuid"]
    platform = meta["meta-platform"]

    cond do
      status != 0 ->
        {:error, nil,
         result("metadata", :fail, "fwup -m -i #{fw} exit #{status}: #{tail(out)}", ms)}

      uuid in [nil, ""] ->
        {:error, nil, result("metadata", :fail, "fwup -m -i #{fw} names no meta-uuid", ms)}

      target != nil and platform != target ->
        {:error, uuid,
         result(
           "metadata",
           :fail,
           "#{fw} is built for platform #{inspect(platform)}, not #{target}",
           ms
         )}

      true ->
        {:ok, uuid,
         result("metadata", :pass, "#{fw}: uuid #{uuid}, platform #{inspect(platform)}", ms)}
    end
  end

  defp parse_meta(out) do
    for line <- lines(out),
        [_, key, value] <- [Regex.run(~r/\A(meta-[a-z-]+)=(.*)\z/, line)],
        into: %{},
        do: {key, unquote_value(value)}
  end

  defp unquote_value("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp unquote_value(value), do: value

  # upload

  defp upload(input) do
    argv = Preflight.ssh_opts(input.known_hosts) ++ ["-s", input.device, "fwup"]
    timeout = Map.get(input, :upload_timeout_ms, @upload_timeout_ms)
    started = now()

    {{status, out}, ms} =
      Result.timed(fn ->
        Cmd.run("ssh", argv, stdin_file: input.fw_path, timeout_ms: timeout)
      end)

    case status do
      0 ->
        {result("upload", :pass, "ssh -s #{input.device} fwup exit 0: #{tail(out)}", ms), started,
         true}

      124 ->
        {result("upload", :fail, "upload timed out after #{timeout} ms: #{tail(out)}", ms),
         started, false}

      _ ->
        {result("upload", :fail, "ssh -s #{input.device} fwup exit #{status}: #{tail(out)}", ms),
         started, false}
    end
  end

  # reboot and active uuid

  defp await(input, expected, started) do
    timeout = Map.get(input, :reboot_timeout_ms, @reboot_timeout_ms)
    deadline = now() + timeout
    t0 = now()

    case poll(input, started, deadline, Map.get(input, :poll_ms, @poll_ms), %{up: nil, error: nil}) do
      {:rebooted, uuid, uptime} ->
        waited = now() - t0

        reboot =
          result(
            "reboot",
            :pass,
            "answered #{waited} ms after the upload, VM uptime #{uptime} ms",
            waited
          )

        [reboot, active(uuid, expected)]

      {:timeout, seen} ->
        why =
          case seen do
            %{up: {uuid, uptime}, error: error} ->
              "#{input.device} answered (uuid #{show(uuid)}, VM uptime #{uptime} ms) but " <>
                "did not reboot within #{timeout} ms of the upload" <>
                if(error, do: "; last ssh error: #{error}", else: "")

            %{error: error} when is_binary(error) ->
              "#{input.device} did not answer within #{timeout} ms of the upload: #{error}"

            _ ->
              "#{input.device} did not answer within #{timeout} ms of the upload"
          end

        [
          result("reboot", :fail, why, now() - t0),
          result(
            "active_uuid",
            :not_exercised,
            "the device did not come back from a reboot; its running firmware is unknown"
          )
        ]
    end
  end

  # `seen`: the last answer from before a reboot and the last ssh error.
  defp poll(input, started, deadline, poll_ms, seen) do
    left = deadline - now()

    if left <= 0 do
      {:timeout, seen}
    else
      argv = Preflight.ssh_opts(input.known_hosts) ++ [input.device, @query]

      answer =
        "ssh"
        |> Cmd.run(argv, timeout_ms: max(min(@answer_timeout_ms, left), 1))
        |> parse_answer()

      since_upload = now() - started

      case answer do
        {:up, uuid, uptime} when uptime < since_upload ->
          {:rebooted, uuid, uptime}

        other ->
          seen =
            case other do
              {:up, uuid, uptime} -> %{seen | up: {uuid, uptime}}
              {:error, detail} -> %{seen | error: detail}
            end

          Process.sleep(min(poll_ms, max(deadline - now(), 0)))
          poll(input, started, deadline, poll_ms, seen)
      end
    end
  end

  defp parse_answer({status, out}) do
    found =
      Enum.find_value(lines(out), fn line ->
        case Regex.run(@answer, line) do
          [_, uuid, uptime] -> {:up, uuid, String.to_integer(uptime)}
          nil -> nil
        end
      end)

    found || {:error, "ssh exit #{status}: #{tail(out)}"}
  end

  defp active(uuid, expected) when uuid == expected,
    do: result("active_uuid", :pass, "the device runs #{expected}, the uploaded image's uuid")

  defp active(uuid, expected) do
    result(
      "active_uuid",
      :fail,
      "expected #{expected} (the uploaded image's meta-uuid), the device runs #{show(uuid)}: " <>
        "it booted another firmware (a fwup revert to the previous one?)"
    )
  end

  defp show(""), do: "(none)"
  defp show(uuid), do: uuid

  defp now, do: System.monotonic_time(:millisecond)

  defp lines(out), do: out |> String.split("\n") |> Enum.map(&String.trim(&1))

  defp tail(out) do
    out
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.take(-5)
    |> Enum.join(" / ")
  end

  defp not_exercised(checks, why), do: Enum.map(checks, &result(&1, :not_exercised, why))

  defp result(check, class, detail, ms \\ 0),
    do: %Result{step: :deploy, check: check, class: class, detail: detail, ms: ms}
end
