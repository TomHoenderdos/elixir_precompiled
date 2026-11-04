# Chain test

A manual end-to-end test of the signed precompiled chain: from the portal's
signed batch, through the client's install into a real Nerves firmware
build, onto a device and running there. It is a separate Mix project; the
library's own test suite does not run it.

**It rewrites the device's firmware.** Step 5 uploads the fixture firmware
(`fixture/`) over ssh and the device reboots into it. Use a device you can
spare for this, and keep the fixture's `nerves_ssh` keys in the operator
file (below) so the next run can deploy again.

## What it proves

Each step checks for itself what it can, and never takes the client's own
report as the verdict:

| Step | What is checked |
| --- | --- |
| 0 `preflight` | The device answers over ssh with the pinned host key, the portal answers, `nerves_bootstrap` and `fwup` are installed, the fixture's lock names every expected dependency, the operator file exists. Fails within seconds, before any build. |
| 1 `trust` | The harness's own verification of the root and the current batch: the pinned root equals the library's, Ed25519 signatures and threshold, format, expiry, freshness and lifetime. No client code. |
| 2 `build` | A real `mix firmware` of the fixture with a fresh client home: every expected dependency is a hit (or a reported miss or refusal), the ones that must never be precompiled are not, and the batch sequence the client used is one the harness verified itself. |
| 3 `integrity` | Every file the client installed in `_build` has the sha256 its manifest names, and the manifest's bytes hash to what the verified batch names. |
| 4 `compiled` | Judged from `_build`: only misses, the fixture itself and Nerves tooling were compiled here. |
| 5 `deploy` | The image's `meta-uuid` and platform, the upload (`ssh -s <device> fwup`), a real reboot, and the device's active firmware UUID afterwards equal to the image's. |
| 6 `device` | `ChainFixture.Probe` on the device: every app starts, every module loads, one smoke call per NIF, every file under `ebin/` and `priv/` equal to the locally built release image, the firmware UUID and the Nerves system. |

Two checks span steps. `build/sequence`: batches come every 15 to 30
minutes and a build takes minutes, so the client often used a newer batch
than step 1 saw; the harness then fetches `batches/<sequence>.json` and
verifies it the same way (`trust/client_batch:*`) and checks step 3 against
it; a client batch it fetches and rejects fails the run. Step 3 also checks
every dependency `_build` shows the client installed, and one the client's
report does not call a hit is a disagreement. `trust/client_verdict`: a batch the harness rejects that the client
installed from, or one it verified that the client refused, is a
disagreement.

Files on the device are compared with the release image, not the manifest:
a Nerves release strips beams, rewrites `.app` files and strips `.so` files.
Step 3 ties `_build` to the manifest, step 6 ties the device to the release.

What the test cannot show is listed in every report under "Known, not
testable".

## Setup

You need Elixir 1.20.3 / OTP 29 (the repository's `.tool-versions`), the
`nerves_bootstrap` archive (`mix archive.install hex nerves_bootstrap`),
`fwup`, `ssh` and `perl` on `PATH`, and a device running a firmware with
`nerves_ssh` that accepts your key (the fixture's own firmware, once flashed
by hand, is one).

Two operator files live outside the repository and are never committed:

- `~/.config/chain_test/known_hosts`: the device's pinned ssh host key, in
  `known_hosts` format. Check the key out of band before you add it. The
  harness runs ssh with `StrictHostKeyChecking=yes` and this file only, and
  never accepts a new or changed key: a re-flashed card fails preflight
  with "host key changed" until you update the file yourself.
- `~/.config/chain_test/target.exs`: the fixture's network and
  `nerves_ssh` authorized keys, an ordinary config file the fixture's
  `config/target.exs` imports. See `fixture/README.md` for what it sets.

Other paths can be passed with `--known-hosts` and `--target-config`.

## Running

From `integration/chain/`:

    mix deps.get
    (cd fixture && mix deps.get)
    mix chain_test --target rpi4 --device <device>

| Option | Default |
| --- | --- |
| `--target` | required: `rpi4` or `rpi0_2` |
| `--device` | required: the device's ssh host name or address |
| `--known-hosts` | `~/.config/chain_test/known_hosts` |
| `--target-config` | `~/.config/chain_test/target.exs` |
| `--source` | `https://compatibility.nerves-project.org/api/precompiled` |
| `--report-dir` | a fresh `<tmp>/chain_test-<UTC timestamp>` |

A run takes as long as a clean firmware build of the fixture plus about ten
minutes for the upload, the reboot and the probe. Each result is printed as
it is known; the last line names the report.

`mix test` runs the harness's own unit tests, with fake `ssh`, `fwup` and
`mix` executables and locally signed fixtures; it never contacts a device
or the portal.

## Reading the report

The report directory holds `<target>-<timestamp>.md` and `.json` with the
same content: the run's meta (both batch sequences, the root version, the
client and nerves commits, Elixir, OTP, the Nerves system), one row per
check with its class, time and detail, the time per step, and the known,
untestable gaps. The command exits 1 when any result is a failing class; the heading then
says `FAIL`.

