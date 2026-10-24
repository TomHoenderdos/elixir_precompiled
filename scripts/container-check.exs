# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Runs on the worker image's toolchain, which is what built the portal's
# pure_elixir entries, so both deps must HIT.
NervesPrecompiled.install([{:jason, "1.4.5"}, {:decimal, "3.2.0"}],
  source: "https://compatibility.nerves-project.org/api/precompiled"
)

IO.puts("Jason.encode!(%{a: 1}) => " <> Jason.encode!(%{a: 1}))
