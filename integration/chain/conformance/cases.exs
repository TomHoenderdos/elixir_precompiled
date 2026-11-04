# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Conformance cases for `mix chain_conformance`. The format is described in
# ChainTest.Conformance.Case and in README.md, "Conformance". Ids are the
# spec's (docs: "Attack vectors"); one case may stand for several rows when
# this harness runs them the same way, its id joining theirs with ".".
# T3's duplicated signature needs a batch threshold of 2: a test-key case.

# The fixture's expected hits: a refused batch makes every one of them a
# refusal, compiled from source instead.
{%{hits: hits}, _} = Code.eval_file(Path.join(__DIR__, "../fixture/expected.exs"))

# What a refused batch looks like to the harness: every expected hit
# `:refused`, nothing installed to check, and, on a home without state, no
# sequence to compare (`sequence: :not_exercised`; a home whose setup wrote
# the snapshot's sequence keeps it, which passes).
refused = fn reason, sequence ->
  %{
    client: %{default: {:fail, reason}, deps: %{}},
    harness:
      Map.merge(
        Map.new(hits, &{"build/hit:#{&1}", :refused}),
        %{"integrity/integrity" => :not_exercised}
      )
      |> then(&if(sequence, do: Map.put(&1, "build/sequence", sequence), else: &1)),
    # R14: a refused batch leaves the state, `_build` and the cache alone.
    after: %{state_sequence: :unchanged, installed: :none, cache: :untouched}
  }
end

# A batch accepted and installed from: the snapshot's builds, all of them.
accepted = %{client: %{default: :snapshot, deps: %{}}, harness: %{}}

# Accepted from the previous batch: the client records N-1, which step 1
# (the snapshot's N) calls a rerun.
accepted_previous = %{accepted | harness: %{"build/sequence" => :rerun}}

