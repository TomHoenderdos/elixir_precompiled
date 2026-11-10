# elixir_precompiled

Install signed, verified precompiled builds of your Hex dependencies
instead of compiling them. Builds come from the
[Nerves compatibility portal](https://compatibility.nerves-project.org),
which builds selected Hex packages for the host (`pure_elixir`) and for
Nerves systems, signs a batch index every 15 minutes, and serves files by
SHA-256. A dependency is installed only when a build matches the project on
every rule in [What matches](#what-matches); everything else compiles as
before, and nothing this library does can fail your build. It can also
install into a running Nerves device: see [On a device](#on-a-device).

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

All of the above runs on the build host. To install on the running
device itself, from an IEx shell on it, see [On a device](#on-a-device).

## On a device

`Precompiled.install/1` installs a signed precompiled library into a
running Nerves device, from an IEx shell on it (over ssh or the console),
with no Mix, no Hex and no compiler on the device. Something goes wrong in
the field and you need `recon` or another diagnostic tool: install it on
that device instead of shipping a debug firmware. It picks the build made
for the device's own Nerves system and versions, checks every byte through
the signed chain, loads it and starts it. It never replaces anything the
firmware has, and nothing it installs is loaded at boot.

### Setup

    mix igniter.install elixir_precompiled --device

(which also sets up the build-time step of [Setup](#setup)), or by hand,
in the firmware's `mix.exs`: the dependency without `runtime: false`, so
the library ships in the firmware, and `castore` when the system has no
CA certificates of its own (see [CA certificates](#ca-certificates)):

```elixir
{:elixir_precompiled, github: "TomHoenderdos/elixir_precompiled", targets: @all_targets},
{:castore, "~> 1.0", targets: @all_targets}
```

The git dependency stands in until the library is on Hex; after the
release, use `"~> 0.2"` instead.

Nothing else. It is on by default and uses the official signed source,
`https://compatibility.nerves-project.org/api/precompiled`, checked
against the root this library ships. Nothing runs on its own: it only
ever acts when someone with a shell on the device calls it.

To limit it, turn it off, or point it elsewhere, set
`config :elixir_precompiled, :device` in the firmware's config
(`config/target.exs`, say):

```elixir
config :elixir_precompiled, :device,
  allow: [:recon, :circuits_gpio]

# or, to turn it off in this firmware:
config :elixir_precompiled, :device, enabled: false
```

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | `false` disables installing: `install/2` returns `{:error, :disabled}`. `list/1`, `uninstall/2` and `clean/1` keep working, so what is installed can still be removed. |
| `allow` | any app | A list of apps: only those may be installed, closure members included. |
| `source` | the official API | Another source: an `https://` API root, or a `file://` bundle dir. |
| `dir` | `/data/precompiled` | Where installs are stored. |
| `max_bytes` | 64 MB | The size bound of that store. |
| `cacerts_path` | none | A PEM CA bundle to verify the source with. |
| `root` | the shipped `root.json` | Another trust anchor. Set here only: a call cannot pass it. |
| `content`, `deadline_seconds`, `max_closure`, `start`, `closure`, `quiet` | as in the options below | Firmware-wide defaults for those `install/2` options. |

`enabled` and `allow` are read from the firmware's config only: a call can
neither pass, widen nor clear them. Any other key under `:device` is
ignored.

Online installs need `:inets`, `:ssl` and `:public_key` in the release
(Nerves firmware with networking usually has them). A firmware that only
installs from bundles can leave them out; an online call then returns
`{:error, {:missing_app, app}}`.

### Usage

```elixir
Precompiled.install(:recon)
Precompiled.install({:circuits_gpio, "2.3.1"})
Precompiled.install([:recon, {:circuits_gpio, "~> 2.3"}])
Precompiled.install(:recon, dry_run: true)
Precompiled.install(:recon, source: "file:///media/usb/precompiled")
Precompiled.list()
Precompiled.uninstall(:recon)
Precompiled.clean()
```

A bare name takes the newest version with a build that matches; a version
or a requirement narrows it. Absent runtime dependencies are installed with
the package, as one unit: anything that fails takes the code path and the
loaded apps back to how they were. Each step prints one line:

```
precompiled: system nerves_system_rpi4 2.2.1, OTP 29, Elixir 1.20.3, aarch64
precompiled: circuits_gpio 2.3.1   PLAN  nerves_system_rpi4, 198 KB
precompiled: circuits_gpio 2.3.1   OK    /data/precompiled/circuits_gpio-2.3.1
precompiled: 1 installed, 198 KB, 2.1 s
{:ok, [%Precompiled.Installed{app: :circuits_gpio, ...}]}
```

- `install/2` returns `{:ok, [%Precompiled.Installed{}]}` with the apps it
  installed (`[]` when everything was already there), or
  `{:error, reason}`. It never raises on the network or on bad input.
- `dry_run: true` plans, checks the trust chain and fetches only the
  manifests and `.app` files, and returns `{:ok, %Precompiled.Plan{}}`.
- `list/1` prints and returns what is in the store, each with its size,
  the batch it was checked against, and whether it is loaded; or
  `{:error, reason}` for a bad option or an unsafe store.
- `uninstall/2` stops the app, unloads it, purges its modules and takes it
  off the code path. Its files stay in the store as a cache
  (`remove: true` drops them). It refuses while other installed apps need
  it (`cascade: true` uninstalls those first) or while other processes run
  its code (`force: true`). Only running code counts: open resources are
  not detected, so an uninstall goes ahead while a shell still holds, say,
  a GPIO handle from `Circuits.GPIO.open/2`. Close such handles
  (`Circuits.GPIO.close/1`) first.
- `clean/1` empties the store, but keeps what is loaded.

The options of `install/2`:

| Option | Default | Meaning |
| --- | --- | --- |
| `:source` | the `:device` config, else the official API | `https://...` (`http://` on loopback only), or `file://DIR` for a bundle. |
| `:content`, `:deadline_seconds` | as on the host | See [Configuration](#configuration). |
| `:cacerts_path` | none | A PEM CA bundle (see [CA certificates](#ca-certificates)). |
| `:dir` | `/data/precompiled` | The store. Its trust state lives in `DIR/.trust`, so another `:dir` has its own trust state, starting again from the shipped root. |
| `:start` | `true` | Start the installed apps (`:temporary`). `false` only loads them. |
| `:closure` | `true` | Install absent runtime dependencies. `false` refuses with `{:needs, [{app, vsn}]}` instead. |
| `:max_closure` | 25 | The most apps one call installs. |
| `:max_bytes` | 64 MB | The size bound of the store. |
| `:dry_run` | `false` | Plan only, as above. |
| `:report` | none | With `dry_run: true`, also write the device facts and the plan as JSON to this path, for `mix precompiled.bundle --device-report`. |
| `:quiet` | `false` | Print nothing. |

An unknown option is refused (`{:bad_option, key}`), never ignored.
`list/1` and `clean/1` take `dir` and `quiet`; they also accept the other
options of `install/2` and `uninstall/2`, so one options list serves all
calls, and ignore them.
`Precompiled`'s module documentation lists every error reason.

### What it refuses

- **Anything the device already has.** An app the firmware has, loaded or
  only shipped in the release, is never replaced: `install(:logger)`
  returns `{:error, {:already_present, :logger, vsn}}`. Apps are matched by
  name and exact version: a build made against `nerves_ssh` 1.3.3 is
  refused on a device with 1.3.2 (`NO  built against nerves_ssh 1.3.3,
  device has 1.3.2`).
- **Conflicts.** A module that is already loaded, or that the code path
  already finds, refuses the install (`{:module_loaded, mod, path}`,
  `{:module_conflict, mod, path}`), and so do two versions of one app in
  one call (`{:conflict, app, vsns}`).
- **Other systems.** A system build serves only the Nerves system it was
  made for, matched by name and exact version (read from
  `/usr/lib/os-release`); builds are made for official Nerves systems. A
  `pure_elixir` build serves any device, and a device whose system is not
  known takes `pure_elixir` builds only. When both kinds match, the system
  build wins. A native library made for another CPU is refused
  (`{:elf, why}`).
- **noexec.** A build with native code is refused when the store is on a
  `noexec` mount (`{:noexec, mount}`).
- **An unset clock.** An online call refuses before any request until the
  clock is synchronized (`NervesTime.synchronized?/0` when `nerves_time` is
  in the firmware): `{:error, {:clock_unsynchronized, now}}`. Set the
  clock or wait for NTP, then retry. A bundle needs no NTP: one without
  `offline.json` is judged by its batch's expiry against the device clock,
  which must be sane; one with a signed `offline.json` needs no clock.

### The cache

Installs stay in the store on `/data` across reboots, but nothing is
loaded at boot: after a reboot `list/0` shows them as cached, not loaded.
Installing the same build again loads it from the store with no download,
after checking every cached file against the signed hashes of the current
batch; a cached build the batch no longer names, or one whose files
changed, is downloaded again and never loaded. The store is bounded by
`max_bytes`, and the least recently used builds that are not loaded are
evicted to make room, before anything is downloaded, so a stale cache never
fills `/data` under a new install. `Precompiled.clean/0` empties it.

The store dir is created `0700`, and must not be writable by group or
others and must be owned by the VM's user. One call at a time changes it.
The same store reached through a link (`/data` is a link to `/root` on
Nerves) is one store; the store dir itself must not be a symlink.

### Bundles: installing with no network

A bundle is a directory with the API's own layout, holding exactly what a
device needs, written on a host with network:

    mix precompiled.bundle recon circuits_gpio@2.3.1 --out bundle \
      --system nerves_system_rpi4@2.2.1 --otp 29 --elixir 1.20.3

It plans on the host as the device would, from the device's facts: the
flags (`--pure` for a device with no Nerves system, `--cpu` for another
CPU than `aarch64-unknown-linux-gnu`), or the JSON a dry run wrote on the
device itself (`Precompiled.install(:recon, dry_run: true, report:
"/data/report.json")`, then `--device-report report.json`). Every byte is
checked against its signed hash before it is written. `mix help
precompiled.bundle` has the details.

Copy the directory to the device (a USB stick, or `sftp` to `/data`) and
install from it:

```elixir
Precompiled.install([:recon, :circuits_gpio], source: "file:///data/bundle")
```

A `file://` install opens no connection and needs no network apps. The
device checks everything again, exactly as over https. A bundle's
`batch.json` is the online batch, so it is valid for 24 hours after the
portal issued it. For a device that stays offline longer, the bundle
carries an `offline.json`, signed by the root's `offline` role with
`mix portal.precompiled.sign_offline` from the portal's repository (see
its `PRECOMPILED_API.md`, "Offline bundles"), within a day of the batch's
issue. An offline document has no expiry and needs no clock. The device
honours it only from a `file://` source, only when its root has an
`offline` role (a device can adopt a newer root from the bundle's
`root.json`, when that root chains from the one it trusts), and never with
a sequence below the highest it has seen. The root this library ships has
no `offline` role yet, so for now a bundle is valid for its batch's 24
hours.

### Trust on the device

The device checks the same chain as the host: the root this library ships
(or the firmware's `root`), the signed batch, each manifest by the hash the batch names,
and each file by the hash its manifest names, size included. A file is
staged, verified and only then moved into the store; the loader hashes the
`.app`, every beam and every `priv` file once more just before anything
loads, and loads the beams from those verified bytes. Nothing unsigned is
ever loaded, nothing is compiled, and there is no fallback that skips a
check. An online batch must pass the freshness checks in [Trust](#trust),
which is why the clock must be set.

### CA certificates

An `https` source is verified with, in this order: `cacerts_path`, the
`ELIXIR_PRECOMPILED_CACERTS_PATH` or `HEX_CACERTS_PATH` file, the system's
own store (`:public_key.cacerts_get/0`), then the `castore` package's
bundle when it is in the firmware. With none of them, the call fails
(`no CA certificates`). Many Nerves systems ship a store of their own
(`nerves_system_qemu_aarch64` does); add `castore` for one whose store is
empty, or to be independent of it.
`mix igniter.install elixir_precompiled --device` adds `castore` unless the
project already depends on it.

### Not supported

- **Hot upgrades.** An app that is present is refused, never replaced:
  no appups and no `code_change`.
- **Surviving a firmware update.** Nothing is loaded at boot anyway. After
  an update a cached build is used only when it still matches the new
  firmware; the firmware itself should include what it needs.
- **Git, path or private packages**, and anything that is not in the
  signed batch.
- **Protocol consolidation.** An installed protocol implementation for a
  protocol the release consolidated is not dispatched; the install says so
  with a `WARN` line.

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
| `batch unavailable: offline, no cached batch` | `ELIXIR_PRECOMPILED_OFFLINE=1` is set and this home holds no batch yet: everything compiles from source. Run once online to fill the cache. |
| `source unreachable (<why>); using the cached batch` | The network failed; a cached batch that still passes every check stood in. When the source failed to connect, manifests and files not in the cache then miss at once: it is not asked again in that run. |
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
* With the Nerves fork, `nerves.init` calls this library itself. The
  library does nothing under `help`, `clean` and `precompiled.*` tasks, but
  the hook still runs its own setup first; the fork's `nerves.init` skip
  list should name `precompiled.*` as well (a change on the fork's side).
* Released nerves 1.x has no `Nerves.build_plan/0`, so no Nerves system is
  known and only `pure_elixir` builds match (see Nerves above).

## Development

```
mix test                                 # unit tests, fixture server on port 4000
TEST_SERVER_PORT=4567 mix test           # when port 4000 is taken (the three ports above it are also used)
mix test --only integration              # child Mix projects against the fixture (needs hex.pm)
mix test --only production               # install/2 against the public portal
scripts/container-check.sh               # the same inside the compatibility worker image
MIX_ENV=prod mix archive.build           # elixir_precompiled-<vsn>.ez
```
