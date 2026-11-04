# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ElixirPrecompiled.SourceScanTest do
  use ExUnit.Case, async: true
  alias ElixirPrecompiled.SourceScan
  @moduletag :tmp_dir

  defp dep(dir, files) do
    for {path, src} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, src)
    end

    dir
  end

  test "module-level reads count, reads inside functions and quotes do not", %{tmp_dir: dir} do
    dep(dir, %{
      "lib/a.ex" => """
      defmodule A do
        @target Mix.target()
        @port System.get_env("A_PORT")
        def f(), do: {Mix.target(), System.get_env("RUNTIME_ONLY")}
        defmacro m(), do: quote(do: System.get_env("CALLER"))
      end
      """
    })

    assert SourceScan.scan(dir) == %{target: true, env: ["A_PORT"]}
  end

  test "mix.exs counts Mix.target anywhere and ignores its env reads", %{tmp_dir: dir} do
    dep(dir, %{
      "mix.exs" => """
      defmodule B.MixProject do
        use Mix.Project
        def project, do: [app: :b, version: "1.0.0", make_env: %{"T" => to_string(Mix.target()), "X" => System.get_env("CC")}]
      end
      """,
      "lib/b.ex" => "defmodule B do\n  def f(), do: :ok\nend\n"
    })

    assert SourceScan.scan(dir) == %{target: true, env: []}
  end

  test "MIX_TARGET through System.get_env is a target read", %{tmp_dir: dir} do
    dep(dir, %{
      "lib/c.ex" =>
        ~s|defmodule C do\n  if System.get_env("MIX_TARGET") == "host", do: def(f(), do: 1)\nend\n|
    })

    assert SourceScan.scan(dir) == %{target: true, env: []}
  end

  test "a computed env var name is reported as such", %{tmp_dir: dir} do
    dep(dir, %{
      "lib/c.ex" => ~s|defmodule C do\n  @v System.fetch_env!("X_" <> "Y")\nend\n|
    })

    assert SourceScan.scan(dir) == %{target: false, env: ["(computed name)"]}
  end

  test "a clean dep reads nothing; an unparsable one is treated as reading everything", %{
    tmp_dir: dir
  } do
    clean =
      dep(Path.join(dir, "clean"), %{"lib/d.ex" => "defmodule D do\n  def f(), do: 1\nend\n"})

    assert SourceScan.scan(clean) == %{target: false, env: []}
    broken = dep(Path.join(dir, "broken"), %{"lib/e.ex" => "defmodule E do\n  def f( do\n"})
    assert SourceScan.scan(broken) == %{target: true, env: ["(unparsable source)"]}
  end

  test "results are cached by package checksum", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n  @t Mix.target()\nend\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("ab", 32)
    assert %{target: true} = SourceScan.cached(home, d, key)
    File.rm_rf!(d)
    assert %{target: true} = SourceScan.cached(home, d, key)
    # Not a checksum: never a file name, scanned every time.
    assert %{target: false} = SourceScan.cached(home, Path.join(dir, "none"), "../x")
  end

  test "a cache entry that is not a regular file is never read", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n  @t Mix.target()\nend\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("cd", 32)
    planted = Path.join(dir, "planted.term")
    File.write!(planted, :erlang.term_to_binary(%{target: false, env: []}))
    File.mkdir_p!(Path.join(home, "scan"))
    File.ln_s!(planted, Path.join([home, "scan", key <> ".term"]))

    assert %{target: true} = SourceScan.cached(home, d, key)
  end
end
