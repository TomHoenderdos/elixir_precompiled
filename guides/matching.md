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
| 6 | Dependencies | be compiled against the versions and checksums in your `mix.lock`, of dependencies Mix loads from Hex here | macros and inlined code from dependencies are baked in |
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

**Rule 6, dependencies.** Three parts:

- every dependency the build was compiled against is in your `mix.lock`,
  at the same version and checksum;
- every one of them, and the package itself, is a dependency Mix loads
  from Hex in your project, with that same lock entry. One Mix loads from
  a path or git here misses with `built against NAME VERSION from Hex, not
  the NAME Mix loads here`. This holds also when `mix.lock` still has its
  old Hex entry: after you change a dependency to `path:` or `git:` with
  `override: true`, `mix deps.get` keeps that entry, and Mix compiles the
  package against your fork;
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
loads from a path or git (`path:` or `git:` with `override: true`) is in
no build, so every build of a package that has it in its tree misses,
whatever entry the lock has for it. Versions and checksums are still
compared against the lock.

`Precompiled.Host.install/2` makes the same whole-tree comparison. It
reads the tree from the dependencies Mix loads in the project
`Mix.install/2` then uses, from the same lock and for the same env:
the tree `Mix.install/2` compiles. With the `lockfile:` option, that lock
is merged into the install project first, as `Mix.install/2` merges it.
A Hex entry the merged lock has for a dependency your install loads from
a path or git makes no candidate of it, and every build of a package that
has it in its tree misses, as in a Mix project.
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
- A Nerves system build records them too when its package reads one at
  module level in `lib/` (circuits_i2c's `CIRCUITS_I2C_I2CDEV`, which its
  `mix.exs` sets from `CROSSCOMPILE` and the `:default_backend` config).
  A variable whose value holds where the Nerves toolchain or system sits
  (`CROSSCOMPILE`) is compared with those two paths left out: your value,
  with your `NERVES_TOOLCHAIN` and `NERVES_SYSTEM` paths cut out, must be
  the build's with its own cut out. A `Mix.target()` read must have been
  made for your target. A device cannot check either and never matches.
- A build whose compile read the whole environment (`System.get_env/0`),
  or whose compile-time config reads could not all be recorded, never
  matches.
