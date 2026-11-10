# Precompiled

[![Hex version](https://img.shields.io/hexpm/v/precompiled.svg)](https://hex.pm/packages/precompiled)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/precompiled/)
[![CI](https://github.com/TomHoenderdos/elixir_precompiled/actions/workflows/ci.yml/badge.svg)](https://github.com/TomHoenderdos/elixir_precompiled/actions/workflows/ci.yml)
[![Nerves](https://compatibility.nerves-project.org/badge/precompiled.svg)](https://compatibility.nerves-project.org/packages/precompiled)

Install signed, verified precompiled builds of your Hex dependencies
instead of compiling them. Builds come from the
[Nerves compatibility portal](https://compatibility.nerves-project.org),
which builds selected Hex packages for the host (`pure_elixir`) and for
Nerves systems, signs a batch index every 15 minutes, and serves files by
SHA-256. A dependency is installed only when a build matches the project on
every rule in [What matches](https://hexdocs.pm/precompiled/matching.html);
everything else compiles as before, and nothing this library does can fail
your build.

## Installation

With [Igniter](https://hex.pm/packages/igniter) (Elixir 1.18 or later):

    mix igniter.install precompiled

Or by hand, in `mix.exs`:

```elixir
def project do
  [
    ...,
    aliases: [
      "deps.loadpaths": ["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"]
    ]
  ]
end

defp deps do
  [
    {:precompiled, "~> 0.3", runtime: false},
    ...
  ]
end
```

No config is needed: builds come from the portal's signed API by default.
The source, its mirrors and the root of trust can be changed only in the
project's config, never by an option or an environment variable (see
[Trust](https://hexdocs.pm/precompiled/trust.html)).

## Usage

Nothing more: every `mix compile`, `mix test`, [`mix phx.server`](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Server.html) and
`mix release` installs the matching builds before Mix compiles the rest,
and prints one line per candidate:

```
precompiled: ash 3.36.0                   HIT   4.1 MB
precompiled: nerves_pack 0.7.1            MISS  built with nerves_ssh 1.3.3, project has 1.3.2
precompiled: 40 hit, 5 miss, 0 fail of 45 deps, 61.2 MB, 8.3 s
```

In a script or a Livebook cell, with the
[archive](https://hexdocs.pm/precompiled/setup.html#mix-install-and-livebook)
installed:

```elixir
Precompiled.Host.install([{:jason, "1.4.5"}, {:decimal, "3.2.0"}])
```

On a running Nerves device, from an IEx shell:

```elixir
Precompiled.install(:recon)
```

`PRECOMPILED=0` turns it off.

`mix precompiled.report` sends the last build's HIT/MISS/FAIL report,
after showing it and asking (see
[Troubleshooting](https://hexdocs.pm/precompiled/troubleshooting.html#reporting-a-miss)).

## Guides

Getting started:

- [Setup](https://hexdocs.pm/precompiled/setup.html): any Mix project,
  umbrellas, Phoenix, CI, `Mix.install` and Livebook
- [Nerves](https://hexdocs.pm/precompiled/nerves.html)
- [On a device](https://hexdocs.pm/precompiled/device.html), including
  bundles for devices with no network

Reference:

- [Configuration](https://hexdocs.pm/precompiled/configuration.html):
  every key and variable, turning it off, seeing what happened
- [What matches](https://hexdocs.pm/precompiled/matching.html)

Explanation:

- [Trust](https://hexdocs.pm/precompiled/trust.html): the signed chain, on
  the host and on the device, and CA certificates

Troubleshooting:

- [Troubleshooting](https://hexdocs.pm/precompiled/troubleshooting.html):
  every line the library prints, and what to do
- [Known limitations](https://hexdocs.pm/precompiled/limitations.html)

The guides are also in
[guides/](https://github.com/TomHoenderdos/elixir_precompiled/tree/main/guides).
To work on the library, see
[CONTRIBUTING.md](https://github.com/TomHoenderdos/elixir_precompiled/blob/main/CONTRIBUTING.md).

## Supported versions

Elixir 1.17 or later on OTP 27 or later; the Igniter installer needs
Elixir 1.18. Builds serve only the toolchains the portal builds with
(today Elixir 1.19.3 and 1.20.3 on OTP 28 and 29); see
[Supported versions](https://hexdocs.pm/precompiled/setup.html#supported-versions).

## Names

The package is `precompiled`; the repository keeps its old name,
`elixir_precompiled`. This library was called `nerves_precompiled` until
v0.1.0; those old config keys and environment variables still work for
one release (see [Configuration](https://hexdocs.pm/precompiled/configuration.html)).
The interim `elixir_precompiled` names (app, modules,
`ELIXIR_PRECOMPILED_*` variables, the cache dir) were never released and
are not read.

## License

Apache-2.0. See [LICENSE](https://github.com/TomHoenderdos/elixir_precompiled/blob/main/LICENSE).
