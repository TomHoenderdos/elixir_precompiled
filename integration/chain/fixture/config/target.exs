# SPDX-FileCopyrightText: None
#
# SPDX-License-Identifier: CC0-1.0
#
import Config

# Start logging and the basic Nerves services as early as allowed.
config :nerves, application_sort: [init: [:nerves_runtime, :nerves_pack]]

# Check that every OTP application started; on a system that supports test
# runs of new firmware, a firmware that fails this reverts to the previous one.
config :nerves_runtime, startup_guard_enabled: true

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Network, nerves_ssh authorized keys and mdns_lite live in an operator file
# outside the repository (see README.md). It is imported last so it can
# override anything above.
site = System.get_env("CHAIN_TARGET_CONFIG", Path.expand("~/.config/chain_test/target.exs"))

if File.exists?(site),
  do: import_config(site),
  else:
    Mix.raise("chain fixture: no site config at #{site} (network and nerves_ssh authorized_keys)")
