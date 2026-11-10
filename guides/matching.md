# What matches

`precompiled` installs a build only when it is certain the build is what
Mix would have compiled for your project. Anything less, and the
dependency simply compiles as usual. This page lists exactly what
"certain" means.

## Which dependencies are considered

A dependency is a **candidate** when all of these hold:

- it comes from Hex (a git or path dependency never is);
- it is not Nerves tooling: `nerves`, its own dependencies,
  `nerves_system_*`, `nerves_toolchain_*`, `nerves_bootstrap`, or
  `precompiled` itself;
- it is not listed in `:except`.

## The rules

A build of a candidate is installed only when **every** rule holds.

| # | Rule | The build must… | Why |
| --- | --- | --- | --- |
| 1 | Target | be `pure_elixir`, or be made for your Nerves system at the exact system version in `mix.lock` | native code only runs where it was built for |
| 2 | Elixir | have the same major.minor as your Elixir, and a version no newer than yours | compiled Elixir runs forward within a minor, not backward |
| 3 | OTP | have the same OTP major | record layouts from OTP headers are inlined at compile time |
| 4 | Dependency env | be compiled in the env the dependency compiles in here (`prod`, unless your `deps` entry sets `env:`) | env changes what gets compiled |
| 5 | Checksum | have the package checksum in your `mix.lock` | it is the exact same release |
| 6 | Dependencies | be compiled against the versions and checksums in your `mix.lock` | macros and inlined code from dependencies are baked in |
| 7 | `compile_env` | have read the same `Application.compile_env` values as your config | those values are baked into the beams |
| 8 | Compile-time inputs | not depend on build-machine facts it can't record (see below) | otherwise it could differ from your build |
| 9 | Build method | be built the way Mix builds the dependency here: no declaration of it (yours or a package's) sets any of `:manager`, `:compile` or `:system_env`, and a manager the build records is the one Mix uses here | an override, or another manager, builds other files |

### The fine print

**Rule 2, versions.** Versions compare as versions:

- a build from Elixir 1.20.1 is served to 1.20.3, not the other way round;
- a 1.21.0-rc.0 build is served to 1.21.0;
- a 1.21.0 build is *not* served to 1.21.0-rc.0.

**Rule 6, dependencies.** Two directions:

- every dependency the build was compiled against is in your `mix.lock`,
  at the same version and checksum;
- every dependency the package declares (optional ones included) that
  your lock has was also in the build. A build made *without* an optional
  dependency you have would lack that integration.

**Rule 8, compile-time inputs.**

- A dependency whose own sources read `Mix.target()` at compile time
  (at module level in `lib/`, or anywhere in `mix.exs`) gets no
  `pure_elixir` build on a device target. It gets a system build only when
  that build was made under your target name: the recorded one, or else
  the system's conventional one (`nerves_system_rpi4` → `rpi4`).
- A dependency that reads an environment variable at module level in
  `lib/` never matches.
- A dependency whose sources can't be scanned never matches: they don't
  parse, or a file is over 2 MB, or the package over 20 MB.

Not covered by rule 8, because builds record neither:

- environment variables read in a dependency's `mix.exs`;
- `Application.get_env` in a module body (Elixir already warns about it).

Such a dependency can be served a build made with other values.

**Rule 9, build method.**

- A dependency declared with `:manager`, `:compile` or `:system_env` never
  matches; the line names the option, for example
  `project sets :manager for this dependency`. This holds wherever Mix finds
  the option: your `deps` entry, the deps list given to
  `Precompiled.Host.install/2`, or the `mix.exs` of a package that depends
  on it.
- A build records the manager Mix built it with (`mix`, `rebar3`, `make`,
  ...). When that is not the manager Mix resolves for the dependency in your
  project, it misses: `built with rebar3, project builds with make`. A build
  that records no manager is judged by the other rules alone.
- A global `Mix.install(deps, system_env: ...)` (also through
  `Precompiled.Host.install/2`) is not an override of any one dependency
  and does not cause a miss. It is the same as setting those variables in
  your shell, which no rule records: builds are made in a clean
  environment, and a dependency whose compile-time output depends on
  environment variables is a [known limitation](limitations.md#matching).
- When `Precompiled.Host.install/2` cannot load the dependencies through
  Mix, how they are built is unknown: every dependency misses with
  `build method unknown (deps did not load: ...)`, after one warning.
- `Precompiled.Host.install/2` applies rule 9 wherever it runs, a device
  included. The device API, `Precompiled.install/2`, does not: it has no
  `deps` options and no manager to compare, and takes the build Mix makes by
  default.

## When several builds match

The first that applies wins:

1. the build that is already installed (its bytes stay as they are);
2. the build made on your exact Elixir patch;
3. the closest older patch;
4. `pure_elixir` before a system build;
5. the newest run.

## When nothing matches

The dependency compiles from source, and its line names the rule that the
closest build broke:

```
precompiled: telemetry_poller 1.1.0       MISS  built with Elixir 1.20.3, running 1.20.1
```
