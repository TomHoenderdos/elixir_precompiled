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
| 1 | Target | be `pure_elixir`, or be made for your Nerves system: on the system version in `mix.lock`, or on another release of that system that provides what the build needs (see below) | native code only runs where its libraries, toolchain and OTP are |
| 2 | Elixir | have the same major.minor as your Elixir, and a version no newer than yours | compiled Elixir runs forward within a minor, not backward |
| 3 | OTP | have the same OTP major | record layouts from OTP headers are inlined at compile time |
| 4 | Dependency env | be compiled in the env the dependency compiles in here (`prod`, unless your `deps` entry sets `env:`) | env changes what gets compiled |
| 5 | Checksum | have the package checksum in your `mix.lock` | it is the exact same release |
| 6 | Dependencies | be compiled against the versions and checksums in your `mix.lock` | macros and inlined code from dependencies are baked in |
| 7 | `compile_env` | have read the same `Application.compile_env` values as your config | those values are baked into the beams |
| 8 | Compile-time inputs | have read the same environment variables your environment gives, and not depend on build-machine facts it can't record (see below) | otherwise it could differ from your build |
| 9 | Build method | be built the way Mix builds the dependency here: no declaration of it (yours or a package's) sets any of `:manager`, `:compile` or `:system_env`, a manager the build records is the one Mix uses here, and, for a rebar3 dependency, your global rebar3 config changes nothing it compiles | an override, another manager, or a global rebar3 config builds other files |

### The fine print

**Rule 1, another release of your system.** A build made for your Nerves
system, but on another release of it (say `nerves_system_rpi4` 2.1.0
while your `mix.lock` has 2.2.0), can still stand in. Which ones can
depends on what is in the build:

- **Beam-only builds** (no native code) are used on any release of the
  system. Beams do not depend on the system's libraries or toolchain.
  The one exception is a dependency whose sources read the Nerves system
  at compile time (`Nerves.Env`), which can bake the system's version or
  settings into its beams: it misses with
  `reads the Nerves system at compile time`, and gets only a build made
  on your exact release.
- **Builds with native code** (NIFs, ports) are used on another release
  only when the build's native files are ordinary shared objects or
  executables, and your release, as the batch's systems table describes
  it, has everything they were linked against:
  - **Toolchain.** The same Nerves toolchain package, in the same
    `major.minor` series (toolchain 15.3.1 and 15.3.2 are both series
    15.3; 15.4.0 is not). Within a series the compiler and C library
    keep their ABI.
  - **OTP.** The same OTP major, and the OTP the build was made on no
    newer than your release's: OTP 28.1.0 code runs on OTP 28.2.0, not
    the other way round. Versions compare part by part, so 27.3.4.1 is
    older than 27.3.4.3.
  - **Libraries.** Every shared library the native code needs (its
    `DT_NEEDED` entries, such as `libc.so.6` or `libstdc++.so.6`) is in
    your release.
  - **Symbol versions.** Every versioned symbol it needs from those
    libraries (`GLIBC_2.38`, `GLIBCXX_3.4.32`, `OPENSSL_3.0.0`) is
    defined there by that exact name. A library keeps every older
    version it ever defined, so a newer library still provides them.
    Names that carry no version number, such as `GLIBC_PRIVATE`, are
    not checked.

  A native build that does not record which libraries it needs (one
  made before that was recorded) is used on its own release only, and
  misses elsewhere with `build predates elf`.
- **Anything else** is used on its own release only. That includes a
  build whose native files are something other than shared objects or
  executables (a kernel module, an object file), and any build made
  before the portal recorded what is in it.

When your release is not in the systems table yet, or its libraries
have not been recorded, only builds made on that exact release match
(`... not yet known to the portal`). The portal records a new release
of a system soon after it appears. Without a systems table in the batch
(an older source), every system build needs your exact release, as
before.

On a device, the same rules choose the build, using the systems table,
and then the device checks its own libraries too: see
[On a device](device.md#what-it-refuses) and below.

**Rule 2, versions.** Versions compare as versions:

- a build from Elixir 1.20.1 is served to 1.20.3, not the other way round;
- a 1.21.0-rc.0 build is served to 1.21.0;
- a 1.21.0 build is *not* served to 1.21.0-rc.0.

**Rule 6, dependencies.** Two directions:

- every dependency the build was compiled against is in your `mix.lock`,
  at the same version and checksum;
- on your build machine, the build was compiled with exactly the
  dependencies Mix compiles the package with in your project, at any
  depth: its whole dependency tree for the current `MIX_ENV` and
  `MIX_TARGET`, optional dependencies included. One the build lacks
  misses with `built without NAME, ...`: it would lack that integration.
  One Mix leaves out here misses with `built with NAME, which Mix leaves
  out of it in this env`: it would have an integration your own compile
  would not.

The tree is what Mix loads, not everything in `mix.lock`. The lock is
shared by every env: a project that declares
`{:lazy_html, ">= 0.1.0", only: :test}`, as `phx_new` does, has lazy_html
in its lock in dev and prod too, yet Mix gives `phoenix_live_view` (which
lists it as optional) no lazy_html there. So in dev and prod the build
without lazy_html matches, and in test the one with it; the same holds for
a package that gets lazy_html further down its tree. A dependency Mix
loads but the lock has no Hex entry for (a path dependency with
`override: true`) is in no build, so every build of a package that has it
in its tree misses. Versions and checksums are still compared against the
lock.

`Precompiled.Host.install/2` makes the same whole-tree comparison. It
reads the tree from the dependencies Mix loads in the project
`Mix.install/2` then uses, from the same lock and for the same env:
the tree `Mix.install/2` compiles. With the `lockfile:` option, that lock
is merged into the install project first, as `Mix.install/2` merges it.
An optional dependency your install brings in counts as present at any
depth; one it has only for another env (`{:lazy_html, ">= 0.1.0", only:
:test}` in a script run in dev) does not. When Mix cannot load those
dependencies, every dependency misses on rule 9 (`build method unknown`,
below). When Mix loads them but the tree is not in the shape the client
reads (a Mix release that changed it), the lock decides instead: every
dependency the package declares (optional ones included) that the lock
has must have been in the build, and dependencies further down are
compared only by version and checksum.

Some builds are made with a common app's optional dependencies added at
every depth of the package's tree, so they match such an app as it is
(the portal calls them world builds, and publishes them under
`builds_closure` in the manifest). They are considered only where the
client has read the dependency tree: on your build machine in a Mix
project, and under `Precompiled.Host.install/2`. Only the whole-tree
comparison above can tell that such a build is the one Mix would make.
Where the lock decides instead, they are never considered. The device API,
`Precompiled.install/2`, never considers them either. The rule holds for
every release that reads `builds_closure`: one reads it only if it
compares the whole tree. Releases before 0.7.0 do not read it at all.

**Rule 8, compile-time inputs.**

- A dependency whose own sources read `Mix.target()` at compile time
  (at module level in `lib/`, or anywhere in `mix.exs`) gets no
  `pure_elixir` build on a device target. It gets a system build only when
  that build was made under your target name: the recorded one, or else
  the system's conventional one (`nerves_system_rpi4` → `rpi4`).
- A build records the environment variables its compile read
  (`compile_inputs`), in `lib/` and in `mix.exs` alike, with the value it
  saw. It matches only when your environment gives the same value, unset
  or set: otherwise `built with a different NAME`. Your value is compared,
  never printed or reported.
- A variable the build set itself (`System.put_env` in a `mix.exs`, then
  read in `lib/`) is not compared: its value follows from inputs the build
  recorded. When those inputs could not be recorded, it is a miss like any
  other differing variable.
- A build whose compile read the whole environment (`System.get_env/0`),
  or whose compile-time config reads could not all be recorded, never
  matches.
- A build made before builds recorded their inputs has none: for it, a
  dependency that reads an environment variable at module level in `lib/`
  never matches, as before.
- A dependency whose sources can't be scanned never matches: they don't
  parse, or a file is over 2 MB, or the package over 20 MB.
- Some settings on your machine change every compile, of any
  dependency, and no build records them, so while one is in place
  nothing matches (`... can change every compile`):
  - `ERL_COMPILER_OPTIONS` set to anything but blanks. The Erlang
    compiler adds it to every `.erl` file Mix or rebar3 compiles, and
    Elixir adds it (without `warnings_as_errors`) to every module it
    compiles, so pure Elixir packages differ too.
  - `ERL_LIBS` set to anything but blanks. Every app under it is on the
    code path a dependency's `mix.exs` and compile can probe: Mix prunes
    it only partly and late, and not at all under `Mix.install/2`.
  - `ERL_FLAGS`, `ERL_AFLAGS`, `ERL_ZFLAGS` or `ELIXIR_ERL_OPTIONS` with an argument that can
    set it, run code or change the code loaded: `-env`, `-eval`, `-s`,
    `-run`, `-S`, `-pa`, `-pz`, `-path`, `-boot`, `-boot_var`,
    `-code_path_choice`, `-args_file`, `-config`, `-extra`, or app env
    for `compiler`, `elixir`, `mix` or `stdlib`. Other flags, such as
    `-kernel shell_history enabled` or `+S 4`, are fine.
  - A `.erlang` file in your home directory or in Erlang's user config
    directory (`~/.config/erlang`, `~/Library/Application Support/erlang`
    on macOS). Every Erlang start runs it, `mix` included. A home whose
    contents cannot be read misses too.

  The line names the variable or file, never its value.

- `Application.get_env` in a module body for an unset key of an app
  outside the dependency's own tree (Elixir already warns about it): what
  it sees depends on whether that app compiled first. The build records
  what it saw and the app's `.app` default. The client predicts the value
  from your config and the order `mix deps.compile` uses in your project,
  and misses with `compile-time config APP KEY would differ in this
  project` when they differ. It predicts a clean compile: an incremental
  compile, or an app installed precompiled, does not load that app's
  `.app`, so it can differ from what the prediction assumes.
- A rebar3 dependency's `platform_define` in `erl_opts` defines its macro
  only when its regex matches rebar3's arch string: the OTP version, the
  system architecture and the word size, such as
  `28.1.1-aarch64-apple-darwin24.6.0-64`. A build records each such regex
  with whether it matched on the build machine. The client computes the
  arch string as rebar3 does and matches every regex against it; when a
  verdict differs, or a regex cannot be evaluated here, it misses with
  `rebar3 platform_define REGEX decides differently on this machine`. The
  line names the regex, never your arch string. Firmware is compiled on
  your build machine, so this check runs there. A device cannot make it
  and misses (see below).

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
- A dependency Mix builds with rebar3 (or whose build records rebar3)
  also depends on your global rebar3 config. rebar3 merges
  `~/.config/rebar3/rebar.config` (under `REBAR_GLOBAL_CONFIG_DIR`
  instead of your home when that is set) into every compile Mix runs it
  for, so its `erl_opts` (a `{d, 'DEBUG'}`, `native`), `overrides`,
  hooks, plugins, or the same keys under its `prod` or `default` profile
  change the beams. While that file sets any key other than ones only
  other rebar3 commands read (`hex`, `dialyzer`, `relx`, `ct_opts`,
  `eunit_opts`, `edoc_opts`, `xref_*`, `cover_*`, `escript_*`, `alias`,
  `shell`, `dist_node`, `project_plugins`, `rebar_packages_cdn`, other
  profiles), every rebar3 dependency misses with
  `global rebar3 config PATH sets KEY`. The line names the file and the
  key, never the value. A file that does not parse misses too
  (`... could not be read`), as does one whose directory cannot be
  searched (`... could not be checked`), as does one with a `rebar.config.script`
  beside it (`... has a .script beside it`). `REBAR_CONFIG` plays no part:
  Mix points it at its own file for every rebar3 compile. Dependencies
  Mix compiles itself are not affected. Firmware is compiled on your
  build machine, so this check runs there; the device API installs builds
  without compiling anything, so no rebar3 config is involved.
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

First the release: among the system builds that pass, only those made
on the release closest to yours are kept:

1. your exact system version;
2. else the highest version below yours;
3. else the lowest version above it.

`pure_elixir` builds count as made on your exact version. Then the first
of these that applies wins:

1. the build that is already installed (its bytes stay as they are);
2. the build made on your exact Elixir patch;
3. the closest older patch;
4. `pure_elixir` before a system build;
5. the newest run.

An installed build is preferred only among the builds of the closest
release: when a build for a closer release appears, it replaces the
installed one.

## Every run checks again

Builds already installed are matched again on every run, against the
current batch and your project as it is now. When you move your project
to another release of its system, a build installed for the old one is
kept only if it still matches; otherwise it is removed, the line says
why (for example `built for nerves_system_rpi4 2.1.0 (toolchain 15.3),
project has 2.3.0 (toolchain 15.4)`), and the dependency compiles from
source.

## On a device

`Precompiled.install/2` chooses builds by the same rules and the same
release order. Before it installs any build with native code, for your
exact release or another one, it also looks up every library the build
needs in the device's own `/lib` and `/usr/lib`, and checks the symbol
versions there. (A build for your exact release made before builds
recorded their libraries has nothing to check, and installs as before.) The systems table describes the release as built; this
check describes the device as it is running. A build that needs
something the device lacks is refused.

One difference: the device has no dependency sources to scan, so it
cannot tell whether a beam-only build's dependency reads the Nerves
system at compile time. On a device, a beam-only build made on another
release of your system is accepted without that check. On your build
machine the check does run.

A device has no build environment of your firmware to compare with. A
build whose compile read an environment variable that was unset at build
time is accepted; one built with it set misses, and the line names the
variable: `built with CI set at compile time; a device cannot check its
firmware's build environment`.

A device has no compile order either. A build whose dependency read an
unset config key of an app outside its tree matches only when that app's
`.app` gives the key no default and the device's config gives the value
the build saw, whether or not that app is installed on the device. Otherwise it misses with `compile-time config APP KEY would
differ in this project`.

A build that records rebar3 `platform_define` verdicts misses on a
device too, naming the regex: the verdicts depend on the machine your
firmware was compiled on (a Mac defines a `darwin` macro a Linux builder
does not), which the device cannot know, and the device's own
architecture is not the one rebar3 saw.

## When nothing matches

The dependency compiles from source, and its line names the rule that the
closest build broke:

```
precompiled: telemetry_poller 1.1.0       MISS  built with Elixir 1.20.3, running 1.20.1
```
