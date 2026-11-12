# On a device

`Precompiled.install/1` installs a signed precompiled library into a
running Nerves device, from an IEx shell on it (over ssh or the console),
with no Mix, no Hex and no compiler on the device. Something goes wrong in
the field and you need `recon` or another diagnostic tool: install it on
that device instead of shipping a debug firmware. It picks the build made
for the device's own Nerves system and versions, checks every byte through
the signed chain, loads it and starts it. It never replaces anything the
firmware has, and nothing it installs is loaded at boot.

## Setup

    mix igniter.install precompiled --device

(which also sets up the build-time step of [Setup](setup.md)), or by hand,
in the firmware's `mix.exs`: the dependency without `runtime: false`, so
the library ships in the firmware, and `castore` when the system has no
CA certificates of its own (see [CA certificates](trust.md#ca-certificates)):

```elixir
{:precompiled, "~> 0.3", targets: @all_targets},
{:castore, "~> 1.0", targets: @all_targets}
```

Nothing else. It is on by default and uses the official signed source,
`https://compatibility.nerves-project.org/api/precompiled`, checked
against the root this library ships. Nothing runs on its own: it only
ever acts when someone with a shell on the device calls it.

To limit it, turn it off, or point it elsewhere, set
`config :precompiled, :device` in the firmware's config
(`config/target.exs`, say):

```elixir
config :precompiled, :device,
  allow: [:recon, :circuits_gpio]

# or, to turn it off in this firmware:
config :precompiled, :device, enabled: false
```

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | `false` disables installing: `install/2` returns `{:error, :disabled}`. `list/1`, `uninstall/2` and `clean/1` keep working, so what is installed can still be removed. |
| `allow` | any app | A list of apps: only those may be installed, closure members included. |
| `source` | the official API | Another source: an `https://` API root, or a `file://` bundle dir. The only place a network source can be set. |
| `dir` | `/data/precompiled` | Where installs are stored. |
| `max_bytes` | 64 MB | The size bound of that store. |
| `cacerts_path` | none | A PEM CA bundle to verify the source with. |
| `root` | the shipped `root.json` | Another trust anchor. Set here only: a call cannot pass it. |
| `content` | the batch's | Mirror or CDN origins (`https://`) to fetch files from. Set here only: a call cannot pass it. |
| `deadline_seconds`, `max_closure`, `start`, `closure`, `quiet` | as in the options below | Firmware-wide defaults for those `install/2` options. |

`enabled` and `allow` are read from the firmware's config only: a call can
neither pass, widen nor clear them. Any other key under `:device` is
ignored.

Online installs need `:inets`, `:ssl` and `:public_key` in the release
(Nerves firmware with networking usually has them). A firmware that only
installs from bundles can leave them out; an online call then returns
`{:error, {:missing_app, app}}`.

## Usage

```elixir
Precompiled.install(:recon)
Precompiled.install({:circuits_gpio, "2.3.1"})
Precompiled.install([:recon, {:circuits_gpio, "~> 2.3"}])
Precompiled.install(:recon, dry_run: true)
Precompiled.install(:recon, source: "file:///media/usb/precompiled")
Precompiled.list()
Precompiled.uninstall(:recon)
Precompiled.clean()
```

A bare name takes the newest version with a build that matches; a version
or a requirement narrows it. Absent runtime dependencies are installed with
the package, as one unit: anything that fails takes the code path and the
loaded apps back to how they were. Each step prints one line:

```
precompiled: system nerves_system_rpi4 2.2.1, OTP 29, Elixir 1.20.3, aarch64
precompiled: circuits_gpio 2.3.1   PLAN  nerves_system_rpi4, 198 KB
precompiled: circuits_gpio 2.3.1   OK    /data/precompiled/circuits_gpio-2.3.1
precompiled: 1 installed, 198 KB, 2.1 s
{:ok, [%Precompiled.Installed{app: :circuits_gpio, ...}]}
```

- `install/2` returns `{:ok, [%Precompiled.Installed{}]}` with the apps it
  installed (`[]` when everything was already there), or
  `{:error, reason}`. It never raises on the network or on bad input.
- `dry_run: true` plans, checks the trust chain and fetches only the
  manifests and `.app` files, and returns `{:ok, %Precompiled.Plan{}}`.
- `list/1` prints and returns what is in the store, each with its size,
  the batch it was checked against, and whether it is loaded; or
  `{:error, reason}` for a bad option or an unsafe store.
- `uninstall/2` stops the app, unloads it, purges its modules and takes it
  off the code path. Its files stay in the store as a cache
  (`remove: true` drops them). It refuses while other installed apps need
  it (`cascade: true` uninstalls those first) or while other processes run
  its code (`force: true`). Only running code counts: open resources are
  not detected, so an uninstall goes ahead while a shell still holds, say,
  a GPIO handle from `Circuits.GPIO.open/2`. Close such handles
  (`Circuits.GPIO.close/1`) first.
- `clean/1` empties the store, but keeps what is loaded.

The options of `install/2`:

| Option | Default | Meaning |
| --- | --- | --- |
| `:source` | the `:device` config, else the official API | `file://DIR` for a bundle only. A per-call `https://` or `http://` source returns `{:error, {:source_not_allowed, source}}`: a network source is firmware config only (see [Trust](trust.md)). A per-call `:content` returns `{:error, {:content_not_allowed, origins}}` the same way. |
| `:deadline_seconds` | as on the host | See [Configuration](configuration.md). |
| `:cacerts_path` | none | A PEM CA bundle (see [CA certificates](trust.md#ca-certificates)). |
| `:dir` | `/data/precompiled` | The store. Its trust state lives in `DIR/.trust`, so another `:dir` has its own trust state, starting again from the shipped root. |
| `:start` | `true` | Start the installed apps (`:temporary`). `false` only loads them. |
| `:closure` | `true` | Install absent runtime dependencies. `false` refuses with `{:needs, [{app, vsn}]}` instead. |
| `:max_closure` | 25 | The most apps one call installs. |
| `:max_bytes` | 64 MB | The size bound of the store. |
| `:dry_run` | `false` | Plan only, as above. |
| `:report` | none | With `dry_run: true`, also write the device facts and the plan as JSON to this path, for `mix precompiled.bundle --device-report`. |
| `:quiet` | `false` | Print nothing. |

An unknown option is refused (`{:bad_option, key}`), never ignored.
`list/1` and `clean/1` take `dir` and `quiet`; they also accept the other
options of `install/2` and `uninstall/2`, so one options list serves all
calls, and ignore them.
[`Precompiled`](https://hexdocs.pm/precompiled/Precompiled.html#module-return-values)'s module documentation lists every error reason.

## What it refuses

- **Anything the device already has.** An app the firmware has, loaded or
  only shipped in the release, is never replaced: `install(:logger)`
  returns `{:error, {:already_present, :logger, vsn}}`. Apps are matched by
  name and exact version: a build made against `nerves_ssh` 1.3.3 is
  refused on a device with 1.3.2 (`NO  built against nerves_ssh 1.3.3,
  device has 1.3.2`).
- **Conflicts.** A module that is already loaded, or that the code path
  already finds, refuses the install (`{:module_loaded, mod, path}`,
  `{:module_conflict, mod, path}`), and so do two versions of one app in
  one call (`{:conflict, app, vsns}`).
- **Other systems.** A system build serves only the Nerves system it was
  made for, matched by name (read from `/usr/lib/os-release`); builds are
  made for official Nerves systems. It must be for the device's exact
  system version, or for another release of that system: a beam-only
  build always (without the source scan a build machine runs, see
  [Known limitations](limitations.md#matching)), a native one when the
  batch's systems table says the device's release has the same toolchain
  series, an OTP no older than the build's and every library the build
  needs ([What matches](matching.md#the-fine-print)). The exact version
  wins, then the closest older release, then the lowest newer one. A
  `pure_elixir` build serves any device, and a device whose system is not
  known takes `pure_elixir` builds only. When both kinds match, the system
  build wins. A native library made for another CPU is refused
  (`{:elf, why}`).
- **Missing libraries.** Before a native build is installed, every library
  it needs is looked up in the device's own `/lib` and `/usr/lib`, and
  must define the symbol versions the build needs. This holds for the
  exact system version too. A build that needs something the device does
  not have is refused (`{:libs, app, reason}`, with `reason.code`
  `:needed_lib_missing` or `:symbol_version_missing`).
- **noexec.** A build with native code is refused when the store is on a
  `noexec` mount (`{:noexec, mount}`).
- **An unset clock.** An online call refuses before any request until the
  clock is synchronized (`NervesTime.synchronized?/0` when `nerves_time` is
  in the firmware): `{:error, {:clock_unsynchronized, now}}`. Set the
  clock or wait for NTP, then retry. A bundle needs no NTP: one without
  `offline.json` is judged by its batch's expiry against the device clock,
  which must be sane; one with a signed `offline.json` needs no clock.

## The cache

Installs stay in the store on `/data` across reboots, but nothing is
loaded at boot: after a reboot `list/0` shows them as cached, not loaded.
Installing the same build again loads it from the store with no download,
after checking every cached file against the signed hashes of the current
batch; a cached build the batch no longer names, or one whose files
changed, is downloaded again and never loaded. The store is bounded by
`max_bytes`, and the least recently used builds that are not loaded are
evicted to make room, before anything is downloaded, so a stale cache never
fills `/data` under a new install. `Precompiled.clean/0` empties it.

The store dir is created `0700`, and must not be writable by group or
others and must be owned by the VM's user. One call at a time changes it.
The same store reached through a link (`/data` is a link to `/root` on
Nerves) is one store; the store dir itself must not be a symlink.

## Bundles: installing with no network

A bundle is a directory with the API's own layout, holding exactly what a
device needs, written on a host with network:

    mix precompiled.bundle recon circuits_gpio@2.3.1 --out bundle \
      --system nerves_system_rpi4@2.2.1 --otp 29 --elixir 1.20.3

It plans on the host as the device would, from the device's facts: the
flags (`--pure` for a device with no Nerves system, `--cpu` for another
CPU than `aarch64-unknown-linux-gnu`), or the JSON a dry run wrote on the
device itself (`Precompiled.install(:recon, dry_run: true, report:
"/data/report.json")`, then `--device-report report.json`). Every byte is
checked against its signed hash before it is written. `mix help
precompiled.bundle` has the details.

Copy the directory to the device (a USB stick, or `sftp` to `/data`) and
install from it:

```elixir
Precompiled.install([:recon, :circuits_gpio], source: "file:///data/bundle")
```

A `file://` install opens no connection and needs no network apps. The
device checks everything again, exactly as over https. A bundle's
`batch.json` is the online batch, so it is valid for 24 hours after the
portal issued it. For a device that stays offline longer, the bundle
carries an `offline.json`, signed by the root's `offline` role with
`mix portal.precompiled.sign_offline` from the portal's repository (see
its `PRECOMPILED_API.md`, "Offline bundles"), within a day of the batch's
issue. An offline document has no expiry and needs no clock. The device
honours it only from a `file://` source, only when its root has an
`offline` role (a device can adopt a newer root from the bundle's
`root.json`, when that root chains from the one it trusts), and never with
a sequence below the highest it has seen. The root this library ships has
no `offline` role yet, so for now a bundle is valid for its batch's 24
hours.

## Trust and CA certificates

The device checks the same signed chain as the host: see
[Trust on the device](trust.md#trust-on-the-device) and
[CA certificates](trust.md#ca-certificates).

## Not supported

- **Hot upgrades.** An app that is present is refused, never replaced:
  no appups and no `code_change`.
- **Surviving a firmware update.** Nothing is loaded at boot anyway. After
  an update a cached build is used only when it still matches the new
  firmware; the firmware itself should include what it needs.
- **Git, path or private packages**, and anything that is not in the
  signed batch.
- **Protocol consolidation.** An installed protocol implementation for a
  protocol the release consolidated is not dispatched; the install says so
  with a `WARN` line.
