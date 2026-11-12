# Troubleshooting

`precompiled` never fails your build: when something is wrong, the
affected dependencies compile from source and one line says why. Find
that line below.

## Getting more detail

| Set | To |
| --- | --- |
| `PRECOMPILED_DEBUG=1` | also list the dependencies that were not candidates, and why |
| `PRECOMPILED=0` | rule the library out completely: it removes its installs and Mix compiles everything |

## Reporting a miss

When a dependency misses or fails and it should not, send the build's
report so it can be looked at:

```
mix precompiled.report
```

Run it with the same `MIX_ENV` and `MIX_TARGET` as the build: it reads
that build's `report.json`, which needs precompiled 0.4.0 or later (an
older build's `report.json` lacks the fields a report needs; the task
notices and sends nothing rather than guessing). It always prints what
it would send and asks before sending anything:

| Flag | Effect |
| --- | --- |
| *(none)* | Shows the report, then asks `[y/N]`; anything but `y` or `yes`, including a non-interactive terminal such as CI, sends nothing |
| `--yes` | Skips the question and sends (for CI) |
| `--contact @you` | Adds a handle for follow-up questions (printable text, at most 100 characters once redacted) |
| `--dump` | Prints the exact JSON to stdout and sends nothing; everything else goes to stderr, so stdout alone can be redirected to a file |
| `--dump out.json` | Writes the JSON to `out.json` instead, and sends nothing |

In a script or Livebook, after `Precompiled.Host.install/2`:
`Precompiled.Host.report()` shows the report; Livebook has no terminal
to answer `[y/N]`, so it stops there. `Precompiled.Host.report(yes: true)`
sends it.

Reporting never fails a build or a script: any problem prints one line,
and `mix precompiled.report` always exits 0.

### What is sent, and what never is

| Sent | Never sent |
| --- | --- |
| Each candidate's name, version, HIT/MISS/FAIL and reason code and text | The project's name, its directory, the host name, the OS user name |
| The Elixir and OTP versions, the OS family and CPU architecture | Config values or environment variables |
| The target and, when it is one of the project's public Hex dependencies, the Nerves system and its version | A private, git or path package's name — only public Hex packages are ever named |
| The public Hex lock entries (name, version, checksum) of the reported dependencies and theirs in turn | — |
| `--contact`, if given | — |

A Nerves system that is *not* a public Hex package (an in-house or
unpublished one) is sent as `custom` with no version, and so is the
target of any line whose reason would otherwise name the real target
(for example "not built for this target"). The project's directory,
home directory, the configured source and mirror hosts, and the local
host name are replaced by `<redacted>` wherever a reason's free text
contains them, regardless of case; `--contact` loses those too, plus
the project's app name, its directory's own name and the OS user name.
Names, versions, targets and reason codes themselves are never
rewritten by this — a host that happens to share a name with a
dependency must not turn that dependency's line into noise.

### An example

This is the `--dump` of a host project with `jason`, `decimal`,
`phoenix`, `circuits_gpio` and a package from a private Hex organisation,
`acme_secret`. The private package is left out of both the lines and the
lock, and the checksums are shortened here only to keep the example
readable.

```json
{
  "built_at": "2026-11-10T14:02:11Z",
  "client": "0.4.0",
  "contact": "@my-github-handle",
  "elixir": "1.20.3",
  "format": 1,
  "lines": [
    {
      "name": "jason",
      "reason": "installed",
      "reason_args": [],
      "reason_code": "hit",
      "status": "hit",
      "version": "1.4.4"
    },
    {
      "name": "decimal",
      "reason": "installed",
      "reason_args": [],
      "reason_code": "hit",
      "status": "hit",
      "version": "2.3.0"
    },
    {
      "name": "telemetry",
      "reason": "not built for 1.3.0",
      "reason_args": [
        "1.3.0"
      ],
      "reason_code": "not_built_version",
      "status": "miss",
      "version": "1.3.0"
    },
    {
      "name": "phoenix",
      "reason": "built against telemetry 1.2.1, lock has 1.3.0",
      "reason_args": [
        "telemetry",
        "1.2.1",
        "1.3.0"
      ],
      "reason_code": "closure_mismatch",
      "status": "miss",
      "version": "1.8.1"
    },
    {
      "name": "circuits_gpio",
      "reason": "not built for host 1.20",
      "reason_args": [
        "host",
        "1.20"
      ],
      "reason_code": "not_built_target",
      "status": "miss",
      "version": "2.1.2"
    }
  ],
  "lock": [
    {
      "checksum": "bbbbbbbb…",
      "name": "jason",
      "version": "1.4.4"
    },
    {
      "checksum": "dddddddd…",
      "name": "decimal",
      "version": "2.3.0"
    },
    {
      "checksum": "22222222…",
      "name": "telemetry",
      "version": "1.3.0"
    },
    {
      "checksum": "ffffffff…",
      "name": "phoenix",
      "version": "1.8.1"
    },
    {
      "checksum": "44444444…",
      "name": "circuits_gpio",
      "version": "2.1.2"
    }
  ],
  "os": {
    "arch": "aarch64-apple-darwin",
    "family": "unix"
  },
  "otp": 29,
  "target": "host"
}
```

