# Nerves

A Nerves project spends most of its [`mix firmware`](https://hexdocs.pm/nerves/Mix.Tasks.Firmware.html) time compiling
dependencies for the target. With `precompiled`, every dependency that has
a matching signed build is installed instead, and only the rest is
compiled. The `precompiled:` line per dependency tells you which was which.

## Setup

Add the alias exactly as for any Mix project
([Setup](setup.md#any-mix-project-plain-phoenix-libraries)).
`nerves_bootstrap` puts its own steps in front of the same alias, so the
Nerves environment is set before `precompiled` runs.

Released nerves 1.x cannot tell the library which system and version you
build for, so on your build machine only `pure_elixir` builds can match
(rule 1 of [What matches](matching.md)). Rule 8 still applies. Everything
else, including dependencies with native code such as circuits, compiles
from source, as it did before.

## On the device itself

Everything above runs on your build machine, during [`mix firmware`](https://hexdocs.pm/nerves/Mix.Tasks.Firmware.html). To
install a library on a running device, from IEx on the device, see
[On a device](device.md):

```elixir
Precompiled.install(:recon)
Precompiled.report()
```

`Precompiled.report()` shows the last install's HIT/MISS/FAIL lines and
sends them to the portal only after you answer yes
([Reporting a miss from a device](device.md#reporting-a-miss-from-a-device)).
