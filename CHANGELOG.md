# Changelog

## v0.2.0 - unreleased

* `Precompiled.install/1,2` installs signed precompiled builds on a running
  Nerves device, without Mix: see the README's "On a device" section.
* `:inets`, `:ssl` and `:public_key` are optional applications; `:crypto`
  stays required.

## v0.1.0 - unreleased

* Any Mix project can use it: `mix precompiled.install`, reached through a
  `deps.loadpaths` alias (`mix igniter.install elixir_precompiled` adds it),
  installs builds before Mix compiles dependencies in plain projects,
  umbrellas and Phoenix apps, and for Nerves with released nerves too,
  where only `pure_elixir` builds match: system (target) builds need the
  Nerves fork's `Nerves.build_plan/0` to name the system.
  `ElixirPrecompiled.run/1` for the nerves hook is unchanged. The Igniter
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
  `ELIXIR_PRECOMPILED_OFFLINE=1` works from the cache; a run has a network
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
* `ELIXIR_PRECOMPILED=0`, or no source configured, now removes installed
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
  (`ELIXIR_PRECOMPILED_CACERTS_PATH` or `HEX_CACERTS_PATH`). The bundle
  replaces the OS store, as Hex's does: verification stays on and only its
  CAs are trusted.
* `ELIXIR_PRECOMPILED_SOURCE` opts in without a config change; it wins over
  app config, an explicit `source:` option wins over it. An empty value
  counts as unset.
* `ElixirPrecompiled.install/2` on Elixir 1.17 and 1.18 installs into the
  dir `Mix.install/2` uses there (`elixir-<vsn>-erts-<vsn>`); before, its
  installs landed beside it and Mix compiled everything.
* CI runs Elixir 1.17 to 1.20.
* A batch issued more than 24 hours ago, more than 5 minutes in the
  future, valid for more than 30 days, or read against a local clock
  earlier than this library's build time, is refused; the run falls back
  to compiling, same as an expired or rolled-back batch.
* Every run, `ElixirPrecompiled.install/2` included, rechecks
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
* Extracted from nerves PR #1220: `ElixirPrecompiled.run/1` is the build-time
  step `nerves` calls; `Config`, `Match`, `Trust` and `Fetch` moved unchanged
  apart from their HTTP client and output.
* New: `ElixirPrecompiled.install/2`, `Mix.install/2` with the precompiled
  step in front of it, for use on a device.
* Config moved to `config :elixir_precompiled, source: ...`; the
  `config :nerves, :precompiled` form still works.
* On a device, a dependency already compiled in the `Mix.install/2` project
  is no candidate again: a second boot with a cached install re-places
  nothing and works offline. Builds this library installed there are
  rechecked against the batch, so such a boot fetches the root and batch.
* Every HTTP request has an overall deadline (300 s by default) on top of
  the inactivity timer, so a server that keeps dripping data cannot hold a
  build or a boot open.
* `elixir_precompiled` never installs a portal build of itself.
* Renamed to `elixir_precompiled`; old config keys and `NERVES_PRECOMPILED*`
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
  `ElixirPrecompiled.install/2` in place of `Mix.install/2`; CI builds it.
* The file cache moved from `~/.nerves/precompiled` to the user cache dir
  (`:filename.basedir(:user_cache, "elixir_precompiled")`,
  `~/Library/Caches/elixir_precompiled` on macOS, `~/.cache/elixir_precompiled`
  on Linux). The old directory is not migrated, so the first run after
  upgrading downloads everything again; set
  `ELIXIR_PRECOMPILED_HOME=~/.nerves/precompiled` to keep using the old one.
