# Trust

The library ships the portal's root of trust (`priv/precompiled/root.json`,
Ed25519, expires 2027-10-22). Every batch index is signed by a key the root
names; every manifest is fetched by the hash the batch names; every file by
the hash the manifest names. Nothing unsigned or unhashed reaches `_build`.
Plain `http` sources are refused except on loopback.

The batch may name content origins (a CDN) that files and manifests are
fetched from before the source; the project can override them with
`:content`. Everything fetched from them is checked against the hashes in
the signed batch and manifests. A bad mirror can therefore only cause a
fallback to the source or a miss, never a wrong install. Redirects are
followed only within the request's origin or to a listed content origin.

The verified batch is kept in the state dir and revalidated with its ETag.
A cached batch passes the same signature, freshness and sequence checks
as a fresh one. The served root is checked at most once an hour (and
whenever a batch fails to verify), so a root rotation reaches a warm client
within that hour. When the source cannot be reached (a transport error, a
5xx, the run deadline), a cached batch that still passes every check is
used and one line says so; a response the source did give and that is
refused (bad signature, an older sequence, an expired batch) never falls
back to the cache.

A batch is also checked for freshness, on top of its signature, expiry and
sequence: it is refused when its `issued` timestamp is more than 24 hours
ago ("batch stale"), more than 5 minutes in the future ("clock"), when it
stays valid for more than 30 days past `issued` ("batch lifetime"), or when
`issued` does not parse ("batch malformed"). A local clock reading earlier
than the moment this library was built is refused outright ("clock"),
since none of the above can be trusted on it. A batch the source did not
deliver (a network error, a 4xx or 5xx, a refused redirect, no usable
cached batch to stand in) is reported as `batch unavailable: <why>`; a
batch that was delivered and fails a check is reported by the check alone:
`batch signature invalid`, `batch stale: ...`, `batch expired at ...`,
`batch sequence N is older than M`, `batch lifetime over 30 days ...`,
`batch malformed`, `clock: ...` or `clock is before ...`. Every refusal
falls back to compiling.
`clock_offset_seconds` moves the client's notion of now for these checks;
it is test-only, read only from project config, and never from an
environment variable.

Every run, `Precompiled.Host.install/2` included, also rechecks builds an
earlier run installed (into a Mix project's `_build` or into the
`Mix.install/2` project) against the current batch: one the batch no
longer names is removed and compiled from source; one whose build still
passes every rule of [What matches](matching.md) with exactly the files
on disk is kept as it is, even when a newer portal run made the same
build again; any other is replaced or removed. One newly listed in
`:except` is removed and compiled from source whether or not a batch is
fetched. When no batch is available (offline, or refused), installed
builds are left as they are and the run prints one warning,
`precompiled: no fresh batch (<reason>); N installed builds kept, not
rechecked`, rather than a FAIL line per dependency; dependencies Mix is
about to compile still get their own FAIL line with the reason.
`report.json` lists every kept build as `fail` with a detail ending
`(installed build kept)`.

An install is checked before it is placed: every path must be a plain
relative path inside the dependency's own build dir, with a safe mode
(`unsafe path or mode (...)`); no two paths may collide, including case
and Unicode-normalisation variants (`path collision: ...`); `ebin/` may
hold only `.beam` files, `<dep>.app` and `<dep>.appup` (anything else,
such as another app's `.app`, is `foreign path: ...`); and the `.app` must
list exactly the beams shipped. Cache entries are never
followed through symlinks.

Root rotation follows TUF: each adopted root must be signed by the
previous root's root keys (to its threshold) and carry a higher version,
and only the root in use must be unexpired, so a root that expires after
a newer one was adopted does not end the chain.

Once a root is adopted, its version is kept as a floor that a later run
will not go back below; `roots.json` losing the entries that reached it
(deleted, truncated, rolled back) is reported as an error rather than
silently accepted (`root version N is older than M`); deleting the
`root_version` file the error names, under the trust state dir in
`PRECOMPILED_HOME`, accepts the older root. A state file that exists
but will not parse (the batch sequence or the root version) is logged as a
warning and treated as 0.

Today the root and batch roles are one Ed25519 key, threshold 1, held
online by the portal. Whoever controls the portal host can therefore
rotate the root and ship code to every opted-in host and device, until a
library release ships a new root. The proposals for splitting the roles
are in the compatibility repository's `docs/PRECOMPILED_SIGNING_PROPOSALS.md`.

## Trust on the device

The device checks the same chain as the host: the root this library ships
(or the firmware's `root`), the signed batch, each manifest by the hash the batch names,
and each file by the hash its manifest names, size included. A file is
staged, verified and only then moved into the store; the loader hashes the
`.app`, every beam and every `priv` file once more just before anything
loads, and loads the beams from those verified bytes. Nothing unsigned is
ever loaded, nothing is compiled, and there is no fallback that skips a
check. An online batch must pass the freshness checks above,
which is why the clock must be set.

## CA certificates

An `https` source is verified with, in this order: `cacerts_path`, the
`PRECOMPILED_CACERTS_PATH` or `HEX_CACERTS_PATH` file, the system's
own store (`:public_key.cacerts_get/0`), then the `castore` package's
bundle when it is in the firmware. With none of them, the call fails
(`no CA certificates`). Many Nerves systems ship a store of their own
(`nerves_system_qemu_aarch64` does); add `castore` for one whose store is
empty, or to be independent of it.
`mix igniter.install precompiled --device` adds `castore` unless the
project already depends on it.
