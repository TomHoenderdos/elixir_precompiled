# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
Precompiled.Fixture.start_link()

ExUnit.start()

# Integration tests start child VMs against the local test server: run
# them with `mix test --only integration`. The one test that needs the
# public portal is tagged :production alone, so `--only integration` never
# reaches it: run it with `mix test --only production`.
# Tests tagged :linux need a Linux device file (/dev/full).
ExUnit.configure(
  exclude: [
    integration: true,
    production: true,
    linux: not match?({:unix, :linux}, :os.type())
  ]
)
