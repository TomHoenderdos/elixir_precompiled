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
