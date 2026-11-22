# Changelog

## v0.9.1 - 2026-11-26

* Security: the closure check now verifies each dependency's source. A
  dependency changed to `path:` or `git:` with `override: true` keeps its
  old Hex entry in `mix.lock` (`mix deps.get` leaves it there), and 0.9.0
  and earlier compared that entry only: a build made against the Hex
  release was installed where Mix compiles the package against your fork.
  Now the package itself, each dependency its build was made against and
  each one Mix compiles it with must be a dependency Mix loads from Hex
  (`Hex.SCM`, no `path:` or `git:` option), with the package, version and
  outer checksum that the rules compared. Anything else misses with the new
  reason code `closure_source`. The same holds under
  `Precompiled.Host.install/2`, which reads the dependencies from the
  install project's own resolution, where a `lockfile:` merge can bring
  the same stale entry; there the lock entry of a dependency Mix loads
  from a path or git is no candidate. 0.9.0 is not published on Hex:
  0.9.1 replaces it.

## v0.9.0 - 2026-11-22

* Probe inputs: a dependency whose compile asks whether a module or an application is there
  (jose's `Code.ensure_loaded?(Poison)`, websock_adapter's `:cowboy_websocket`, vega_lite's
  `:wx`), and its dependents, can now install precompiled. The portal records each such
  question the builder answered "absent" as a `probe` compile input, and this client takes the
  build only when nothing in this project can supply the module or application either: no
  dependency Mix loads in this env that the portal knows defines it, no dependency outside the build's
  closure that defines it in its sources (read, not compiled), nothing on this VM's code path,
  and for an OTP application, nothing installed here. Otherwise it misses as `probe_definer`,
  `probe_otp_app` or, when it cannot tell, `probe_unknown`. `Mix.install` checks the install
  project's own dependencies. A device never takes such a build. Earlier clients treat the
  input as malformed and miss.

* Security: the device API's test seams (`:root`, `:env`, `:clock_synchronized?`, `:lib_roots` and a
  per-call network `:source`, and `mix precompiled.report`'s `:gets` and `:interactive?`) are now
  compiled in only when this library is built in its own test env. In 0.8.0, `config :precompiled,
  test_seams: true` in a firmware or project opened them on any build; now no application env does.

* Relocated builds: a dependency whose own beams hold the path it was compiled at (fine's
  `Fine.include_dir/0`, a `__DIR__` literal, a path into its build's `priv`) can now install
  precompiled. The portal builds it at three different roots and lists it under a
  version's `relocated` object, which earlier clients never read, with the record of every
  occurrence of the builder's deps and build path. This client takes one only after every
  other list missed, rewrites each occurrence to this project's own deps and build path at
  install, exactly as this project's own compile would have written it (the literal
  re-encoded, the module's md5, fun uniqs and default `vsn` taken again), and records the
  rewritten files' hashes in the install's provenance. A moved project installs it again,
  relocated to its new paths. A package listed there only because a dependency of it was
  relocated comes with a record that names no file to rewrite; the same rules hold it.

* A relocated build misses on OTP 27 (`relocated_otp`); when this project's deps or build
  path is not its own real path or the host is not unix (`relocated_paths`); when a path
  is not printable ASCII (`relocated_path_ascii`); when a component is spelled otherwise
  than its dir lists it, as `/users/me` for `/Users/me` on a volume that ignores case
  (`relocated_path_spelling`); when a path is outside the envelope of the three roots the
  portal proved the build at (`relocated_path_envelope`); and when the record's roots are
  not the builder's own layout, a served beam was not compiled from the package's dir under
  the record's deps path, the record does not match the served beams or the rewrite would
  not be this VM's own compile (`relocation_refused`). The client derives every occurrence
  from the served beams itself, takes the md5 as this OTP does (`beam_lib:md5/1`) and
  checks every file of the entry. A build path in the record must be followed by Mix's own
  layout under a build path: nothing, `/consolidated/...`, or `/lib/<app>/` and then `ebin`,
  `priv`, `include` or `.mix`, `<app>` the package or one of its locked dependencies. A refusal at install reports as `relocation_refused`. What
  the three roots cannot show: a compile-time test of the path against a constant none of
  them holds, or one that answers the same at all three and otherwise at this project's
  path; list such a dependency in `:except`. The roots' layout is fixed: another needs a new
  record version.

* A build whose compile read one app's whole config (`Application.get_all_env/1`, tz's
  compile-time check of its own options) carries a `config_all` compile input: the builder's
  config of that app, every key. This client compares it with the project's config of the
  app as a whole map: the same keys with the same values hit, anything else misses (reason
  code `config_all_differs`). An app already loaded is compared only when its `.app` declares
  no env; a device misses. Earlier clients treat the item as malformed: a miss.

