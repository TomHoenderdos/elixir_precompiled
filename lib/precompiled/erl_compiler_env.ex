# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ErlCompilerEnv do
  @moduledoc false
  # What in the environment can change every compile on this machine,
  # whatever the dependency, and that no build records. Builds are made in
  # a clean environment, so any of these makes every candidate miss.
  #
  # - ERL_COMPILER_OPTIONS: OTP's compile:file/2 and compile:forms/2
  #   append it to their options, which covers Mix's compile.erlang
  #   (`:compile.file/2`) and rebar3's erl compiler. Elixir does not use
  #   compile:forms, but it appends the same list itself
  #   (elixir_erl_compiler:env_compiler_options/0, without
  #   warnings_as_errors) to every module it compiles, so Elixir-only
  #   packages change too (`[no_line_info]` gives other beams).
  # - ERL_FLAGS, ERL_AFLAGS, ERL_ZFLAGS: emulator arguments for every
  #   `erl`, the one Mix runs in and the one rebar3 runs in. Among them,
  #   `-env` sets ERL_COMPILER_OPTIONS, `-eval`/`-s`/`-run`/`-S` run code,
  #   `-pa`/`-pz`/`-path`/`-boot`/`-boot_var`/`-code_path_choice` choose the
  #   code loaded (a compiler of one's own), `-args_file` reads more
  #   arguments, `-config` and `-compiler`/`-elixir`/`-mix`/`-stdlib` set
  #   app env, and `-extra` passes arguments on. Any of those is a miss;
  #   other flags (`-kernel shell_history enabled`, `+S 4`, `-name`) are
  #   left alone.
  # - ELIXIR_ERL_OPTIONS: the `elixir` script passes it to `erl` as is, so
  #   the same flags count.
  # - ERL_LIBS: the code server adds every app under it to the code path
  #   at boot, where a dependency's mix.exs or compile can find it
  #   (`:code.lib_dir/1`, `Code.ensure_loaded?/1`). Mix prunes paths it
  #   did not load only inside compile.all, after the dep's mix.exs is
  #   evaluated, keeps any listed app the code path resolves (an
  #   `extra_applications` entry shadowed under ERL_LIBS), and does not
  #   prune at all under Mix.install (`prune_code_paths: false`). Mix
  #   replaces ERL_LIBS only for rebar3 and make subprocesses. So set,
  #   it is a miss.
  # - `.erlang`: the default boot script runs c:erlangrc/0 at every start,
  #   `-noshell` included, which evaluates the first `.erlang` in HOME or
  #   filename:basedir(user_config, "erlang"). It can do anything, so its
  #   presence is a miss, and so is a dir whose contents cannot be told.
  #
  # The text names the variable or file, never its value.

  alias Precompiled.FileUtil
  alias Precompiled.Reason

  @flag_vars ~w(ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS)
  @unsafe ~w(-eval -s -run -S -pa -pz -path -env -args_file -boot -boot_var -config
             -code_path_choice -compiler -elixir -mix -stdlib -extra)

  @type getenv :: (String.t() -> String.t() | nil)

  @doc false
  @spec check(getenv()) :: :ok | {:miss, Reason.t()}
  def check(getenv) do
    with :ok <- compiler_options(getenv),
         :ok <- erl_libs(getenv),
         :ok <- flags(getenv) do
      erlangrc(getenv)
    end
  end

  defp compiler_options(getenv) do
    case getenv.("ERL_COMPILER_OPTIONS") do
      v when is_binary(v) ->
        if String.trim(v) == "",
          do: :ok,
          else:
            miss(
              "ERL_COMPILER_OPTIONS",
              "ERL_COMPILER_OPTIONS is set, which changes every compile"
            )

      _ ->
        :ok
    end
  end

  defp erl_libs(getenv) do
    case getenv.("ERL_LIBS") do
      v when is_binary(v) ->
        if String.trim(v) == "",
          do: :ok,
          else: miss("ERL_LIBS", "ERL_LIBS is set, which can change every compile")

      _ ->
        :ok
    end
  end

  defp flags(getenv) do
    Enum.find_value(@flag_vars, :ok, fn var ->
      with v when is_binary(v) <- getenv.(var),
           token when is_binary(token) <- Enum.find(String.split(v), &(&1 in @unsafe)) do
        miss(var, "#{var} has #{token}, which can change every compile")
      else
        _ -> nil
      end
    end)
  end

  defp erlangrc(getenv) do
    dirs = Enum.reject([getenv.("HOME"), user_config_dir(getenv)], &(&1 in [nil, ""]))

    Enum.find_value(dirs, :ok, fn dir ->
      file = Path.join(dir, ".erlang")

      case FileUtil.presence(file) do
        :absent -> nil
        :unknown -> miss(".erlang", "#{file} could not be checked")
        _ -> miss(".erlang", "#{file} runs at every Erlang start, which can change every compile")
      end
    end)
  end

  @doc false
  # filename:basedir(user_config, "erlang"), from `getenv` rather than the
  # VM's own environment where the OS allows it.
  @spec user_config_dir(getenv()) :: Path.t() | nil
  def user_config_dir(getenv) do
    home = getenv.("HOME")

    case :os.type() do
      {:unix, :darwin} when is_binary(home) ->
        Path.join([home, "Library", "Application Support", "erlang"])

      {:unix, _} ->
        case getenv.("XDG_CONFIG_HOME") do
          xdg when is_binary(xdg) and xdg != "" -> Path.join(xdg, "erlang")
          _ when is_binary(home) -> Path.join([home, ".config", "erlang"])
          _ -> nil
        end

      _ ->
        to_string(:filename.basedir(:user_config, ~c"erlang"))
    end
  end

  defp miss(arg, text), do: {:miss, Reason.new(:erl_compiler_options, [arg], text)}
end