- 0.9.0: a build whose compile asked whether a module or an application is
  there (`Code.ensure_loaded?(Poison)`, `Application.spec(:phoenix_html)`,
  `Code.ensure_loaded?(:wx)`), where the builder had nothing that supplies
  it, records the question as a `probe` input. Mix answers "present" for
  you when a dependency compiled before it defines the module (its modules
  stay loaded), when `Mix.install` has it on its unpruned code path, or
  when your code path holds it (an archive, your OTP, an editor's VM such
  as ElixirLS). So the build matches only when your project cannot supply
  it either:
  - a module: no dependency Mix loads in this env and target (every lock
    entry, when the dependencies did not load) is a package the portal
    knows defines it, no dependency outside the build's
    own closure defines it in its sources, and your code path has no beam
    of it. Otherwise `built where Poison is absent; poison can supply it
    here` (`probe_definer`). The sources, and each dependency's `mix.exs`,
    are read without compiling them: every literal `defmodule`,
    `defprotocol` and `defimpl` name, through nesting and aliases, a module
    another macro may define from a literal alias (`defenum Name`,
    `defmock(Name, ...)`, an inline `embeds_one :x, Name do`), each
    implementation an `@derive` defines, every `-module` of an Erlang file,
    and each leex and yecc file's name. A module loaded in this VM counts
    too. A file that names the module and defines a module
    under a name it computes (a `defmodule` of anything but a literal
    alias, one inside a `quote`, `Module.create/3`, a `Code` compile or
    eval call), a symlink, a file that does not parse or a dependency
    whose dir cannot be read means this client cannot tell:
    `... cannot tell whether this project supplies it` (`probe_unknown`);
  - an application: no dependency of your project is that application, and
    your code path and your OTP and Elixir install hold no `.app` of it
    (`probe_definer`);
  - an OTP application no package of the build lists (vega_lite's `:wx`):
    it is not installed here at all (`built where OTP application wx is
    absent; it is installed here`, `probe_otp_app`).

  Under `Precompiled.Host.install/2` your project is the install's: its
  lock, its dependencies and its `deps` dir. A device cannot check the
  project its firmware was compiled in, and never takes such a build.
  What this cannot see: a dependency outside the build's closure that
  builds the module's name from parts no file naming its last segment
  shows, in a release the portal does not list as a definer.
- A build made before builds recorded their inputs has none: for it, a
  dependency that reads an environment variable at module level in `lib/`
  never matches, as before.
- A dependency whose sources can't be scanned never matches: they don't
  parse, or a file is over 2 MB, or the package over 20 MB.
- Some settings on your machine change every compile, of any
  dependency, and no build records them, so while one is in place
  nothing matches (`... can change every compile`):
  - `ERL_COMPILER_OPTIONS` set to anything but blanks or exactly
    `deterministic`. The Erlang compiler adds it to every `.erl` file Mix
    or rebar3 compiles, and Elixir adds it (without `warnings_as_errors`)
    to every module it compiles, so pure Elixir packages differ too. It is
    read as OTP reads it, so `deterministic` and `[deterministic]` are the
    same value; anything else (another option beside it, a repeat, a value
    that does not parse) misses as `... is set to options other than
    exactly deterministic ...`. With exactly `deterministic` (what
    nerves_livebook, Nix's `buildMix` and Guix set) only builds the portal
    compiled with that option are taken, from a version's `deterministic`
    list, judged by every other rule as usual; a version that has builds
    but none of those misses as `no ERL_COMPILER_OPTIONS=deterministic
    build of VERSION yet` (`deterministic_not_built`). A project without
    the option never takes one of those builds.
    Elixir 1.18 and later read the variable once per VM, on its first
    compile (`mix.exs` itself), and compile every later module with that
    value, while rebar3 and `compile.erlang` read it afresh. So it must be
    set before Mix starts or in `mix.exs` outside any function, as
    nerves_livebook does: set later (in `project/0`, `config/config.exs`)
    or cleared, every dependency misses as `ERL_COMPILER_OPTIONS changed
    after this VM's first Elixir compile, ...`.
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
  from your config and the order `mix deps.compile` uses in your project
  (under `Mix.install/2`, in its install project, with its `:config` and
  `:config_path`), and misses with `compile-time config APP KEY would differ in this
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

## Host-native builds (opt-in)

With `config :precompiled, host_native: true`, a project on a Linux
glibc host, x86_64 or aarch64, that is no Nerves target also considers a
version's host-native builds, after every other build missed: a NIF
package's beams and `.so` files built together for one triple
(`x86_64-linux-gnu`, `aarch64-linux-gnu`, read from
`:erlang.system_info(:system_architecture)`). Such a build is
ABI-compatible with your machine, not the bytes your own compile would
produce, which is why it is opt-in. It installs only when every rule
above but the target holds, and also:

- it was made for your machine's triple, with glibc (musl and macOS hosts
  have no triple, and miss);
- its OTP major is yours and its full OTP version no newer than yours;
- its NIF version is no newer than your VM's;
- every library its `.so` files need is found on your machine
  (`ldconfig -p`, then the `/lib64`, multiarch and `/lib` dirs), for your
  machine's architecture, and defines every symbol version they need;
- its `.so` files are ones the package downloads from its upstream
  release (as rustler_precompiled packages do), from an archive the
  package's own checksum file in `deps/` lists with the same sha256. The
  file is read as data, never run. A `.so` the build compiled itself is
  never used: its compiler flags may have assumed the builder's CPU.

A Nerves project, and a device, never read host-native builds.

## Foreign priv builds (Kino.JS writers)

A few packages write into another package's build dir when they compile:
a module that uses `Kino.JS` with `assets_path:` packs its assets into an
archive under kino's `priv`, `_build/<env>/lib/kino/priv/assets/<d>/<h>.tar.gz`,
where `<d>` is the module's name with every `.` replaced by `_`
(`Kino.VegaLite` gives `Kino_VegaLite`). The portal serves such a build
only for the one pattern it reviewed (rule `kino_js_v1`, kino 0.19.1),
under a version's `foreign_priv` object, which clients before 0.8.0 never
read. kino's own builds are listed there too, so an older client compiles
kino from source rather than install one that would lose those archives.

The object holds the same lists as the version (`builds`,
`builds_with_inputs`, `builds_closure`), and inside `deterministic` its
own. It is read only after the regular builds, and the host-native ones,
missed, in the same mode: a project that sets
`ERL_COMPILER_OPTIONS=deterministic` reads only the one inside
`deterministic`, and `builds_closure` is read only where the dependency
closure is known, as for the regular lists. Every rule above applies. A
build there that places archives (kino's own place none) must also pass,
before anything is downloaded:

- its rule is one this client knows (`kino_js_v1`), else
  `foreign_priv_rule_unknown`;
- every archive is for kino, at a path of exactly that shape, mode 0644,
  in the directory of one of the build's own modules, one archive per
  directory, at most 64 of them and 10 MiB in all, else `malformed entry`.

A build there without archives is taken only as kino's own (it names
kino as its `foreign_priv_target`); for any other package it is a
`malformed entry`, and so is a kino build there that places archives.

The writer is then installed after every other dependency of the run,
writers one at a time by name, and only into a kino that nothing later in
this run removes:

| kino in this run | The writer |
| --- | --- |
| installed or kept precompiled, or already compiled by Mix and current | HIT: `...; 1 archive into kino` |
| compiles from source (a miss, `:except`, a revoked build, or not yet compiled) | MISS `writes into kino's priv; kino compiles from source in this run` |
| its `priv` links to its sources | MISS `writes into kino's priv, which links to its sources` |
| not in the build | MISS `writes into kino's priv; kino is not in this build` |

It also misses, `writes kino's priv/assets/<d>, which <app> also claims`,
when another writer of the run, kino's own modules or any other
dependency's `.app` in the build has a module for the same directory;
two writers of one directory both miss. On a miss an installed writer is
removed, so Mix compiles it, after kino, and its compile writes its own
archive. Only `priv/assets/<d>` for a `<d>` being placed is ever removed
under kino's build dir, as Kino.JS removes it itself; a failure there is a
FAIL, and Mix compiles the writer.

The same holds for an installed writer this run cannot recheck (no fresh
batch, or its manifest out of reach) and so keeps as it is: it is kept
only while kino ends the run's installs settled as above and the archives
its install recorded are on disk, placed again from the cache when they
are not. Otherwise it misses and is removed, so a kino removed or
reinstalled in the same run never leaves it without its archives.

Every run checks an installed writer's archives on disk, not only when its
manifest changed: each `priv/assets/<d>` must hold exactly its archive.
When it does not (Mix recompiled kino, which wipes its build dir), the
archive is placed again from the cache, without reinstalling the writer.
Replacing kino keeps the `priv/assets/<d>` its new build does not ship
(archives of Mix-built writers, of installed ones and of your project's
own modules), and removing kino (a revoke, `:except`, `PRECOMPILED=0`,
`mix precompiled.clean`) first marks each Mix-built dependency whose
archive was in it, so Mix recompiles it after kino: it removes both of
Mix's marks of a compiled dependency, `.mix/compile.elixir_scm` (read from
Elixir 1.19 on) and `.mix/compile.fetch` (read by 1.17 and 1.18).

A device never installs a foreign priv build: `writes into kino's priv at
compile time; not installed on a device`.

## Relocated builds (paths in the beams)

Some packages keep the path they were compiled at in their beams: fine's
`Fine.include_dir/0` returns `Path.expand("c_include")` from fine's own dir,
a `__DIR__` literal names the source dir, a path into the build's `priv` is
taken at compile time. A byte copy of such a build would hold the portal
builder's path, not yours. The portal builds such a package again at two
more roots, unlike the first and each other in length, depth, case, spaces,
the project dir's name and the order of the deps and build paths, and keeps
it only when the three builds differ in those paths alone. It lists it under
a version's `relocated` object, which clients before 0.9.0 never read, with
a record of where each path sits: the builder's deps and build paths, the
other two builds', and per beam every occurrence (a literal, an atom, an
attribute, a line-table file name).