* A build's recorded compile-time config value now matches the project's only when it is the same
  term exactly: `1` no longer matches `1.0` (they compare equal but compile to other code), for
  `compile_env` items, `config_all` entries, the value a `config_order` item's reader saw, and
  a host environment variable alike.

## v0.8.0 - 2026-11-20

* Foreign priv builds: a dependency whose compile packs Kino.JS assets into kino's priv
  (kino_vega_lite, kino_maplibre, ...) can now install precompiled. The portal lists such
  builds, and kino's own, under a version's `foreign_priv` object, which earlier clients
  never read. This client takes one only after the regular builds missed, and only while
  kino itself is installed precompiled or already compiled by Mix in this project; the
  writer's archives then go exactly where its own compile would put them.

* A dependency that writes into kino's priv misses when kino compiles from source in the
  same run (reason code `foreign_priv_target_compiles`), when kino's priv links to its
  sources (`foreign_priv_target_linked`), when kino is not in the build
  (`foreign_priv_target_missing`), when another module claims the same asset directory
  (`foreign_priv_conflict`), and under a rule this client does not know
  (`foreign_priv_rule_unknown`). A device never installs one (`foreign_priv_device`).

* Every run checks an installed writer's archives on disk, offline and without a fresh
  batch too, and places them again when Mix removed them; replacing kino keeps the archives it does not ship; removing kino makes Mix
  recompile the dependencies whose archives were in it.

* Upgrading from 0.7.x: kino itself is listed for 0.8.0 only, so an older client compiles
  kino from source.

## v0.7.3 - 2026-11-17

* A project whose config sets `config :elixir, :time_zone_database, ...`
  (ex_nvr's `Tzdata.TimeZoneDatabase`, a dependency not compiled yet when
  this library runs) no longer FAILs every dependency with
  `batch malformed`. The batch's time checks asked the configured time
  zone database for plain UTC arithmetic; they now name the UTC-only one.
  Like any other config, the key is compared where a build recorded it
  under `compile_env`, and otherwise ignored.
* A crash in this library is never a FAIL or a refusal any more. One
  while checking the root or batch is every dependency's MISS,
  `trust check crashed: <error>` (reason code `internal`), and an
  installed build is removed, so Mix compiles it, rather than kept
  unchecked; it used to read as `batch malformed` on every line. One
  while checking a single dependency is that dependency's MISS,
  `candidate crashed: <error>`, with nothing of a half-finished install
  left behind; a build dir that will not go is a FAIL naming the file
  (reason code `remove_failed`), as for a revoked build.

* A cache entry that another writer replaced with the same bytes while
  it was being read no longer FAILs the dependency with `cache refused
  (... changed while being read)`. Two runs sharing a home, or two
  dependencies of one run whose builds share a file, each write the
  entry they downloaded, renaming a new file over it; a read whose open
  got the new file now looks at the name again, as a symlink or other
  non-regular file is still refused. One that keeps changing is
  downloaded again; the bytes are re-hashed either way.

* A dependency declared under another name than its Hex package
  (`{:eini, "~> 2.2", hex: :eini_beam}`, locked as
  `eini: {:hex, :eini_beam, ...}`) is looked up by its Hex package,
  `eini_beam`, not by the app, which here is the name of another Hex
  package. The build still installs as the app Mix expects. Before, the
  other package's manifest was read; its builds missed, since the lock's
  outer checksum (`package_checksum`) is the real package's, so the dep
  never got its own build. `mix precompiled.report` sends such a line
  under the Hex package name too, as its lock entry already was.

