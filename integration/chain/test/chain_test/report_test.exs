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
    # Markdown-escaped: renders as batch_signature.
    assert Enum.any?(rows, &(&1 =~ "batch\\_signature" and &1 =~ "fail"))
    # A pipe or newline in a detail must not break the table.
    refute Enum.any?(String.split(text, "\n"), &(&1 == "line 2 |"))

    [_, gaps] = String.split(text, "## Known, not testable", parts: 2)
    assert gaps =~ "- gap one"
    assert gaps =~ "- gap two"

    for value <- ["41", "42", "abc123", "def456", "1.20.3", "2.0.1"], do: assert(text =~ value)
  end

  test "the heading is PASS, RERUN when the worst class is a rerun, else FAIL", %{tmp_dir: dir} do
    heading = fn results, name ->
      {:ok, %{md: md}} = Report.write(Path.join(dir, name), "rpi4", results, %{})
      md |> File.read!() |> String.split("\n") |> hd()
    end

    pass = %Result{step: :trust, check: "a", class: :pass}
    miss = %Result{step: :build, check: "b", class: :miss}
    rerun = %Result{step: :build, check: "sequence", class: :rerun}
    fail = %Result{step: :deploy, check: "c", class: :fail}

    assert heading.([pass, miss], "p") == "# Chain test: rpi4 (PASS)"
    assert heading.([pass, rerun, miss], "r") == "# Chain test: rpi4 (RERUN)"
    assert heading.([rerun, fail], "f") == "# Chain test: rpi4 (FAIL)"
  end

  test "not testable here counts in the heading and gets its own section", %{tmp_dir: dir} do
    write = fn results, name ->
      {:ok, %{md: md}} = Report.write(Path.join(dir, name), "rpi4", results, %{})
      File.read!(md)
    end

    pass = %Result{step: :conformance, check: "T0", class: :pass}

    untestable = %Result{
      step: :conformance,
      check: "X1",
      class: :not_testable,
      detail: "not testable here: no old batch"
    }

    fail = %Result{step: :conformance, check: "F", class: :fail}
    miss = %Result{step: :build, check: "hit:a", class: :miss}

    md = write.([pass, untestable], "t")
    assert hd(String.split(md, "\n")) == "# Chain test: rpi4 (PASS (1 not testable here))"
    assert md =~ "## Not testable here\n\n- X1: not testable here: no old batch\n"

    named = %{untestable | check: "M3"}
    assert write.([named], "n") =~ "- M3 (rows M3): not testable here: no old batch\n"

    assert hd(String.split(write.([pass, untestable, miss], "m"), "\n")) ==
             "# Chain test: rpi4 (PASS (1 miss, 1 not testable here))"

    assert hd(String.split(write.([untestable, fail], "f"), "\n")) == "# Chain test: rpi4 (FAIL)"
    refute write.([pass], "p") =~ "## Not testable here"
  end

  test "the heading counts expected hits that missed", %{tmp_dir: dir} do
    heading = fn results, name ->
      {:ok, %{md: md}} = Report.write(Path.join(dir, name), "rpi4", results, %{})
      md |> File.read!() |> String.split("\n") |> hd()
    end

    pass = %Result{step: :trust, check: "a", class: :pass}
    miss = fn dep -> %Result{step: :build, check: "hit:#{dep}", class: :miss} end
    root_miss = %Result{step: :trust, check: "served_root", class: :miss}
    rerun = %Result{step: :build, check: "sequence", class: :rerun}

    assert heading.([pass, miss.("a"), miss.("b"), root_miss], "m") ==
             "# Chain test: rpi4 (PASS (2 miss))"

    assert heading.([pass, root_miss], "n") == "# Chain test: rpi4 (PASS)"
    assert heading.([rerun, miss.("a")], "r") == "# Chain test: rpi4 (RERUN (1 miss))"
  end

  test "invalid UTF-8 in a detail is replaced, never breaks the JSON", %{tmp_dir: dir} do
    bad = %Result{
      step: :device,
      check: "files:x",
      class: :fail,
      detail: "name " <> <<255>> <> " end"
    }

    {:ok, %{json: json, md: md}} = Report.write(dir, "rpi4", [bad], %{})

    doc = JSON.decode!(File.read!(json))
    assert hd(doc["results"])["detail"] =~ "name "
    assert String.valid?(hd(doc["results"])["detail"])
    assert String.valid?(File.read!(md))
  end

  test "Markdown in untrusted text is escaped", %{tmp_dir: dir} do
    detail = "`code` *b* _i_ [link](http://x) <script>"
    r = %Result{step: :device, check: "files:x", class: :fail, detail: detail}
    {:ok, %{md: md}} = Report.write(dir, "rpi4", [r], %{})
    text = File.read!(md)

    refute text =~ "<script>"
    refute text =~ "[link](http://x)"
    refute text =~ "`code`"
    assert text =~ "\\`code\\`"
    assert text =~ "&lt;script&gt;"
  end

  test "known_gaps/0 is a non-empty list of strings" do
    assert [_ | _] = gaps = Report.known_gaps()
    assert Enum.all?(gaps, &is_binary/1)
  end

  test "known_gaps/0 names P5 for a git dep: covered by the client's own tests" do
    assert Enum.any?(Report.known_gaps(), &(&1 =~ "P5 for a git dep" and &1 =~ "client"))
  end

  test "known_gaps/0 names P7: the client trusts the signed target claim" do
    assert Enum.any?(Report.known_gaps(), &(&1 =~ "P7" and &1 =~ "trusts the signed claim"))
  end

  test "row_ids/1 reads the attack-vector rows out of a case id" do
    assert Report.row_ids("T4.R3") == ["T4", "R3"]
    assert Report.row_ids("R1.R6.T10") == ["R1", "R6", "T10"]
    assert Report.row_ids("N1-manifest") == ["N1"]
    assert Report.row_ids("N5-manifest-500") == ["N5"]
    assert Report.row_ids("L2-T0") == ["T0"]
    assert Report.row_ids("TLS-T0") == ["T0"]
    assert Report.row_ids("N3-self-signed") == ["N3"]
    assert Report.row_ids("X1") == []
  end

  test "meta layers become a per-layer table; without them there is none", %{tmp_dir: dir} do
    layers = [
      %{layer: "layer 1", cases: 5, pass: 2, fail: 1, not_testable: 1, rerun: 1},
      %{layer: "layer 2", cases: 2, pass: 1, not_exercised: 1}
    ]

    {:ok, %{md: md, json: json}} = Report.write(dir, "rpi4", [], %{layers: layers})
    text = File.read!(md)

    assert text =~
             "## Per layer\n\n" <>
               "| layer | cases | pass | fail | not exercised | not testable | other |\n" <>
               "| --- | --- | --- | --- | --- | --- | --- |\n" <>
               "| layer 1 | 5 | 2 | 1 | 0 | 1 | 1 |\n" <>
               "| layer 2 | 2 | 1 | 0 | 1 | 0 | 0 |\n"

    assert [%{"layer" => "layer 1", "cases" => 5} | _] =
             JSON.decode!(File.read!(json))["meta"]["layers"]

    {:ok, %{md: plain}} = Report.write(Path.join(dir, "p"), "rpi4", [], %{})
    refute File.read!(plain) =~ "## Per layer"
  end

  test "known_gaps/0 names N3's positive control: the client has no CA option" do
    assert [gap] = Enum.filter(Report.known_gaps(), &(&1 =~ "N3"))
    assert gap =~ "no CA option"
    assert gap =~ "no N3 trust case (self-signed, wrong-host)"
  end

  test "known_gaps/0 does not list R20: --policy tests it" do
    refute Enum.any?(Report.known_gaps(), &(&1 =~ "R20"))
  end
end
