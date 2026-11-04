# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Report do
  @moduledoc """
  Writes a run's results as Markdown and JSON: `<dir>/<target>-<timestamp>.md`
  and `.json`, the timestamp taken from `meta.started_at`.

  Sections after the results: the time per step; "Per layer" when the meta
  carries `layers` (a conformance summary: each layer's verdicts counted by
  class); "Not testable here", one line per `:not_testable` case with the
  spec ids its case id names and its reason; and "Known, not testable",
  the meta's `known_gaps`.
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
      "but not cross-architecture protection.",
    "P5 for a git dep (the lock names it, so only the client's git/path rule stops a " <>
      "precompiled build of it): covered by the client's own tests, its end-to-end git-dep " <>
      "test in the client suite; the conformance case P5-path covers path deps.",
    "P7, a forged entry claiming the project's target and toolchain but carrying another " <>
      "target's .so: the client cannot tell (it trusts the signed claim); it is a layer-3 / " <>
      "on-device item, caught by step 6's smoke call failing on the device.",
    "N3's positive control through a client CA option: the client has no CA option (it " <>
      "trusts the OS store only), so it cannot be told to trust a test CA the way a user " <>
      "would. TLS-T0 stands in: the run's test CA loaded as the build VM's whole store " <>
      "(:public_key.cacerts_load/1 from the case's config file), which no N3 trust case " <>
      "(self-signed, wrong-host) gets; N3-hostname uses the same store to reach the " <>
      "hostname check alone."
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
    #{step_times(results)}#{layers(meta[:layers])}#{not_testable(results)}
    ## Known, not testable

    #{gaps}\
    """
  end

  @layer_columns [
    pass: "pass",
    fail: "fail",
    not_exercised: "not exercised",
    not_testable: "not testable"
  ]

  # A conformance summary's verdicts per layer.
  defp layers([_ | _] = layers) do
    head = Enum.map_join(@layer_columns, " | ", &elem(&1, 1))

    rows =
      Enum.map_join(layers, "", fn l ->
        counts = Enum.map(@layer_columns, fn {k, _} -> Map.get(l, k, 0) end)
        other = l.cases - Enum.sum(counts)
        "| #{cell(l.layer)} | #{l.cases} | #{Enum.join(counts, " | ")} | #{other} |\n"
      end)

    "\n## Per layer\n\n| layer | cases | #{head} | other |\n" <>
      "| --- | --- | --- | --- | --- | --- | --- |\n" <> rows
  end

  defp layers(_), do: ""

  # Cases the snapshot could not back, apart from the results that ran.
  defp not_testable(results) do
    case Enum.filter(results, &(&1.class == :not_testable)) do
      [] ->
        ""

      rs ->
        "\n## Not testable here\n\n" <>
          Enum.map_join(rs, "", &"- #{cell(&1.check)}#{spec(&1.check)}: #{cell(&1.detail)}\n")
    end
  end

  defp spec(id) do
    case spec_ids(to_string(id)) do
      [] -> ""
      ids -> " (spec #{Enum.join(ids, ", ")})"
    end
  end

  @doc """
  The spec's ids (`T4`, `R3`, ...: a row letter and a number) a case id
  names: `"T4.R3"` both, `"N1-manifest"` N1, `"L2-T0"` T0.
  """
  @spec spec_ids(String.t()) :: [String.t()]
  def spec_ids(id) do
    ~r/(?<![A-Za-z0-9])[TMFNCRP][0-9]+(?![0-9])/
    |> Regex.scan(id)
    |> List.flatten()
  end

  # A rerun exits 0 but does not count as a pass: run again.
  # "PASS (2 miss)" when expected hits fell back to compiling, "PASS (1 not
  # testable here)" when a case could not be backed by the snapshot.
  defp verdict(results) do
    base =
      cond do
        Result.exit_code(results) == 1 -> "FAIL"
        Enum.any?(results, &(&1.class == :rerun)) -> "RERUN"
        true -> "PASS"
      end

    misses = Enum.count(results, &(&1.class == :miss and String.starts_with?(&1.check, "hit:")))
    untestable = Enum.count(results, &(&1.class == :not_testable))

    notes =
      [{misses, "miss"}, {untestable, "not testable here"}]
      |> Enum.filter(fn {n, _} -> n > 0 end)
      |> Enum.map_join(", ", fn {n, what} -> "#{n} #{what}" end)

    if base != "FAIL" and notes != "", do: "#{base} (#{notes})", else: base
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
