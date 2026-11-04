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
untestable gaps. A conformance summary adds the verdicts counted per layer
and, for each case the snapshot could not back, the attack-vector rows
it stands for and its reason ("Not testable here"). The command exits 1 when any result is a failing class; the heading then
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
| `transform` | `{module, args}`: a `ChainTest.Mirror.Transform` and its args. `ChainTest.Mirror.Identity` serves unchanged; `ChainTest.Mirror.Status` takes `%{paths: ["v2/manifests/jason.json", ...], status: 500}` (a non-empty list of snapshot paths and an HTTP status 100-599; nothing else) and answers that status with an empty body for those paths, or `%{files_of: "jason", status: 404}` for every `files/<sha256>` the snapshot holds of that dep (C0: a trap, below). A transform may define `valid_args?/1`; the case file is refused before any download when it returns false. A transform gets each response's path relative to the snapshot (`"v2/manifests/jason.json"`) and bytes, and returns `{status, bytes}`. |
| `client` | `%{default: expect, deps: %{dep => expect}}`: what `report.json` must say for each expected hit, each dep in `deps` and each dep the snapshot holds a build of, except the deps `nerves` pulls in (Nerves tooling the client leaves to `nerves_bootstrap`; read from the lock and the compiled `nerves.app`) (`deps[dep]`, else `default`). `expect` is `:hit`, `:miss`, `:fail`, `{status, "detail prefix"}`, `:none` (no report line: a client that never ran), or one the snapshot decides per dep: `:snapshot` (a hit when the snapshot holds a build the client could select), `:older_manifest` (M3: `manifest hash differs from batch` for a dep served an older batch's manifest, else `:snapshot`) or `:recheck` (R16, only with `runs: 2`: `manifest hash differs from batch` for a held dep the previous batch names another manifest for, `revoked: no longer in the current batch` for one it names none for, and no report line for every other, a kept install). A dep the last two make anything but a hit has its `build/hit:` row judged by its client line instead. |
| `harness` | `%{"step/check" => class}`: harness results that must have that class. `step` is `build`, `integrity` or `compiled`, `check` as the per-case report prints it (`"build/hit:jason"`, `"integrity/integrity:ash"`, `"compiled/reported_miss:jason"`). Every other result must be `pass` or `miss`; a `rerun` is a difference, since the snapshot never moves. |
| `runs` (optional) | `2`: build twice. The first build is cold, served unchanged by the reference mirror, in a home of its own removed afterwards, and must pass every check; the case's own build then starts from its `_build` (warm), with the case's home, setup and mirror (R16). The cold build's leftovers are not judged again there: the integrity `unreported:` row of each dep a `:recheck` expectation keeps, and step 4's `compiled_here`. |
| `setup` (optional) | `{module, args}`: a `ChainTest.Conformance.Setup` run against the case's fresh client home before the build (write a state file, fill the cache, plant a symlink). It gets the home, the snapshot with the case's `source`, `root` and mirror URLs under `:case`, and its args; `ChainTest.Conformance.Setup.state_dir/3` names the client's state dir. A setup that fails fails the case, unbuilt. `ChainTest.Conformance.Setup.State` writes the batch sequence state (`sequence: :snapshot`, `{:below, n}` or `:corrupt`; `source: :second` for the second mirror's); `ChainTest.Conformance.Setup.PlantRoot` writes an attacker's self-signed root at `path` under the home; `ChainTest.Conformance.Setup.Cache` fills the client's file cache from the snapshot's files (`plant: :all_files`, with `deps: [dep]` only those deps' files (C0), `:corrupt_files` (one byte changed, size kept), `:link_entries` (each entry a symlink to the right bytes under `outside/` in the home) or `:link_dir` (`files` itself a symlink to an empty dir there)). |
| `client_config` (optional) | Merged into the fixture's `config :elixir_precompiled` for this case's build only, after the operator's site config: `clock_offset_seconds` (integer, or `{:age, seconds}`: the client's clock that long after the snapshot batch's `issued`, resolved just before the build, so the case does not depend on the snapshot's age or the run's order), `root` (an absolute path, or `{:test_root, :v1 | :threshold_2}` for a layer-2 case, below), `source` (URL). |
| `proxy` (optional) | `:mirror`: the build's `HTTP_PROXY` is the case mirror (`HTTPS_PROXY` unset), so a plain-http request to any host reaches it; the mirror answers a proxied request 400 and logs it with its URL (N2). Not with a `tls` transform. |
| `client_env` (optional) | Environment variables for this case's build only, from the names a client might wrongly read a root path from (`ChainTest.Build.client_env_names/0`: `ELIXIR_PRECOMPILED_ROOT` and `NERVES_PRECOMPILED_ROOT` only, the names the client's own pattern would give; it reads neither today, and T9 pins that): an absolute path, or `{:home, rel}` for a path under the case home. Every allowed name a case does not give is unset. |
| `after` (optional) | Post-conditions after the build: `state_sequence` (the client's state file for the case's source and root holds an integer, or `:snapshot`, the snapshot batch's sequence, or `:previous`, the previous batch's; `:absent`; or `:unchanged`, every state file in the home as setup left it), `other_states` (`:unchanged`: every state file but that one as setup left it), `installed` (`:none`: no `.mix/elixir_precompiled.json` in the target's `_build`; `:snapshot`: exactly the deps the snapshot holds a build of; `{:without, [dep]}`, `:older_manifest`, `:recheck`: those but the named deps, or the ones the matching `client` expectation fails), `cache` (`:untouched`: every cache entry as setup left it, compared by kind, the sha256 of a file's bytes and a symlink's target, never following one, with nothing gained or removed; `:verified`: every entry a regular file directly in `files/` whose bytes hash to its name, so no changed byte and no symlink stayed; a file setup planted may stay as it left it only when no installed file has its sha256, since the snapshot holds builds the client never selects), `tls` (with a `tls` transform: `{:rejected, alert}`, every connection a handshake the client aborted with that certificate alert and no request through, judged by that log alone, `not_exercised` without a handshake; `:clean`, no handshake failed), `proxied` (with `proxy: :mirror`: `:none`, the mirror logged nothing at all; `:requested`, only proxied requests, at least one; either is judged by that log alone), `outside: :untouched` (what setup planted under `outside/` in the home, the targets of its symlinks, compared the same way; a setup that planted nothing there fails it), `log` (a non-empty string, or a list of them, the build's output must contain: a client warning, say), and, with `mirrors: 2`, `second_mirror` (`:requested`: the client asked the second mirror for something; `:untouched`: it asked nothing), `root_version` (the `root_version` file in that state dir: `:absent`, no root adopted, or the integer it holds), and `unrequested` (a list of snapshot paths the client must never have asked either mirror for: no logged target, decoded, its query dropped, in any case, may end in one's base name). |
| `gate` (optional) | The id of an earlier case of the same layer: this case runs only after that one passed, else it is `not_exercised`. A refusal whose positive control failed says nothing (T7 on T7-chained, T3-duplicated on T3-pair). `--only` brings the gates along. |

A transform answers `{status, bytes}` or, to misbehave in other ways,
`{status, headers, body}`, `{:redirect, 3xx, location}` (or `{:scheme,
"http"}` for the same path on the mirror's own host and port), `{:stream, status,
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
served), `:previous_differs` (R16) or `:older_manifest_bytes` (M3). A case whose snapshot lacks one is `not_testable`, "not
testable here", with the reason; it does not fail the run. That is only
for a batch the portal does not have (a 404, or none old enough within the
probes): one the snapshot could not fetch makes the case `not_exercised`,
and one the portal served but that does not verify makes it a `fail`.

The layer-1 transforms over real signed bytes:
`ChainTest.Mirror.BatchSignatures` (`change: :flip_bit | :remove` on
`batch.json`; a duplicated signature needs a threshold-2 root, layer 2), `ChainTest.Mirror.OlderBatch` (`batch:
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
build the harness selects; N6 runs over TLS (below). A case standing for
several attack-vector rows joins their ids with `.` (`T4.R3`): every case
home is a fresh `ELIXIR_PRECOMPILED_HOME`, so T10 and R6 run as R1 and R2.

### Layer 2: test keys

Layer 2 asks what a compromised portal could do: inputs only a key holder
can make. A case with `client_config: %{root: {:test_root, name}}` runs
against a copy of the snapshot signed with throwaway Ed25519 keys made for
this run (`ChainTest.TestKey`), never the portal's key. The keys stay in
memory; the test roots and the copy go into a private directory under the
system tmp dir, removed after the run. Test roots: `:v1` (one batch key,
threshold 1) and `:threshold_2` (two batch keys, both needed). The copy is
the real batch's payload byte for byte, signed by the test batch key, with
the real manifests and files, and the harness's own trust checks accept it
under the test root before any case runs.

The control `L2-T0` (identity under `:v1`) must show the same hits as T0
before any other layer-2 case is judged: if it does not pass, the client is
not shown to take the test root, and every other layer-2 case is
`not_exercised`. `--only` a layer-2 case runs `L2-T0` too. A real-root case
fails when its home shows a test root (a state dir named for one, a file
naming a test key) or its config names one; a layer-2 case fails when its
home holds the real root's state dir.

The layer-2 transforms and setup sign with the test keys, so a case file
using them without a test root is refused:
`ChainTest.Mirror.TestBatch` (the batch re-signed at request time:
`signers`, the keys that sign it, repeats kept (`:batch`, `:outside`,
`:rotated`, `:unchained`, `:pair_a`, `:pair_b`); `issued_ahead: s`, issued
`s` seconds after the request; `lifetime: s`; `root: :unchained` (a v2 root
v1 did not sign), `:rotated` (the v2 v1 did sign) or `:withheld`
(`root.json` a 404)),
`ChainTest.Mirror.Forge` (`forge: kind`, a forged manifest for jason signed
into the test batch: paths with `..`, absolute or outside `ebin/`/`priv/`, a
setuid or 0777 mode, a file in the project's app dir or the project's
`.app` name, another package checksum or deps lock, a build for the
fixture's own path dep `chain_path_dep` (`fixture/deps_local/chain_path_dep`,
not Nerves tooling; a path dep is never in `mix.lock`, so the client's lock
check stops it before its git/path rule) at its own version and identity, an `.app` naming another app or version, duplicate, case-variant
and Unicode-variant paths, a build for a package the project does not
lock) and `ChainTest.Conformance.Setup.AdoptedRoot` (the state of a client
that already adopted the rotated root v2, R17). R18 pins a known gap: a
fresh home cannot learn of a rotation the mirror withholds. P7, a forged
entry for this target carrying another target's `.so`, is known, not
testable: the client trusts the signed claim, and only the device smoke
call catches it. P5-path's path dep is never in `mix.lock`, so the client's
lock check stops it before its git/path rule (the rule P9 exercises); never
precompiled holds for every path dep. P5 for a git dep is known, not
testable here: the client's own suite covers it with its end-to-end git-dep
test.

A case passes when the client used its mirror and the client and the
harness say what it expects. Using the mirror means the mirror's log has a
`GET batch.json` and, for every dep the report calls a hit, a `GET` of its
manifest that the mirror answered 200 (or whose response the case's own
transform changed); without that, an identity case is `not_exercised` and any other case
fails. Whatever a case expects, a report line calling a dep a hit when the
snapshot holds no build of it fails the case: the client installed something
it was never served. A case whose transform changed nothing the client asked
for is `not_exercised`, unless the transform is a trap
(`ChainTest.Mirror.Transform.trap?/1`, C0's `files_of`): it changes only
what the client must never ask for, so changing nothing is the expected
outcome. A case that crashes is a `fail`; the others still
run. An empty `--only`, or a run that selects no case, is refused.
Each case's own results are in `<target>-<id>-<stamp>.md`; the verdicts in
`<target>-conformance-<stamp>.md`.

### TLS and transport cases

The TLS cases (N3, N6) run the case mirror over HTTPS: a transform's args
`tls: :ip | :self_signed | :wrong_host` give it a certificate of that kind,
made for that case alone with `:public_key` (`ChainTest.TestCert`: P-256
keys, a CA of its own for `:ip` and `:wrong_host`; nothing written to
disk, no `openssl`). Without a CA of its own, the client trusts the OS
store, which knows no test CA. So the N3 cases that test trust
(`N3-self-signed`, `N3-wrong-host`) build with the OS store, and must refuse every handshake;
the mirror logs each one with the alert the client sent, and `after: %{tls:
{:rejected, alert}}` judges the case by that log alone, every handshake
aborted with exactly that alert (`:unknown_ca` for a CA the client does not
know, `:bad_certificate` for a self-signed or wrong-host certificate), so
N3-hostname cannot pass on an unknown CA. `trust_ca: true` needs a kind with
a CA (`:ip`, `:wrong_host`). A case whose args also say
`trust_ca: true` gives the client that CA through its own CA option,
`ELIXIR_PRECOMPILED_CACERTS_PATH` (a bundle that replaces the OS store),
the way a user names a private CA: a PEM in a private temp dir, removed
after the build, and the variable unset for every other build: `TLS-T0`, the control, must then install as
T0 does, and `N3-hostname` (a wrong-host certificate from that trusted
CA, the hostname check alone), `N6` and `N6-manifest` (a redirect from
https to plain http on the same host and port, `ChainTest.Mirror.Downgrade`)
are gated on it. A client that followed the downgrade would send plain http
to the TLS port, which the mirror logs as a failed handshake: `after: %{tls:
:clean}` fails on it.

N2 (an http source outside loopback) builds with the case mirror as its
`HTTP_PROXY` (`proxy: :mirror`) and `source: "http://chain-n2.invalid"`:
the client must be disabled before any fetch, so the mirror logs nothing
(`after: %{proxied: :none}`), no `report.json` is written, the log has the
client's warning, and everything compiles. Its control `N2-proxy` (a
loopback source, `http://localhost:1`, which the client allows) shows that
the route works: its requests reach the mirror as proxied requests.

The client's reasons these cases pin: `batch unavailable: ` followed by
why, for a batch never delivered (a refused handshake, a transport error,
an HTTP error, the deadline; N1-batch pins `batch unavailable: redirect to
another host refused`), while a batch delivered and refused prints its own
reason without that prefix; `redirect to another host refused` and
`source must be https (http only on loopback), disabled`. The cache and
file cases pin `cache refused` (C2), `size mismatch` (F2-truncated),
`file larger than declared size` and `sha256 mismatch`; the forged
manifests `unsafe path or mode (...)`, `foreign path` and `path
collision`. Each is a prefix of the client's reason (a substring for a
log line).

### The production policy check (R20)

    mix chain_conformance --policy [--source URL] [--report-dir DIR]

R20 is a check, not a mirror case, and never part of a case run: it
fetches the portal's current `batch.json` (and `root.json`), read only,
verifies it under the pinned root (`ChainTest.Trust`), and requires
`expires - issued` to be at most 24 hours and `now - issued` at most 15
minutes when the response arrived (and the batch not issued more than 300 s ahead of
this clock). One row, `policy/R20`, in `policy-<stamp>.md`: `pass`,
`fail` (a batch that does not verify, or dates outside the policy), or
`not_exercised` (the batch could not be fetched). It needs no fixture build
and no snapshot.

### Attack vectors

What the cases test, one row per vector; case ids name these rows. Layer
1 uses the portal's real signed bytes, layer 2 a test root and test keys
("Layer 2: test keys").

| Row | Vector | Expected |
| --- | --- | --- |
| T0 | The mirror passes everything through unchanged (control) | the same hits as production, so a refusal below comes from its change, not the mirror path |
| T1 | The batch signature with one bit flipped | refused |
| T2 | The batch signed by a key the root does not name | refused |
| T3 | Signatures removed, or one key's signature duplicated (threshold counted per key id) | refused |
| T4 | Rollback: an older batch after the client saw a higher sequence | refused |
| T5 | An old or expired batch replayed | refused |
| T6 | Root swap: an attacker's `root.json` on the mirror | ignored; the shipped root holds |
| T7 | A root rotation whose newer root the old one did not sign | refused |
| T8 | A batch expiring ten years after its issue | refused: a batch may live at most 30 days |
| T9 | A root path named only by an environment variable | ignored; the shipped root holds |
| T10 | The sequence state reset by pointing `ELIXIR_PRECOMPILED_HOME` at a fresh dir, then an older batch | no rollback beyond the 24-hour freshness bound (as R1, R2) |
| M1 | Manifest bytes that differ from the hash the batch names | refused, nothing installed |
| M2 | One package's manifest served as another's | refused on the hash |
| M3 | A manifest an older batch named, served under the current batch | refused: the current batch does not name its hash |
| M4 | A manifest entry for another target, OTP, Elixir or NIF version | not selected; the build installed is the one the harness selects |
| F1 | A file with one byte changed | refused on the sha256 |
| F2 | A file truncated, larger than declared, or an endless stream | refused within the size cap and deadline |
| N1 | A redirect to another host | refused, never followed |
| N2 | An `http` source outside loopback | the client disabled, no request made |
| N3 | HTTPS with a self-signed or wrong-host certificate | refused |
| N4 | A server dripping one byte at a time | given up at the client's deadline |
| N5 | The portal unreachable or answering 5xx | everything compiles, the build succeeds |
| N6 | A redirect to the same host over `http` | refused, never followed |
| C0 | The right files already in the cache (control) | installed from the cache, not fetched again |
| C1 | A corrupted cached file | fetched again, never installed from the cache |
| C2 | Symlinks in the cache pointing out of it | refused, nothing written through them |
| R0 | The current batch, fresh home (control) | accepted; the state records its sequence |
| R1 | The batch before the current one, fresh home | accepted: within the 24-hour bound |
| R2 | A batch issued over 25 hours ago, unexpired, fresh home | refused as stale |
| R3 | The state holds sequence N, the mirror serves N-1 | refused; the state stays N |
| R4 | A corrupt or unparsable state file | treated as 0 and logged; then as R1 and R2 |
| R5 | The state far below the served sequence | accepted: gaps are allowed |
| R6 | The client home (`ELIXIR_PRECOMPILED_HOME` or `home:`) pointed at a fresh dir | as R1 and R2: freshness still bounds |
| R7 | The client's clock 25 hours past the batch's issue | refused as stale |
| R8 | The client's clock 23 hours past the batch's issue | accepted |
| R9 | A batch issued an hour ahead of the client's clock | refused |
| R10 | A batch issued five minutes ahead of the client's clock | accepted: within the tolerance |
| R11 | A batch that lives 30 days, 25 hours past its issue | refused as stale; its expiry does not keep it alive |
| R12 | The client's clock before the library was built | refused, everything compiles |
| R13 | The client's clock a year ahead | refused as stale (freshness is checked before expiry), everything compiles |
| R14 | A refused batch (any of the above) | the state, `_build` and the cache unchanged |
| R15 | The cache holds a build's files the served batch does not vouch for | not installed from the cache |
| R16 | A warm `_build` holding a dep installed from a manifest the current batch no longer names | removed and compiled |
| R17 | The client adopted root v2; the mirror serves only v1 | v2 kept |
| R18 | A fresh home; the mirror withholds newer roots | the shipped root used: a known gap |
| R19 | Two sources | independent state: an old batch for one does not touch the other's |
| R20 | The production portal's own batches | every batch lives at most 24 hours and is at most 15 minutes old when fetched |
| P1 | A manifest file path with `..`, absolute, or outside `ebin/` and `priv/` | refused |
| P2 | A file mode setuid or 0777 | refused: only 644 and 755 |
| P3 | A file outside the dep's own app dir, or an `.app` named for the project | refused |
| P4 | A build made against another package checksum or deps lock | a miss |
| P5 | A build for a git or path dependency | never precompiled |
| P6 | An `.app` whose name or version differs from the package | refused |
| P7 | A forged entry claiming this target, carrying another target's `.so` | the client cannot tell: only the device smoke call catches it (known, not testable) |
| P8 | Colliding paths: duplicates, case variants, Unicode-normalisation variants | refused |
| P9 | A build for a package the project does not lock | nothing installed for it |

### The cases

Every case in `conformance/cases.exs`, with the attack-vector rows it
stands for (below) and its layer (1: real root; 2: test keys). "after X"
is its gate. P7, P5 for a git dep and the other "known, not testable" items are in every report's
"Known, not testable" section instead.

- R14 (a refused batch leaves the state, `_build` and the cache alone) is
  not a case of its own: it is every refusal's after-condition
  (`state_sequence: :unchanged, installed: :none, cache: :untouched`).
- C1's cached-manifest half does not apply: the client caches files only,
  never manifests, so C1 corrupts cached files.
- R6's `home:` config route is folded into the `ELIXIR_PRECOMPILED_HOME`
  cases (`R1.R6.T10`, `R2.R6.T10`): both name the client home, and every
  case home is a fresh one.
- M3 never runs against production: the portal serves only the current
  batch's manifests, so the snapshot never holds an older one's bytes and
  M3 is "not testable here".

| Case | Rows | Layer | What it shows |
| --- | --- | --- | --- |
| `T0` | T0, M4 | 1 | The mirror serves the snapshot unchanged: the client installs every build the snapshot holds. |
| `R8` | R8 | 1 | Freeze: the client's clock is 23 hours past the current batch's issue; still fresh, it is accepted. |
| `N5-manifest-500` | N5 | 1 | The mirror answers 500 for jason's manifest: the client compiles jason and says why. |
| `R0` | R0 | 1 | The current batch on a fresh home: accepted, and the state records its sequence. |
| `T1` | T1 | 1 | One bit of the batch signature flipped: the batch is refused. |
| `T3-removed` | T3 | 1 | The batch served with its signatures removed: refused. |
| `T4.R3` | T4, R3 | 1 | Rollback: the client's state holds the current sequence, the mirror serves the batch before it; refused, the state stays. |
| `T5` | T5 | 1 | Replay: a client that saw the current batch is served one issued over 25 hours earlier; refused as stale. |
| `T6` | T6 | 1 | The mirror serves an attacker's newer root.json: the client keeps its shipped root and installs as in T0. |
| `T9` | T9 | 1 | Pins today's behaviour: only environment variables name a root path, an attacker's, and the client, which reads none, installs as in T0. |
| `R1.R6.T10` | R1, R6, T10 | 1 | A fresh home is served the batch before the current one: accepted, within the 24-hour bound. |
| `R2.R6.T10` | R2, R6, T10 | 1 | A fresh home is served a batch issued over 25 hours ago: refused as stale, state or not. Real 24-hour batches that old are also expired; the pinned batch stale prefix proves the freshness bound is what refused. |
| `R4-previous` | R4 | 1 | A corrupt state file counts as 0: the batch before the current one is accepted and replaces it. |
| `R4-old` | R4 | 1 | A corrupt state file counts as 0, yet a batch issued over 25 hours ago is still refused as stale. Freshness is checked before the state is read, so the corrupt file is never read and nothing is logged; R4-previous checks the log. |
| `R5` | R5 | 1 | The state holds a sequence 40 below the current batch: gaps are allowed, it is accepted. (after T4.R3) |
| `R7` | R7 | 1 | Freeze: the client's clock is 25 hours past the current batch's issue; refused as stale. |
| `R12` | R12 | 1 | The client's clock is 30 days before the library was built: refused, and everything compiles. |
| `R13` | R13 | 1 | The client's clock is a year past the batch's issue: refused as stale, and everything compiles. |
| `R19` | R19 | 1 | Two sources: one's state holds the current sequence, the other is served the batch before it; accepted there, the first source's state untouched. (after T4.R3) |
| `M1` | M1 | 1 | One byte of every manifest changed: each fails the hash the batch names, and nothing is installed. |
| `M2` | M2 | 1 | Each dep's manifest is another dep's real one: refused on the hash, nothing installed. |
| `M3` | M3 | 1 | A real manifest an older batch names, and the current one does not, served under the current batch: refused on the hash. |
| `F1` | F1 | 1 | One byte of every file changed, its size kept: refused on the sha256, nothing installed or cached. |
| `F2-truncated` | F2 | 1 | Every file cut one byte short of the length it declares: refused, nothing installed or cached. |
| `F2-larger` | F2 | 1 | Every file one byte larger than the manifest's size: refused at the size cap, nothing installed or cached. |
| `F2-endless` | F2 | 1 | Every file an endless stream without a length: refused at the size cap, nothing installed or cached. |
| `N1` | N1 | 1 | Every file redirected to another origin, a second mirror with the right bytes: refused as cross-origin, never followed. |
| `N1-manifest` | N1 | 1 | Every manifest redirected to another origin: refused as cross-origin, never followed, nothing installed. |
| `N1-batch` | N1 | 1 | batch.json redirected to another origin: refused as cross-origin, never followed, and the reason says so. |
| `N4` | N4 | 1 | batch.json dripped one byte every 2 seconds: the client gives up at its own deadline and compiles everything. |
| `N5-batch` | N5 | 1 | The mirror answers 503 for batch.json: no batch, nothing installed, everything compiles. |
| `C0` | C0 | 1 | The control: the cache holds jason's files, the mirror answers 404 for them; jason is installed from the cache. |
| `C1` | C1 | 1 | The cache holds every file with one byte changed, its size kept: each is fetched again, and only the right bytes are installed and cached. (after C0) |
| `C2-entry` | C2 | 1 | Each cache entry is a symlink out of the cache, to the right bytes: refused, the links and their targets left alone. |
| `C2-dir` | C2 | 1 | The cache dir itself is a symlink out of the home: refused, nothing written through it. |
| `R15-refused` | R15 | 1 | The cache holds every file of every build, the batch is refused: nothing is installed from the cache. (after C0) |
| `R15-unserved` | R15 | 1 | The cache holds every file of every build, jason's manifest is not served: jason is not installed from the cache. (after C0) |
| `R16` | R16 | 1 | A warm _build holds a dep installed from a manifest the served batch no longer names: it is removed and compiled. |
| `N2-proxy` | N2 | 1 | The control: a loopback http source, fetched through the case mirror as HTTP proxy, which logs each request and answers 400. |
| `N2` | N2 | 1 | An http source outside loopback: the client is disabled before any fetch, no request leaves the build, and everything compiles. (after N2-proxy) |
| `TLS-T0` | T0 | 1 | The control: the snapshot over HTTPS, its test CA the build's only trusted one; the same hits as T0. |
| `N3-self-signed` | N3 | 1 | HTTPS with a self-signed certificate for 127.0.0.1: every handshake refused, nothing fetched, everything compiles. |
| `N3-wrong-host` | N3 | 1 | HTTPS with a certificate for another host, from a CA the client does not know: every handshake refused. |
| `N3-hostname` | N3 | 1 | HTTPS with a certificate for another host from the CA the build trusts (TLS-T0's): refused on the hostname alone. (after TLS-T0) |
| `N6` | N6 | 1 | Every file redirected from https to http on the same host and port: refused as another origin, never followed. (after TLS-T0) |
| `N6-manifest` | N6 | 1 | Every manifest redirected from https to http on the same host and port: refused, never followed, nothing installed. (after TLS-T0) |
| `L2-T0` | T0 | 2 | The control: the snapshot's batch signed by the test key, served unchanged to a client pinned to the test root; the same hits as T0. |
| `T2` | T2 | 2 | The batch signed by a key the root's batch role does not name: refused. |
| `T3-pair` | T3 | 2 | Under the threshold-2 root, the batch signed by both of its batch keys: accepted, so T3-duplicated's refusal is the duplicate's. |
| `T3-duplicated` | T3 | 2 | Under a root whose batch role needs two signatures, the batch carries one key's signature twice: refused. (after T3-pair) |
| `T7-chained` | T7 | 2 | The mirror serves a root v2 that v1 signed, and a batch only v2's key signed: v2 is adopted, the batch accepted. |
| `T7` | T7 | 2 | The mirror serves a root v2 that v1 did not sign, and a batch only v2's key signed: v2 is not adopted, the batch refused. (after T7-chained) |
| `T8` | T8 | 2 | A batch expiring ten years after its issue: refused for its lifetime. |
| `R9` | R9 | 2 | A batch issued an hour ahead of the client's clock: refused. |
| `R10` | R10 | 2 | A batch issued five minutes ahead of the client's clock, the tolerance: accepted. |
| `R11` | R11 | 2 | A batch that lives 30 days, the client's clock 25 hours past its issue: refused as stale, its expiry does not keep it alive. |
| `T5-expired` | T5 | 2 | A batch that lives one hour, the client's clock two hours past its issue: fresh, but refused as expired. |
| `R17` | R17 | 2 | The client adopted root v2 earlier; the mirror serves only v1 and a batch v2's key signed: v2 is kept, the batch accepted. |
| `R18` | R18 | 2 | Known gap, pinned: a fresh home, the mirror withholds every newer root (root.json a 404) and serves a batch the shipped root's key signed: the shipped root is used and the batch accepted. |
| `P1-dotdot` | P1 | 2 | jason's build names a file at ebin/../..: refused, nothing of jason installed. |
| `P1-absolute` | P1 | 2 | jason's build names a file at an absolute path: refused, nothing of jason installed. |
| `P1-outside` | P1 | 2 | jason's build names a file outside ebin/ and priv/: refused, nothing of jason installed. |
| `P2-setuid` | P2 | 2 | jason's .app with a setuid mode: refused, only 644 and 755 are allowed. |
| `P2-0777` | P2 | 2 | jason's .app with mode 0777: refused, only 644 and 755 are allowed. |
| `P3-escape` | P3 | 2 | jason's build names a file in the project's own app dir: refused. |
| `P3-app` | P3 | 2 | jason's build carries the project's .app name in its ebin, ahead of the project's own on the code path: refused. |
| `P4-checksum` | P4 | 2 | jason's build claims another package checksum than the lock's: a miss, jason compiled. |
| `P4-deps` | P4 | 2 | jason's build was made against another checksum of a locked dep: a miss, jason compiled. |
| `P5-path` | P5 | 2 | The batch names a build for the fixture's path dep chain_path_dep, at its own version and identity: never precompiled, its manifest never even asked for. A path dep is never in mix.lock, so the client's lock check stops it before its git/path rule (as for P9); never precompiled holds for every path dep. |
| `P6-name` | P6 | 2 | jason's served .app names another application: refused. |
| `P6-version` | P6 | 2 | jason's served .app names another version: refused. |
| `P8-duplicate` | P8 | 2 | jason's build names one beam path twice, with other bytes: refused. |
| `P8-case` | P8 | 2 | jason's build names a beam path and its lower-case variant: refused. |
| `P8-unicode` | P8 | 2 | jason's build names one priv path precomposed and decomposed: refused. |
| `P9` | P9 | 2 | The batch names a build for a package the project does not lock: nothing installed for it, its manifest never asked for. |

To add a case: pick the attack-vector row's id (or `<id>-<variant>`, or
ids joined with `.` when one case stands for several rows); add a map to
`conformance/cases.exs` with the row's expected outcome as `client`,
`harness` and `after`, starting from the helpers at the top of the file
(`refused`, `none_installed`, `no_batch`, `accepted`); reuse a transform
or setup, or write one implementing `ChainTest.Mirror.Transform` /
`ChainTest.Conformance.Setup` with `valid_args?/1` (and `needs/1` when it
needs an older batch); give a refusal whose meaning depends on a working
path a `gate` on its positive control; add the case to this table (and a row to the attack-vector table for a
new vector) and a test under `test/chain_test/conformance/`; run `mix test`, then `mix
chain_conformance --only <id>`. A case that cannot run on this machine is
not faked: its transform's `needs/1` makes it `not_testable`, or it goes
in `ChainTest.Report.known_gaps/0`.
