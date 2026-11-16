# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.HostNative do
  @moduledoc false
  # Host-native builds (`config :precompiled, host_native: true`): a
  # package's beams and priv libraries built on a Linux glibc machine of one
  # triple, served to another machine of that triple. This module reads the
  # running machine (its triple, full OTP version, NIF version and library
  # dirs) and holds the rules only those builds have; Match applies them
  # with the rules every host build passes.
  #
  # The `.so` of a package that downloads its own NIF (rustler_precompiled,
  # evision) is the upstream release file, pinned by the package's own
  # checksum file in the lock-pinned tarball. The build names that file and
  # the archive in `origins`; the archive must be listed there with its
  # sha256 here too. The checksum file is read as data with
  # Code.string_to_quoted/2 and never evaluated: anything but a literal map
  # of names to sha256 strings is no checksum file.

  alias Precompiled.Reason

  @type host :: %{
          triple: String.t() | nil,
          system_architecture: String.t(),
          otp_full: String.t() | nil,
          nif_version: String.t(),
          lib_roots: [Path.t()]
        }

  # The ldconfig -p flag each triple's own libraries carry (glibc's
  # elf/cache.c); a 32-bit library of a multiarch host has none of them.
  @ldconfig_flags %{"x86_64-linux-gnu" => "x86-64", "aarch64-linux-gnu" => "AArch64"}
  @machines %{"x86_64-linux-gnu" => :x86_64, "aarch64-linux-gnu" => :aarch64}
  @ldconfig_paths ["/sbin/ldconfig", "/usr/sbin/ldconfig"]
  @max_ldconfig_bytes 4 * 1024 * 1024
  @max_checksum_bytes 1024 * 1024
  @checksum_file ~r/\Achecksum(-[A-Za-z0-9_.]+)?\.exs\z/
  @sha256 ~r/\Asha256:[0-9a-f]{64}\z/

  @doc false
  # This machine, as host-native builds are matched against it.
  @spec host() :: host()
  def host() do
    arch = List.to_string(:erlang.system_info(:system_architecture))
    triple = triple(arch)

    %{
      triple: triple,
      system_architecture: arch,
      otp_full: otp_full(),
      nif_version: List.to_string(:erlang.system_info(:nif_version)),
      lib_roots: if(triple, do: lib_roots(triple), else: [])
    }
  end

  @doc false
  # The normalised triple of a `:system_architecture` string, nil for one
  # no host-native build is made for: x86_64 or aarch64 (amd64 and arm64
  # are the same machines) on Linux with glibc, the string ending in
  # "-linux-gnu". musl, darwin and gnueabihf are none.
  @spec triple(String.t()) :: String.t() | nil
  def triple(arch) when is_binary(arch) do
    with true <- String.ends_with?(arch, "-linux-gnu"),
         [cpu | _] <- String.split(arch, "-"),
         {:ok, cpu} <- cpu(cpu) do
      cpu <> "-linux-gnu"
    else
      _ -> nil
    end
  end

  def triple(_arch), do: nil

  defp cpu(c) when c in ["x86_64", "amd64"], do: {:ok, "x86_64"}
  defp cpu(c) when c in ["aarch64", "arm64"], do: {:ok, "aarch64"}
  defp cpu(_c), do: :error

  # The release's full version (27.3.4.1), as rebar3 reads it; nil when the
  # release's OTP_VERSION file cannot be read.
  defp otp_full() do
    release = List.to_string(:erlang.system_info(:otp_release))
    file = Path.join([List.to_string(:code.root_dir()), "releases", release, "OTP_VERSION"])

    case File.read(file) do
      {:ok, _} = read -> release |> Precompiled.Rebar3Arch.otp_version(read) |> String.trim()
      {:error, _} -> nil
    end
  end

  @doc false
  # Where the dynamic loader finds a triple's libraries: the dirs of
  # `ldconfig -p`'s entries for it, then the 64-bit, multiarch and plain
  # /lib dirs, those that exist, each once. Options (tests): `:ldconfig`,
  # its output (nil for none), and `:dir?`.
  @spec lib_roots(String.t(), keyword()) :: [Path.t()]
  def lib_roots(triple, opts \\ []) do
    ldconfig = Keyword.get_lazy(opts, :ldconfig, &ldconfig/0)
    dir? = Keyword.get(opts, :dir?, &File.dir?/1)

    fixed = [
      "/lib64",
      "/usr/lib64",
      "/lib/#{triple}",
      "/usr/lib/#{triple}",
      "/lib",
      "/usr/lib"
    ]

    (ldconfig_dirs(ldconfig, triple) ++ fixed) |> Enum.uniq() |> Enum.filter(dir?)
  end

  @doc false
  # The dirs of `ldconfig -p` lines whose flags name the triple's machine,
  # in order, each once. Lines that do not parse are skipped.
  @spec ldconfig_dirs(String.t() | nil, String.t()) :: [Path.t()]
  def ldconfig_dirs(output, triple) when is_binary(output) do
    flag = Map.get(@ldconfig_flags, triple)

    for line <- String.split(output, "\n"),
        [_, flags, path] <- [Regex.run(~r/^\s*\S+\s+\(([^)]*)\)\s+=>\s+(\S+)\s*$/, line)],
        flag != nil and flag in String.split(flags, ~r/,\s*/),
        Path.type(path) == :absolute,
        uniq: true,
        do: Path.dirname(path)
  end

  def ldconfig_dirs(_output, _triple), do: []

  defp ldconfig() do
    case System.find_executable("ldconfig") || Enum.find(@ldconfig_paths, &File.regular?/1) do
      nil ->
        nil

      exe ->
        case System.cmd(exe, ["-p"], stderr_to_stdout: false) do
          {out, 0} when byte_size(out) <= @max_ldconfig_bytes -> out
          _ -> nil
        end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc false
  # The build was made for this machine: target host_native, this host's
  # triple, glibc. A host without a triple misses every build, named by its
  # raw architecture.
  @spec triple_reason(term(), map(), map()) :: :ok | {:miss, Reason.t()}
  def triple_reason(target, b, host) do
    if target == "host_native" and is_binary(host.triple) and b["triple"] == host.triple and
         b["libc"] == "glibc",
       do: :ok,
       else:
         {:miss,
          Reason.new(:triple_differs, [
            built_for(target, b),
            host.triple || host.system_architecture
          ])}
  end

  defp built_for("host_native", %{"libc" => "glibc", "triple" => t}), do: t
  defp built_for("host_native", %{"libc" => libc}) when is_binary(libc), do: libc
  defp built_for("host_native", b), do: b["triple"]
  defp built_for(target, _b), do: target

  @doc false
  # The NIF version the build's library was made for must be no newer than
  # this VM's: a VM loads NIFs of its own and older minor versions.
  @spec nif_reason(term(), term()) :: :ok | {:miss, Reason.t()}
  def nif_reason(built, running) do
    case {dotted(built), dotted(running)} do
      {:error, _} -> malformed()
      {{:ok, b}, {:ok, r}} when b <= r -> :ok
      _ -> {:miss, Reason.new(:nif_version_newer, [built, running])}
    end
  end

  # Dotted integers, padded with zeros so "2.9" < "2.17" and "2" == "2.0".
  defp dotted(v, width \\ 4)

  defp dotted(v, width) when is_binary(v) do
    parts = String.split(v, ".")

    if parts != [] and Enum.all?(parts, &(&1 =~ ~r/\A\d{1,9}\z/)) and length(parts) <= width,
      do:
        {:ok, Enum.map(parts, &String.to_integer/1) ++ List.duplicate(0, width - length(parts))},
      else: :error
  end

  defp dotted(_v, _width), do: :error

  @doc false
  # Every library the build's ELF files need is found in this machine's
  # library dirs and defines every symbol version they need. A library of
  # another machine or class under that name counts as missing.
  @spec needs_reason(map(), map()) :: :ok | {:miss, Reason.t()}
  def needs_reason(%{"native" => true, "elf" => %{"needs" => needs}}, host) when is_map(needs) do
    machine = Map.get(@machines, host.triple)

    read = fn path ->
      case Precompiled.Elf.read_file(path) do
        {:ok, %{class: 64, machine: ^machine}} = ok when machine != nil -> ok
        _ -> :not_elf
      end
    end

    case Precompiled.Device.Libs.check(needs, host.lib_roots, read: read) do
      {:miss, %Reason{code: :needed_lib_missing, args: [soname]} = r} ->
        {:miss, %{r | text: "#{soname} missing on this machine"}}

      other ->
        other
    end
  end

  def needs_reason(_b, _host), do: malformed()

  defp malformed(), do: {:miss, Reason.new(:malformed_entry, [], "malformed entry")}

  @doc false
  # Every origin's archive is listed, with the sha256 the build names, in
  # the package's own checksum file under `deps_path`. No origins (the
  # package compiled its library itself) passes. Origins that are not a
  # list of complete entries are a malformed entry.
  @spec origins_reason(term(), Path.t(), String.t()) :: :ok | {:miss, Reason.t()}
  def origins_reason(origins, deps_path, dep) when is_list(origins) do
    if Enum.all?(origins, &origin?/1),
      do: Enum.reduce_while(origins, :ok, &origin_ok(&1, &2, deps_path, dep)),
      else: malformed()
  end

  def origins_reason(_origins, _deps_path, _dep), do: malformed()

  defp origin?(%{"checksum_file" => f, "archive" => a, "archive_sha256" => s} = o),
    do: is_binary(f) and is_binary(a) and is_binary(s) and is_binary(o["path"])

  defp origin?(_o), do: false

  defp origin_ok(%{"checksum_file" => file, "archive" => archive} = o, :ok, deps_path, dep) do
    with :ok <- plain_checksum_name(file),
         {:ok, sums} <- checksum_file(Path.join([deps_path, dep, file])) do
      if Map.get(sums, archive) == "sha256:" <> o["archive_sha256"],
        do: {:cont, :ok},
        else: {:halt, {:miss, Reason.new(:origin_unverified, [archive], unlisted(archive))}}
    else
      {:error, why} ->
        {:halt,
         {:miss,
          Reason.new(
            :origin_unverified,
            [file],
            "checksum file #{Path.join([deps_path, dep, file])} unusable (#{why}), " <>
              unlisted(archive)
          )}}
    end
  end

  defp unlisted(archive), do: "#{archive} not in the package's checksum file"

  defp plain_checksum_name(file) do
    if Regex.match?(@checksum_file, file),
      do: :ok,
      else: {:error, "not a checksum file name"}
  end

  @doc false
  # A rustler_precompiled-style checksum file, read as data: at most 1 MiB,
  # parsed with Code.string_to_quoted/2 (no new atoms) and never evaluated.
  # Only a literal map of string names to "sha256:<64 lowercase hex>"
  # strings is one.
  @spec checksum_file(Path.t()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def checksum_file(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_checksum_bytes <-
           File.stat(path),
         {:ok, text} <- File.read(path),
         true <- byte_size(text) <= @max_checksum_bytes,
         {:ok, quoted} <- Code.string_to_quoted(text, existing_atoms_only: true) do
      literal_sums(quoted)
    else
      {:ok, %File.Stat{}} -> {:error, "not a regular file of at most 1 MiB"}
      {:error, posix} when is_atom(posix) -> {:error, :file.format_error(posix) |> to_string()}
      _ -> {:error, "not Elixir data"}
    end
  rescue
    _ -> {:error, "not Elixir data"}
  end

  defp literal_sums({:%{}, _meta, pairs}) when is_list(pairs) do
    if Enum.all?(pairs, &sum_pair?/1),
      do: {:ok, Map.new(pairs)},
      else: {:error, "not a map of names to sha256 strings"}
  end

  defp literal_sums(_quoted), do: {:error, "not a literal map"}

  defp sum_pair?({name, sum}) when is_binary(name) and is_binary(sum),
    do: Regex.match?(@sha256, sum)

  defp sum_pair?(_pair), do: false
end
