# Trust

`precompiled` puts code from the internet into your build, so it has to be
sure that code is exactly what the portal built and signed. This page
shows how each byte is checked before it is used, and what happens when a
check fails.

The short version: **nothing unsigned or unhashed is ever installed, and
every failed check falls back to compiling from source.**

## The chain

Each step is verified by the one above it:

```
root.json        shipped in this library (priv/precompiled/root.json)
   │ names the signing key of
   ▼
batch.json       signed index, published every 15 minutes
   │ names the SHA-256 of
   ▼
manifest         one per package: its builds and their files
   │ names the SHA-256 and size of
   ▼
file             a beam, .app or priv file
```

- The root is an Ed25519 key, valid until 2027-10-22.
- Plain `http` sources are refused, except on loopback.

## Mirrors and redirects

A batch may name content origins (a CDN) to fetch files and manifests
from before the source itself. You can override them with `:content`.

- Everything from a mirror is checked against the hashes in the signed
  batch and manifests. A bad mirror can only cause a fallback to the
  source, or a miss. It can never cause a wrong install.
- Redirects are followed only within the same origin, or to a listed
  content origin.

## Batch checks

A batch must pass all of these, on top of its signature:

| Check | Refused when | Message |
| --- | --- | --- |
| Signature | not signed by a key the root names | `batch signature invalid` |
| Expiry | past its `expires` | `batch expired at ...` |
| Sequence | older than one this machine already saw | `batch sequence N is older than M` |
| Staleness | `issued` more than 24 hours ago | `batch stale: ...` |
| Future | `issued` more than 5 minutes ahead of your clock | `clock: ...` |
| Lifetime | valid for more than 30 days past `issued` | `batch lifetime over 30 days ...` |
| Format | `issued` does not parse | `batch malformed` |
| Your clock | earlier than the moment this library was built | `clock is before ...` |

A batch the source never delivered (a network error, a 4xx or 5xx, a
refused redirect) is reported as `batch unavailable: <why>`.

Every refusal falls back to compiling.

`clock_offset_seconds` shifts the client's idea of "now" for these checks.
It is for tests only: it is read only from project config, never from an
environment variable.

### Caching and going offline

- The verified batch is kept in the state dir and revalidated with its
  ETag. A cached batch passes exactly the same checks as a fresh one.
- The served root is checked at most once an hour, and whenever a batch
  fails to verify. A root rotation reaches a warm client within that hour.
- **The source can't be reached** (transport error, 5xx, the run's
  deadline): a cached batch that still passes every check is used, and
  one line says so.
- **The source answered, but the answer was refused** (bad signature,
  older sequence, expired): it never falls back to the cache.

## Builds you already have

Every run, `Precompiled.Host.install/2` included, rechecks what an earlier
run installed against the current batch:

| The installed build… | What happens |
| --- | --- |
| is no longer in the batch | removed, compiled from source |
| still passes every rule of [What matches](matching.md) with exactly the files on disk | kept as it is, even if a newer portal run made the same build again |
| anything else | replaced or removed |
| is newly listed in `:except` | removed, compiled from source (also without a batch) |

When no batch is available (offline, or refused), installed builds are
left alone and the run prints one warning instead of a FAIL line each:

```
precompiled: no fresh batch (<reason>); N installed builds kept, not rechecked
```

Dependencies Mix is about to compile still get their own FAIL line.
`report.json` lists each kept build as `fail`, with a detail ending in
`(installed build kept)`.

## What an install may contain

Before anything is placed, every path in a build is checked:

- a plain relative path, inside the dependency's own build dir, with a
  safe mode (`unsafe path or mode (...)`);
- no two paths may collide, including case and Unicode-normalisation
  variants (`path collision: ...`);
- `ebin/` holds only `.beam` files, `<dep>.app` and `<dep>.appup`
  (anything else, such as another app's `.app`, is `foreign path: ...`);
- the `.app` lists exactly the beams that ship.

Cache entries are never followed through symlinks.

## Root rotation

Rotation follows [TUF](https://theupdateframework.io):

- each new root must be signed by the previous root's root keys, up to
  its threshold, and carry a higher version;
- only the root in use must be unexpired, so an old root that expires
  after a newer one was adopted does not break the chain.

Once a root is adopted, its version becomes a floor. If the stored roots
go missing (deleted, truncated, rolled back), the run reports an error
instead of quietly accepting an older root:

```
root version N is older than M
```

To accept the older root on purpose, delete the `root_version` file the
error names, under the trust state dir in `PRECOMPILED_HOME`. A state file
that exists but doesn't parse (batch sequence or root version) is logged
as a warning and treated as 0.

## Who you are trusting today

> **Today the root and batch roles share one Ed25519 key, threshold 1,
> held online by the portal.** Whoever controls the portal host can rotate
> the root and ship code to every opted-in host and device, until a
> library release ships a new root.

The proposals for splitting the roles are in the compatibility
repository's `docs/PRECOMPILED_SIGNING_PROPOSALS.md`.

## Trust on the device

The device checks the same chain as the host: the root this library ships
(or the firmware's `root`), the signed batch, each manifest by hash, and
each file by hash and size.

1. A file is staged, verified, and only then moved into the store.
2. Just before loading, the loader hashes the `.app`, every beam and
   every `priv` file once more.
3. The beams are loaded from those verified bytes.

Nothing unsigned is ever loaded, nothing is compiled, and no fallback
skips a check. An online batch must pass the batch checks above, which is
why the device clock must be set.

## CA certificates

An `https` source is verified with the first of these that exists:

1. `cacerts_path` in the config;
2. the file in `PRECOMPILED_CACERTS_PATH` or `HEX_CACERTS_PATH`;
3. the system's own store (`:public_key.cacerts_get/0`);
4. the `castore` package's bundle, when it is in the firmware.

With none of them, the call fails with `no CA certificates`.

Many Nerves systems ship their own store (`nerves_system_qemu_aarch64`
does). Add `castore` for a system whose store is empty, or to not depend
on it. `mix igniter.install precompiled --device` adds `castore` unless
the project already depends on it.
