# Changelog

## v0.1.0 - unreleased

* A batch issued more than 24 hours ago, more than 5 minutes in the
  future, valid for more than 30 days, or read against a local clock
  earlier than this library's build time, is refused; the run falls back
  to compiling, same as an expired or rolled-back batch.
* Every run, `ElixirPrecompiled.install/2` included, rechecks
  dependencies an earlier run installed (in a Mix project's `_build` or
  the `Mix.install/2` project) against the current batch: one the batch no longer names, or one newly listed in
  `:except`, is removed and compiled from source; one whose manifest
  changed is matched again. A warm build with precompiled dependencies
  already installed now fetches the root and the batch on every run. When
  no batch is available, installed builds are left as they are. Builds
  installed by an earlier version carry no provenance file and are
  rechecked only after `mix deps.clean --build` or a clean `_build`.
* The adopted root version is kept and never goes back; a trust-state
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
