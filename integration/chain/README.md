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
it. `trust/client_verdict`: a batch the harness rejects that the client
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
| `miss` | A dependency compiled because no precompiled build was found, or the served root differs from the pinned one. Reported, not an error. | 0 |
| `rerun` | Production moved during the run: the client used a newer batch the harness could not fetch or verify (its `trust/client_batch:*` rows say why), or a manifest moved. Integrity results that only reflect that batch mismatch are reruns too. Run again. | 0 |
| `fail` | Checked and wrong. | 1 |
| `refused` | The client refused where it should have installed; the detail is the client's reason. | 1 |
| `disagreement` | The client's account and the harness's own check differ: a hit whose files do not match its manifest, a device file that differs from the release image, a verdict on the batch that differs. | 1 |
| `not_exercised` | The check could not run, so it proves nothing (an earlier step failed). | 1 |

A run whose report is all `pass`, `miss` and `rerun` exits 0. The report's
heading is `PASS` only without a `rerun`; with one it is `RERUN`, and the run
should be repeated before it counts. When step 1 could not verify any batch
either, the client batch's failed checks stay failures.
