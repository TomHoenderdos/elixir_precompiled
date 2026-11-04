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

  test "a clean dep reads nothing; an unparsable one is not scannable", %{
    tmp_dir: dir
  } do
    clean =
      dep(Path.join(dir, "clean"), %{"lib/d.ex" => "defmodule D do\n  def f(), do: 1\nend\n"})

    assert SourceScan.scan(clean) == %{target: false, env: []}
    broken = dep(Path.join(dir, "broken"), %{"lib/e.ex" => "defmodule E do\n  def f( do\n"})
    assert SourceScan.scan(broken) == {:unscannable, "lib/e.ex does not parse"}
  end

  test "results are cached by package checksum", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n  @t Mix.target()\nend\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("ab", 32)
    assert %{target: true} = SourceScan.cached(home, d, key)
    File.rm_rf!(d)
    entry = Path.join([home, "scan", "v1", key <> ".term"])
    File.touch!(entry, 1)
    assert %{target: true} = SourceScan.cached(home, d, key)
    # A hit marks the entry as used, so the cache gc evicts by last use.
    assert {:ok, %File.Stat{mtime: m}} = File.lstat(entry, time: :posix)
    assert m > 1
    # Not a checksum: never a file name, scanned every time.
    assert %{target: false} = SourceScan.cached(home, Path.join(dir, "none"), "../x")
  end

  test "a cache entry that is not a regular file is never read", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n  @t Mix.target()\nend\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("cd", 32)
    planted = Path.join(dir, "planted.term")
    File.write!(planted, :erlang.term_to_binary(%{target: false, env: []}))
    File.mkdir_p!(Path.join([home, "scan", "v1"]))
    File.ln_s!(planted, Path.join([home, "scan", "v1", key <> ".term"]))

    assert %{target: true} = SourceScan.cached(home, d, key)
  end

  test "a macro body outside its quote runs at the caller's compile time", %{tmp_dir: dir} do
    dep(dir, %{
      "lib/u.ex" => """
      defmodule U do
        defmacro __using__(_opts) do
          target = Mix.target()
          quote do: @target unquote(target)
        end
      end
      """
    })

    assert SourceScan.scan(dir) == %{target: true, env: []}
  end

  test "other spellings of an env or target read", %{tmp_dir: dir} do
    cases = [
      {~s|@all System.get_env()|, %{target: false, env: ["(all variables)"]}},
      {~s|@a :os.getenv('A_VAR')|, %{target: false, env: ["A_VAR"]}},
      {~s|@b :os.getenv(~c"B_VAR")|, %{target: false, env: ["B_VAR"]}},
      {~s|@c :os.getenv()|, %{target: false, env: ["(all variables)"]}},
      {~s|@t :os.getenv('MIX_TARGET')|, %{target: true, env: []}},
      {~s|@t Elixir.Mix.target()|, %{target: true, env: []}},
      {~s|@e Elixir.System.fetch_env("E_VAR")|, %{target: false, env: ["E_VAR"]}}
    ]

    for {{line, expected}, i} <- Enum.with_index(cases) do
      d = dep(Path.join(dir, "c#{i}"), %{"lib/x.ex" => "defmodule X do\n  #{line}\nend\n"})
      assert SourceScan.scan(d) == expected, line
    end
  end

  test "a file over 2 MB or sources over 20 MB are not scannable", %{tmp_dir: dir} do
    pad = fn n -> "defmodule P do\n  #" <> String.duplicate("x", n) <> "\nend\n" end
    big = dep(Path.join(dir, "big"), %{"lib/big.ex" => pad.(2 * 1024 * 1024)})
    assert SourceScan.scan(big) == {:unscannable, "lib/big.ex is over 2 MB"}

    many = for i <- 1..11, into: %{}, do: {"lib/f#{i}.ex", pad.(2_000_000)}

    assert SourceScan.scan(dep(Path.join(dir, "many"), many)) ==
             {:unscannable, "sources over 20 MB"}
  end

  test "a passed deadline makes the dep unscannable, and that is not cached", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n  def f(), do: 1\nend\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("ef", 32)
    past = System.monotonic_time(:millisecond) - 1
    assert {:unscannable, "run deadline passed"} = SourceScan.cached(home, d, key, past)
    assert %{target: false, env: []} = SourceScan.cached(home, d, key)
  end

  # Only what the package's bytes decide is cached under its checksum: an
  # I/O error says something about this disk today, not about the package.
  test "a source that cannot be read is unscannable, and that is not cached", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n  @t Mix.target()\nend\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("cd", 32)
    src = Path.join(d, "lib/a.ex")
    File.chmod!(src, 0o000)

    try do
      assert {:unscannable, "lib/a.ex: " <> _} = SourceScan.cached(home, d, key)
    after
      File.chmod!(src, 0o644)
    end

    assert %{target: true} = SourceScan.cached(home, d, key)
  end

  test "a source that does not parse is unscannable, and that is cached", %{tmp_dir: dir} do
    d = dep(Path.join(dir, "dep"), %{"lib/a.ex" => "defmodule A do\n"})
    home = Path.join(dir, "home")
    key = String.duplicate("ab", 32)
    assert {:unscannable, "lib/a.ex does not parse"} = SourceScan.cached(home, d, key)
    File.write!(Path.join(d, "lib/a.ex"), "defmodule A do\nend\n")
    assert {:unscannable, "lib/a.ex does not parse"} = SourceScan.cached(home, d, key)
  end
end

defmodule ElixirPrecompiled.SourceScanAtomsTest do
  # Not async: the atom table is global, and other tests create atoms.
  use ExUnit.Case, async: false
  alias ElixirPrecompiled.SourceScan
  @moduletag :tmp_dir

  test "scanning creates no atom for the identifiers a source names", %{tmp_dir: dir} do
    tag = "ep#{System.unique_integer([:positive])}"
    n = 2000
    mod = String.capitalize(tag)

    body =
      for i <- 1..n, into: "" do
        "  def #{tag}_f#{i}(#{tag}_v#{i}), do: {:#{tag}_a#{i}, #{tag}_k#{i}: #{mod}M#{i}.x()}\n"
      end

    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(
      Path.join(dir, "lib/n.ex"),
      "defmodule #{mod} do\n  @x #{mod}.Y.z()\n" <> body <> "end\n"
    )

    before = :erlang.system_info(:atom_count)
    assert %{target: false, env: []} = SourceScan.scan(dir)
    assert :erlang.system_info(:atom_count) - before < 100
  end
end