* `ERL_COMPILER_OPTIONS=deterministic` (or `[deterministic]`, read as OTP
  reads it) no longer makes every dependency miss: such a project takes
  only builds the portal compiled with exactly that option, listed under a
  version's `deterministic` object (the same `builds`, `builds_with_inputs`
  and `builds_closure` lists, each read as the version's own) and marked
  `build.erl_compiler_options: ["deterministic"]`, and never a build made
  without it. A project without the option never takes one of those. A
  version with builds but none of those misses with the new reason code
  `deterministic_not_built`. Clients before this release never read the
  object. Any other value still misses, now as `ERL_COMPILER_OPTIONS is set
  to options other than exactly deterministic, ...`.
  The value must also be what this VM's Elixir compiles with: Elixir 1.18+
  reads the variable once, on the VM's first compile (mix.exs itself), so
  a project that sets it later (in `project/0` or `config/config.exs`) or
  clears it misses as `ERL_COMPILER_OPTIONS changed after this VM's first
  Elixir compile, ...`: its Elixir deps compile without the option while
  rebar3 and `compile.erlang` see it.

## v0.7.2 - 2026-11-17

* Host-native builds, opt-in: with `config :precompiled, host_native: true`
  (under `Mix.install/2`, `config: [precompiled: [host_native: true]]`) a
  Linux glibc host (x86_64 or aarch64) that is no Nerves target also reads
  a version's `builds_host_native` list, after its regular builds missed:
  a NIF package's beams and priv libraries built for this machine's
  triple, ABI-compatible with it rather than the bytes Mix would compile
  here. Such a build is installed only when, besides the rules of any host
  build, it records its compile inputs (the env its native tool picks the
  library by is compared like any other), its OTP major is this one and its full OTP version and NIF version
  no newer, every library its ELF files need is found here
  (`ldconfig -p`, the 64-bit, multiarch and `/lib` dirs) with every symbol
  version they need, and every library is one downloaded from an upstream
  release whose archive is listed, with its sha256, in the package's own
  checksum file under `deps/` (read as data, never evaluated); a library
  the build compiled itself is never used. Before it replaces anything in
  `_build`, every staged file that is ELF is read back, whichever of the
  entry's lists names it: it must be a 64-bit shared library (ET_DYN) of
  this machine that one of the build's origins names.
  Three new reason codes:
  `triple_differs`, `nif_version_newer`, `origin_unverified`. Off, the
  list is never read and nothing changes.

## v0.7.1 - 2026-11-16

