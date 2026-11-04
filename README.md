# elixir_precompiled

Install signed, verified precompiled builds of your Hex dependencies
instead of compiling them. Builds come from the
[Nerves compatibility portal](https://compatibility.nerves-project.org),
which builds selected Hex packages for the host (`pure_elixir`) and for
Nerves systems, signs a batch index every 15 minutes, and serves files by
SHA-256. A dependency is installed only when a build matches the project on
every rule in [What matches](#what-matches); everything else compiles as
before, and nothing this library does can fail your build.

Status: pre-release. Not on Hex yet: use a git dependency, or the archive
for `Mix.install`. This library was called `nerves_precompiled` until
v0.1.0; the old config key and environment variables still work for one
release (see [Configuration](#configuration)).

## Setup

### Any Mix project (plain, Phoenix, libraries)

With [Igniter](https://hex.pm/packages/igniter) (Elixir 1.18 or later):

    mix igniter.install elixir_precompiled

It adds the dependency as `runtime: false`, sets `:source` in
`config/config.exs` (`--source URL` names another portal) and puts
`"deps.compile elixir_precompiled", "precompiled.install"` at the front of
the `deps.loadpaths` alias, before any steps already there. Running it
again changes nothing. Igniter is an optional dependency: a project that
does not use it never fetches it.

By hand, three lines:

```elixir
# mix.exs
def project do
  [
    ...,
    aliases: [
      "deps.loadpaths": ["deps.compile elixir_precompiled", "precompiled.install", "deps.loadpaths"]
    ]
  ]
end

defp deps do
  [
    {:elixir_precompiled, github: "TomHoenderdos/elixir_precompiled", runtime: false},
    ...
  ]
end

# config/config.exs
config :elixir_precompiled, source: "https://compatibility.nerves-project.org/api/precompiled"
```

Every `mix compile`, `mix test`, `mix run`, `mix phx.server` and
`mix release` passes through `deps.loadpaths` before Mix compiles
dependencies; the alias installs the matching builds first. The first
entry compiles this library so its task exists. Without it, Mix would
compile every dependency before the task could run. Keep the dependency
in every environment (no `only:`), since `mix test` runs in `test`.

Instead of the config, `ELIXIR_PRECOMPILED_SOURCE=<url>` opts a single run
(CI, a script) in. An empty value counts as unset.

On the host, only `pure_elixir` builds can match. The portal builds those
with Elixir 1.19.3 and 1.20.3 on OTP 28 and 29 today, so other toolchains
compile everything (see [Supported versions](#supported-versions)).

### Umbrella

Put the alias in the umbrella root's `mix.exs`; add the dependency to any
one app (or all of them) and the config to the root `config/config.exs`.
The Igniter installer does not edit umbrellas.

### Phoenix

Nothing beyond the above: `mix phx.server`, `mix test` and `mix release`
all go through the alias. Assets are not touched.

### CI

Nothing CI-specific is needed; for speed:

- cache the download cache (`~/.cache/elixir_precompiled` on Linux,
  `~/Library/Caches/elixir_precompiled` on macOS, or
  `ELIXIR_PRECOMPILED_HOME`) keyed on `mix.lock`, Elixir and OTP, next to
  `deps` and `_build`;
- a warm step asks the source one conditional question (`If-None-Match`
  on the batch) and downloads nothing else. Until the portal answers that
  question with `304 Not Modified`, the batch itself is downloaded again;
  manifests and files still come from the cache;
- `ELIXIR_PRECOMPILED_SOURCE=<url>` turns it on without a config change.

```yaml
- uses: actions/cache@v4
  with:
    path: |
      deps
      _build
      ~/.cache/elixir_precompiled
    key: ${{ runner.os }}-${{ matrix.elixir }}-${{ matrix.otp }}-${{ hashFiles('mix.lock') }}
```

When the cache dir is not writable (a read-only pre-seeded cache) or there
is no `HOME`, a run uses a fresh cache in
`_build/<env>/lib/.precompiled/home` instead. One line says so.

### Mix.install and Livebook

`Mix.install/2` runs once per VM, so the library comes from an archive.
Install it once into the Mix home the runtime uses:

    mix archive.install github TomHoenderdos/elixir_precompiled

Then, in a script after `Mix.start()` or a Livebook setup cell:

```elixir
ElixirPrecompiled.install([{:jason, "1.4.5"}],
  source: "https://compatibility.nerves-project.org/api/precompiled")
```

It is `Mix.install/2` with the precompiled step in front: matching builds
are installed into Mix's install project, and Mix compiles the rest. It
takes `Mix.install/2`'s options plus `:source`, `:except`, `:root` and
`:home`. `ELIXIR_PRECOMPILED_SOURCE` works instead of `:source`. Keep the
archive named `elixir_precompiled*.ez`: another name can make
`:code.priv_dir/1` miss the root of trust.

### Nerves

Either works:

- the alias above, as for any project. nerves_bootstrap prepends its own
  steps to the same alias, so the Nerves environment is set before ours
  runs;
- or the nerves `feat/precompiled` branch
  ([nerves-project/nerves#1220](https://github.com/nerves-project/nerves/pull/1220)),
  whose `nerves.init` calls this library itself:
  `{:nerves, github: "TomHoenderdos/nerves", branch: "feat/precompiled", runtime: false}`.
  With it, `mix nerves.info` repeats the last run.

Both together are fine: a second call in one Mix run reuses the first.

Builds made for a Nerves system need the fork: the system and its version
come from its `Nerves.build_plan/0`, which released nerves 1.x does not
have. With released nerves the alias still works, but only `pure_elixir`
builds match (rule 1 below; rule 8 still applies) and every other
dependency compiles from source.

On a device, `ElixirPrecompiled.install/2` above works with the running
Nerves system, read from `/usr/lib/os-release` (written by every Nerves
system's `nerves_system_br` post-build script). It needs:

- `:mix` in `extra_applications` (the library's own `.app` starts
  `:inets`, `:ssl`, `:crypto` and `:public_key`);
- a writable `MIX_INSTALL_DIR` (for example `/data/mix-installs`);
- Hex;
- for packages that MISS and have rebar3 dependencies, an `escript`
  executable (Nerves releases ship none); some dependencies also need
  `:eex` or `:ex_unit` in the release. A HIT needs none of that.

The install project under `MIX_INSTALL_DIR` persists across boots: a
dependency this library installed there is rechecked against the current
batch on every boot, as in a Mix project's `_build`. A boot with no network
keeps the installed builds and still starts.

A device whose clock is not yet set (no RTC, before NTP) refuses every
batch ("clock is before ...") and compiles; call it after
`NervesTime.synchronized?/0` is true.

## Seeing what happened

Every candidate prints one line, then a summary:

```
precompiled: ash 3.36.0                   HIT   4.1 MB
precompiled: nerves_pack 0.7.1            MISS  built with nerves_ssh 1.3.3, project has 1.3.2
precompiled: 40 hit, 5 miss, 0 fail of 45 deps, 61.2 MB, 8.3 s
```

A warm run whose installs the batch still vouches for prints nothing.

- `mix precompiled.status` lists what is installed in this `_build`, with
  the batch and manifest each came from.
- `_build/<env>/lib/.precompiled/report.json` (`"format": 1`) holds the
  last run that printed lines.
- Each installed dependency carries `.mix/elixir_precompiled.json`.

## Turning it off

- `ELIXIR_PRECOMPILED=0` (`false` and `no` work too), or removing
  `:source`, turns it off and removes the builds it installed, so Mix
  compiles them in that same run. Only build dirs this library wrote are
  removed, never one Mix compiled, and only in the `_build` of the run's
  own env and target: a run on `host` removes host installs, never a
  device target's.
- `mix precompiled.clean` removes this `_build`'s installs.
  `--cache` also empties the download cache (files, manifests and source
  scans), from the same cache dir a run uses.
- `:except` keeps listed dependencies compiled from source; an earlier
  install of one is removed.

## Configuration

| Key or variable | Meaning |
| --- | --- |
| `:source` / `ELIXIR_PRECOMPILED_SOURCE` | The portal's precompiled API URL; nothing happens without one. `https` only (`http` on loopback). The variable beats app config; an `install/2` option beats both. |
| `:except` | Dependencies never installed precompiled, e.g. `[:ash]`. |
| `:content` | Content origins (mirrors, CDNs) to fetch files and manifests from instead of the ones the signed batch names. `https` only (`http` on loopback). |
| `:root` | A `root.json` to trust instead of the one this library ships. |
| `:home` / `ELIXIR_PRECOMPILED_HOME` | Cache and trust state dir. Unlike `:source`, the config key beats the variable. Default: the user cache dir (`:filename.basedir(:user_cache, "elixir_precompiled")`). `ELIXIR_PRECOMPILED_HOME=~/.nerves/precompiled` keeps using the pre-rename cache. |
| `:deadline_seconds` | All network for one run (default 300); what is still waiting then compiles. Root and batch get 15 s together, connects 5 s. |
| `:root_check_seconds` | How often the served root is checked for a rotation (default 3600; a batch that fails to verify checks it at once). |
| `:cache_max_mb` | Cache size bound (default 4096), least recently used evicted, checked once a day. Trust state is never evicted. |
| `ELIXIR_PRECOMPILED=0` | Off: installs nothing and removes earlier installs. |
| `ELIXIR_PRECOMPILED_OFFLINE=1` | No network: the cached batch (while fresh) and cached files only. |
| `ELIXIR_PRECOMPILED_CACERTS_PATH` (or `HEX_CACERTS_PATH`) | A PEM CA bundle that replaces the OS store (TLS-intercepting proxies). Verification stays on; only the bundle's CAs are trusted. |
| `HTTPS_PROXY`/`https_proxy`, `HTTP_PROXY`/`http_proxy`, `NO_PROXY`/`no_proxy` | Proxies, as Hex reads them. Credentials in the proxy URL are sent only to the proxy. `NO_PROXY` takes host names, domains (`.corp.example`), IP addresses and `*`; CIDR ranges are ignored. |
| `ELIXIR_PRECOMPILED_DEBUG=1` | Also print each dependency that was not a candidate, and why. |

The keys go in `config :elixir_precompiled, ...` or as options to
`ElixirPrecompiled.install/2`. The old names (`config :nerves_precompiled`,
`config :nerves, :precompiled`, `NERVES_PRECOMPILED*`) are still read for
one release, when the new ones are unset.

## What matches

A dependency is a candidate when it comes from Hex (a git or path
dependency never is), is not Nerves tooling (`nerves`, its own
dependencies, `nerves_system_*`, `nerves_toolchain_*`, `nerves_bootstrap`,
`elixir_precompiled` itself) and is not in `:except`. A build of a
candidate is installed only when every rule holds:

1. **Target.** The build is `pure_elixir` (it serves every system and
   plain Elixir), or it was made for this project's Nerves system at the
   exact system version in `mix.lock`.
2. **Elixir.** Same major and minor as the running Elixir, and the running
   version is at least the one the build was made with. Elixir code compiled
   on 1.20.1 runs on 1.20.3, not the other way round; versions compare as
   versions, so a 1.21.0 build is not served to 1.21.0-rc.0, while a
   1.21.0-rc.0 build is served to 1.21.0.
3. **OTP.** The same OTP major. What a build inlines at compile time from
   OTP headers (record layouts) can change between majors.
4. **Dependency env.** The build was compiled in the env the dependency
   compiles in here: `prod`, unless the project's `deps` entry overrides it
   with `env:`.
5. **Checksum.** The build's package checksum equals the dependency's
   checksum in `mix.lock`.
6. **Dependencies.** Every dependency the build was compiled against is in
   `mix.lock` at the same version and checksum, and every dependency the
   package declares (optional ones included) that the lock has was in the
   build.
7. **compile_env.** Every `Application.compile_env` value the build read
   equals the project's config for that key.
8. **Compile-time inputs.** A dependency whose own sources read
   `Mix.target()` at compile time (module level in `lib/`, anywhere in
   `mix.exs`) gets no `pure_elixir` build on a device target. It gets a
   system build only when the build was made under the project's target
   name: the recorded one, or else the system's conventional one
   (`nerves_system_rpi4` → `rpi4`). A dependency that reads an environment
   variable at module level in `lib/` never matches, nor does one whose
   sources cannot be scanned (they do not parse, or are over 2 MB a file or
   20 MB a package). Not covered: environment variables read in a
   dependency's `mix.exs`, and `Application.get_env` in a module body
   (Elixir warns about it). Builds record neither, so such a dependency
   can be served a build made with other values.

When several builds pass, the one already installed wins (its bytes stay as
they are), then the one made on the running Elixir patch, the closest older
patch, `pure_elixir` before a system build, and the newest run. When none
passes, the line gives the rule the build that got furthest broke, for
example `MISS  built with Elixir 1.20.3, running 1.20.1`.

## Trust

The library ships the portal's root of trust (`priv/precompiled/root.json`,
Ed25519, expires 2027-10-22). Every batch index is signed by a key the root
names; every manifest is fetched by the hash the batch names; every file by
the hash the manifest names. Nothing unsigned or unhashed reaches `_build`.
Plain `http` sources are refused except on loopback.

The batch may name content origins (a CDN) that files and manifests are
fetched from before the source; the project can override them with
`:content`. Everything fetched from them is checked against the hashes in
the signed batch and manifests. A bad mirror can therefore only cause a
fallback to the source or a miss, never a wrong install. Redirects are
followed only within the request's origin or to a listed content origin.

The verified batch is kept in the state dir and revalidated with its ETag.
A cached batch passes the same signature, freshness and sequence checks
as a fresh one. The served root is checked at most once an hour (and
whenever a batch fails to verify), so a root rotation reaches a warm client
within that hour. When the source cannot be reached (a transport error, a
5xx, the run deadline), a cached batch that still passes every check is
used and one line says so; a response the source did give and that is
refused (bad signature, an older sequence, an expired batch) never falls
back to the cache.

A batch is also checked for freshness, on top of its signature, expiry and
sequence: it is refused when its `issued` timestamp is more than 24 hours
ago ("batch stale"), more than 5 minutes in the future ("clock"), when it
stays valid for more than 30 days past `issued` ("batch lifetime"), or when
`issued` does not parse ("batch malformed"). A local clock reading earlier
than the moment this library was built is refused outright ("clock"),
since none of the above can be trusted on it. A batch the source did not
deliver (a network error, a 4xx or 5xx, a refused redirect, no usable
cached batch to stand in) is reported as `batch unavailable: <why>`; a
batch that was delivered and fails a check is reported by the check alone:
`batch signature invalid`, `batch stale: ...`, `batch expired at ...`,
`batch sequence N is older than M`, `batch lifetime over 30 days ...`,
`batch malformed`, `clock: ...` or `clock is before ...`. Every refusal
falls back to compiling.
`clock_offset_seconds` moves the client's notion of now for these checks;
it is test-only, read only from project config, and never from an
environment variable.

Every run, `ElixirPrecompiled.install/2` included, also rechecks builds an
earlier run installed (into a Mix project's `_build` or into the
`Mix.install/2` project) against the current batch: one the batch no
longer names is removed and compiled from source; one whose build still
passes every rule of [What matches](#what-matches) with exactly the files
on disk is kept as it is, even when a newer portal run made the same
build again; any other is replaced or removed. One newly listed in
`:except` is removed and compiled from source whether or not a batch is
fetched. When no batch is available (offline, or refused), installed
builds are left as they are and the run prints one warning,
`precompiled: no fresh batch (<reason>); N installed builds kept, not
rechecked`, rather than a FAIL line per dependency; dependencies Mix is
about to compile still get their own FAIL line with the reason.
`report.json` lists every kept build as `fail` with a detail ending
`(installed build kept)`.

An install is checked before it is placed: every path must be a plain
relative path inside the dependency's own build dir, with a safe mode
(`unsafe path or mode (...)`); no two paths may collide, including case
and Unicode-normalisation variants (`path collision: ...`); `ebin/` may
hold only `.beam` files, `<dep>.app` and `<dep>.appup` (anything else,
such as another app's `.app`, is `foreign path: ...`); and the `.app` must
list exactly the beams shipped. Cache entries are never
followed through symlinks.

Root rotation follows TUF: each adopted root must be signed by the
previous root's root keys (to its threshold) and carry a higher version,
and only the root in use must be unexpired, so a root that expires after
a newer one was adopted does not end the chain.

Once a root is adopted, its version is kept as a floor that a later run
will not go back below; `roots.json` losing the entries that reached it
(deleted, truncated, rolled back) is reported as an error rather than
silently accepted (`root version N is older than M`); deleting the
`root_version` file the error names, under the trust state dir in
`ELIXIR_PRECOMPILED_HOME`, accepts the older root. A state file that exists
but will not parse (the batch sequence or the root version) is logged as a
warning and treated as 0.

Today the root and batch roles are one Ed25519 key, threshold 1, held
online by the portal. Whoever controls the portal host can therefore
rotate the root and ship code to every opted-in host and device, until a
library release ships a new root. The proposals for splitting the roles
are in the compatibility repository's `docs/PRECOMPILED_SIGNING_PROPOSALS.md`.

## Supported versions

Elixir 1.17 or later on OTP 27 or later. CI runs 1.17/27, 1.18/27, 1.19/28
and 1.20/29. The portal currently builds with Elixir 1.19.3 and 1.20.3 on
OTP 28 and 29. A build serves the same Elixir minor at the same or a later
patch, on the same OTP major, so other toolchains compile everything.
Igniter's installer needs Elixir 1.18.

## Troubleshooting

| Line | What it means |
| --- | --- |
| `batch unavailable: <why>` | The source did not deliver a batch (network error, 4xx/5xx, refused redirect) and no cached one could stand in: everything compiles from source. |
| `batch signature invalid`, `batch stale: ...`, `batch expired at ...`, `batch sequence N is older than M`, `batch lifetime ...`, `batch malformed` | A batch was delivered but failed that check; it is never used, and nothing installs this run. A stale or expired batch usually means the source stopped publishing. |
| `source unreachable (<why>); using the cached batch` | The network failed; a cached batch that still passes every check stood in. |
| `no fresh batch (<why>); N installed builds kept, not rechecked` | Earlier installs stay as they are until a batch is available again. |
| `clock is before ...` | The machine's clock is wrong (a device before NTP). Set it; nothing installs until then. |
| `cache dir ... is not writable; using ...` | The run used a fresh cache under `_build`. Fix the permissions or set `ELIXIR_PRECOMPILED_HOME`. |
| `FAIL  cache refused (... remove it)` | A cache entry or dir is a symlink or not a plain file; it is never followed. Remove the path the line names. |
| `MISS  reads Mix.target() at compile time ...` | Rule 8: no build was made for this target name. |
| `internal error, compiling from source` | A bug in this library; the build carries on. Please report it with the line. |

`ELIXIR_PRECOMPILED_DEBUG=1` also lists the dependencies that were not
candidates and why. `ELIXIR_PRECOMPILED=0` rules this library out
completely: it removes its installs and Mix compiles everything.

## Known limitations

* Mix's `:lockfile` option is passed through to `Mix.install/2` but not used
  for the precompiled step, so an external lockfile can make Mix re-resolve
  and recompile what was just installed.
* `:config` and `:config_path` are not applied before the check, so a
  dependency whose compile-time config they change misses, or is placed and
  then recompiled by Mix's config-outdated check. Never a wrong build.
* `MIX_INSTALL_RESTORE_PROJECT_DIR` is ignored by the precompiled step.
* One online key signs both the root and the batches (see Trust).
* On a machine with no trust state yet (a fresh install, or one pointed at
  a new `:home`), an older batch issued within the last 24 hours still
  passes the freshness checks: there is no stored sequence yet to catch it
  as a rollback.
* A mirror that withholds newer roots leaves a fresh `:home` on the
  shipped root; a root is only adopted when the source actually serves it.
* The provenance file (`.mix/elixir_precompiled.json` under a dependency's
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

## Development

```
mix test                                 # unit tests, fixture server on port 4000
TEST_SERVER_PORT=4567 mix test           # when port 4000 is taken (the three ports above it are also used)
mix test --only integration              # child Mix projects against the fixture (needs hex.pm)
mix test --only production               # install/2 against the public portal
scripts/container-check.sh               # the same inside the compatibility worker image
MIX_ENV=prod mix archive.build           # elixir_precompiled-<vsn>.ez
```
