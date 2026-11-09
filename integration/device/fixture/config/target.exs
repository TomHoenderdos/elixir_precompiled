# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
import Config

# Start the basic Nerves services as early as allowed.
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Check that every OTP application started.
config :nerves_runtime, startup_guard_enabled: true

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# The test's throwaway public key, read at build time so no key enters the
# repository (README.md).
config :nerves_ssh, authorized_keys: [System.fetch_env!("DEVICE_TEST_PUBKEY")]

# qemu user networking hands out an address over DHCP on eth0. nerves_time
# keeps its default NTP servers.
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}
  ]

config :mdns_lite,
  hosts: [:hostname, "nerves"],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22}
  ]