* A firmware build whose package reads an environment variable at compile
  time is no longer refused by rule 8 when it records its compile inputs
  (circuits_i2c's `CIRCUITS_I2C_I2CDEV` and circuits_spi's
  `CIRCUITS_SPI_SPIDEV`, which their `mix.exs` sets from the Nerves target
  and the `:default_backend` config). Two new input kinds decide it: an
  `env` item with `set_by: "nerves"` (`CROSSCOMPILE`) holds when this
  project's value, cut at its own `NERVES_TOOLCHAIN` and `NERVES_SYSTEM`
  paths, cuts to the build's, and misses with `built with a different
  CROSSCOMPILE` otherwise; a `mix_target` item holds when the build's target
  is the one Mix compiles for, and misses with `rule8_target` otherwise.
  A device cannot check either and misses. Clients before this release
  treat both as malformed and miss.
* A build whose compile read the OS type (`:os.type/0`: kino's `Kino.JS`
  asset hook, and every package whose compile runs it) carries an
  `os_type` compile input. It holds when the build's family and name are
  this machine's `:os.type/0`, or the family alone when the build records
  no name (only Elixir's `File.rm_rf/1` read it), and misses with
  `built on unix:linux, this machine is unix:darwin` otherwise. A device
  cannot check the machine its firmware was compiled on and misses.
  Clients before this release treat the item as malformed and miss.
* A build whose compile read the byte order (`System.endianness/0`: nx and
  every package with nx in its closure, such as polaris, nx_image,
  nx_signal and safetensors) carries an `endian` compile input. It holds
  when the build's byte order is this machine's, and misses with
  `built on a little-endian machine, this one is big-endian` otherwise. A
  device cannot check the machine its firmware was compiled on and misses.
  Clients before this release treat the item as malformed and miss, as
  they do for any input kind they do not know.
* `Precompiled.report/1` sends a device's last `Precompiled.install/2`
  outcome to the configured source, as `mix precompiled.report` does for a
  build: every install but a dry run now records its HIT, MISS and FAIL
  lines, with reason codes, in the store's `.last-install.json`, and
  `report/1` shows them and asks before sending (`yes: true` skips the
  question; with no terminal it cancels). A device's MISS now keeps the
  reason code and version of the build it tried; the printed lines and
  `{:no_build, pkg, why}` are unchanged. Only names the signed batch lists
  are sent; a call refused before it ran records that no install ran.
* README: what the portal builds (including builds for a typical Phoenix
  app's optional dependencies), the `~> 0.7` requirement, the closest
  build on a `MISS` line, `Precompiled.Host.install/2`'s `Mix.install/2`
  options, and the environment checks that stop installs.

## v0.7.0 - 2026-11-15

* `Precompiled.Host.install/2` now predicts a dependency's compile-time
  read of another app's config from the order `Mix.install/2`'s
  `deps.compile` uses in its install project, as a Mix project does.
  Before, every such build missed under `Mix.install/2` with
  `compile-time config APP KEY would differ in this project`, for example
  `phoenix_live_dashboard` without `phoenix_view`.
* `Precompiled.Host.install/2` now checks a build's compile-time config
  against `Mix.install/2`'s `:config` and `:config_path`, applied before
  the check as `Mix.install/2` applies them (the file's keys replace
  `:config`'s). Before, a build that recorded a key unset was installed
  even when `:config` set it. A `:config_path` that cannot be read makes
  every dependency that reads compile-time config compile from source.
* A fresh `_build` no longer compiles this library again. As a dependency
  fetched from Hex (never a path or git checkout) it keeps its own compiled modules in
  `deps/precompiled/.compile_cache`, keyed on the toolchain, the compiler
  options, every source file and `config :precompiled`, and restores them, each file checked by
  sha256, into a `_build` that has none: another `MIX_ENV` or
  `MIX_TARGET`, `rm -rf _build`. About 0.4 s less per fresh `_build` on a
  laptop, more on a CI runner with few cores. `PRECOMPILED_COMPILE_CACHE=0`
  turns it off.
* Installing a build makes fewer file system calls: its dirs are made once,
  a file whose mode is already the one a new file gets is not set again,
  and a cache entry used in the last day is not marked used again (the
  cache gc orders by day). Every file is still hashed before it is placed.

* A `MISS` line now names the build that came closest after its reason:
  `; closest build HASH: VARIANT, Elixir X/OTP Y, SYSTEM RELEASE, closure
  +a -b`, with the first 12 characters of the build's files hash, its
  variant (a world build's own, else `with` or `without` the package's
  optional dependencies), its toolchain, its system and release, and how
  its closure differs from the one Mix compiles the package with here. A
  `HIT` line names the build it installed the same way, after its size
  (`; build HASH: ...`). Only manifest values and dependency names are
  printed; nothing from the environment is. Reason codes and arguments are
  unchanged, so `mix precompiled.report` sends what it sent before.
* `Precompiled.Host.install/2` now reads the dependency tree `Mix.install/2`
  compiles, from the dependencies Mix loads in its install project, and
  matches the way a Mix project on your build machine does: a build must
  have been compiled with exactly the package's dependencies in that tree,
  at any depth, optional ones included, and the builds a manifest lists
  under `builds_closure` are considered too. An optional dependency the
  install has only for another env (`only: :test` in a script run in dev)
  no longer counts as present because the lock has it. The tree is read
  after the `lockfile:` option's lock is merged into the install project,
  as `Mix.install/2` merges it, so a lock that pins a dependency to another
  version is checked against too, where before Mix could compile a placed
  build's package differently from the build. When Mix cannot load the
  dependencies, every dependency misses (`build method unknown`), as
  before; when it loads them but their tree is not in the shape the
  client reads, the lock decides as before and `builds_closure` is not
  read.
* On your build machine, a build that records rebar3 `platform_define`
  verdicts (`compile_inputs` items of kind `platform_define`, each a regex
  and whether it matched the builder's arch string) matches only when
  every regex decides the same against this machine's arch string,
  computed as rebar3 computes it (OTP version, system architecture, word
  size). Otherwise the line reads `rebar3 platform_define REGEX decides
  differently on this machine` (new reason code `platform_define_differs`),
  as it does for a regex the client cannot evaluate. On a device such a
  build misses with the same code: the device cannot know the machine its
  firmware was compiled on. Releases before this one miss on the new
  kind as a malformed entry.
* On your build machine, a project whose dependency tree the client has
  read also considers the builds a manifest lists under `builds_closure`
  for a version: builds made with a common app's optional dependencies
  added at every depth of the package's tree. Such a build matches only
  under the whole-tree comparison below, so it is never considered where
  the client has not read the tree, or on a device. A release reads `builds_closure` only if
  it makes that comparison; earlier releases ignore the list. A
  `builds_closure` that is not a list is ignored and leaves the version's
  other builds as they were. A manifest without it is read as before.
* On your build machine, a dependency Mix compiles with rebar3 no longer
  matches while your global rebar3 config (`~/.config/rebar3/rebar.config`,
  or the one under `REBAR_GLOBAL_CONFIG_DIR`) sets a key that changes
  what rebar3 compiles, such as `erl_opts`, `overrides`, hooks or
  plugins: rebar3 merges that file into every dependency compile, so the
  beams built here would differ from the published build. The line reads
  `global rebar3 config PATH sets KEY` (new reason code
  `rebar3_global_config`) and names the key, never its value. A file that
  does not parse, or one with a `rebar.config.script` beside it, misses
  the same way, as does one whose directory cannot be searched. Mix
  dependencies and devices are not affected.
* On your build machine, nothing matches while `ERL_COMPILER_OPTIONS` is
  set, while `ERL_LIBS` is set, while `ERL_FLAGS`, `ERL_AFLAGS`,
  `ERL_ZFLAGS` or `ELIXIR_ERL_OPTIONS` carry an argument
  that can set it, run code or change the code loaded (`-env`, `-eval`,
  `-pa`, ...), or while a `.erlang` file sits in your home or Erlang's
  user config directory. Each changes every compile, Elixir modules
  included, and no build records it. The line names the variable or file,
  never its value (new reason code `erl_compiler_options`).
* On your build machine, a build matches only when it was compiled with
  exactly the dependencies Mix compiles the package with in your project,
  at any depth, for the current env: not everything `mix.lock` has. A
  project that pulls an optional dependency in `only: :test` (as `phx_new`
  does lazy_html for phoenix_live_view) no longer misses the build made
  without it in dev and prod, and no longer accepts there a build made
  with it, directly or further down the tree, which Mix would compile
  differently: that misses with `built with NAME, which Mix leaves out of
  it in this env`. In test the build with it matches, as before. A
  dependency Mix loads but the lock has no Hex entry for (a path
  dependency with `override: true`) now misses every build that lacks it
  (`built without NAME, which is not a Hex dependency here`). Versions
  and checksums are still checked against the lock. `Mix.install/2`
  projects and devices behave as before.

## v0.6.0 - 2026-11-13

* Builds whose compile read an environment variable or the whole
  environment are now published, with what the compile read
  (`compile_inputs`). This release reads them; earlier releases never see
  them and behave as before.
* On your build machine, a build that read a variable matches only when
  your environment gives the same value (unset or set alike): otherwise
  `built with a different NAME`. Your value is never printed or reported.
  A variable the build set itself, from inputs it recorded, is not
  compared. A build that read the whole environment, or whose config reads
  were not all recorded, does not match.
* On a device, a build that read a variable matches when the variable was
  unset at build time; one built with it set misses with
  `built with NAME set at compile time; a device cannot check its
  firmware's build environment`.
