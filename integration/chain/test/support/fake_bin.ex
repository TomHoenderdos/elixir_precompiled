# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.FakeBin do
  @moduledoc """
  Writes executable shell stubs into a fresh tmp dir and puts that dir on
  `PATH` for the duration of one function call.

  Every stub records its argv, one argument per line, in `<dir>/<name>.argv`
  before running its body; `argv/2` reads it back.
  """

  @doc """
  Runs `fun.(dir)` with the `stubs` (`%{name => sh body}`) on `PATH`.

  `path: :prepend` (default) puts the stub dir in front of the current
  `PATH`; `path: :only` uses the stub dir plus `/bin:/usr/bin`, so a tool that
  is not stubbed is not found.
  """
  def with_stubs(stubs, fun, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "chain_fake_bin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {name, body} <- stubs do
      path = Path.join(dir, name)
      argv = Path.join(dir, name <> ".argv")
      File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{argv}'\n#{body}\n")
      File.chmod!(path, 0o755)
    end

    old = System.get_env("PATH")

    new =
      case Keyword.get(opts, :path, :prepend) do
        :prepend -> dir <> ":" <> (old || "")
        :only -> dir <> ":/bin:/usr/bin"
      end

    System.put_env("PATH", new)

    try do
      fun.(dir)
    after
      System.put_env("PATH", old || "")
      File.rm_rf(dir)
    end
  end

  @doc "The argv the stub `name` was last called with, or `nil` if it never ran."
  def argv(dir, name) do
    case File.read(Path.join(dir, name <> ".argv")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, _} -> nil
    end
  end
end
