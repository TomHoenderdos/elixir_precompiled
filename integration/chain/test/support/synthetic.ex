# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Synthetic do
  @moduledoc """
  Synthetic fixture trees: a `mix.lock`, a `_build/<target>_dev/lib` with
  installed or compiled deps, format-2 manifests and a verified-batch info
  map, so the build-side checks run without Nerves, a network or a device.
  """

  @doc "Lowercase hex sha256."
  @spec sha(binary()) :: String.t()
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc """
  Lays out `<root>/mix.lock` and returns `build_lib`
  (`<root>/_build/<target>_dev/lib`). `lock` is `%{dep => {version, outer}}`;
  the system `nerves_system_<target>` is locked at `system_version`.
  """
  @spec tree(Path.t(), String.t(), %{atom() => {String.t(), String.t()}}, String.t()) :: Path.t()
  def tree(root, target, lock, system_version \\ "2.2.1") do
    system = :"nerves_system_#{target}"

    entries =
      lock
      |> Map.put(system, {system_version, String.duplicate("e", 64)})
      |> Enum.map(fn {dep, {vsn, outer}} ->
        ~s(  "#{dep}": {:hex, #{inspect(dep)}, #{inspect(vsn)}, "inner", [:mix], [], ) <>
          ~s("hexpm", #{inspect(outer)}},\n)
      end)

    File.mkdir_p!(root)
    File.write!(Path.join(root, "mix.lock"), "%{\n" <> Enum.join(entries) <> "}\n")
    build_lib = Path.join([root, "_build", "#{target}_dev", "lib"])
    File.mkdir_p!(build_lib)
    build_lib
  end

  @doc """
  Writes `files` (`%{"ebin/x.beam" => bytes}`) under `<build_lib>/<dep>` and
  the `.mix` files of `kind`: `:installed` (marker + provenance, what the
  client writes), `:elixir` (Mix compiled an Elixir dep), `:scm` (a rebar or
  make dep Mix compiled: marker only).
  """
  @spec dep(Path.t(), atom(), %{String.t() => binary()}, :installed | :elixir | :scm, map()) ::
          Path.t()
  def dep(build_lib, dep, files, kind, provenance \\ %{}) do
    dir = Path.join(build_lib, to_string(dep))

    for {path, bytes} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, bytes)
    end

    mix = Path.join(dir, ".mix")
    File.mkdir_p!(mix)
    File.write!(Path.join(mix, "compile.elixir_scm"), "marker")

    case kind do
      :installed ->
        File.write!(Path.join(mix, "elixir_precompiled.json"), JSON.encode!(provenance))

      :elixir ->
        File.write!(Path.join(mix, "compile.elixir"), "manifest")

      :scm ->
        :ok
    end

    dir
  end

  @doc "A manifest file entry for `path` with `bytes`."
  @spec file_entry(String.t(), binary(), non_neg_integer()) :: map()
  def file_entry(path, bytes, mode \\ 0o100644),
    do: %{"path" => path, "sha256" => sha(bytes), "size" => byte_size(bytes), "mode" => mode}

  @doc """
  One format-2 build. `opts`: `:target` (default `"pure_elixir"`),
  `:system_version`, `:elixir`, `:otp`, `:outer`, `:run_id`.
  """
  @spec build(%{String.t() => binary()} | [{String.t(), binary()}], keyword()) :: map()
  def build(files, opts) do
    {ebin, priv} = Enum.split_with(files, fn {p, _} -> String.starts_with?(p, "ebin/") end)

    %{
      "target" => Keyword.get(opts, :target, "pure_elixir"),
      "ebin" => Enum.map(ebin, fn {p, b} -> file_entry(p, b) end),
      "priv" => Enum.map(priv, fn {p, b} -> file_entry(p, b, 0o100755) end),
      "build" => %{
        "elixir" => Keyword.get(opts, :elixir, System.version()),
        "otp" => Keyword.get(opts, :otp, System.otp_release()),
        "dep_env" => "prod",
        "package_checksum" => Keyword.fetch!(opts, :outer),
        "deps" => %{},
        "compile_env" => [],
        "run_id" => Keyword.get(opts, :run_id, "run-1"),
        "system_version" => Keyword.get(opts, :system_version)
      }
    }
  end

  @doc "A format-2 manifest document with `builds` for `version`."
  @spec manifest(String.t(), [map()]) :: String.t()
  def manifest(version, builds),
    do: JSON.encode!(%{"format" => 2, "versions" => %{version => %{"builds" => builds}}})

  @doc "Writes `bytes` as `<served>/<dir>/<name>.json`."
  @spec serve_manifest(Path.t(), String.t(), String.t(), binary()) :: :ok
  def serve_manifest(served, dir, name, bytes) do
    path = Path.join([served, dir, name <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  @doc "A verified-batch info map, as `ChainTest.Trust.check/1` returns it."
  @spec info(integer(), map(), map()) :: map()
  def info(sequence, v2, v1 \\ %{}),
    do: %{sequence: sequence, root_version: 1, manifests: v1, manifests_v2: v2}

  @doc "A client report map with `lines` of `{name, version, status, detail}`."
  @spec report([{String.t(), String.t(), String.t(), String.t()}]) :: map()
  def report(lines) do
    %{
      "format" => 1,
      "lines" =>
        Enum.map(lines, fn {n, v, s, d} ->
          %{"name" => n, "version" => v, "status" => s, "detail" => d}
        end)
    }
  end
end
