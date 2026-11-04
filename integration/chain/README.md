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

A run whose report is all `pass`, `miss` and `rerun` exits 0. The report's
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
kept in a directory under the system tmp dir and removed after the run
(`--snapshot-dir DIR` keeps it there). A snapshot is good for 24 hours, the
client's batch freshness bound, so every run takes a new one.
That download is the only time a run contacts the portal.

Each case gets a mirror over the snapshot that changes its responses as the
case says, a fresh client home, a clean `_build` and `mix compile` of the
fixture for the target. Steps 3 and 4 then check what the client installed
against the unchanged snapshot.

Cases are data, in `conformance/cases.exs`, one map per case:

| Key | Meaning |
| --- | --- |
| `id` | Unique; a letter or digit, then letters, digits, `.` or `-`. |
| `description` | One plain sentence. |
| `transform` | `{module, args}`: a `ChainTest.Mirror.Transform` and its args. `ChainTest.Mirror.Identity` serves unchanged; `ChainTest.Mirror.Status` takes `%{paths: ["v2/manifests/jason.json", ...], status: 500}` (a non-empty list of snapshot paths and an HTTP status 100-599; nothing else) and answers that status with an empty body for those paths. A transform may define `valid_args?/1`; the case file is refused before any download when it returns false. A transform gets each response's path relative to the snapshot (`"v2/manifests/jason.json"`) and bytes, and returns `{status, bytes}`. |
| `client` | `%{default: expect, deps: %{dep => expect}}`: what `report.json` must say for each expected hit and each dep in `deps`. `expect` is `:hit`, `:miss`, `:fail`, `{status, "detail prefix"}`, or `:snapshot` (a hit when the snapshot holds a build the client could select). |
| `harness` | `%{"step/check" => class}`: harness results that must have that class. `step` is `build`, `integrity` or `compiled`, `check` as the per-case report prints it (`"build/hit:jason"`, `"integrity/integrity:ash"`, `"compiled/reported_miss:jason"`). Every other result must be `pass` or `miss`; a `rerun` is a difference, since the snapshot never moves. |

A case passes when the client used its mirror and the client and the
harness say what it expects. Using the mirror means the mirror's log has a
`GET batch.json` and a `GET` of the manifest of every dep the report calls a
hit; without that, an identity case is `not_exercised` and any other case
fails. Whatever a case expects, a report line calling a dep a hit when the
snapshot holds no build of it fails the case: the client installed something
it was never served. A case whose transform changed nothing the client asked
for is `not_exercised`. A case that crashes is a `fail`; the others still
run. An empty `--only`, or a run that selects no case, is refused.
Each case's own results are in `<target>-<id>-<stamp>.md`; the verdicts in
`<target>-conformance-<stamp>.md`.