| Class | Meaning | Exit |
| --- | --- | --- |
| `pass` | Checked and as expected. | 0 |
| `miss` | A dependency compiled because no precompiled build was found, or the served root differs from the pinned one. Reported, not an error; the heading counts missed hits, e.g. `PASS (2 miss)`. A miss because the manifest was unavailable or malformed is a `fail`. | 0 |
| `rerun` | Production moved during the run: the client used a batch the harness could not fetch (`batches/<n>.json` unavailable: an HTTP error, a transport error, a timeout; its `trust/client_batch:*` rows say why), or a manifest moved under a newer verified batch. Integrity results that only reflect that batch mismatch are reruns too. A client batch the harness fetched and rejects is a `fail`, never a rerun. Run again. | 0 |
| `fail` | Checked and wrong. | 1 |
| `refused` | The client refused where it should have installed; the detail is the client's reason. | 1 |
| `disagreement` | The client's account and the harness's own check differ: a hit whose files do not match its manifest, a device file that differs from the release image, a verdict on the batch that differs. | 1 |
| `not_exercised` | The check could not run, so it proves nothing (an earlier step failed). | 1 |
| `not_testable` | Conformance only: a case the snapshot cannot back, decided from snapshot facts alone before anything ran (an older batch the portal no longer keeps, a root with batch threshold 1). Listed in the report's "Not testable here" section; the heading counts them, e.g. `PASS (1 not testable here)`. | 0 |

A run whose report is all `pass`, `miss`, `rerun` and `not_testable` exits 0. The report's
heading is `PASS` only without a `rerun`; with one it is `RERUN`, and the run
should be repeated before it counts. When step 1 could not verify any batch
either, the client batch's failed checks stay failures.

## Conformance

`mix chain_conformance` runs the client against a mirror of the portal on
127.0.0.1, one case at a time, and needs no device:

    mix chain_conformance [--target rpi4] [--only T0] [--cases PATH]

It takes a fresh snapshot of the portal first (`mix chain_snapshot` does
only that): the root, the current batch, the fixture's manifests and the
files of the builds the client could select, verified by the harness and
kept in a directory under the system tmp dir and removed after the run.
`--snapshot-dir DIR` keeps it there, and a later run given the same
`--snapshot-dir` loads it instead of downloading again: re-verified (batch
signature, every manifest and file hash) and refused when it is older than
24 hours, the client's batch freshness bound, or was taken from another
source, for another target or of another fixture lock. Without
`--snapshot-dir`, every run takes a new one.
That download is the only time a run contacts the portal.

Each case gets a mirror over the snapshot that changes its responses as the
case says, a fresh client home, a clean `_build` and `mix compile` of the
fixture for the target. Steps 3 and 4 then check what the client installed
against the unchanged snapshot.

