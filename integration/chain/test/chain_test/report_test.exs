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

  test "known_gaps/0 names P7: the client trusts the signed target claim" do
    assert Enum.any?(Report.known_gaps(), &(&1 =~ "P7" and &1 =~ "trusts the signed claim"))
  end
end
