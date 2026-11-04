# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Conformance cases for `mix chain_conformance`. The format is described in
# ChainTest.Conformance.Case and in README.md, "Conformance". Ids are the
# spec's (docs: "Attack vectors"); one case may stand for several rows when
# this harness runs them the same way, its id joining theirs with ".".
# T3's duplicated signature needs a batch threshold of 2: a test-key case
# (layer 2, at the end).
#
# M4 (entry selection) has no case of its own: with real signed bytes it is
# T0's, whose integrity step checks that every hit installed exactly the
# build the harness selects from the manifest for this target, OTP and
# Elixir. A forged entry for another target is layer 2 (P7). N6 (a
# same-host scheme downgrade) needs TLS: Task 5's mirror.

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

# The batch accepted, and every dep the snapshot holds a build of refused
# at one step (`expect`, the client's own reason): nothing installed, no
# changed byte left in the cache, the state at the batch's sequence.
none_installed = fn expect ->
  %{
    client: %{default: expect, deps: %{}},
    harness:
      Map.merge(
        Map.new(hits, &{"build/hit:#{&1}", :fail}),
        %{"integrity/integrity" => :not_exercised}
      ),
    after: %{state_sequence: :snapshot, installed: :none, cache: :verified}
  }
end

# No batch at all (`batch unavailable`, a transport failure): like a
# refusal, with R14's post-conditions, but not one of the client's refusal
# reasons, so the hit rows are plain failures.
no_batch = %{
  client: %{default: {:fail, "batch unavailable"}, deps: %{}},
  harness:
    Map.merge(Map.new(hits, &{"build/hit:#{&1}", :fail}), %{
      "integrity/integrity" => :not_exercised,
      "build/sequence" => :not_exercised
    }),
  after: %{state_sequence: :unchanged, installed: :none, cache: :untouched}
}

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
  }),
  # Layer 1: manifests, files, the network and the cache, real bytes.
  Map.merge(none_installed.({:fail, "manifest hash differs from batch"}), %{
    id: "M1",
    description:
      "One byte of every manifest changed: each fails the hash the batch names, and nothing is installed.",
    transform: {ChainTest.Mirror.ManifestBytes, %{change: :flip_byte}}
  }),
  Map.merge(none_installed.({:fail, "manifest hash differs from batch"}), %{
    id: "M2",
    description:
      "Each dep's manifest is another dep's real one: refused on the hash, nothing installed.",
    transform: {ChainTest.Mirror.ManifestBytes, %{change: :swap}}
  }),
  %{
    id: "M3",
    description:
      "A real manifest an older batch names, and the current one does not, served under the current batch: refused on the hash.",
    transform: {ChainTest.Mirror.OlderManifest, %{}},
    client: %{default: :older_manifest, deps: %{}},
    harness: %{},
    after: %{state_sequence: :snapshot, installed: :older_manifest, cache: :verified}
  },
  Map.merge(none_installed.({:fail, "sha256 mismatch"}), %{
    id: "F1",
    description:
      "One byte of every file changed, its size kept: refused on the sha256, nothing installed or cached.",
    transform: {ChainTest.Mirror.FileBytes, %{change: :flip_byte}}
  }),
  Map.merge(none_installed.(:fail), %{
    id: "F2-truncated",
    description:
      "Every file cut one byte short of the length it declares: refused, nothing installed or cached.",
    transform: {ChainTest.Mirror.FileBytes, %{change: :truncate}}
  }),
  Map.merge(none_installed.({:fail, "file larger than declared size"}), %{
    id: "F2-larger",
    description:
      "Every file one byte larger than the manifest's size: refused at the size cap, nothing installed or cached.",
    transform: {ChainTest.Mirror.FileBytes, %{change: :larger}}
  }),
  Map.merge(none_installed.({:fail, "file larger than declared size"}), %{
    id: "F2-endless",
    description:
      "Every file an endless stream without a length: refused at the size cap, nothing installed or cached.",
    transform: {ChainTest.Mirror.FileBytes, %{change: :endless}}
  }),
  none_installed.({:fail, "file not available:"})
  |> Map.merge(%{
    id: "N1",
    description:
      "Every file redirected to another origin, a second mirror with the right bytes: refused as cross-origin, never followed.",
    transform: {ChainTest.Mirror.Redirect, %{paths: :files, mirrors: 2}}
  })
  |> Map.update!(
    :after,
    &Map.merge(&1, %{second_mirror: :untouched, log: "redirect to another host refused"})
  ),
  none_installed.({:miss, "manifest unavailable: redirect to another host refused"})
  |> Map.merge(%{
    id: "N1-manifest",
    description:
      "Every manifest redirected to another origin: refused as cross-origin, never followed, nothing installed.",
    transform: {ChainTest.Mirror.Redirect, %{paths: :manifests, mirrors: 2}}
  })
  |> Map.update!(:after, &Map.put(&1, :second_mirror, :untouched)),
  Map.merge(no_batch, %{
    id: "N1-batch",
    description:
      "batch.json redirected to another origin: refused as cross-origin, never followed, and the reason says so.",
    transform: {ChainTest.Mirror.Redirect, %{paths: :batch, mirrors: 2}},
    after:
      Map.merge(no_batch.after, %{
        second_mirror: :untouched,
        log: "redirect to another host refused"
      })
  }),
  # The client gives up on a request after 300 s whatever trickles in; the
  # mirror's cap is set past it (330 s), so only the client's own deadline
  # can end this case before the mirror does.
  Map.merge(no_batch, %{
    id: "N4",
    description:
      "batch.json dripped one byte every 2 seconds: the client gives up at its own deadline and compiles everything.",
    transform: {ChainTest.Mirror.Drip, %{paths: :batch, stream_max_ms: 330_000}}
  }),
  %{
    id: "C1",
    description:
      "The cache holds every file with one byte changed, its size kept: each is fetched again, and only the right bytes are installed and cached.",
    transform: {ChainTest.Mirror.Identity, %{}},
    setup: {ChainTest.Conformance.Setup.Cache, %{plant: :corrupt_files}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{},
    after: %{state_sequence: :snapshot, installed: :snapshot, cache: :verified}
  },
  Map.merge(none_installed.(:fail), %{
    id: "C2-entry",
    description:
      "Each cache entry is a symlink out of the cache, to the right bytes: refused, the links and their targets left alone.",
    transform: {ChainTest.Mirror.Identity, %{}},
    setup: {ChainTest.Conformance.Setup.Cache, %{plant: :link_entries}},
    after: %{state_sequence: :snapshot, installed: :none, cache: :untouched, outside: :untouched}
  }),
  Map.merge(none_installed.(:fail), %{
    id: "C2-dir",
    description:
      "The cache dir itself is a symlink out of the home: refused, nothing written through it.",
    transform: {ChainTest.Mirror.Identity, %{}},
    setup: {ChainTest.Conformance.Setup.Cache, %{plant: :link_dir}},
    after: %{state_sequence: :snapshot, installed: :none, cache: :untouched, outside: :untouched}
  }),
  # R15 with real bytes: the cache holds every file, and the batch does not
  # vouch for them (refused), or does not lead to them (jason's manifest is
  # not served). A build dropped from a signed batch needs a test key:
  # layer 2.
  Map.merge(refused.("batch signature invalid", :not_exercised), %{
    id: "R15-refused",
    description:
      "The cache holds every file of every build, the batch is refused: nothing is installed from the cache.",
    transform: {ChainTest.Mirror.BatchSignatures, %{change: :flip_bit}},
    setup: {ChainTest.Conformance.Setup.Cache, %{plant: :all_files}}
  }),
  %{
    id: "R15-unserved",
    description:
      "The cache holds every file of every build, jason's manifest is not served: jason is not installed from the cache.",
    transform:
      {ChainTest.Mirror.Status,
       %{paths: ["v2/manifests/jason.json", "manifests/jason.json"], status: 404}},
    setup: {ChainTest.Conformance.Setup.Cache, %{plant: :all_files}},
    client: %{default: :snapshot, deps: %{jason: {:miss, "no manifest"}}},
    harness: %{},
    after: %{state_sequence: :snapshot, installed: {:without, ["jason"]}, cache: :untouched}
  },
  # R16 builds twice: first cold from the current batch, then, over that
  # warm _build and with a fresh home, against the batch before it, which
  # names another manifest (or none) for a dep the first build installed.
  %{
    id: "R16",
    description:
      "A warm _build holds a dep installed from a manifest the served batch no longer names: it is removed and compiled.",
    runs: 2,
    transform: {ChainTest.Mirror.OlderBatch, %{batch: :previous, recheck: true}},
    client: %{default: :recheck, deps: %{}},
    harness: %{"build/sequence" => :rerun},
    after: %{state_sequence: :previous, installed: :recheck}
  }
] ++
  (
    # Layer 2: a compromised portal. Each case runs against a copy of the
    # snapshot signed with throwaway keys made for this run
    # (ChainTest.TestKey), the client pinned to a test root through
    # `client_config: %{root: {:test_root, name}}`, never the real one. The
    # control L2-T0 must pass first: without it no refusal below says
    # anything about the client.
    #
    # P7 (a forged entry claiming this target and toolchain but carrying
    # another target's .so) is known, not testable: the client cannot tell,
    # it trusts the signed claim; only the device smoke call catches it
    # (ChainTest.Report.known_gaps/0).
    test_root = %{root: {:test_root, :v1}}
    l2 = fn c -> Map.update(c, :client_config, test_root, &Map.merge(test_root, &1)) end
    l2_refused = fn reason -> l2.(refused.(reason, :not_exercised)) end
    l2_accepted = fn post -> l2.(Map.put(accepted, :after, post)) end
    fresh = %{state_sequence: :snapshot, installed: :snapshot}

    # A forged manifest for jason signed into the test batch: jason is
    # refused (`expect`), nothing of it installed, every other dep a hit.
    forged = fn id, kind, expect, description ->
      class = if match?({:miss, _}, expect), do: :miss, else: :fail

      l2.(%{
        id: id,
        description: description,
        transform: {ChainTest.Mirror.Forge, %{forge: kind}},
        client: %{default: :snapshot, deps: %{jason: expect}},
        harness: %{"build/hit:jason" => class},
        after: %{state_sequence: :snapshot, installed: {:without, ["jason"]}, cache: :verified}
      })
    end

    # A forged manifest the client must never even consider: everything
    # installs as in L2-T0, nothing more.
    # The client must not even ask for the manifests of `names`.
    ignored = fn id, kind, names, description ->
      unrequested = for n <- names, dir <- ["v2/manifests", "manifests"], do: "#{dir}/#{n}.json"

      l2.(
        Map.merge(accepted, %{
          id: id,
          description: description,
          transform: {ChainTest.Mirror.Forge, %{forge: kind}},
          after: Map.put(fresh, :unrequested, unrequested)
        })
      )
    end

    # The client's reason names the entry's path: no other refusal (a 404,
    # a hash, a staging crash) can stand in for it.
    unsafe = &{:fail, "unsafe path or mode (#{inspect(&1)})"}
    # The reasons plan 4's client hardening gives: a file outside the dep's
    # app dir or another app's .app, and colliding paths. Red until it lands.
    foreign = {:fail, "foreign path"}
    collision = {:fail, "path collision"}

    [
      l2_accepted.(fresh)
      |> Map.merge(%{
        id: "L2-T0",
        description:
          "The control: the snapshot's batch signed by the test key, served unchanged to a client pinned to the test root; the same hits as T0.",
        transform: {ChainTest.Mirror.Identity, %{}}
      }),
      Map.merge(l2_refused.("batch signature invalid"), %{
        id: "T2",
        description: "The batch signed by a key the root's batch role does not name: refused.",
        transform: {ChainTest.Mirror.TestBatch, %{signers: [:outside]}}
      }),
      # T3-duplicated's gate: the same root accepts two distinct keys.
      l2_accepted.(fresh)
      |> Map.merge(%{
        id: "T3-pair",
        description:
          "Under the threshold-2 root, the batch signed by both of its batch keys: accepted, so T3-duplicated's refusal is the duplicate's.",
        transform: {ChainTest.Mirror.TestBatch, %{signers: [:pair_a, :pair_b]}},
        client_config: %{root: {:test_root, :threshold_2}}
      }),
      # Threshold counted per key id: one key's signature twice is one.
      Map.merge(l2_refused.("batch signature invalid"), %{
        id: "T3-duplicated",
        description:
          "Under a root whose batch role needs two signatures, the batch carries one key's signature twice: refused.",
        transform: {ChainTest.Mirror.TestBatch, %{signers: [:pair_a, :pair_a]}},
        client_config: %{root: {:test_root, :threshold_2}},
        gate: "T3-pair"
      }),
      # T7's gate: the same request shape with a validly chained v2, so T7's
      # refusal is the broken chain's.
      l2_accepted.(Map.put(fresh, :root_version, 2))
      |> Map.merge(%{
        id: "T7-chained",
        description:
          "The mirror serves a root v2 that v1 signed, and a batch only v2's key signed: v2 is adopted, the batch accepted.",
        transform: {ChainTest.Mirror.TestBatch, %{root: :rotated, signers: [:rotated]}}
      }),
      l2_refused.("batch signature invalid")
      |> Map.merge(%{
        id: "T7",
        gate: "T7-chained",
        description:
          "The mirror serves a root v2 that v1 did not sign, and a batch only v2's key signed: v2 is not adopted, the batch refused.",
        transform: {ChainTest.Mirror.TestBatch, %{root: :unchained, signers: [:unchained]}}
      })
      |> Map.update!(:after, &Map.put(&1, :root_version, :absent)),
      Map.merge(l2_refused.("batch lifetime"), %{
        id: "T8",
        description: "A batch expiring ten years after its issue: refused for its lifetime.",
        transform: {ChainTest.Mirror.TestBatch, %{lifetime: 3650 * 86_400}}
      }),
      Map.merge(l2_refused.("clock: batch issued at"), %{
        id: "R9",
        description: "A batch issued an hour ahead of the client's clock: refused.",
        transform: {ChainTest.Mirror.TestBatch, %{issued_ahead: 3600}}
      }),
      l2_accepted.(fresh)
      |> Map.merge(%{
        id: "R10",
        description:
          "A batch issued five minutes ahead of the client's clock, the tolerance: accepted.",
        transform: {ChainTest.Mirror.TestBatch, %{issued_ahead: 300}}
      }),
      # The lifetime is the client's cap, so only freshness can refuse it.
      Map.merge(l2_refused.("batch stale"), %{
        id: "R11",
        description:
          "A batch that lives 30 days, the client's clock 25 hours past its issue: refused as stale, its expiry does not keep it alive.",
        transform: {ChainTest.Mirror.TestBatch, %{lifetime: 30 * 86_400}},
        client_config: %{clock_offset_seconds: {:age, 25 * 3600}}
      }),
      # The reason R13 cannot give with real 24-hour batches: within the
      # freshness bound, past the expiry.
      Map.merge(l2_refused.("batch expired at"), %{
        id: "T5-expired",
        description:
          "A batch that lives one hour, the client's clock two hours past its issue: fresh, but refused as expired.",
        transform: {ChainTest.Mirror.TestBatch, %{lifetime: 3600}},
        client_config: %{clock_offset_seconds: {:age, 2 * 3600}}
      }),
      l2_accepted.(Map.put(fresh, :root_version, 2))
      |> Map.merge(%{
        id: "R17",
        description:
          "The client adopted root v2 earlier; the mirror serves only v1 and a batch v2's key signed: v2 is kept, the batch accepted.",
        transform: {ChainTest.Mirror.TestBatch, %{signers: [:rotated]}},
        setup: {ChainTest.Conformance.Setup.AdoptedRoot, %{}}
      }),
      # Known gap, pinned: the client cannot learn of a rotation it is not
      # shown, so a fresh home keeps trusting the shipped root's batch key.
      l2_accepted.(Map.put(fresh, :root_version, :absent))
      |> Map.merge(%{
        id: "R18",
        description:
          "Known gap, pinned: a fresh home, the mirror withholds every newer root (root.json a 404) and serves a batch the shipped root's key signed: the shipped root is used and the batch accepted.",
        transform: {ChainTest.Mirror.TestBatch, %{root: :withheld}}
      }),
      forged.(
        "P1-dotdot",
        :dotdot,
        unsafe.("ebin/../../chain_forged.beam"),
        "jason's build names a file at ebin/../..: refused, nothing of jason installed."
      ),
      forged.(
        "P1-absolute",
        :absolute,
        unsafe.("/tmp/chain_forged.beam"),
        "jason's build names a file at an absolute path: refused, nothing of jason installed."
      ),
      forged.(
        "P1-outside",
        :outside_dirs,
        unsafe.("lib/chain_forged.beam"),
        "jason's build names a file outside ebin/ and priv/: refused, nothing of jason installed."
      ),
      forged.(
        "P2-setuid",
        :setuid,
        unsafe.("ebin/jason.app"),
        "jason's .app with a setuid mode: refused, only 644 and 755 are allowed."
      ),
      forged.(
        "P2-0777",
        :mode_777,
        unsafe.("ebin/jason.app"),
        "jason's .app with mode 0777: refused, only 644 and 755 are allowed."
      ),
      forged.(
        "P3-escape",
        :escape_app_dir,
        unsafe.("ebin/../../chain_fixture/ebin/chain_fixture.app"),
        "jason's build names a file in the project's own app dir: refused."
      ),
      forged.(
        "P3-app",
        :project_app,
        foreign,
        "jason's build carries the project's .app name in its ebin, ahead of the project's own on the code path: refused."
      ),
      forged.(
        "P4-checksum",
        :package_checksum,
        {:miss, "package checksum differs from mix.lock"},
        "jason's build claims another package checksum than the lock's: a miss, jason compiled."
      ),
      forged.(
        "P4-deps",
        :deps_lock,
        {:miss, "built against"},
        "jason's build was made against another checksum of a locked dep: a miss, jason compiled."
      ),
      ignored.(
        "P5",
        :path_dep,
        ["chain_path_dep"],
        "The batch names a build for the fixture's path dep chain_path_dep, at its own version and identity: never precompiled, its manifest never even asked for."
      ),
      forged.(
        "P6-name",
        :app_name,
        {:fail, "downloaded .app names"},
        "jason's served .app names another application: refused."
      ),
      forged.(
        "P6-version",
        :app_version,
        {:fail, "downloaded .app names"},
        "jason's served .app names another version: refused."
      ),
      # The laptop's file system folds case and Unicode normalisation: the
      # second entry would overwrite the first.
      forged.(
        "P8-duplicate",
        :duplicate,
        collision,
        "jason's build names one beam path twice, with other bytes: refused."
      ),
      forged.(
        "P8-case",
        :case_variant,
        collision,
        "jason's build names a beam path and its lower-case variant: refused."
      ),
      forged.(
        "P8-unicode",
        :unicode_variant,
        collision,
        "jason's build names one priv path precomposed and decomposed: refused."
      ),
      ignored.(
        "P9",
        :unlocked_package,
        ["chain_absent"],
        "The batch names a build for a package the project does not lock: nothing installed for it, its manifest never asked for."
      )
    ]
    # Last, so a case's own client_config (a clock, the threshold-2 root)
    # keeps the test root.
    |> Enum.map(l2)
  )
