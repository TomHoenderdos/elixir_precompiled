# Known limitations

What `precompiled` does not do yet, or does not protect against. Each
item says what happens and what to do about it. Apart from the two items
under Matching, and the clean-compile assumption behind the compile
order prediction (an incremental compile, or an app installed
precompiled, can differ from it; see
[Matching](matching.md)), none of them can make Mix (or a device) use a
wrong build: the worst case is a dependency that compiles anyway.

## Matching

**Your build environment is recorded only in part.** Builds record the
environment variables a dependency's compile read and compare them with
yours, but not your `PATH`, compilers or other tools. A dependency whose
compile-time output depends on them (a Makefile or `c_src`) can be served
a build made without your values. Variables set in your shell and a
global `Mix.install(deps, system_env: ...)` count the same. For a build
without `compile_inputs`, rule 8 refuses only the case it can see: an env
read at module level in `lib/`.
*Fix:* list such a dependency in `:except`.

**A device does not scan sources.** On a device, a beam-only build made on
another release of the device's Nerves system is accepted without the
source scan the build machine runs, so a dependency that reads the Nerves
system at compile time (`Nerves.Env`) is not detected there. Its beams may
carry the other release's version or settings.
*Fix:* ship such a dependency in the firmware instead of installing it on
the device.

**A Kino.JS writer misses wherever kino compiles from source.** A
dependency that packs Kino.JS assets into kino's priv (see
[Foreign priv builds](matching.md#foreign-priv-builds-kino-js-writers))
installs only into a kino that is installed precompiled or already
compiled by Mix; when kino compiles in the same run, the writer compiles
too.
*Status:* measured first; a later release may place archives after Mix
compiles kino.

**A relocated build is proven at three roots, not at yours.** The portal
builds such a package at three roots that differ in length, depth, case,
spaces, project dir name and the order of the deps and build paths, and
that hold between them the words user paths hold (`/home/`, `/Users/`,
`.cache/mix/installs`, `Library`, `Projects`, `projects`, `src`, `code`,
`app`, `nix/store`, a dot-dir, `@` and `~`). It keeps the build only when
the three differ in the paths alone, and this client relocates only to
paths inside the envelope the three span: their characters, between their
lengths and depths (see
[Relocated builds](matching.md#relocated-builds-paths-in-the-beams)). What
is not seen: a compile-time test of the path against a constant that none
of the three roots holds (a prefix such as `/opt/` or `/srv/`, a word no
root holds), or any test that answers the same at all three roots and
otherwise at your path.
*Fix:* list such a dependency in `:except`.

## Trust

**One key signs everything.** The portal holds one online key for both
the root and the batches. Whoever controls the portal host could ship code
to every project and device that uses the library, until a library
release ships a new root.
*Status:* proposals to split the roles are in the compatibility
repository's `docs/PRECOMPILED_SIGNING_PROPOSALS.md`. See
[Who you are trusting today](trust.md#who-you-are-trusting-today).

**A fresh machine can't spot an older batch.** With no trust state yet
(a fresh install, or a new `:home`), there is no stored sequence to
compare against. An older batch, issued within the last 24 hours, still
passes the freshness checks.
*Impact:* small: the batch must still be signed and less than a day old.

**A mirror can hold back a root rotation.** A root is only adopted when
the source serves it, so a mirror that withholds newer roots keeps a
fresh `:home` on the root this library ships.
*Impact:* that machine misses newer builds signed under the new root;
nothing wrong installs.

**`_build` is trusted.** The provenance file (`.mix/precompiled.json` in a
dependency's build dir) is how an installed build is told apart from a
compiled one. Anyone who can write `_build` can forge it, but they could
already change any compiled code there.

## Mix.install

How these options of `Mix.install/2` reach the precompiled step.
`:config` and `:config_path` are not listed: they are applied before the
check as `Mix.install/2` applies them, so the check sees the compile-time
config the dependencies compile with.

| Option | What happens | Result |
| --- | --- | --- |
| `:lockfile` | Merged into the install project before the check, as `Mix.install/2` merges it | The check sees the versions and tree Mix compiles; Mix then finds the merge done |
| `MIX_INSTALL_RESTORE_PROJECT_DIR` | Ignored | — |

In every case the dependency ends up compiled, never wrong.

## Nerves

**Released nerves serves only `pure_elixir` builds.** Nerves 1.x has no
`Nerves.build_plan/0`, so the system isn't known on your build machine;
see [Nerves](nerves.md).

**System builds may have stripped beams.** Protocols they define are not
consolidated, and Dialyzer has no types for them. A run says how many.

## On a device

See also [Not supported](device.md#not-supported) in the device guide.

**Offline bundles last 24 hours for now.** A bundle that is good for
longer needs a signed `offline.json`, and the root this library ships has
no `offline` role yet.
*Until then:* build the bundle the same day you install it.

**An unsynced clock weakens a bundle's expiry check.** A device without
NTP judges a bundle's batch by its own clock, which only has to be later
than this library's build time. A batch that has really expired can still
pass. The batch must still be signed and not older than one the device
already saw. This goes away once bundles carry a signed `offline.json`,
which needs no clock.

**A Kino.JS writer never installs on a device.** Its archives belong in
kino's own directory, which a device's store cannot take.
*Impact:* Mix compiles it at firmware build time as before.

**Open handles are not "in use".** `Precompiled.uninstall/2` sees code that
is running, not resources that are open, like a GPIO handle.
*Fix:* close them before you uninstall.

## Upgrading from an older version

**Older installs are not rechecked.** Builds installed by a version of this
library from before provenance files carry none, so they are not
rechecked.
*Fix:* run `mix deps.clean --build`, or start from a clean `_build`. For
`Precompiled.Host.install/2`, use a forced install.
