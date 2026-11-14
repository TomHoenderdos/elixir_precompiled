# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Rebar3Arch do
  @moduledoc false
  # rebar3's arch string and its platform_define test, as rebar3 3.25
  # computes them (rebar_utils:get_arch/0 and is_arch/1):
  #
  #   get_arch() -> otp_release() ++ "-" ++
  #                 erlang:system_info(system_architecture) ++ "-" ++ wordsize().
  #   is_arch(Regex) -> re:run(get_arch(), Regex, [{capture, none}, unicode]).
  #
  # otp_release() is an "R..." release as it is, else the release's
  # OTP_VERSION file under code:root_dir() (up to a "**" marker, or with
  # trailing newlines trimmed), else otp_release itself. wordsize() is the
  # external word size in bits. No OS type is part of it, e.g.
  # "28.1.1-aarch64-apple-darwin24.6.0-64".
  #
  # Mix runs rebar3 under the same OTP install as this VM, so the strings
  # agree. The builder's OTP major equals ours (toolchain_otp), so :re
  # compiles a regex the same way it did there.

  # A regex past either limit cannot be evaluated here: a miss, never a
  # guess. rebar3 sets no match limit (and reads one PCRE hits as
  # nomatch); a regex that needs this many steps against a short arch
  # string is not one any package means. :report_errors makes a limit hit
  # an error rather than a nomatch.
  @max_regex_bytes 1024
  @match_limit 1_000_000

  @spec arch() :: String.t()
  def arch() do
    release = List.to_string(:erlang.system_info(:otp_release))
    file = Path.join([List.to_string(:code.root_dir()), "releases", release, "OTP_VERSION"])
    sys = List.to_string(:erlang.system_info(:system_architecture))
    otp_version(release, File.read(file)) <> "-" <> sys <> "-" <> wordsize()
  end

  @doc false
  @spec otp_version(String.t(), {:ok, binary()} | {:error, term()}) :: String.t()
  def otp_version("R" <> _ = release, _file), do: release
  def otp_version(release, {:error, _}), do: release

  def otp_version(_release, {:ok, vsn}) do
    case :binary.match(vsn, "**") do
      {pos, _} -> binary_part(vsn, 0, pos)
      :nomatch -> String.trim_trailing(vsn, "\n")
    end
  end

  defp wordsize() do
    Integer.to_string(:erlang.system_info({:wordsize, :external}) * 8)
  rescue
    ArgumentError -> Integer.to_string(:erlang.system_info(:wordsize) * 8)
  end

  # Whether rebar3 would define the platform_define's macro on `arch`:
  # true or false, or :error for a regex this client cannot evaluate.
  @spec match(term(), String.t()) :: boolean() | :error
  def match(regex, arch)
      when is_binary(regex) and byte_size(regex) <= @max_regex_bytes and is_binary(arch) do
    subject = :binary.bin_to_list(arch)

    case :re.run(subject, regex, [
           {:capture, :none},
           :unicode,
           :report_errors,
           {:match_limit, @match_limit}
         ]) do
      :match -> true
      :nomatch -> false
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def match(_regex, _arch), do: :error
end
