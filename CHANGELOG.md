# Changelog

## v0.3.1 - 2026-11-10

* New matching rule 9, build method. A dependency whose `deps` entry sets
  `:manager`, `:compile` or `:system_env` is built differently from any
  precompiled build, so it always compiles from source, with a line such as
  `MISS  project sets :manager for this dependency`. This includes options
  a package's own `mix.exs` sets on its dependencies, under
  `Precompiled.Host.install/2` too. An installed build is removed on the
  next run once such an option appears.
* A global `Mix.install(deps, system_env: ...)` is not treated as an
  override: rule 8 already refuses dependencies that read an environment
  variable at module level in `lib/`, and reads in a dependency's `mix.exs`
  remain a documented limitation.
* A manifest build may record `manager` (a string such as `"mix"`,
  `"rebar3"` or `"make"`). When it differs from the manager Mix resolves
  for the dependency, the build misses: `built with rebar3, project builds
  with make`. A build without `manager` matches as before. The device API
  (`Precompiled.install/2`) does not compare it.

## v0.3.0 - 2026-11-10

Breaking changes. A source or mirror learns which dependencies a project
has, and a root decides whose builds run, so all three are now set only in
the project's config, never by an option or environment variable a pasted snippet could
carry (see the Trust guide).

* The source defaults to the official API,
  `https://compatibility.nerves-project.org/api/precompiled`, checked
  against the shipped root. No source configured no longer means off; to
  turn it off, use `PRECOMPILED=0`, `config :precompiled, :device,
  enabled: false` on a device, or `:except` per dependency.
* `Precompiled.Host.install/2` no longer takes `:source`, `:root` or
  `:content`; passing any of them raises `ArgumentError`. `config
  :precompiled, source: ..., root: ..., content: [...]` still sets them.
* `PRECOMPILED_SOURCE` (and `NERVES_PRECOMPILED_SOURCE`) is no longer
  read.
* On a device, a per-call `:source` must be a `file://` bundle; a network
  source per call returns `{:error, {:source_not_allowed, source}}`. A
  network source comes from `config :precompiled, :device, source: ...`
  or the default. A per-call `:content` returns `{:error,
  {:content_not_allowed, origins}}`; `content:` in the `:device` config
  still works.
* The Igniter installer no longer writes `config :precompiled, source:`
  and has no `--source` option.

Also:

* `Precompiled.Host.install/2` starts Mix itself, as `Mix.install/2`
  does, so it works in a fresh Livebook runtime.
* The "Mix.install and Livebook" setup is one cell that installs the
  archive when it is missing.
* The Nerves, What matches, Trust and Troubleshooting guides are
  rewritten for reading, mostly as tables, and Known limitations is its
  own guide.
* The docs are titled "Precompiled", and the README has a Nerves
  compatibility badge.

## v0.2.1 - 2026-11-10

* Docs only. The README's guide links open the HexDocs pages again (on
  hex.pm they opened the raw Markdown), `Precompiled.Host.run/1`
  documents its own `report()` type, and the docs build without
  warnings.
* `mix hex.publish` runs in the docs env, where ex_doc lives.

## v0.2.0 - 2026-11-10

* Renamed to `precompiled` before the first Hex release: the app and
  package `:precompiled`, modules `Precompiled.*` (the host API, `run/1`
  and the `Mix.install/2` wrapper `install/2`, is now `Precompiled.Host`;
  `Precompiled` itself is the device API), config `config :precompiled`,
  environment variables `PRECOMPILED_*`, the default cache dir
  `:filename.basedir(:user_cache, "precompiled")`, the provenance file
  `.mix/precompiled.json` and the archive `precompiled-<vsn>.ez`. The
  Igniter installer is `mix igniter.install precompiled`
  (`mix precompiled.install`), and the `deps.loadpaths` step it adds is
  now `mix precompiled.deps`. A clean break: none of the interim
  `elixir_precompiled` names is read, and a cache under the old dir is
  simply not used. The repository keeps its name, `elixir_precompiled`.
* `Precompiled.install/1,2` installs signed precompiled builds into a
  running Nerves device from an IEx shell, with no Mix, Hex or compiler on
  the device: it selects the build for the device's system, OTP, Elixir,
  CPU and present apps (by name and exact version), verifies every byte,
  loads and starts it with its absent runtime dependencies, and rolls the
  whole call back on any failure. Nothing present is ever replaced.
  `Precompiled.list/1`, `Precompiled.uninstall/2` and `dry_run: true`
  (with `report:` for a bundle) come with it. See the "On a
  device" guide.
* On by default, with the official signed source
  (`https://compatibility.nerves-project.org/api/precompiled`) as the
  default source; it only acts when called. `config :precompiled,
  :device` sets `enabled: false` (no installs), `allow: [...]` (an allowlist),
  another `source`, `dir`, `max_bytes` and `cacerts_path`; `enabled` and
  `allow` cannot be overridden by a call.
