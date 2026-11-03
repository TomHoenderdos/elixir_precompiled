# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# The fixture's expected precompiled hits for every target, and the deps that
# must never be installed precompiled. A pinned dep that turns from hit into
# miss fails the chain test with the client's reason; bump this file together
# with mix.lock.
%{
  hits: [:exqlite, :argon2_elixir, :circuits_gpio, :jason, :ash, :spark, :reactor, :plug],
  never: [:nerves, :elixir_precompiled]
}
