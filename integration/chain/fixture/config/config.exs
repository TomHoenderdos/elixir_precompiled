# SPDX-FileCopyrightText: None
#
# SPDX-License-Identifier: CC0-1.0
#
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# A fixed SOURCE_DATE_EPOCH, so two builds of the same lock are comparable.
# See https://reproducible-builds.org/docs/source-date-epoch/
config :nerves, source_date_epoch: "1792484640"

# The chain test passes CHAIN_SOURCE; the default is the production portal.
config :precompiled,
  source:
    System.get_env("CHAIN_SOURCE", "https://compatibility.nerves-project.org/api/precompiled")

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

# A conformance case's client config (clock offset, root, source), written by
# the harness for one build. Imported last, after the host or target config
# and the operator's site file they import, so nothing overrides the case.
if client = System.get_env("CHAIN_CLIENT_CONFIG"), do: import_config(client)
