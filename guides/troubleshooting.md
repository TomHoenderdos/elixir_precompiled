# Troubleshooting

`precompiled` never fails your build: when something is wrong, the
affected dependencies compile from source and one line says why. Find
that line below.

## Getting more detail

| Set | To |
| --- | --- |
| `PRECOMPILED_DEBUG=1` | also list the dependencies that were not candidates, and why |
| `PRECOMPILED=0` | rule the library out completely: it removes its installs and Mix compiles everything |

## Setup

| Line | Meaning | What to do |
| --- | --- | --- |
| `ArgumentError: precompiled: :source is not an option` (or `:root`) | `Precompiled.Host.install/2` was given a source or root. | Drop the option: the official API is the default. A self-hosted source goes in the project's config ([Trust](trust.md#where-the-source-and-root-come-from)). |
| `{:error, {:source_not_allowed, source}}` | A device call named a network source. | Drop it, or set it in the firmware's `config :precompiled, :device`. Per call, only `file://` bundles. |
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
[What matches](matching.md) for all the rules. One worth knowing:

| Line | Meaning |
| --- | --- |
| `MISS  reads Mix.target() at compile time ...` | Rule 8: no build was made for your target name. It compiles from source. |

## A bug

| Line | Meaning | What to do |
| --- | --- | --- |
| `internal error, compiling from source` | A bug in this library. Your build carries on. | Please [report it](https://github.com/TomHoenderdos/elixir_precompiled/issues) with the line. |

Still stuck? See [Known limitations](limitations.md).
