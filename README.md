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

```elixir
# mix.exs
{:nerves, "~> 2.0", runtime: false},
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

`mix nerves.info` repeats the last run. `except: [:dep]` opts single
dependencies out; `NERVES_PRECOMPILED=0` disables a run;
`NERVES_PRECOMPILED_HOME` moves the file cache (default `~/.nerves/precompiled`).

## On a device

```elixir
NervesPrecompiled.install([{:jason, "1.4.5"}],
  source: "https://compatibility.nerves-project.org/api/precompiled")
```

is `Mix.install/2` with the precompiled step in front of it: the matching
builds for the running Nerves system are installed, Mix compiles the rest.
The firmware needs `:mix`, `:inets` and `:ssl` in `extra_applications`, a
writable `MIX_INSTALL_DIR` (for example `/data/mix-installs`) and Hex.
`:source` can also come from the application config as above. Mix's
`:lockfile` option is passed through but not used for the precompiled step,
so an external lockfile can make Mix re-resolve and recompile what was just
installed; that is a miss, never a wrong build.

## Trust

The library ships the portal's root of trust (`priv/precompiled/root.json`,
Ed25519, expires 2027-10-22). Every batch index is signed by a key the root
names; every manifest is fetched by the hash the batch names; every file by
the hash the manifest names. Nothing unsigned or unhashed reaches `_build`.
Plain `http` sources are refused except on loopback.

## Development

```
mix test                       # unit tests, fixture server on port 4000
TEST_SERVER_PORT=4567 mix test # when something else holds port 4000
mix test --include integration # install/2 in a child VM against production
scripts/container-check.sh     # the same inside the compatibility worker image
```