[
  %{
    id: "T0",
    description:
      "The mirror serves the snapshot unchanged: the client installs every build the snapshot holds.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{}
  },
  # Clock offsets are ages from the snapshot batch's `issued` ({:age, s}),
  # resolved just before each build, so no case depends on the run's order
  # or the snapshot's age.
  Map.merge(accepted, %{
    id: "R8",
    description:
      "Freeze: the client's clock is 23 hours past the current batch's issue; still fresh, it is accepted.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client_config: %{clock_offset_seconds: {:age, 23 * 3600}},
    after: %{state_sequence: :snapshot, installed: :snapshot}
  }),
  %{
    id: "N5-manifest-500",
    description:
      "The mirror answers 500 for jason's manifest: the client compiles jason and says why.",
    transform:
      {ChainTest.Mirror.Status,
       %{paths: ["v2/manifests/jason.json", "manifests/jason.json"], status: 500}},
    client: %{default: :snapshot, deps: %{jason: {:miss, "manifest unavailable: Status 500"}}},
    harness: %{"build/hit:jason" => :fail}
  },
  Map.merge(accepted, %{
    id: "R0",
    description:
      "The current batch on a fresh home: accepted, and the state records its sequence.",
    transform: {ChainTest.Mirror.Identity, %{}},
    after: %{state_sequence: :snapshot, installed: :snapshot}
  }),
  Map.merge(refused.("batch signature invalid", :not_exercised), %{
    id: "T1",
    description: "One bit of the batch signature flipped: the batch is refused.",
    transform: {ChainTest.Mirror.BatchSignatures, %{change: :flip_bit}}
  }),
  Map.merge(refused.("batch signature invalid", :not_exercised), %{
    id: "T3-removed",
    description: "The batch served with its signatures removed: refused.",
    transform: {ChainTest.Mirror.BatchSignatures, %{change: :remove}}
  }),
  Map.merge(refused.("batch sequence", nil), %{
    id: "T4.R3",
    description:
      "Rollback: the client's state holds the current sequence, the mirror serves the batch before it; refused, the state stays.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :previous}},
    setup: {ChainTest.Conformance.Setup.State, %{sequence: :snapshot}}
  }),
  Map.merge(refused.("batch stale", nil), %{
    id: "T5",
    description:
      "Replay: a client that saw the current batch is served one issued over 25 hours earlier; refused as stale.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :old}},
    setup: {ChainTest.Conformance.Setup.State, %{sequence: :snapshot}}
  }),
  Map.merge(accepted, %{
    id: "T6",
    description:
      "The mirror serves an attacker's newer root.json: the client keeps its shipped root and installs as in T0.",
    transform: {ChainTest.Mirror.RootSwap, %{}},
    after: %{state_sequence: :snapshot, installed: :snapshot}
  }),
  Map.merge(accepted, %{
    id: "T9",
    description:
      "Pins today's behaviour: only environment variables name a root path, an attacker's, and the client, which reads none, installs as in T0.",
    transform: {ChainTest.Mirror.Identity, %{}},
    setup: {ChainTest.Conformance.Setup.PlantRoot, %{path: "attacker/root.json"}},
    client_env: %{
      "ELIXIR_PRECOMPILED_ROOT" => {:home, "attacker/root.json"},
      "NERVES_PRECOMPILED_ROOT" => {:home, "attacker/root.json"}
    },
    after: %{state_sequence: :snapshot, installed: :snapshot}
  }),
  # Every case's home is a fresh ELIXIR_PRECOMPILED_HOME, so the reset T10
  # and R6 describe is R1 and R2 here.
  Map.merge(accepted_previous, %{
    id: "R1.R6.T10",
    description:
      "A fresh home is served the batch before the current one: accepted, within the 24-hour bound.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :previous, hits: true}},
    after: %{state_sequence: :previous, installed: :snapshot}
  }),
  Map.merge(refused.("batch stale", :not_exercised), %{
    id: "R2.R6.T10",
    description:
      "A fresh home is served a batch issued over 25 hours ago: refused as stale, state or not. Real 24-hour batches that old are also expired; the pinned batch stale prefix proves the freshness bound is what refused.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :old}}
  }),
  Map.merge(accepted_previous, %{
    id: "R4-previous",
    description:
      "A corrupt state file counts as 0: the batch before the current one is accepted and replaces it.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :previous, hits: true}},
    setup: {ChainTest.Conformance.Setup.State, %{sequence: :corrupt}},
    after: %{
      state_sequence: :previous,
      installed: :snapshot,
      # The sequence state's warning, not the root version's.
      log: ["precompiled: sequence state ", "is unreadable; treating it as 0"]
    }
  }),
  refused.("batch stale", :not_exercised)
  |> Map.merge(%{
    id: "R4-old",
    description:
      "A corrupt state file counts as 0, yet a batch issued over 25 hours ago is still refused as stale. Freshness is checked before the state is read, so the corrupt file is never read and nothing is logged; R4-previous checks the log.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :old}},
    setup: {ChainTest.Conformance.Setup.State, %{sequence: :corrupt}}
  }),
  Map.merge(accepted, %{
    id: "R5",
    description:
      "The state holds a sequence 40 below the current batch: gaps are allowed, it is accepted.",
    transform: {ChainTest.Mirror.Identity, %{}},
    setup: {ChainTest.Conformance.Setup.State, %{sequence: {:below, 40}}},
    after: %{state_sequence: :snapshot, installed: :snapshot}
  }),
  Map.merge(refused.("batch stale", :not_exercised), %{
    id: "R7",
    description:
      "Freeze: the client's clock is 25 hours past the current batch's issue; refused as stale.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client_config: %{clock_offset_seconds: {:age, 25 * 3600}}
  }),
  # "clock is before": the floor check's own reason, not the future-issue
  # one ("clock: batch issued at ...").
  Map.merge(refused.("clock is before", :not_exercised), %{
    id: "R12",
    description:
      "The client's clock is 30 days before the library was built: refused, and everything compiles.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client_config: %{clock_offset_seconds: -30 * 86_400}
  }),
  # The spec row, amended: freshness is checked before expiry, so a clock a
  # year ahead reads as stale, not expired.
  Map.merge(refused.("batch stale", :not_exercised), %{
    id: "R13",
    description:
      "The client's clock is a year past the batch's issue: refused as stale, and everything compiles.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client_config: %{clock_offset_seconds: {:age, 365 * 86_400}}
  }),
  Map.merge(accepted_previous, %{
    id: "R19",
    description:
      "Two sources: one's state holds the current sequence, the other is served the batch before it; accepted there, the first source's state untouched.",
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :previous, hits: true, mirrors: 2}},
    setup: {ChainTest.Conformance.Setup.State, %{sequence: :snapshot, source: :second}},
    after: %{
      state_sequence: :previous,
      other_states: :unchanged,
      installed: :snapshot,
      second_mirror: :untouched
    }
  })
]
