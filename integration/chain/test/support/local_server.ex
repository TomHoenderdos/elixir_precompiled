# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.LocalServer do
  @moduledoc """
  A plain-HTTP inets server on 127.0.0.1 serving the files in one directory,
  so tests never reach the network.
  """

  @doc "Serves `dir`; returns `{base_url, pid}`. Stop it with `stop/1`."
  @spec serve(Path.t()) :: {String.t(), pid()}
  def serve(dir) do
    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"localhost",
        server_root: String.to_charlist(dir),
        document_root: String.to_charlist(dir),
        mime_types: [{~c"json", ~c"application/json"}]
      )

    port = :httpd.info(pid)[:port]
    {"http://127.0.0.1:#{port}", pid}
  end

  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(pid), do: :inets.stop(:httpd, pid)
end
