# Setup

## Any Mix project (plain, Phoenix, libraries)

With [Igniter](https://hex.pm/packages/igniter) (Elixir 1.18 or later):

    mix igniter.install precompiled

It adds the dependency as `runtime: false`, sets `:source` in
`config/config.exs` (`--source URL` names another portal) and puts
`"deps.compile precompiled", "precompiled.deps"` at the front of
the `deps.loadpaths` alias, before any steps already there. Running it
again changes nothing. Igniter is an optional dependency: a project that
does not use it never fetches it.

By hand, three lines:

```elixir
# mix.exs
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
    {:precompiled, "~> 0.2", runtime: false},
    ...
  ]
end

# config/config.exs
config :precompiled, source: "https://compatibility.nerves-project.org/api/precompiled"
```

For unreleased changes, the git form works too:
`{:precompiled, github: "TomHoenderdos/elixir_precompiled", runtime: false}`
(and `mix archive.install github TomHoenderdos/elixir_precompiled` for
the archive below).

Every `mix compile`, `mix test`, `mix run`, `mix phx.server` and
`mix release` passes through `deps.loadpaths` before Mix compiles
dependencies; the alias installs the matching builds first. The first
entry compiles this library so its task exists. Without it, Mix would
compile every dependency before the task could run. Keep the dependency
in every environment (no `only:`), since `mix test` runs in `test`.

Instead of the config, `PRECOMPILED_SOURCE=<url>` opts a single run
(CI, a script) in. An empty value counts as unset.

On the host, only `pure_elixir` builds can match. The portal builds those
with Elixir 1.19.3 and 1.20.3 on OTP 28 and 29 today, so other toolchains
compile everything (see [Supported versions](#supported-versions)).

## Umbrella

Put the alias in the umbrella root's `mix.exs`; add the dependency to any
one app (or all of them) and the config to the root `config/config.exs`.
The Igniter installer does not edit umbrellas.

## Phoenix

Nothing beyond the above: `mix phx.server`, `mix test` and `mix release`
all go through the alias. Assets are not touched.

## CI

Nothing CI-specific is needed; for speed:

- cache the download cache (`~/.cache/precompiled` on Linux,
  `~/Library/Caches/precompiled` on macOS, or
  `PRECOMPILED_HOME`) keyed on `mix.lock`, Elixir and OTP, next to
  `deps` and `_build`;
- a warm step asks the source one conditional question (`If-None-Match`
  on the batch) and downloads nothing else. Until the portal answers that
  question with `304 Not Modified`, the batch itself is downloaded again;
  manifests and files still come from the cache;
- `PRECOMPILED_SOURCE=<url>` turns it on without a config change.

```yaml
- uses: actions/cache@v4
  with:
    path: |
      deps
      _build
      ~/.cache/precompiled
    key: ${{ runner.os }}-${{ matrix.elixir }}-${{ matrix.otp }}-${{ hashFiles('mix.lock') }}
```

When the cache dir is not writable (a read-only pre-seeded cache) or there
is no `HOME`, a run uses a fresh cache in
`_build/<env>/lib/.precompiled/home` instead. One line says so.

## Mix.install and Livebook

`Mix.install/2` runs once per VM, so the library comes from an archive.
Install it once into the Mix home the runtime uses:

    mix archive.install hex precompiled

Then, in a script after `Mix.start()` or a Livebook setup cell:

```elixir
Precompiled.Host.install([{:jason, "1.4.5"}],
  source: "https://compatibility.nerves-project.org/api/precompiled")
```

It is `Mix.install/2` with the precompiled step in front: matching builds
are installed into Mix's install project, and Mix compiles the rest. It
takes `Mix.install/2`'s options plus `:source`, `:except`, `:root` and
`:home`. `PRECOMPILED_SOURCE` works instead of `:source`. Keep the
archive named `precompiled*.ez`: another name can make
`:code.priv_dir/1` miss the root of trust.

## Supported versions

Elixir 1.17 or later on OTP 27 or later. CI runs 1.17/27, 1.18/27, 1.19/28
and 1.20/29. The portal currently builds with Elixir 1.19.3 and 1.20.3 on
OTP 28 and 29. A build serves the same Elixir minor at the same or a later
patch, on the same OTP major, so other toolchains compile everything.
Igniter's installer needs Elixir 1.18.