A package that depends on such a build is proven the same way, at the same
three roots, and listed there too: its own beams often hold no path
(the record names no file to rewrite), but what its compile took from the
dependency was only proven at those roots, so every rule below holds it.
The roots' layout is fixed: a record at any other roots is refused, and a
portal that changed it would need a new record version.

The object holds the same lists as the version (`builds`,
`builds_with_inputs`, `builds_closure`). It is read last, after the regular,
host-native and foreign priv lists missed, and never in deterministic mode
(a relocated build has no deterministic sibling). Every rule above applies,
then these, before anything is downloaded:

- OTP 28 or later (`relocated_otp`): OTP 27 compresses the literal table,
  which the rewrite does not read;
- this project's deps path and build path (`Mix.Project.deps_path/0` and
  `build_path/0`, so also `MIX_DEPS_PATH`, `MIX_BUILD_PATH`, an umbrella's
  `deps_path:` and `Mix.install/2`'s dir) are absolute, normalised and real
  all the way down, no symlink in either, on a unix host (`relocated_paths`);
- each is printable ASCII (`relocated_path_ascii`): the builder's are, and
  a path with other bytes has more than one byte form a compile could take;
- each component is spelled exactly as its parent dir lists it, byte for
  byte (`relocated_path_spelling`): Mix compiles a dependency after a cd
  into its dir, so `__DIR__` holds the spelling on disk, which a volume that
  ignores case (macOS by default) lets differ from the spelling Mix was
  given;
