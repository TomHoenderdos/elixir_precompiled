# Setup

## Any Mix project (plain, Phoenix, libraries)

With [Igniter](https://hex.pm/packages/igniter) (Elixir 1.18 or later):

    mix igniter.install precompiled

It adds the dependency as `runtime: false` and puts
`"deps.compile precompiled", "precompiled.deps"` at the front of
the `deps.loadpaths` alias, before any steps already there. Running it
again changes nothing. Igniter is an optional dependency: a project that
does not use it never fetches it.

By hand, two lines:

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
    {:precompiled, "~> 0.3", runtime: false},
    ...
  ]
end
```

No config is needed: the source is the portal's signed API,
`https://compatibility.nerves-project.org/api/precompiled`, checked
against the root of trust this library ships.

For unreleased changes, the git form works too:
`{:precompiled, github: "TomHoenderdos/elixir_precompiled", runtime: false}`
(and `mix archive.install github TomHoenderdos/elixir_precompiled` for
the archive below).

Every `mix compile`, `mix test`, `mix run`, [`mix phx.server`](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Server.html) and
`mix release` passes through `deps.loadpaths` before Mix compiles
dependencies; the alias installs the matching builds first. The first
entry compiles this library so its task exists. Without it, Mix would
compile every dependency before the task could run. Keep the dependency
in every environment (no `only:`), since `mix test` runs in `test`.

`config :precompiled, source: ..., root: ...` points it at another
source and root, for a self-hosted mirror of the API, and `content:
[...]` adds file mirrors. Those keys are project config only: no option,
call or environment variable sets them, because a source or mirror
learns which dependencies you use and a root decides whose builds run
(see [Trust](trust.md)).

On the host, only `pure_elixir` builds can match. The portal builds those
with Elixir 1.19.3 and 1.20.3 on OTP 28 and 29 today, so other toolchains
compile everything (see [Supported versions](#supported-versions)).

## Umbrella

Put the alias in the umbrella root's `mix.exs`; add the dependency to any
one app (or all of them), and any config to the root `config/config.exs`.
The Igniter installer does not edit umbrellas.

## Phoenix

Nothing beyond the above: [`mix phx.server`](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Server.html), `mix test` and `mix release`
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
  manifests and files still come from the cache. While the question is
  out, dependencies are matched against the cached batch; the answer
  still decides what is installed.

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
One cell (or the top of a script) does it all:

```elixir
Mix.start()

unless Code.ensure_loaded?(Precompiled.Host) do
  Mix.Local.append_archives()

  unless Code.ensure_loaded?(Precompiled.Host) do
    Mix.Hex.ensure_installed?(true)
    Mix.Task.run("archive.install", ["hex", "precompiled", "--force"])
    Mix.Local.append_archives()
  end
end

Precompiled.Host.install([{:jason, "1.4.5"}, {:decimal, "3.2.0"}])
```

It loads the `precompiled` archive, installing it first when it is
missing, then calls `Precompiled.Host.install/2`: `Mix.install/2` with
matching builds installed first and the rest compiled by Mix. The first
run builds the archive once; later runs find it. `Mix.Hex.ensure_installed?/1`
is internal Mix API, needed only when Hex is not installed yet.

Or install the archive once from a terminal, into the Mix home the
runtime uses, and keep only the last line:

    mix archive.install hex precompiled

Builds of these two exist for Elixir 1.20 on OTP 29 today; on other
versions they compile as usual. `Precompiled.Host.install/2` takes
`Mix.install/2`'s options plus `:except` and `:home`; `:source`, `:root`
and `:content` raise, since they are project config only. Keep the archive named
`precompiled*.ez`: another name can make `:code.priv_dir/1` miss the
root of trust.

## Supported versions

Elixir 1.17 or later on OTP 27 or later. CI runs 1.17/27, 1.18/27, 1.19/28
and 1.20/29. The portal currently builds with Elixir 1.19.3 and 1.20.3 on
OTP 28 and 29. A build serves the same Elixir minor at the same or a later
patch, on the same OTP major, so other toolchains compile everything.
Igniter's installer needs Elixir 1.18.
