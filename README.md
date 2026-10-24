# nerves_precompiled

Install signed, verified precompiled dependency builds instead of compiling
them. Builds come from the [Nerves compatibility portal](https://compatibility.nerves-project.org),
which compiles every Hex package against every Nerves system, signs a batch
index every 15 minutes and serves the files by SHA-256. A dependency is
installed instead of compiled only when its Elixir version, OTP version,
Nerves system, dependency lock entry and compile-time config match the build
exactly; everything else compiles as before.

Status: proof of concept for Nerves 2. Not on Hex yet; use a git dependency.

## At build time, with nerves

The hook that calls this library lives on the nerves `feat/precompiled`
branch ([nerves-project/nerves#1220](https://github.com/nerves-project/nerves/pull/1220)).
Released nerves does not call it: with a Hex nerves, `mix firmware` prints
no precompiled lines and installs nothing. Until the PR is merged, depend
on the branch:

```elixir
# mix.exs
{:nerves, github: "TomHoenderdos/nerves", branch: "feat/precompiled", runtime: false},
{:nerves_precompiled, github: "TomHoenderdos/nerves_precompiled"},

# config/config.exs
config :nerves_precompiled,
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
| `:home` | The file and trust-state cache (default `~/.nerves/precompiled`). |
| `NERVES_PRECOMPILED=0` | Disables a run (`false` and `no` work too). |
| `NERVES_PRECOMPILED_HOME` | The cache directory when `:home` is not set. |
| `NERVES_PRECOMPILED_DEBUG=1` | Also prints each dependency that was not a candidate, with the reason (tooling, `except`, not from Hex, ...). |

The keys go in `config :nerves_precompiled, ...` or, on a device, as
options to `NervesPrecompiled.install/2`. When `:nerves_precompiled` has no
application config at all, the `config :nerves, :precompiled, source: ...`
form from nerves#1220 is read instead.

## On a device

```elixir
NervesPrecompiled.install([{:jason, "1.4.5"}],
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
```
