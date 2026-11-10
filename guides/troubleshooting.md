# Troubleshooting

| Line | What it means |
| --- | --- |
| `batch unavailable: <why>` | The source did not deliver a batch (network error, 4xx/5xx, refused redirect) and no cached one could stand in: everything compiles from source. |
| `batch signature invalid`, `batch stale: ...`, `batch expired at ...`, `batch sequence N is older than M`, `batch lifetime ...`, `batch malformed` | A batch was delivered but failed that check; it is never used, and nothing installs this run. A stale or expired batch usually means the source stopped publishing. |
| `batch unavailable: offline, no cached batch` | `PRECOMPILED_OFFLINE=1` is set and this home holds no batch yet: everything compiles from source. Run once online to fill the cache. |
| `source unreachable (<why>); using the cached batch` | The network failed; a cached batch that still passes every check stood in. When the source failed to connect, manifests and files not in the cache then miss at once: it is not asked again in that run. |
| `no fresh batch (<why>); N installed builds kept, not rechecked` | Earlier installs stay as they are until a batch is available again. |
| `clock is before ...` | The machine's clock is wrong (a device before NTP). Set it; nothing installs until then. |
| `cache dir ... is not writable; using ...` | The run used a fresh cache under `_build`. Fix the permissions or set `PRECOMPILED_HOME`. |
| `FAIL  cache refused (... remove it)` | A cache entry or dir is a symlink or not a plain file; it is never followed. Remove the path the line names. |
| `MISS  reads Mix.target() at compile time ...` | Rule 8: no build was made for this target name. |
| `internal error, compiling from source` | A bug in this library; the build carries on. Please report it with the line. |

`PRECOMPILED_DEBUG=1` also lists the dependencies that were not
candidates and why. `PRECOMPILED=0` rules this library out
completely: it removes its installs and Mix compiles everything.

# Known limitations

* Mix's `:lockfile` option is passed through to `Mix.install/2` but not used
  for the precompiled step, so an external lockfile can make Mix re-resolve
  and recompile what was just installed.
* `:config` and `:config_path` are not applied before the check, so a
  dependency whose compile-time config they change misses, or is placed and
  then recompiled by Mix's config-outdated check. Never a wrong build.
* `MIX_INSTALL_RESTORE_PROJECT_DIR` is ignored by the precompiled step.
* One online key signs both the root and the batches (see [Trust](trust.md)).
* On a machine with no trust state yet (a fresh install, or one pointed at
  a new `:home`), an older batch issued within the last 24 hours still
  passes the freshness checks: there is no stored sequence yet to catch it
  as a rollback.
* A mirror that withholds newer roots leaves a fresh `:home` on the
  shipped root; a root is only adopted when the source actually serves it.
* The provenance file (`.mix/precompiled.json` under a dependency's
  build dir) is what tells an installed build from a compiled one; anyone
  who can write `_build` can forge it, the same trust `_build` already
  carries.
* Builds installed by an earlier version of this library carry no
  provenance file and are not rechecked; they are rechecked only after
  `mix deps.clean --build` or a clean `_build` (for `install/2`, a forced
  install) has them installed again.
* Builds made for a Nerves system may have stripped beams: protocols they
  define are not consolidated and Dialyzer has no types for them (a run
  says how many).
* With the Nerves fork, `nerves.init` calls this library itself. The
  library does nothing under `help`, `clean` and `precompiled.*` tasks, but
  the hook still runs its own setup first; the fork's `nerves.init` skip
  list should name `precompiled.*` as well (a change on the fork's side).
* Released nerves 1.x has no `Nerves.build_plan/0`, so no Nerves system is
  known and only `pure_elixir` builds match (see [Nerves](nerves.md)).
