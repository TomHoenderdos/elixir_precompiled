# Device test (qemu)

An end-to-end test of `Precompiled.install/2` on a real Nerves firmware. It
builds a firmware for `nerves_system_qemu_aarch64` 0.5.1 (`fixture/`), boots
it in `qemu-system-aarch64`, and drives the install scenarios over ssh,
where `nerves_ssh` evaluates each command as Elixir. It is a separate Mix
project; the library's own test suite does not run it.

**It talks to the public portal**, `https://compatibility.nerves-project.org/api/precompiled`,
with the library's defaults: the fixture configures nothing for
`:elixir_precompiled`, so the test also proves that the defaults (on, the
official signed source) work with nothing configured. It needs the portal to
have builds of `recon` 2.5.6 (`pure_elixir`) and `circuits_gpio` 2.3.1 for
`nerves_system_qemu_aarch64` 0.5.1, Elixir 1.20.3 and OTP 29.

## What it proves

The tests run in file order: the cache tests build on the earlier installs.

- **No Mix.** The release has no `Mix` module, the device layer is loaded,
  and no `:elixir_precompiled` config is set. With `DEVICE_TEST_MODE=embedded`
  it also checks that the VM runs in embedded mode.
- **recon.** A `pure_elixir` package installs from the portal and runs
  (`:recon.info/2`).
- **circuits_gpio.** A NIF package installs the build made for this Nerves
  system, and its NIF is loaded (`Circuits.GPIO.backend_info/0` names the
  cdev backend).
- **Production smoke.** A dry run plans against production, writes the
  device report, and installs nothing.
- **Negatives.** An app the firmware already has is refused
  (`:already_present`); with `/data` remounted `noexec` a NIF install is
  refused (`{:noexec, "/root"}`); an unsynchronized clock refuses an online
  install; once `/data` is `exec` again the same install goes through.
- **Reboot.** After a reboot nothing installed is loaded, `list/0` still
  shows the cached build, and installing again loads it from the cache with
  no download.
- **A changed cached file.** A beam overwritten on `/data` between boots is
  never loaded: the next install downloads the build again.
- **clean/0.** It empties the cache but keeps what is loaded.
- **Offline.** A bundle written on the host with `mix precompiled.bundle`
  and copied to `/data` over sftp installs with the guest network down; once
  one of its files is changed, the install fails with a sha256 mismatch.

## Prerequisites

- `qemu-system-aarch64` (on macOS, `brew install qemu`; Apple silicon runs
  it with `hvf`, Linux on aarch64 with `kvm`, anything else under TCG,
  which takes minutes per boot), `fwup`, `ssh` and `sftp`.
- Docker and the worker image `ncc-worker:local` (Elixir 1.20.3, OTP 29,
  `nerves_bootstrap`, `fwup`). It is built locally from the portal
  repository and not published; `DEVICE_TEST_IMAGE` names another image
  with the same tools.
- Elixir and OTP on the host for the harness and for
  `mix precompiled.bundle` (run from the repository root).
- A throwaway ssh key pair, outside the repository:

  ```bash
  ssh-keygen -t ed25519 -N "" -f "$TMPDIR/device-test-key"
  ```

  The public key is built into the firmware's `nerves_ssh` config from
  `DEVICE_TEST_PUBKEY`; the harness logs in with `DEVICE_TEST_KEY`.

## Running it

```bash
cd integration/device
DEVICE_TEST_PUBKEY="$(cat "$TMPDIR/device-test-key.pub")" ./build_firmware.sh
DEVICE_TEST_KEY="$TMPDIR/device-test-key" mix test --only qemu
```

`build_firmware.sh` runs `mix deps.get && mix firmware` for the fixture in
the image, as the invoking user, with the repository mounted at `/src` and
the network on. The Nerves artifacts and the Hex cache stay in `_qemu/home`
between builds.

The suite boots a fresh disk image, kills qemu when it ends, and appends
the guest console to `_qemu/qemu.log`. To boot the firmware by hand:

```bash
./run_qemu.sh            # or ./run_qemu.sh --offline
ssh -p 10022 -i "$TMPDIR/device-test-key" -o StrictHostKeyChecking=no localhost 'IO.puts(1 + 1)'
```

For the embedded-mode run, build with `EMBEDDED=1` and test with
`DEVICE_TEST_MODE=embedded`:

```bash
EMBEDDED=1 DEVICE_TEST_PUBKEY="$(cat "$TMPDIR/device-test-key.pub")" ./build_firmware.sh
DEVICE_TEST_MODE=embedded DEVICE_TEST_KEY="$TMPDIR/device-test-key" mix test --only qemu
```
