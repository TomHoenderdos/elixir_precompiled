# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.Downgrade do
  @moduledoc """
  N6: a scheme downgrade. Over HTTPS the client trusts (`tls: :ip,
  trust_ca: true`), the mirror answers the named resources with a `302` to
  the same path on its own host and port under plain `http`: only the
  scheme differs. `paths` is `:files` or `:manifests`. Nothing listens for
  plain http there but the TLS mirror itself, which logs such a request as
  a failed handshake, so a client that follows shows in the log.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.Mirror.Transform

  @impl true
  def valid_args?(%{paths: paths, tls: :ip, trust_ca: true} = args) when map_size(args) == 3,
    do: paths in [:files, :manifests]

  def valid_args?(_args), do: false

  @impl true
  def transform(path, bytes, %{paths: paths}) do
    if named?(paths, path), do: {:redirect, 302, {:scheme, "http"}}, else: {200, bytes}
  end

  defp named?(:manifests, path), do: Transform.manifest_path?(path)
  defp named?(:files, path), do: Transform.file_path?(path)
end
