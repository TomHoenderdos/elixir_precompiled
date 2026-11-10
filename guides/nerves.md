# Nerves

Either works:

- the alias from [Setup](setup.md#any-mix-project-plain-phoenix-libraries),
  as for any project. nerves_bootstrap prepends its own
  steps to the same alias, so the Nerves environment is set before ours
  runs;
- or the nerves `feat/precompiled` branch
  ([nerves-project/nerves#1220](https://github.com/nerves-project/nerves/pull/1220)),
  whose `nerves.init` calls this library itself:
  `{:nerves, github: "TomHoenderdos/nerves", branch: "feat/precompiled", runtime: false}`.
  With it, `mix nerves.info` repeats the last run. The hook it calls is
  `Precompiled.Host.run/1`; a fork built against the pre-rename module
  name must be updated to it.

Both together are fine: a second call in one Mix run reuses the first.

Builds made for a Nerves system need the fork: the system and its version
come from its `Nerves.build_plan/0`, which released nerves 1.x does not
have. With released nerves the alias still works, but only `pure_elixir`
builds match (rule 1 of [What matches](matching.md); rule 8 still applies) and every other
dependency compiles from source.

All of the above runs on the build host. To install on the running
device itself, from an IEx shell on it, see [On a device](device.md).
