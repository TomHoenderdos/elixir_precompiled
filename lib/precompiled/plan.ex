# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Plan do
  @moduledoc """
  What `Precompiled.install/2` would install (`dry_run: true` returns it).

  `skipped` lists `{app, dep}` for each optional dependency `dep` of `app`
  that is neither on the device nor requested, and so is not installed.
  """

  defstruct installs: [], present: [], warnings: [], skipped: [], bytes: 0

  @type install :: %{
          app: atom(),
          version: String.t(),
          target: String.t(),
          build: map(),
          role: :requested | :dependency,
          bytes: non_neg_integer(),
          manifest: %{sha: String.t(), path: String.t()},
          deferred_env: [map()]
        }

  @type t :: %__MODULE__{
          installs: [install()],
          present: [{atom(), String.t()}],
          warnings: [String.t()],
          skipped: [{atom(), atom()}],
          bytes: non_neg_integer()
        }
end