### Retracting a report

A new report answers with its id, printed once:

```
precompiled: report 3f9c2b7a-...
```

That id is the only way to retract it:

```
curl -X DELETE <source>/reports/<id>
```

Keep it somewhere. Sending the exact same report again answers
"already received" and prints no id — the source hands an id out only
once, so a second report of the same build cannot be used to retract
the first one. A "not built" miss of a package the portal already
tracks may be queued for a build from the report alone.

A build with no candidate dependencies does not write a new
`report.json`: the previous one stays in place, and that is what
`mix precompiled.report` sends. The command's summary shows how old it
is, so it is clear when it is not from the latest build.

## Setup

| Line | Meaning | What to do |
| --- | --- | --- |
| `ArgumentError: precompiled: :source is not an option` (or `:root`, `:content`) | `Precompiled.Host.install/2` was given a source, root or content origins. | Drop the option: the official API is the default. A self-hosted source goes in the project's config ([Trust](trust.md#where-the-source-and-root-come-from)). |
| `{:error, {:source_not_allowed, source}}` | A device call named a network source. | Drop it, or set it in the firmware's `config :precompiled, :device`. Per call, only `file://` bundles. |
| `{:error, {:content_not_allowed, origins}}` | A device call named content origins (mirrors). | Drop it, or set `content:` in the firmware's `config :precompiled, :device`. |
| `source must be https (http only on loopback), disabled: ...` | The configured source is plain `http` or not a URL; nothing installs. | Fix `config :precompiled, source:`. |

## Nothing installs: the batch

Without a usable batch, nothing installs and everything compiles.

| Line | Meaning | What to do |
| --- | --- | --- |
| `batch unavailable: <why>` | The source sent no batch (network error, 4xx/5xx, refused redirect) and no cached one could stand in. | Check the network or the source URL. |
| `batch signature invalid` | A batch arrived but isn't signed by a key your root trusts. | Report it: the source or a mirror serves something wrong. |
| `batch stale: ...`, `batch expired at ...` | The batch is too old. | Usually the source stopped publishing; try again later. |
| `batch sequence N is older than M` | The source served an older batch than this machine already saw. | A rollback or a stale mirror; it is refused on purpose. |
| `batch lifetime ...`, `batch malformed` | The batch is not valid. | Report it. |

