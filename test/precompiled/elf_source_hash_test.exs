# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ElfSourceHashTest do
  use ExUnit.Case, async: true

  # The portal carries the source this reader is a verbatim copy of, and
  # the same test with the same constant. Changing the reader means
  # changing both.
  @hash "595c45615d5ef194f4887184cc197910e90d7fb53d636eeb1c5037526bd5e140"

  @source Path.expand("../../lib/precompiled/elf.ex", __DIR__)

  test "the reader's source matches the portal's copy" do
    lines = @source |> File.read!() |> String.split("\n")
    [defmodule_line | body] = Enum.drop_while(lines, &String.starts_with?(&1, "#"))
    assert String.starts_with?(defmodule_line, "defmodule ")

    normalised = body |> Enum.join("\n") |> String.replace("Precompiled.Elf", "ELF")
    assert :crypto.hash(:sha256, normalised) |> Base.encode16(case: :lower) == @hash
  end
end
