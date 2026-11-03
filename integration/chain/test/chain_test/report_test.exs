# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.ReportTest do
  use ExUnit.Case, async: true

  alias ChainTest.{Report, Result}

  @moduletag :tmp_dir

  @results [
    %Result{step: :preflight, check: "ssh", class: :pass, detail: "ok", ms: 120},
    %Result{
      step: :trust,
      check: "batch_signature",
      class: :fail,
      detail: "bad | sig\nline 2",
      ms: 3
    },
    %Result{step: :build, check: "hits", class: :rerun, detail: "sequence moved", ms: 90_000}
  ]

  @meta %{
    batch_sequence_step1: 41,
    batch_sequence_step2: 42,
    root_version: 3,
    client_commit: "abc123",
    nerves_commit: "def456",
    elixir: "1.20.3",
    otp: "29",
    system_version: "2.0.1",
    started_at: ~U[2026-11-03 12:34:56Z],
    known_gaps: ["gap one", "gap two"]
  }

  test "writes <target>-<timestamp>.md and .json", %{tmp_dir: dir} do
    assert {:ok, %{md: md, json: json}} = Report.write(dir, "rpi4", @results, @meta)
    assert Path.dirname(md) == dir
    assert Path.basename(md) =~ ~r/^rpi4-\d{8}T\d{6}Z\.md$/
    assert Path.rootname(md) == Path.rootname(json)
    assert Path.extname(json) == ".json"
    assert File.exists?(md) and File.exists?(json)
  end

  test "creates the report dir", %{tmp_dir: dir} do
    nested = Path.join(dir, "a/b")
    assert {:ok, %{md: md}} = Report.write(nested, "rpi0_2", @results, @meta)
    assert File.exists?(md)
  end

  test "JSON round-trips every result and every meta key", %{tmp_dir: dir} do
    {:ok, %{json: json}} = Report.write(dir, "rpi4", @results, @meta)
    doc = json |> File.read!() |> JSON.decode!()

    assert doc["target"] == "rpi4"

    decoded =
      Enum.map(doc["results"], fn r ->
        %Result{
          step: String.to_existing_atom(r["step"]),
          check: r["check"],
          class: String.to_existing_atom(r["class"]),
          detail: r["detail"],
          ms: r["ms"]
        }
      end)

    assert decoded == @results

    for {key, value} <- @meta do
      expected = if key == :started_at, do: DateTime.to_iso8601(value), else: value
      assert doc["meta"][Atom.to_string(key)] == expected, "meta #{key}"
    end
  end

  test "Markdown has one table row per result and the known gaps", %{tmp_dir: dir} do
    {:ok, %{md: md}} = Report.write(dir, "rpi4", @results, @meta)
    text = File.read!(md)

    rows =
      text
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ ~r/^\| (preflight|trust|build) \| [^|]+ \| (pass|fail|rerun) \|/))

    assert length(rows) == length(@results)
    assert Enum.any?(rows, &(&1 =~ "batch_signature" and &1 =~ "fail"))
    # A pipe or newline in a detail must not break the table.
    refute Enum.any?(String.split(text, "\n"), &(&1 == "line 2 |"))

    [_, gaps] = String.split(text, "## Known, not testable", parts: 2)
    assert gaps =~ "- gap one"
    assert gaps =~ "- gap two"

    for value <- ["41", "42", "abc123", "def456", "1.20.3", "2.0.1"], do: assert(text =~ value)
  end

  test "known_gaps/0 is a non-empty list of strings" do
    assert [_ | _] = gaps = Report.known_gaps()
    assert Enum.all?(gaps, &is_binary/1)
  end
end
