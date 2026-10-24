# elixir_precompiled

Install signed, verified precompiled dependency builds instead of compiling
them. Builds come from the [Nerves compatibility portal](https://compatibility.nerves-project.org),
which compiles every Hex package against every Nerves system, signs a batch
index every 15 minutes and serves the files by SHA-256. A dependency is
installed instead of compiled only when the build matches the project on
every rule in [What matches](#what-matches); everything else compiles as
before.

Status: proof of concept for Nerves 2. Not on Hex yet; use a git dependency
or the archive. This library was called `nerves_precompiled` until v0.1.0;
the old config key and environment variables still work for one release
(see [Configuration](#configuration)).

## At build time, with nerves

The hook that calls this library lives on the nerves `feat/precompiled`
branch ([nerves-project/nerves#1220](https://github.com/nerves-project/nerves/pull/1220)).
Released nerves does not call it: with a Hex nerves, `mix firmware` prints
no precompiled lines and installs nothing. Until the PR is merged, depend
on the branch:

```elixir
# mix.exs
{:nerves, github: "TomHoenderdos/nerves", branch: "feat/precompiled", runtime: false},
{:elixir_precompiled, github: "TomHoenderdos/elixir_precompiled"},

# config/config.exs
config :elixir_precompiled,
  source: "https://compatibility.nerves-project.org/api/precompiled"
```

`mix firmware` then prints one line per dependency:

```
precompiled: ash 3.36.0                   HIT   4.1 MB
precompiled: circuits_gpio 2.3.0          HIT   0.2 MB
precompiled: nerves_pack 0.7.1            MISS  built with nerves_ssh 1.3.3, project has 1.3.2
precompiled: 40 hit, 5 miss, 0 fail of 45 deps, 61.2 MB, 8.3 s
```

`mix nerves.info` repeats the last run.

## Configuration

| Key or variable | Meaning |
| --- | --- |
| `:source` | The portal's precompiled API URL. Without it nothing is installed. `https` only, `http` only on loopback. |
| `:except` | Dependencies never installed precompiled, for example `[:ash]`. |
| `:root` | Path to a `root.json` used instead of the one the library ships. |
| `:home` | The file and trust-state cache (default the user cache dir Mix uses for its own, `:filename.basedir(:user_cache, "elixir_precompiled")`). |
| `ELIXIR_PRECOMPILED=0` | Disables a run (`false` and `no` work too). |
| `ELIXIR_PRECOMPILED_HOME` | The cache directory when `:home` is not set. |
| `ELIXIR_PRECOMPILED_DEBUG=1` | Also prints each dependency that was not a candidate, with the reason (tooling, `except`, not from Hex, ...). |

The keys go in `config :elixir_precompiled, ...` or, on a device, as
options to `ElixirPrecompiled.install/2`. When `:elixir_precompiled` has no
application config at all, `config :nerves_precompiled, ...` (the name this
library had before) is read, then `config :nerves, :precompiled, source: ...`
form from nerves#1220. The `NERVES_PRECOMPILED*` env var names also still
work when the `ELIXIR_PRECOMPILED*` ones are unset. Both old forms are kept
for one release.

## On a device

```elixir
ElixirPrecompiled.install([{:jason, "1.4.5"}],
  source: "https://compatibility.nerves-project.org/api/precompiled")
```

is `Mix.install/2` with the precompiled step in front of it: the matching
builds for the running Nerves system are installed, Mix compiles the rest.
Of the applications, only `:mix` must be added to `extra_applications`;
the library's own `.app` starts `:inets`, `:ssl`, `:crypto` and
`:public_key`. The firmware also needs a writable `MIX_INSTALL_DIR` (for
example `/data/mix-installs`) and Hex. `:source` can also come from the
application config as above. Once a dependency is compiled in the install
project, later boots leave it to Mix, so a cached install needs no network.

## Livebook and `Mix.install`

`Mix.install/2` runs once per VM, so the client cannot be installed by it.
Install the archive once into the Mix home the runtime uses:

    mix archive.install github TomHoenderdos/elixir_precompiled

Then, in the notebook's setup cell (or any script), in place of `Mix.install/2`:

    ElixirPrecompiled.install([{:jason, "1.4.5"}, {:decimal, "3.2.0"}],
      source: "https://compatibility.nerves-project.org/api/precompiled")

Matching builds are installed into Mix's install project; Mix compiles the rest.

## What matches

A dependency is a candidate when it comes from Hex, is not Nerves tooling
(`nerves`, its own dependencies, `nerves_system_*`, `nerves_toolchain_*`,
`nerves_bootstrap`, `elixir_precompiled` itself) and is not in `:except`.
A build of a candidate is installed only when every rule holds:

1. **Target.** The build is `pure_elixir` (it serves every system and
   plain Elixir), or it was made for this project's Nerves system at the
   exact system version in `mix.lock`.
2. **Elixir.** Same major and minor as the running Elixir, and the running
   version is at least the one the build was made with. Elixir code compiled
   on 1.20.1 runs on 1.20.3, not the other way round; versions compare as
   versions, so a 1.21.0 build is not served to 1.21.0-rc.0, while a
   1.21.0-rc.0 build is served to 1.21.0.
3. **OTP.** The same OTP major. What a build inlines at compile time from
   OTP headers (record layouts) can change between majors.
4. **Dependency env.** The build was compiled in the env the dependency
   compiles in here: `prod`, unless the project's `deps` entry overrides it
   with `env:`.
5. **Checksum.** The build's package checksum equals the dependency's
   checksum in `mix.lock`.
6. **Dependencies.** Every dependency the build was compiled against is in
   `mix.lock` at the same version and checksum, and every dependency the
   package declares (optional ones included) that the lock has was in the
   build.
7. **compile_env.** Every `Application.compile_env` value the build read
   equals the project's config for that key.

When several builds pass, the one made on the running Elixir patch wins,
then the closest older patch, then `pure_elixir` before a system build,
then the newest run. When none passes, the line gives the rule the build
that got furthest broke, for example
`MISS  built with Elixir 1.20.3, running 1.20.1`.

## Trust

The library ships the portal's root of trust (`priv/precompiled/root.json`,
Ed25519, expires 2027-10-22). Every batch index is signed by a key the root
names; every manifest is fetched by the hash the batch names; every file by
the hash the manifest names. Nothing unsigned or unhashed reaches `_build`.
Plain `http` sources are refused except on loopback.

Today the root and batch roles are one Ed25519 key, threshold 1, held
online by the portal. Whoever controls the portal host can therefore
rotate the root and ship code to every opted-in host and device, until a
library release ships a new root. The proposals for splitting the roles
are in the compatibility repository's `docs/PRECOMPILED_SIGNING_PROPOSALS.md`.

## Known limitations

* Mix's `:lockfile` option is passed through to `Mix.install/2` but not used
  for the precompiled step, so an external lockfile can make Mix re-resolve
  and recompile what was just installed.
* `:config` and `:config_path` are not applied before the check, so a
  dependency whose compile-time config they change misses, or is placed and
  then recompiled by Mix's config-outdated check. Never a wrong build.
* `MIX_INSTALL_RESTORE_PROJECT_DIR` is ignored by the precompiled step.
* One online key signs both the root and the batches (see Trust).

## Development

```
mix test                       # unit tests, fixture server on port 4000
TEST_SERVER_PORT=4567 mix test # when something else holds port 4000
mix test --include integration # install/2 in a child VM against production
scripts/container-check.sh     # the same inside the compatibility worker image
MIX_ENV=prod mix archive.build # elixir_precompiled-0.1.0.ez, for Livebook
```