- each lies inside the envelope of the builder's three roots
  (`relocated_path_envelope`): its characters among theirs, its length and
  depth between their shortest and longest, shallowest and deepest;
- the record's three roots are the builder's own, as this library ships
  them, and it names beams of the entry's own `ebin`, well formed, each
  build path in it followed by Mix's own layout under a build path: nothing,
  `/consolidated/...`, or `/lib/<app>/` and then `ebin`, `priv`, `include`
  or `.mix`, `<app>` the package or one of its locked dependencies
  (`relocation_refused`).

At install, after every served file is verified, the client requires each
beam to have been compiled from the package's own dir under the record's
deps path (its `CInf` source), derives each beam's occurrences of the
builder's paths itself and requires them to be the record's (and each build
path in them followed by Mix's layout), finds none in any other file of the
entry, and rewrites each
occurrence to your paths exactly as your own compile would have written it:
a literal re-encoded by this VM, an atom or file name in place, the module's
md5 taken as this OTP takes it (`beam_lib:md5/1`), each fun's `old_uniq` and
a default `vsn` from it. Anything it cannot do so is `relocation_refused`,
and nothing is installed. The install's provenance records the rewritten
files' hashes with the paths they were rewritten to. A later run keeps the
install while your paths are those; a moved project installs it again,
relocated to its new paths.

A device never installs a relocated build, and a relocation record in any
list but `relocated` is a `malformed entry`.

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
closest build broke, then that build:

```
precompiled: telemetry_poller 1.1.0       MISS  built with Elixir 1.20.3, running 1.20.1; closest build 5ccaf59fba70: Elixir 1.20.3/OTP 28
```

The closest build is the one that got furthest through the rules before
one broke (of a tie, the one made on the release closest to the project's, then the first listed). It is named by the first 12
characters of its files hash, then, where the manifest says, its variant,
its toolchain, its system and release, and how its dependency closure
differs from the one Mix compiles the package with here:

* the variant is a world build's own (`world_phx`), else `with` or
  `without` the package's optional dependencies, for a package that
  declares any;
* in `closure +a -b`, `+a` is a dependency the build was made with that
  Mix leaves out here, `-b` one Mix compiles the package with that the
  build lacks (at most three of each, then `+N more`).

A `HIT` line names the build it installed the same way, after its size:
`HIT  4.1 MB; build 3f2a9c01b7de: without, Elixir 1.20.0/OTP 28`.

Only manifest values and dependency names are printed, each limited to
letters, digits and `_ . + : -` (anything else prints as `?`). Nothing
from your environment is. The closest build is part of the line only: a
report (`mix precompiled.report`) sends the reason's code and arguments,
which it does not change.
