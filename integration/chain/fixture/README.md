# Chain test fixture

A small Nerves project the chain test (`integration/chain/`) builds with
`mix firmware`, deploys and probes. Its dependencies cover each kind of
precompiled build:

- C NIFs built with elixir_make: `exqlite`, `argon2_elixir`;
- a NIF with target hardware: `circuits_gpio`;
- pure Elixir: `jason`, `ash` (with its optional `plug`, which the portal's
  ash builds carry);
- `nerves_pack`, which brings `nerves_ssh`, so the next run can deploy again;
- `nerves` (the `feat/precompiled` branch) and `elixir_precompiled` (this
  repository, by path), which are never installed precompiled;
- `chain_path_dep` (`deps_local/chain_path_dep`, one module), a path dep that
  is not Nerves tooling: never installed precompiled, whatever a batch names
  (the conformance case P5).

`expected.exs` lists the dependencies that must be precompiled hits
(`hits`) and the ones that never may be (`never`). The versions are pinned
in `mix.exs` and `mix.lock`; bump them together with `expected.exs`.

## The operator file

The firmware needs a network configuration and the ssh keys allowed to log
in. Neither belongs in a public repository, so `config/target.exs` imports
them from a file outside it:

    ~/.config/chain_test/target.exs

or the path in `CHAIN_TARGET_CONFIG`. It is an ordinary config file
(`import Config` first) and is imported last, so it overrides the fixture's
own target config. It should set at least:

- `config :nerves_ssh, authorized_keys: [...]`, the public keys that may log
  in and upload firmware;
- `config :vintage_net, config: [...]`, the network the device joins;
- optionally `config :mdns_lite, ...`.

Without it, a target build stops with `chain fixture: no site config at
...`. Host builds (`mix test`) do not read it.

## Environment

| Variable | Meaning |
| --- | --- |
| `CHAIN_SOURCE` | The precompiled API the client uses (default: the production portal). |
| `CHAIN_TARGET_CONFIG` | The operator file (default `~/.config/chain_test/target.exs`). |
| `CHAIN_CLIENT_CONFIG` | A config file merged into `config :elixir_precompiled`; the harness writes one for a conformance case's `client_config`, for that build only. |
| `CHAIN_NERVES_PATH` | A local nerves checkout instead of the `feat/precompiled` branch. |

## The probe

`ChainFixture.Probe.run(apps)` starts each app, loads every module, makes
one smoke call per NIF (exqlite `select 1`, argon2 hash and verify,
`Circuits.GPIO.enumerate/0`), hashes every file under each app's `ebin/`
and `priv/`, and prints one JSON document between
`-----BEGIN CHAIN PROBE-----` and `-----END CHAIN PROBE-----`.
`ChainFixture.Probe.run()` probes the hits in `expected.exs`. It also
reports the active firmware UUID and the running Nerves system (from
os-release, else the firmware's platform, else `"unknown"`). It uses
Elixir's own `JSON` and calls none of the test subjects directly, so a
broken dependency shows in the report instead of breaking the probe.

    mix test          # the probe on host
