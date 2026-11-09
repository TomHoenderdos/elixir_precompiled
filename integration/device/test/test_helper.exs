# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# The qemu tests boot a firmware and talk to the public portal: they run
# only with `mix test --only qemu`, in file order (the cache tests build on
# the earlier installs).
ExUnit.start(exclude: [:qemu], seed: 0)
