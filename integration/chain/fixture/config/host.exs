# SPDX-FileCopyrightText: None
#
# SPDX-License-Identifier: CC0-1.0
#
import Config

# On host the KV store is in memory and carries no firmware UUID, so the
# probe reports "firmware_uuid": null there.
config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}
