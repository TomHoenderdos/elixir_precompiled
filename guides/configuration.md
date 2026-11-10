# Configuration

| Key or variable | Meaning |
| --- | --- |
| `:source` | The precompiled API URL. Default: `https://compatibility.nerves-project.org/api/precompiled`. `https` only (`http` on loopback). Config only. |
| `:except` | Dependencies never installed precompiled, e.g. `[:ash]`. |
| `:content` | Content origins (mirrors, CDNs) to fetch files and manifests from instead of the ones the signed batch names. `https` only (`http` on loopback). |
| `:root` | A `root.json` to trust instead of the one this library ships. Config only. |
| `:home` / `PRECOMPILED_HOME` | Cache and trust state dir. The config key beats the variable. Default: the user cache dir (`:filename.basedir(:user_cache, "precompiled")`). `PRECOMPILED_HOME=~/.nerves/precompiled` keeps using the pre-rename cache. |
| `:deadline_seconds` | All network for one run (default 300); what is still waiting then compiles. Root and batch get 15 s together, connects 5 s. |
| `:root_check_seconds` | How often the served root is checked for a rotation (default 3600; a batch that fails to verify checks it at once). |
| `:cache_max_mb` | Cache size bound (default 4096), least recently used evicted, checked once a day. Trust state is never evicted. |
| `PRECOMPILED=0` | Off: installs nothing and removes earlier installs. |
| `PRECOMPILED_OFFLINE=1` | No network: the cached batch (while fresh) and cached files only. |
| `PRECOMPILED_CACERTS_PATH` (or `HEX_CACERTS_PATH`) | A PEM CA bundle that replaces the OS store (TLS-intercepting proxies). Verification stays on; only the bundle's CAs are trusted. |
| `HTTPS_PROXY`/`https_proxy`, `HTTP_PROXY`/`http_proxy`, `NO_PROXY`/`no_proxy` | Proxies, as Hex reads them. Credentials in the proxy URL are sent only to the proxy. `NO_PROXY` takes host names, domains (`.corp.example`), IP addresses and `*`; CIDR ranges are ignored. |
| `PRECOMPILED_DEBUG=1` | Also print each dependency that was not a candidate, and why. |

The keys go in `config :precompiled, ...`; `Precompiled.Host.install/2`
also takes `:except` and `:home` as options. `:source` and `:root` are
project config only: no option or environment variable sets them,
because a source learns which dependencies you use and a root decides
whose builds run (see [Trust](trust.md)). The old names (`config :nerves_precompiled`,
`config :nerves, :precompiled`, `NERVES_PRECOMPILED*`) are still read for
one release, when the new ones are unset.

## Turning it off

- `PRECOMPILED=0` (`false` and `no` work too) turns it off and removes the builds it installed, so Mix
  compiles them in that same run. Only build dirs this library wrote are
  removed, never one Mix compiled, and only in the `_build` of the run's
  own env and target: a run on `host` removes host installs, never a
  device target's.
- `mix precompiled.clean` removes this `_build`'s installs.
  `--cache` also empties the download cache (files, manifests and source
  scans), from the same cache dir a run uses.
- `:except` keeps listed dependencies compiled from source; an earlier
  install of one is removed.

## Seeing what happened

Every candidate prints one line, then a summary:

```
precompiled: ash 3.36.0                   HIT   4.1 MB
precompiled: nerves_pack 0.7.1            MISS  built with nerves_ssh 1.3.3, project has 1.3.2
precompiled: 40 hit, 5 miss, 0 fail of 45 deps, 61.2 MB, 8.3 s
```

A warm run whose installs the batch still vouches for prints nothing.

- `mix precompiled.status` lists what is installed in this `_build`, with
  the batch and manifest each came from.
- `_build/<env>/lib/.precompiled/report.json` (`"format": 1`) holds the
  last run that printed lines.
- Each installed dependency carries `.mix/precompiled.json`.