* A build that records its compile inputs is no longer refused by the
  module-level `System.get_env` scan (rule 8); builds without them still
  are.
* A build whose dependency read an unset config key of an app outside
  its own dependency tree (`Application.get_env` in a module body) records
  what it saw and the app's `.app` default. On your build machine the
  client predicts what `mix deps.compile` would give it in your project,
  from your config and your deps' compile order: a different value misses
  with `compile-time config APP KEY would differ in this project`. In a
  partitioned compile (`MIX_OS_DEPS_COMPILE_PARTITION_COUNT` above 1),
  such an item misses unless your config sets the key or the app is not
  among your dependencies (nor part of OTP or Elixir); then it is compared
  as above. On a device such a build matches only when the app's `.app`
  gives the key no default and the device's config gives the value the
  build saw.
* New miss report codes: `env_differs`, `env_set_at_build`, `env_all`,
  `config_unrecorded`, `config_order_differs`.

## v0.5.1 - 2026-11-12

* On a device, an optional dependency (such as `:rustler` for
  `rustler_precompiled`) no longer blocks an install when this target has
  no build of it: the package installs without it.
* On a device, optional dependencies are no longer installed along with a
  package: `install(:axon)` skips `kino` and the like unless the device
  has them or the call asks for them (`install([:axon, :kino])`), prints
  one line per skipped dependency, and prefers a build locked without them.
