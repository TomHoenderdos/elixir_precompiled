# Nerves

A Nerves project spends most of its `mix firmware` time compiling
dependencies for the target. With `precompiled`, every dependency that has
a matching signed build for your Nerves system is installed instead, and
only the rest is compiled. The line per dependency tells you which was
which:

```
precompiled: circuits_gpio 2.3.1          HIT   48 KB
precompiled: nerves_pack 0.7.1            MISS  built with nerves_ssh 1.3.3, project has 1.3.2
```

## Pick a setup

| | Released `nerves` | The `nerves` fork |
| --- | --- | --- |
| How | The alias from [Setup](setup.md#any-mix-project-plain-phoenix-libraries) | `{:nerves, github: "TomHoenderdos/nerves", branch: "feat/precompiled", runtime: false}` |
| Builds served | `pure_elixir` only | `pure_elixir` **and** builds for your Nerves system |
| What compiles | Every dependency with native code | Only what has no matching build |
| `mix nerves.info` | — | Shows the last run |

Start with the alias: it works with the nerves you already have. Switch to
the fork when you want the native-code dependencies (circuits, NIFs) to
come precompiled too.

### Released nerves: the alias

Add the alias exactly as for any Mix project
([Setup](setup.md#any-mix-project-plain-phoenix-libraries)).
`nerves_bootstrap` puts its own steps in front of the same alias, so the
Nerves environment is set before `precompiled` runs.

Released nerves 1.x cannot tell the library which system and version you
build for, so only `pure_elixir` builds can match (rule 1 of
[What matches](matching.md)). Rule 8 still applies. Everything else
compiles from source, as it did before.

### The fork: system builds too

The `feat/precompiled` branch of nerves
([nerves-project/nerves#1220](https://github.com/nerves-project/nerves/pull/1220))
calls `Precompiled.Host.run/1` from its own `nerves.init`. The system and
its exact version come from `Nerves.build_plan/0`, so builds made for your
system match as well.

```elixir
{:nerves, github: "TomHoenderdos/nerves", branch: "feat/precompiled", runtime: false}
```

Using the fork *and* the alias is fine: the second call in a Mix run
reuses the first.

## On the device itself

Everything above runs on your build machine, during `mix firmware`. To
install a library on a running device, from IEx on the device, see
[On a device](device.md).
