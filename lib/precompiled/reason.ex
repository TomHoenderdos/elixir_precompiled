# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Reason do
  @moduledoc false
  # Why a line says HIT, MISS or FAIL, twice over: `text` is what the line
  # prints here and may name paths, URLs or exception messages; `code` and
  # `args` are stable, carry only package names, versions and Elixir, OTP,
  # target and system names, and are what `mix precompiled.report` sends,
  # with `render/2` of them as the text. The table is shared with the portal
  # (`Portal.Reports.Payload.known_codes/0`): change both together.

  defstruct [:code, args: [], text: ""]

  @type t :: %__MODULE__{code: atom(), args: [String.t()], text: String.t()}

  @templates [
    hit: "installed",
    not_in_batch: "not in batch",
    not_built_version: "not built for {0}",
    not_built_target: "not built for {0} {1}",
    build_method_unknown: "build method unknown (deps did not load)",
    build_method_override: "project sets :{0} for this dependency",
    build_method_mismatch: "built with {0}, project builds with {1}",
    malformed_entry: "malformed entry",
    rule8_unscannable: "source not scannable",
    rule8_env: "reads an environment variable at compile time, which no build records",
    rule8_target: "reads Mix.target() at compile time; built for target {0}, project targets {1}",
    build_predates: "build predates {0}",
    toolchain_elixir: "built with Elixir {0}, running {1}",
    toolchain_otp: "built on OTP {0}, running {1}",
    dep_env_differs: "built with env {0}, dependency compiles as {1}",
    checksum_differs: "package checksum differs from mix.lock",
    closure_mismatch: "built against {0} {1}, lock has {2}",
    closure_checksum: "built against {0} {1} with another checksum",
    closure_absent: "built against {0} {1}, not in lock",
    closure_without: "built without {0}, lock has {1}",
    closure_env_absent: "built with {0}, which Mix leaves out of it in this env",
    compile_env_differs: "compile_env differs: {*}",
    excepted: "excepted: compiled from source",
    revoked_provenance: "revoked: provenance unreadable",
    revoked_not_in_batch: "revoked: no longer in the current batch",
    remove_failed: "could not remove the installed build",
    deadline_passed: "run deadline passed",
    fetch_failed: "download failed",
    verify_failed: "verification failed",
    install_failed: "install failed",
    internal: "internal error",
    system_version_abi: "built for {0} {1} (toolchain {2}), project has {3} (toolchain {4})",
    toolchain_otp_minor: "built on OTP {0}, release has {1}",
    needed_lib_missing: "{0} missing on target",
    symbol_version_missing: "{0} lacks {1}",
    system_unknown: "{0} {1} not yet known to the portal",
    system_bound_compile: "reads the Nerves system at compile time",
    env_differs: "built with a different {0}",
    env_set_at_build:
      "built with {0} set at compile time; a device cannot check its firmware's build environment",
    env_all: "reads the whole environment at compile time",
    config_unrecorded: "compile-time config reads not recorded",
    config_order_differs: "compile-time config {0} {1} would differ in this project"
  ]

  @codes Keyword.keys(@templates)
  @by_name Map.new(@codes, &{Atom.to_string(&1), &1})
  @arg ~r/\A[A-Za-z0-9_.+:\-]{0,64}\z/
  @max_args 8

  @spec codes() :: [atom()]
  def codes(), do: @codes

  @spec new(atom(), [term()], String.t()) :: t()
  def new(code, args, text) when code in @codes and is_binary(text),
    do: %__MODULE__{code: code, args: clean_args(args), text: text}

  def new(code, _args, _text), do: raise(ArgumentError, "unknown reason code #{inspect(code)}")

  @spec new(atom(), [term()]) :: t()
  def new(code, args) when code in @codes do
    args = clean_args(args)
    %__MODULE__{code: code, args: args, text: render(code, args)}
  end

  def new(code, _args), do: raise(ArgumentError, "unknown reason code #{inspect(code)}")

  @spec render(atom(), [String.t()]) :: String.t()
  def render(code, args) do
    template = Keyword.get(@templates, code, Keyword.fetch!(@templates, :internal))

    Regex.replace(~r/\{(\d+|\*)\}/, template, fn
      _, "*" -> Enum.join(args, ", ")
      _, n -> Enum.at(args, String.to_integer(n), "?")
    end)
  end

  @spec code(term()) :: atom()
  def code(name) when is_binary(name), do: Map.get(@by_name, name, :internal)
  def code(_name), do: :internal

  @spec clean_args(term()) :: [String.t()]
  def clean_args(args) when is_list(args), do: args |> Enum.take(@max_args) |> Enum.map(&arg/1)
  def clean_args(_args), do: []

  defp arg(a) when is_integer(a), do: Integer.to_string(a)
  defp arg(a) when is_binary(a), do: if(Regex.match?(@arg, a), do: a, else: "?")
  defp arg(_a), do: "?"

  @spec textual(term()) :: term()
  def textual({status, %__MODULE__{text: text}}), do: {status, text}
  def textual(other), do: other

  @spec of_batch_error(String.t(), String.t()) :: t()
  def of_batch_error(why, suffix \\ "") do
    code =
      if String.starts_with?(why, "batch unavailable"), do: :fetch_failed, else: :verify_failed

    new(code, [], why <> suffix)
  end

  # Fetch.manifest/4: a 404 or a network error is a download that failed; a
  # local cache refusing its own file is an install error; anything else it
  # refuses is the manifest failing a check.
  @spec of_manifest(term()) :: term()
  def of_manifest({:miss, why}) when is_binary(why), do: {:miss, new(:fetch_failed, [], why)}

  def of_manifest({:unreachable, why}) when is_binary(why),
    do: {:unreachable, new(:fetch_failed, [], why)}

  def of_manifest({:fail, "cache refused" <> _ = why}), do: {:fail, new(:install_failed, [], why)}
  def of_manifest({:fail, why}) when is_binary(why), do: {:fail, new(:verify_failed, [], why)}
  def of_manifest(other), do: other

  @verify [
    "downloaded .app",
    "staged .app",
    "size mismatch",
    "sha256 mismatch",
    "file larger than declared size"
  ]
  @fetch ["file not available", "offline: file not cached"]

  # An install or keep outcome. The texts are the client's own fixed
  # messages (Fetch.install/6, Check.keep/4 and the .app check); one this
  # table does not know is an install error.
  @spec of_install(term()) :: term()
  def of_install({:fail, %__MODULE__{}} = coded), do: coded

  def of_install({:fail, why}) when is_binary(why) do
    code =
      cond do
        String.starts_with?(why, "downloaded .app: compile_env differs") -> :compile_env_differs
        String.starts_with?(why, @verify) -> :verify_failed
        String.starts_with?(why, @fetch) -> :fetch_failed
        true -> :install_failed
      end

    {:fail, new(code, [], why)}
  end

  def of_install(other), do: other
end
