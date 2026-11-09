#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Boots the test firmware (build_firmware.sh) in qemu, with the guest's ssh on
# localhost:10022. --offline boots it with no guest network (restrict=on);
# the ssh forward still works. The disk image is made from the firmware when
# it is missing or older than the firmware, and otherwise kept, so /data
# survives a restart. The flags are those of the system's own
# `mix nerves.gen.qemu`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fw="$here/fixture/_build/qemu_aarch64_dev/nerves/images/device_fixture.fw"
img="$here/_qemu/disk.img"
# Where build_firmware.sh's Nerves home unpacks the system artifact.
loader="$here/_qemu/home/.nerves/artifacts/nerves_system_qemu_aarch64-portable-0.5.1/images/little_loader.elf"

[ -f "$fw" ] || { echo "no firmware at $fw; run build_firmware.sh" >&2; exit 1; }
[ -f "$loader" ] || { echo "no little_loader.elf at $loader" >&2; exit 1; }
mkdir -p "$here/_qemu"
if [ ! -f "$img" ] || [ "$fw" -nt "$img" ]; then
  rm -f "$img"
  fwup -a -i "$fw" -d "$img" -t complete
fi

net="user,id=eth0,hostfwd=tcp:127.0.0.1:10022-:22"
[ "${1:-}" = "--offline" ] && net="$net,restrict=on"

machine="virt"
cpu="cortex-a53"
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) machine="virt,accel=hvf"; cpu="host" ;;
  Linux/aarch64) [ -w /dev/kvm ] && { machine="virt,accel=kvm"; cpu="host"; } ;;
esac

exec qemu-system-aarch64 \
  -machine "$machine" \
  -cpu "$cpu" \
  -smp 2 \
  -m 1024M \
  -kernel "$loader" \
  -netdev "$net" \
  -device virtio-net-device,netdev=eth0,mac=fe:db:ed:de:d0:01 \
  -global virtio-mmio.force-legacy=false \
  -drive if=none,file="$img",format=raw,id=vdisk \
  -device virtio-blk-device,drive=vdisk,bus=virtio-mmio-bus.0 \
  -nographic