* Installs are kept as a cache on `/data` across reboots, never loaded at
  boot; installing again loads from the cache after re-verifying every
  file. The cache is bounded by `max_bytes` with least recently used
  eviction, and `Precompiled.clean/0` empties it.
* `file://` sources: a bundle directory with the API's layout, read from
  local storage only, with no network and no network apps.
* Offline bundles: a bundle's `offline.json`, signed by the root's
  `offline` role, has no expiry and needs no clock; a device honours it
  only from a `file://` source, under a root with an `offline` role, and
  never below the highest offline sequence it has seen. A device adopts a
  newer root from a bundle when it chains. The shipped root has no
  `offline` role yet, so a bundle is valid for its batch's 24 hours.
* `mix precompiled.bundle PKG[@REQ]... --out DIR` writes a bundle on a
  host with network, planned from the device's facts (flags, or a dry
  run's `--device-report`), with every byte checked before it is written.
* `mix igniter.install precompiled --device` keeps the dependency
  at runtime so it ships in the firmware, and adds `castore` unless the
  project already depends on it.
* `:inets`, `:ssl` and `:public_key` are optional applications; `:crypto`
  stays required. A firmware without them installs from bundles only (an
  online call returns `{:error, {:missing_app, app}}`).
* `cacerts_path:` (an option of `Precompiled.install/2` and a `:device`
  config key) names a PEM CA bundle for a device install. Without one (and
  without `PRECOMPILED_CACERTS_PATH`/`HEX_CACERTS_PATH`),
  an empty or missing OS certificate store now falls back to the `castore`
  package's bundle when that is loaded. With no certificates at all the
  error now reads `no CA certificates` (before: `no CA certificate store on
  this system`), and an empty store is that error too, never a TLS attempt
  with no CAs.

* The host's check that an installed build is still intact is stricter
  about `priv`: a `priv` that is a copy rather than Mix's link to the
  dependency's sources (as on Windows, where links may be refused) no
  longer counts as intact, so such a build is installed once more.
* `enabled: false` disables `install/2` only: `list/1`, `uninstall/2`
  and `clean/1` keep working, so what is installed can still be removed.

## v0.1.0 - unreleased

* Any Mix project can use it: `mix precompiled.deps`, reached through a
  `deps.loadpaths` alias (`mix igniter.install precompiled` adds it),
  installs builds before Mix compiles dependencies in plain projects,
  umbrellas and Phoenix apps, and for Nerves with released nerves too,
  where only `pure_elixir` builds match: system (target) builds need the
  Nerves fork's `Nerves.build_plan/0` to name the system.
  `Precompiled.Host.run/1` for the nerves hook is unchanged. The Igniter
  installer sets the dependency `runtime: false`, `:source` in
  `config/config.exs` and the alias, prepended to an existing one; Igniter
  is an optional dependency, declared only on Elixir 1.18+.
* Never fails a build: any internal error is one warning and a source
  compile; no `HOME` or an unwritable cache moves the cache under `_build`.
* Warm runs make one conditional batch request (`If-None-Match`) and
  download nothing once the source answers `If-None-Match` with `304` (until
  then the batch itself is downloaded again; manifests and files still come
  from the cache); the root is checked at most once an hour; manifests are
  cached by SHA-256; files of a dependency download in parallel.
  `PRECOMPILED_OFFLINE=1` works from the cache; a run has a network
  deadline (`:deadline_seconds`, 300; root and batch 15 s). When the source
  cannot be reached, a cached batch that still passes every check is used;
  a refused response never falls back. A source that failed to connect is
  then not asked again in that run, so uncached manifests and files miss at once; a content
  origin that fails to connect is skipped for the run (the source still
  serves).
* Content origins: the signed batch (or `:content`) may name CDNs for files
  and manifests, with fallback to the source; every byte is still checked.
* An installed build is kept while the batch still offers its exact files,
  so a new portal run of the same inputs no longer recompiles the project.
* Install refuses colliding paths (duplicate, case or Unicode variants,
  `path collision: ...`), paths that are not plain relative paths inside
  the dependency's own build dir (`unsafe path or mode (...)`), `ebin/`
  entries other than beams, `<dep>.app` and `<dep>.appup`, such as another
  app's `.app` (`foreign path: ...`), and beams the `.app` does not list; linking happens before the install is renamed into place. A cache
  entry that is a symlink is never followed: that dependency compiles, and
  the line names the path to remove.
* Dependencies that read `Mix.target()` or environment variables at compile
  time are matched on them (README, rule 8).
* `nerves`' own dependencies are recognised from Mix's dependency data, so a
  git or path `nerves` keeps them out.
