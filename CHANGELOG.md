# Changelog

## v0.1.0 - unreleased

* Extracted from nerves PR #1220: `ElixirPrecompiled.run/1` is the build-time
  step `nerves` calls; `Config`, `Match`, `Trust` and `Fetch` moved unchanged
  apart from their HTTP client and output.
* New: `ElixirPrecompiled.install/2`, `Mix.install/2` with the precompiled
  step in front of it, for use on a device.
* Config moved to `config :elixir_precompiled, source: ...`; the
  `config :nerves, :precompiled` form still works.
* On a device, a dependency already compiled in the `Mix.install/2` project
  is left to Mix: a second boot with a cached install fetches nothing and
  re-places nothing, and works offline.
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
