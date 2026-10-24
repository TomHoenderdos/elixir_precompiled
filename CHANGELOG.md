# Changelog

## v0.1.0 - unreleased

* Extracted from nerves PR #1220: `NervesPrecompiled.run/1` is the build-time
  step `nerves` calls; `Config`, `Match`, `Trust` and `Fetch` moved unchanged
  apart from their HTTP client and output.
* New: `NervesPrecompiled.install/2`, `Mix.install/2` with the precompiled
  step in front of it, for use on a device.
* Config moved to `config :nerves_precompiled, source: ...`; the
  `config :nerves, :precompiled` form still works.