The snapshot also keeps two older batches, verified like the current one
except for their age: `previous` (`N-1`) and `old` (the newest batch issued
more than 25 hours before `N`), with the fixture deps each names another
manifest for than `N` does (only their hashes: the portal serves the current
batch's manifests only). The portal may not have them; a case that needs one
it lacks is `not_testable`, "not testable here", with the reason, and is not
run.

Cases are data, in `conformance/cases.exs`, one map per case:

| Key | Meaning |
| --- | --- |
| `id` | Unique; a letter or digit, then letters, digits, `.` or `-`. |
| `description` | One plain sentence. |
| `transform` | `{module, args}`: a `ChainTest.Mirror.Transform` and its args. `ChainTest.Mirror.Identity` serves unchanged; `ChainTest.Mirror.Status` takes `%{paths: ["v2/manifests/jason.json", ...], status: 500}` (a non-empty list of snapshot paths and an HTTP status 100-599; nothing else) and answers that status with an empty body for those paths. A transform may define `valid_args?/1`; the case file is refused before any download when it returns false. A transform gets each response's path relative to the snapshot (`"v2/manifests/jason.json"`) and bytes, and returns `{status, bytes}`. |
| `client` | `%{default: expect, deps: %{dep => expect}}`: what `report.json` must say for each expected hit, each dep in `deps` and each dep the snapshot holds a build of, except the deps `nerves` pulls in (Nerves tooling the client leaves to `nerves_bootstrap`; read from the lock and the compiled `nerves.app`) (`deps[dep]`, else `default`). `expect` is `:hit`, `:miss`, `:fail`, `{status, "detail prefix"}`, or one the snapshot decides per dep: `:snapshot` (a hit when the snapshot holds a build the client could select), `:older_manifest` (M3: `manifest hash differs from batch` for a dep served an older batch's manifest, else `:snapshot`) or `:recheck` (R16, only with `runs: 2`: `manifest hash differs from batch` for a held dep the previous batch names another manifest for, `revoked: no longer in the current batch` for one it names none for, and no report line for every other, a kept install). A dep the last two make anything but a hit has its `build/hit:` row judged by its client line instead. |
| `harness` | `%{"step/check" => class}`: harness results that must have that class. `step` is `build`, `integrity` or `compiled`, `check` as the per-case report prints it (`"build/hit:jason"`, `"integrity/integrity:ash"`, `"compiled/reported_miss:jason"`). Every other result must be `pass` or `miss`; a `rerun` is a difference, since the snapshot never moves. |
| `runs` (optional) | `2`: build twice. The first build is cold, served unchanged by the reference mirror, in a home of its own removed afterwards, and must pass every check; the case's own build then starts from its `_build` (warm), with the case's home, setup and mirror (R16). The cold build's leftovers are not judged again there: the integrity `unreported:` row of each dep a `:recheck` expectation keeps, and step 4's `compiled_here`. |
| `setup` (optional) | `{module, args}`: a `ChainTest.Conformance.Setup` run against the case's fresh client home before the build (write a state file, fill the cache, plant a symlink). It gets the home, the snapshot with the case's `source`, `root` and mirror URLs under `:case`, and its args; `ChainTest.Conformance.Setup.state_dir/3` names the client's state dir. A setup that fails fails the case, unbuilt. `ChainTest.Conformance.Setup.State` writes the batch sequence state (`sequence: :snapshot`, `{:below, n}` or `:corrupt`; `source: :second` for the second mirror's); `ChainTest.Conformance.Setup.PlantRoot` writes an attacker's self-signed root at `path` under the home; `ChainTest.Conformance.Setup.Cache` fills the client's file cache from the snapshot's files (`plant: :all_files`, `:corrupt_files` (one byte changed, size kept), `:link_entries` (each entry a symlink to the right bytes under `outside/` in the home) or `:link_dir` (`files` itself a symlink to an empty dir there)). |
| `client_config` (optional) | Merged into the fixture's `config :elixir_precompiled` for this case's build only, after the operator's site config: `clock_offset_seconds` (integer, or `{:age, seconds}`: the client's clock that long after the snapshot batch's `issued`, resolved just before the build, so the case does not depend on the snapshot's age or the run's order), `root` (an absolute path), `source` (URL). |
| `client_env` (optional) | Environment variables for this case's build only, from the names a client might wrongly read a root path from (`ChainTest.Build.client_env_names/0`: `ELIXIR_PRECOMPILED_ROOT` and `NERVES_PRECOMPILED_ROOT` only, the names the client's own pattern would give; it reads neither today, and T9 pins that): an absolute path, or `{:home, rel}` for a path under the case home. Every allowed name a case does not give is unset. |
| `after` (optional) | Post-conditions after the build: `state_sequence` (the client's state file for the case's source and root holds an integer, or `:snapshot`, the snapshot batch's sequence, or `:previous`, the previous batch's; `:absent`; or `:unchanged`, every state file in the home as setup left it), `other_states` (`:unchanged`: every state file but that one as setup left it), `installed` (`:none`: no `.mix/elixir_precompiled.json` in the target's `_build`; `:snapshot`: exactly the deps the snapshot holds a build of; `{:without, [dep]}`, `:older_manifest`, `:recheck`: those but the named deps, or the ones the matching `client` expectation fails), `cache` (`:untouched`: every cache entry as setup left it, compared by kind, the sha256 of a file's bytes and a symlink's target, never following one, with nothing gained or removed; `:verified`: every entry a regular file directly in `files/` whose bytes hash to its name, so no changed byte and no symlink stayed; a file setup planted may stay as it left it only when no installed file has its sha256, since the snapshot holds builds the client never selects), `outside: :untouched` (what setup planted under `outside/` in the home, the targets of its symlinks, compared the same way; a setup that planted nothing there fails it), `log` (a non-empty string, or a list of them, the build's output must contain: a client warning, say), and, with `mirrors: 2`, `second_mirror` (`:requested`: the client asked the second mirror for something; `:untouched`: it asked nothing). |

