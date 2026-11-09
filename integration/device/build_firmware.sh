#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Builds the qemu_aarch64 test firmware inside the worker image, which has the
# Elixir, OTP, nerves_bootstrap and fwup the system needs. Needs
# DEVICE_TEST_PUBKEY (the public key nerves_ssh accepts). EMBEDDED=1 builds a
# firmware that boots with -mode embedded.
#
# The image (ncc-worker:local, override with DEVICE_TEST_IMAGE) is built
# locally from the portal repository; it is not published.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
target="${MIX_TARGET:-qemu_aarch64}"
image="${DEVICE_TEST_IMAGE:-ncc-worker:local}"
: "${DEVICE_TEST_PUBKEY:?set DEVICE_TEST_PUBKEY to the test public key}"

# A writable home for the Nerves artifacts and the Hex cache, kept between
# builds. The image's Mix archives (hex, nerves_bootstrap) stay read-only.
mkdir -p "$here/_qemu/home"

docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/src/integration/device/_qemu/home \
  -e MIX_HOME=/home/nerves/.mix \
  -e HEX_HOME=/src/integration/device/_qemu/home/.hex \
  -e MIX_TARGET="$target" -e DEVICE_TEST_PUBKEY -e EMBEDDED="${EMBEDDED:-}" \
  -v "$repo:/src" -w /src/integration/device/fixture \
  --entrypoint sh "$image" -c 'mix deps.get && mix firmware'
