# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Conformance.Setup do
  @moduledoc """
  A conformance case's preparation of the client home, as data: a module
  implementing this behaviour plus its args map, written `{module, args}`
  as a case's `setup`. It runs once per case against the case's fresh,
  empty client home (`ELIXIR_PRECOMPILED_HOME`), after the case's mirrors
  are up and before the build: write a state file, pre-populate the cache,
  plant a symlink.

  `setup(home, snapshot, args)` gets the snapshot (`ChainTest.Snapshot`)
  with the case's context under `:case`: `%{source: url, root: path,
  mirrors: [url]}`, `source` and `root` the client's source and shipped
  root for this build (the case mirror's URL and the library's root unless
  the case's `client_config` says otherwise), `mirrors` the case mirror's
  base URL followed by the second mirror's, when the case has one.
  `state_dir/3` names the client's state dir for a source and root.

  As for transforms, `valid_args?/1` and `needs/1` are optional, and the
  args key `:case` is reserved.
  """

  alias ChainTest.Mirror.Transform

  @callback setup(home :: Path.t(), snapshot :: map(), args :: map()) :: :ok | {:error, term()}

  @doc "Whether `args` is an args map this setup accepts. Optional: without it, any map is."
  @callback valid_args?(args :: map()) :: boolean()

  @doc "What the setup needs of the snapshot. Optional: without it, nothing."
  @callback needs(args :: map()) :: [ChainTest.Snapshot.need()]

  @optional_callbacks valid_args?: 1, needs: 1

  @doc """
  Whether `term` is `{module, args}` with a loaded module implementing
  `setup/3`, `args` without `:case`, and the optional callbacks accepting
  `args`.
  """
  @spec valid?(term()) :: boolean()
  def valid?({module, args}) when is_atom(module) and is_map(args) do
    Code.ensure_loaded?(module) and function_exported?(module, :setup, 3) and
      not Map.has_key?(args, :case) and Transform.valid_args?(module, args) and
      Transform.needs_valid?(module, args)
  end

  def valid?(_), do: false

  @doc "What `{module, args}` needs of the snapshot (`needs/1`, else nothing)."
  @spec needs({module(), map()}) :: [ChainTest.Snapshot.need()]
  def needs({module, args}), do: Transform.module_needs(module, args)

  @doc """
  Runs the setup. Anything but `:ok` (an error, a raise, a throw, an exit,
  another answer) is `{:error, why}`.
  """
  @spec run({module(), map()}, Path.t(), map()) :: :ok | {:error, String.t()}
  def run({module, args}, home, snapshot) do
    case module.setup(home, snapshot, args) do
      :ok -> :ok
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, why} -> {:error, inspect(why)}
      other -> {:error, "setup returned #{inspect(other, limit: 20)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  @doc """
  The client's state dir for `source` and the shipped root at `root_path`
  under `home`, named as the client names it (`ElixirPrecompiled.Trust.state_dir/2`):
  the first 16 hex digits of sha256 of `"<source>|<first root-role key id>"`,
  the source without a trailing `/`.
  """
  @spec state_dir(Path.t(), String.t(), Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def state_dir(home, source, root_path) do
    with {:ok, keyid} <- first_root_keyid(root_path) do
      hash = :crypto.hash(:sha256, String.trim_trailing(source, "/") <> "|" <> keyid)
      {:ok, Path.join(home, binary_part(Base.encode16(hash, case: :lower), 0, 16))}
    end
  end

  # As the client: a root whose payload names no root key gives "".
  defp first_root_keyid(root_path) do
    with {:ok, body} <- File.read(root_path),
         {:ok, %{"payload" => p}} when is_binary(p) <- JSON.decode(body),
         {:ok, payload} <- Base.url_decode64(p, padding: false),
         {:ok, root} <- JSON.decode(payload) do
      case root do
        %{"roles" => %{"root" => %{"keyids" => [id | _]}}} when is_binary(id) -> {:ok, id}
        _ -> {:ok, ""}
      end
    else
      {:error, why} when is_atom(why) -> {:error, "#{root_path}: #{:file.format_error(why)}"}
      _ -> {:error, "#{root_path} is not a root envelope"}
    end
  end
end