A transform answers `{status, bytes}` or, to misbehave in other ways,
`{status, headers, body}`, `{:redirect, 3xx, location}`, `{:stream, status,
chunks, delay_ms}` (no `content-length`, a delay before each chunk),
`{:truncate, status, body, n}` (declares the whole body, sends `n` bytes),
`:close` (no response at all) or `{:endless, status, chunk, delay_ms}` (until
the client hangs up). A streamed body stops at 64 MiB or 120 s, so a case
cannot hang the run; a transform's args may move the time cap with
`stream_max_ms` (1 to 600000), for a drip that must outlast the client's
own deadline. Anything but `{200, bytes}` with the snapshot's own
bytes counts as a change for the "not exercised" check. A transform that crashes or answers a malformed shape gets the client a 500 and fails the case, naming the error, so a typo never stands in for the change it meant. Both mirrors of a two-mirror case are judged this way. A transform whose
args say `mirrors: 2` gets a second mirror (a cross-origin redirect target,
say), whose URL it finds under the args' `:case` key; `needs/1` on a
transform or setup names what it needs of the snapshot: an older batch
(`:previous`, `:old`), `:previous_manifests` (the previous batch names the
current batch's manifest for every held dep, since only those bytes can be
served) or `:batch_threshold_2` (a root whose batch role needs two
signatures). A case whose snapshot lacks one is `not_testable`, "not
testable here", with the reason; it does not fail the run. That is only
for a batch the portal does not have (a 404, or none old enough within the
probes): one the snapshot could not fetch makes the case `not_exercised`,
and one the portal served but that does not verify makes it a `fail`.

The layer-1 transforms over real signed bytes:
`ChainTest.Mirror.BatchSignatures` (`change: :flip_bit | :remove |
:duplicate` on `batch.json`), `ChainTest.Mirror.OlderBatch` (`batch:
:previous | :old` served as `batch.json`; `hits: true` when the case
installs from it; `recheck: true` for R16, which also needs a previous
batch naming another manifest, or none, for a held dep) and
`ChainTest.Mirror.RootSwap` (an attacker's newer, self-signed `root.json`);
`ChainTest.Mirror.ManifestBytes` (`change: :flip_byte | :swap`, every
manifest one byte changed or served as another dep's), `ChainTest.Mirror.OlderManifest`
(an older batch's real manifest served under `N`, M3: it needs those bytes,
which the portal does not serve, so it is not testable here today),
`ChainTest.Mirror.FileBytes` (`change: :flip_byte | :truncate | :larger |
:endless` on every file), `ChainTest.Mirror.Redirect` (`paths: :batch |
:manifests | :files`, `mirrors: 2`: a 302 to the second mirror, another
origin) and `ChainTest.Mirror.Drip` (`paths: :batch | :files`, one byte
every 2 s, with `stream_max_ms`). M4 has no case of its own: with real bytes
entry selection is T0's, whose integrity step checks each hit installed the
build the harness selects; N6 needs TLS. A case standing for several spec rows joins
their ids with `.` (`T4.R3`): every case home is a fresh
`ELIXIR_PRECOMPILED_HOME`, so T10 and R6 run as R1 and R2.

A case passes when the client used its mirror and the client and the
harness say what it expects. Using the mirror means the mirror's log has a
`GET batch.json` and, for every dep the report calls a hit, a `GET` of its
manifest that the mirror answered 200 (or whose response the case's own
transform changed); without that, an identity case is `not_exercised` and any other case
fails. Whatever a case expects, a report line calling a dep a hit when the
snapshot holds no build of it fails the case: the client installed something
it was never served. A case whose transform changed nothing the client asked
for is `not_exercised`. A case that crashes is a `fail`; the others still
run. An empty `--only`, or a run that selects no case, is refused.
Each case's own results are in `<target>-<id>-<stamp>.md`; the verdicts in
`<target>-conformance-<stamp>.md`.
