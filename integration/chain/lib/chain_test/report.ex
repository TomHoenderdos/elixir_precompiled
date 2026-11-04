# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Report do
  @moduledoc """
  Writes a run's results as Markdown and JSON: `<dir>/<target>-<timestamp>.md`
  and `.json`, the timestamp taken from `meta.started_at`.
  """

  alias ChainTest.Result

  @meta_keys [
    :batch_sequence_step1,
    :batch_sequence_step2,
    :root_version,
    :client_commit,
    :nerves_commit,
    :elixir,
    :otp,
    :system_version,
    :started_at,
    :known_gaps
  ]

  @known_gaps [
    "A compromised portal key: it can sign valid builds. Only the reproduce layer and the " <>
      "on-device checks catch that, and only partly. Today one online key holds both the root " <>
      "and the batch role.",
    "A freeze attack: an old but unexpired batch cannot be told from the current one until it " <>
      "expires. The window is at most the batch lifetime (24 hours under the portal's policy).",
    "The client's own known gaps: the max_bytes cap applies to streamed 2xx bodies only; Mix's " <>
      ":lockfile, :config and :config_path are not applied before the check.",
    "Two targets, one ABI: rpi4 and rpi0_2 are both aarch64. They exercise two targets' builds " <>
      "but not cross-architecture protection."
  ]

  @doc "The \"known, not testable\" items every report names."
  @spec known_gaps() :: [String.t()]
  def known_gaps(), do: @known_gaps

  @doc "The meta keys a report carries."
  @spec meta_keys() :: [atom()]
  def meta_keys(), do: @meta_keys

  @spec write(Path.t(), String.t(), [Result.t()], map()) :: {:ok, %{md: Path.t(), json: Path.t()}}
  def write(dir, target, results, meta) do
    File.mkdir_p!(dir)
    base = Path.join(dir, "#{target}-#{stamp(meta[:started_at])}")
    md = base <> ".md"
    json = base <> ".json"

    File.write!(json, json_doc(target, results, meta))
    File.write!(md, markdown(target, results, meta))
    {:ok, %{md: md, json: json}}
  end

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y%m%dT%H%M%SZ")
  defp stamp(_), do: stamp(DateTime.utc_now())

  defp json_doc(target, results, meta) do
    %{
      "target" => target,
      "meta" => Map.new(meta, fn {k, v} -> {to_string(k), json_value(v)} end),
      "results" => Enum.map(results, &result_map/1),
      "exit_code" => Result.exit_code(results)
    }
    |> JSON.encode!()
  end

  defp result_map(%Result{} = r) do
    %{
      "step" => Atom.to_string(r.step),
      "check" => text(r.check),
      "class" => Atom.to_string(r.class),
      "detail" => text(r.detail),
      "ms" => r.ms
    }
  end

  defp json_value(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  defp json_value(value) when is_binary(value), do: text(value)
  defp json_value(value), do: value

  # Details quote untrusted bytes (file names, client output): never let
  # invalid UTF-8 break the report.
  defp text(value) when is_binary(value), do: String.replace_invalid(value)
  defp text(value), do: value

  defp markdown(target, results, meta) do
    verdict = verdict(results)

    meta_rows =
      Enum.map_join(@meta_keys -- [:known_gaps], "", fn key ->
        "| #{key} | #{cell(json_value(meta[key]))} |\n"
      end)

    result_rows =
      Enum.map_join(results, "", fn r ->
        "| #{r.step} | #{cell(r.check)} | #{r.class} | #{r.ms} | #{cell(r.detail)} |\n"
      end)

    gaps = Enum.map_join(meta[:known_gaps] || [], "", &"- #{&1}\n")

    """
    # Chain test: #{target} (#{verdict})

    | key | value |
    | --- | --- |
    #{meta_rows}
    ## Results

    | step | check | class | ms | detail |
    | --- | --- | --- | --- | --- |
    #{result_rows}
    #{step_times(results)}
    ## Known, not testable

    #{gaps}\
    """
  end

  # A rerun exits 0 but does not count as a pass: run again.
  # "PASS (2 miss)" when expected hits fell back to compiling.
  defp verdict(results) do
    base =
      cond do
        Result.exit_code(results) == 1 -> "FAIL"
        Enum.any?(results, &(&1.class == :rerun)) -> "RERUN"
        true -> "PASS"
      end

    misses = Enum.count(results, &(&1.class == :miss and String.starts_with?(&1.check, "hit:")))
    if base != "FAIL" and misses > 0, do: "#{base} (#{misses} miss)", else: base
  end

  defp step_times(results) do
    rows =
      results
      |> Enum.map(& &1.step)
      |> Enum.uniq()
      |> Enum.map_join("", fn step ->
        ms = for(r <- results, r.step == step, do: r.ms) |> Enum.sum()
        "| #{step} | #{ms} |\n"
      end)

    "## Time per step\n\n| step | ms |\n| --- | --- |\n" <> rows
  end

  defp cell(nil), do: ""

  # Table cells carry untrusted text: escape HTML first, then Markdown's
  # inline syntax, then the table's own pipe; newlines become <br>.
  defp cell(value) do
    value
    |> to_string()
    |> String.replace_invalid()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~r/([\\`*_\[\]#!~])/, "\\\\\\1")
    |> String.replace("|", "\\|")
    |> String.replace(~r/\r?\n/, "<br>")
  end
end
