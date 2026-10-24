# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
NervesPrecompiled.Fixture.start_link()

ExUnit.start()

# Integration tests need the network (hex.pm and the production portal).
# Run them with: mix test --include integration
ExUnit.configure(exclude: [integration: true])
