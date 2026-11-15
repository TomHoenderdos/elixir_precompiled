# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.MixProject.CompileCache do
  @moduledoc false
  # This library's own compiled modules, kept next to its sources in the
  # project's deps dir, so a fresh _build (another MIX_ENV or MIX_TARGET,
  # `rm -rf _build`, `mix clean --deps`) does not compile it again.
  #
  # Loaded by the `compile.precompiled_cache` compiler in mix.exs, which
  # Mix runs before the Elixir compiler when it compiles this library as
  # a dependency. Only for the Hex package (`hex_metadata.config` in the
  # dep dir): a path or git checkout is someone's working copy and is never
  # written to. The cache lives in the dep dir itself, so whoever can write
  # it can already change the sources Mix compiles: it trusts nothing new.
  #
  # An entry is the compile path's beams and the Elixir compiler's manifest,
  # under a key over everything the compile reads (the toolchain, the dep
  # dir, compiler options, every source file, the deps' .app files). It is
  # restored only into a compile path with neither, every file checked
  # against the sha256 the index recorded, the manifest written last; any
  # failure removes what was written and Mix compiles as before. Mix then
  # checks the restored manifest as it checks its own: a changed source,
  # mix.exs or compile-time config still recompiles.
  #
  # `PRECOMPILED_COMPILE_CACHE=0` turns it off.

  @root ".compile_cache"
  @manifest "compile.elixir"

  @type inputs :: %{
          toolchain: tuple(),
          dir: String.t(),
          env: atom(),
          args: [String.t()],
          options: keyword(),
          erl_compiler_options: String.t() | nil,
          project: keyword(),
          sources: [{String.t(), binary()}],
          deps: [{atom(), binary() | nil}]
        }

  # The compiler's run/1, from mix.exs: restores before compile.elixir and
  # saves after it. Never fails the compile.
  @spec run([String.t()], String.t()) :: {:noop, []}
  def run(args, dir) do
    if enabled?(args, dir, System.get_env("PRECOMPILED_COMPILE_CACHE")) do
      root = Path.join(dir, @root)
      key = key(inputs(args, dir))
      ebin = Mix.Project.compile_path()
      manifest = Path.join(Mix.Project.manifest_path(), @manifest)
      _ = restore(root, key, ebin, manifest)

      Mix.Task.Compiler.after_compiler(:elixir, fn
        {:ok, _} = result ->
          _ = save(root, key, ebin, manifest)
          result

        result ->
          result
      end)
    end

    {:noop, []}
  rescue
    _ -> {:noop, []}
  end

  @spec enabled?([String.t()], String.t(), String.t() | nil) :: boolean()
  def enabled?(args, dir, env_var) do
    env_var != "0" and "--from-mix-deps-compile" in args and "--force" not in args and
      File.regular?(Path.join(dir, "hex_metadata.config"))
  end

  @spec key(inputs()) :: String.t()
  def key(inputs) do
    inputs = %{inputs | sources: Enum.sort(inputs.sources), deps: Enum.sort(inputs.deps)}

    :crypto.hash(:sha256, :erlang.term_to_binary({1, inputs}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # What the compile of this library reads, from inside Mix's compile of
  # it (the current project is this library).
  defp inputs(args, dir) do
    config = Mix.Project.config()
    elixirc = Mix.Utils.extract_files(config[:elixirc_paths] || ["lib"], [:ex])
    erlc = Mix.Utils.extract_files(config[:erlc_paths] || ["src"], [:erl, :hrl])
    own = ["mix.exs", Path.relative_to(__ENV__.file, dir)]

    %{
      toolchain:
        {System.version(), System.otp_release(), to_string(:erlang.system_info(:version)),
         Application.spec(:compiler, :vsn)},
      dir: dir,
      env: Mix.env(),
      args: args,
      options: Enum.sort(Code.compiler_options()),
      erl_compiler_options: System.get_env("ERL_COMPILER_OPTIONS"),
      project:
        Keyword.take(config, [:elixirc_options, :erlc_options, :erlc_include_path, :compilers]),
      sources: for(f <- Enum.uniq(elixirc ++ erlc ++ own), do: {f, digest(Path.join(dir, f))}),
      deps: for(dep <- config[:deps] || [], app = elem(dep, 0), do: {app, app_digest(app)})
    }
  end

  defp digest(path), do: :crypto.hash(:sha256, File.read!(path))

  # A dep's .app as the code path has it; nil when it is not there (an
  # optional dep the project does not use).
  defp app_digest(app) do
    case :code.lib_dir(app) do
      {:error, _} ->
        nil

      dir ->
        path = Path.join([to_string(dir), "ebin", "#{app}.app"])
        if File.regular?(path), do: digest(path)
    end
  end

  @spec restore(String.t(), String.t(), String.t(), String.t()) :: :hit | :miss | :skip
  def restore(root, key, ebin, manifest) do
    if File.exists?(manifest) or Path.wildcard(Path.join(ebin, "*.beam")) != [] do
      :skip
    else
      entry = Path.join(root, key)

      with {:ok, bin} <- File.read(Path.join(entry, "index")),
           entries when is_list(entries) <- :erlang.binary_to_term(bin, [:safe]),
           {:ok, files} <- read_all(entry, entries) do
        place(files, ebin, manifest)
      else
        _ -> :miss
      end
    end
  rescue
    _ -> :miss
  end

  defp read_all(entry, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {rel, size, sha}, {:ok, acc} when is_binary(rel) and is_integer(size) ->
        with true <- valid?(rel),
             {:ok, bytes} <- File.read(Path.join(entry, rel)),
             true <- byte_size(bytes) == size and :crypto.hash(:sha256, bytes) == sha do
          {:cont, {:ok, [{rel, bytes} | acc]}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  # Only beams directly in ebin, and the manifest.
  defp valid?(@manifest), do: true

  defp valid?("ebin/" <> name),
    do: Path.basename(name) == name and Path.extname(name) == ".beam" and name != ".beam"

  defp valid?(_), do: false

  # Beams first, the manifest last: a manifest is never there without its
  # beams. Any failure removes what this call wrote.
  defp place(files, ebin, manifest) do
    {[{_, manifest_bytes}], beams} = Enum.split_with(files, &(elem(&1, 0) == @manifest))
    File.mkdir_p!(ebin)
    File.mkdir_p!(Path.dirname(manifest))
    targets = for {"ebin/" <> name, _} <- beams, do: Path.join(ebin, name)

    try do
      for {{_, bytes}, path} <- Enum.zip(beams, targets), do: File.write!(path, bytes)
      File.write!(manifest, manifest_bytes)
      :hit
    rescue
      _ ->
        Enum.each([manifest | targets], &File.rm/1)
        :miss
    end
  rescue
    _ -> :miss
  end

  # One entry per dep dir: the newest key replaces the others. Written to a
  # temp dir and renamed into place, so a reader sees a whole entry or none.
  @spec save(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def save(root, key, ebin, manifest) do
    tmp = Path.join(root, ".tmp-#{System.pid()}-#{System.unique_integer([:positive])}")
    beams = ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort()

    try do
      File.mkdir_p!(Path.join(tmp, "ebin"))

      entries =
        for {src, rel} <-
              [{manifest, @manifest} | Enum.map(beams, &{&1, "ebin/" <> Path.basename(&1)})] do
          bytes = File.read!(src)
          File.write!(Path.join(tmp, rel), bytes)
          {rel, byte_size(bytes), :crypto.hash(:sha256, bytes)}
        end

      File.write!(Path.join(tmp, "index"), :erlang.term_to_binary(entries))
      entry = Path.join(root, key)

      # Another run may have saved the same key meanwhile; either is whole.
      if not File.dir?(entry), do: File.rename!(tmp, entry)
      prune(root, key)
      :ok
    rescue
      e -> {:error, e}
    after
      File.rm_rf(tmp)
    end
  end

  # Every other key, and temp dirs a killed run left (an hour old: a
  # younger one may be another run's save in progress).
  defp prune(root, key) do
    old = System.os_time(:second) - 3600

    for name <- File.ls!(root),
        name != key,
        path = Path.join(root, name),
        gone?(name, path, old),
        do: File.rm_rf(path)
  end

  defp gone?(".tmp-" <> _, path, old) do
    match?({:ok, %File.Stat{mtime: mtime}} when mtime < old, File.lstat(path, time: :posix))
  end

  defp gone?(_name, _path, _old), do: true
end
