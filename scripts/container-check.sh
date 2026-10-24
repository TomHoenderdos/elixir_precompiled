#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# NervesPrecompiled.install/2 inside the compatibility worker image against
# the production portal. The image's Elixir/OTP is the one the portal builds
# with, so this is the device path with the device's exact toolchain, minus
# the device.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${NCC_IMAGE:-ncc-worker:local}"

docker run --rm --entrypoint sh \
  -v "$PWD:/src:ro" \
  -e MIX_INSTALL_DIR=/tmp/installs \
  -e NERVES_PRECOMPILED_HOME=/tmp/precompiled-home \
  "$IMAGE" -c '
    set -e
    cp -r /src /tmp/lib && cd /tmp/lib && rm -rf _build deps
    MIX_ENV=prod mix compile
    cd /tmp
    elixir -pa /tmp/lib/_build/prod/lib/nerves_precompiled/ebin /tmp/lib/scripts/container-check.exs
  '