* On a device, an online install no longer waits for NTP: it goes ahead
  with the clock as it is and lets the batch's own time checks decide.
  Only when one of them fails before NTP has answered does it say to wait
  for NTP (still `{:error, {:clock_unsynchronized, now}}`).
* On a device, a store too small for an install prints one readable line
  with the sizes, the store directory and the largest build, instead of
  the raw `{:too_big, needed, free}` (the returned error is unchanged).

## v0.5.0 - 2026-11-12

* Target builds now match across releases of the same Nerves system:
  beam-only builds always, NIF builds when the toolchain series, OTP
  version and needed libraries line up (checked on the host against the
  portal's systems table and on the device against its own libraries).
* On a device, every native build, for the exact release too, is checked
  against the device's own `/lib` and `/usr/lib` before it is installed.
* Beam-only builds with no priv files match across releases too.

## v0.4.0 - 2026-11-11

* New `mix precompiled.report` and `Precompiled.Host.report/1`: send the
  last build's HIT/MISS/FAIL report to the configured source, after
  showing exactly what will be sent and asking first (`--yes` for CI,
  `--dump` to only look). Lines go as stable reason codes with package
  names and versions, and only the project's public Hex lock entries go
  with them; a Nerves system that is not a public Hex package, and any
  reason that would name it or the target, is sent as `custom` instead.
  Sending the same report twice answers "already received" and no id,
  since the source hands an id out only once; the id from a first send
  is the only way to retract it (`DELETE <source>/reports/<id>`).
  Nothing is ever sent during a build, and the task always exits 0.
* `report.json` lines gain `reason_code` and `reason_args`, and the
  report gains `built_at` and the build's `context` (Elixir, OTP,
  target, Nerves system). Existing fields are unchanged. A build with
  no candidate dependencies does not write a new `report.json`; the
  previous one, and whatever it reports, stays in place.
* `mix precompiled.report` (and `Precompiled.Host.report/1`) need a
  `report.json` written by this release: one from an earlier release
  lacks the fields above, and the command says so and sends nothing
  rather than guessing.

## v0.3.2 - 2026-11-10

### Security

* Recorded compile_env values are decoded with size, compression and term
  kind limits. A value over 64 KiB, a compressed one, or one holding a
  fun, pid, port or reference anywhere is never decoded into a usable
  term: it differs from the project's value, so that build misses with
  `compile_env differs: ...` and the dependency compiles from source.
  Before, a small compressed value was inflated in full while it was
  read. A value that is not valid base64 is a miss too, never a raise.
  The local source-scan cache is read with the same limits; an entry
  outside them is rescanned.

## v0.3.1 - 2026-11-10

* New matching rule 9, build method. A dependency whose `deps` entry sets
  `:manager`, `:compile` or `:system_env` is built differently from any
  precompiled build, so it always compiles from source, with a line such as
  `MISS  project sets :manager for this dependency`. This includes options
  a package's own `mix.exs` sets on its dependencies, under
  `Precompiled.Host.install/2` too. An installed build is removed on the
  next run once such an option appears.
* A global `Mix.install(deps, system_env: ...)` is not treated as an
  override: it is the same as the shell environment, which no rule
  records. Builds are made in a clean environment, and a dependency whose
  compile-time output depends on environment variables is a known
  limitation (Known limitations, Matching).
* Under `Precompiled.Host.install/2`, when Mix cannot load the
  dependencies, every one misses with `build method unknown (deps did not
  load: ...)`, after one warning naming the cause.
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
