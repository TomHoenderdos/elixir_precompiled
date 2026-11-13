# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mid do
  @moduledoc false
  File.write!(
    System.fetch_env!("ORDER_LOG"),
    "mid #{inspect(Application.fetch_env(:solo_b, :k))}\n",
    [:append]
  )
end
