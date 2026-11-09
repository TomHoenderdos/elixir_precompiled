# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.Installed do
  @moduledoc """
  One app `Precompiled.install/2` installed, or one `Precompiled.list/1`
  found in the store.

    * `:app`, `:version` - the app and its version;
    * `:target` - `"pure_elixir"` or the Nerves system it was built for;
    * `:path` - its directory in the store;
    * `:role` - `:requested`, or `:dependency` when it came in for another
      app's closure;
    * `:bytes` - its size on disk;
    * `:from_cache?` - whether it was loaded from the store with no
      download;
    * `:loaded?` - whether it is loaded in this VM;
    * `:batch_sequence` - the sequence of the signed batch it was checked
      against, or `nil` when an offline bundle's document vouched for it.
  """

  defstruct [
    :app,
    :version,
    :target,
    :path,
    :role,
    :bytes,
    :from_cache?,
    :loaded?,
    :batch_sequence
  ]

  @type t :: %__MODULE__{
          app: atom(),
          version: String.t(),
          target: String.t() | nil,
          path: Path.t(),
          role: :requested | :dependency | nil,
          bytes: non_neg_integer(),
          from_cache?: boolean(),
          loaded?: boolean(),
          batch_sequence: integer() | nil
        }
end