* `PRECOMPILED=0`, or no source configured, now removes installed
  builds (Mix compiles them in that run). Only the `_build` of the run's
  own env and target is touched: under Nerves a run on `host` removes the
  host installs, never a device target's.
* `mix precompiled.status` and `mix precompiled.clean [--cache]`; the cache
  is bounded (`:cache_max_mb`, 4096).
* A batch the source did not deliver is reported as
  `batch unavailable: <why>` (before: the bare reason); a delivered batch
  that fails a check is still reported by the check alone (`batch stale`,
  `batch signature invalid`, ...).
* Lower-case proxy variables, `NO_PROXY`, and a CA bundle
  (`PRECOMPILED_CACERTS_PATH` or `HEX_CACERTS_PATH`). The bundle
  replaces the OS store, as Hex's does: verification stays on and only its
  CAs are trusted.
* `PRECOMPILED_SOURCE` opts in without a config change; it wins over
  app config, an explicit `source:` option wins over it. An empty value
  counts as unset.
* `Precompiled.Host.install/2` on Elixir 1.17 and 1.18 installs into the
  dir `Mix.install/2` uses there (`elixir-<vsn>-erts-<vsn>`); before, its
  installs landed beside it and Mix compiled everything.
* CI runs Elixir 1.17 to 1.20.
* A batch issued more than 24 hours ago, more than 5 minutes in the
  future, valid for more than 30 days, or read against a local clock
  earlier than this library's build time, is refused; the run falls back
  to compiling, same as an expired or rolled-back batch.
* Every run, `Precompiled.Host.install/2` included, rechecks
  dependencies an earlier run installed (in a Mix project's `_build` or
  the `Mix.install/2` project) against the current batch: one the batch no longer names, or one newly listed in
  `:except`, is removed and compiled from source; one whose manifest
  changed is matched again. When
  no batch is available, installed builds are left as they are and one
  warning line says how many were kept, not rechecked (`report.json`
  still lists each as `fail`, `(installed build kept)`). Builds
  installed by an earlier version carry no provenance file and are
  rechecked only after `mix deps.clean --build` or a clean `_build`.
* Root rotation follows TUF: an intermediate root that expired after a
  newer one was adopted no longer ends the chain; only the root in use
  must be unexpired. Before, v1 -> v2 -> v3 fell back to v1 once v2
  expired, which with the version floor failed every run.
* The adopted root version is kept and never goes back (the error names
  the `root_version` file to delete to accept an older root); a trust-state
  file that exists but will not parse is warned about and treated as 0.
* On a device, the Nerves system is read from `/usr/lib/os-release`; the
  loaded-application lookup never matched because systems are `runtime:
  false`, so devices only got pure-Elixir hits.
* Extracted from nerves PR #1220: `Precompiled.Host.run/1` is the build-time
  step `nerves` calls; `Config`, `Match`, `Trust` and `Fetch` moved unchanged
  apart from their HTTP client and output.
* New: `Precompiled.Host.install/2`, `Mix.install/2` with the precompiled
  step in front of it, for use on a device.
* Config moved to `config :precompiled, source: ...`; the
  `config :nerves, :precompiled` form still works.
* On a device, a dependency already compiled in the `Mix.install/2` project
  is no candidate again: a second boot with a cached install re-places
  nothing and works offline. Builds this library installed there are
  rechecked against the batch, so such a boot fetches the root and batch.
* Every HTTP request has an overall deadline (300 s by default) on top of
  the inactivity timer, so a server that keeps dripping data cannot hold a
  build or a boot open.
* `precompiled` never installs a portal build of itself.
* Renamed to `precompiled`; old config keys and `NERVES_PRECOMPILED*`
  variables still work for one release.
* Reads manifest format 2: a version lists its builds, each with a target
  (`pure_elixir` or a Nerves system) and the toolchain it was made with.
  Format 1 manifests still work.
* Matching rules: the running Elixir must have the build's minor and at
  least its patch (pre-releases compare as older), the OTP major must be
  equal, and the dependency's compile env (`dep_env`, `prod` unless the
  project overrides it with `env:`) must equal the build's. Among passing
  builds the closest Elixir patch wins, then `pure_elixir`, then the newest
  run.
* `report.json` carries `"format": 1`.
* Ships as a Mix archive (`mix archive.install github
  TomHoenderdos/elixir_precompiled`) so Livebook and scripts can call
  `Precompiled.Host.install/2` in place of `Mix.install/2`; CI builds it.
* The file cache moved from `~/.nerves/precompiled` to the user cache dir
  (`:filename.basedir(:user_cache, "precompiled")`,
  `~/Library/Caches/precompiled` on macOS, `~/.cache/precompiled`
  on Linux). The old directory is not migrated, so the first run after
  upgrading downloads everything again; set
  `PRECOMPILED_HOME=~/.nerves/precompiled` to keep using the old one.
