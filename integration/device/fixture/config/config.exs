# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# A fixed SOURCE_DATE_EPOCH, so two builds of the same lock are comparable.
# See https://reproducible-builds.org/docs/source-date-epoch/
config :nerves, source_date_epoch: "1794262280"

# No :elixir_precompiled config anywhere: the test proves the defaults (on,
# the official source) with nothing configured.

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