See [Trust](trust.md#batch-checks) for every batch check.

## Working offline

| Line | Meaning | What to do |
| --- | --- | --- |
| `source unreachable (<why>); using the cached batch` | The network failed; a cached batch that still passes every check stood in. | Nothing. Files that are not in the cache miss straight away; the source is not asked again in that run. |
| `batch unavailable: offline, no cached batch` | `PRECOMPILED_OFFLINE=1` is set and this machine has no batch yet. | Run once online to fill the cache. |
| `no fresh batch (<why>); N installed builds kept, not rechecked` | Earlier installs stay as they are. | Nothing; they are rechecked once a batch is available again. |

## Clock

| Line | Meaning | What to do |
| --- | --- | --- |
| `clock is before ...` | The machine's clock is wrong, typically a device before NTP. | Set the clock. Nothing installs until then. |
| `clock: ...` | A batch claims to be from the future. | Check the clock. |

## Cache

| Line | Meaning | What to do |
| --- | --- | --- |
| `cache dir ... is not writable; using ...` | The run used a fresh cache under `_build`. | Fix the permissions, or set `PRECOMPILED_HOME`. |
| `FAIL  cache refused (... remove it)` | A cache entry is a symlink or not a plain file; it is never followed. | Remove the path the line names. |

## A dependency misses

A `MISS` line names the rule that the closest build broke; see
[What matches](matching.md) for all the rules. Some worth knowing:

| Line | Meaning |
| --- | --- |
| `MISS  reads Mix.target() at compile time ...` | Rule 8: no build was made for your target name. It compiles from source. |
| `MISS  project sets :manager for this dependency` | Rule 9: your `deps` entry, or a package's `mix.exs`, changes how Mix builds it, with `:manager`, `:compile` or `:system_env`. It always compiles from source. |
| `MISS  built with rebar3, project builds with make` | Rule 9: the build was made by another manager than Mix uses for it here. It compiles from source. |
| `MISS  build method unknown (deps did not load: ...)` | Rule 9: `Precompiled.Host.install/2` could not load the dependencies through Mix (the warning above names why), so no build can be confirmed. Everything compiles from source. |
| `MISS  built with rebar3, project's manager for it is unknown` | Rule 9: Mix resolved no manager for the dependency here (often: its sources are not fetched yet), so the build's cannot be confirmed. It compiles from source. |

### Builds from another release of your system

These lines come from rule 1, when the only builds are for other
releases of your Nerves system (see
[What matches](matching.md#the-fine-print)). Each one leaves the
dependency compiling from source; the code in brackets is the
`reason_code` a report carries.

| Line | Meaning | What to do |
| --- | --- | --- |
| `MISS  built for nerves_system_rpi4 2.1.0 (toolchain 15.3), project has 2.3.0 (toolchain 15.4)` (`system_version_abi`) | The build has native code, and was made with another toolchain series (or another toolchain package) than your release uses. A `?` means that toolchain's series is not known. | Nothing to fix: a build for your release, or for one on the same series, will match once the portal has one. |
| `MISS  built on OTP 28.2.0, release has 28.1.0` (`toolchain_otp_minor`) | The native build was made on a newer OTP than your release ships, or another OTP major. A `?` means one of the two is not recorded. | Nothing to fix; a build made on your OTP, or an older one of the same major, will match. Moving to a newer system release often helps. |
| `MISS  libssl.so.3 missing on target` (`needed_lib_missing`) | The native code needs a shared library your release does not have. On a device, the device itself lacks it. | Use a system release that includes the library, or let it compile from source. On a device, check the firmware's system. |
| `MISS  libstdc++.so.6 lacks GLIBCXX_3.4.32` (`symbol_version_missing`) | Your release (or on a device, the device) has the library, but an older one that does not define a symbol version the native code needs. | As above: a newer system release, or a build made on yours. |
| `MISS  nerves_system_rpi4 2.4.0 not yet known to the portal` (`system_unknown`) | The batch's systems table has no entry for your release, or not yet its libraries or OTP, so no native build from another release can be checked against it. | Wait: the portal records new releases of a system after they appear, and native builds start to match then. Builds made on your exact release still match now. |
| `MISS  reads the Nerves system at compile time` (`system_bound_compile`) | A beam-only build from another release, of a dependency whose sources read the Nerves system (`Nerves.Env`) at compile time, so its beams may carry the system's version or settings. | Nothing to fix: only a build made on your exact release matches it. |
| `MISS  build predates elf` (`build_predates`) | A native build from another release that does not record which libraries it needs, so it cannot be checked against your release. | Nothing to fix; newer builds record it. |

On a device, `needed_lib_missing` and `symbol_version_missing` also come
from the check against the device's own libraries, for builds of your
exact release too: `{:error, {:libs, app, reason}}`.

## A bug

| Line | Meaning | What to do |
| --- | --- | --- |
| `internal error, compiling from source` | A bug in this library. Your build carries on. | Please [report it](https://github.com/TomHoenderdos/elixir_precompiled/issues) with the line. |

Still stuck? See [Known limitations](limitations.md).
