# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Result do
  @moduledoc """
  One check's outcome.

  Classes:

    * `:pass` - checked and as expected.
    * `:fail` - checked and wrong.
    * `:refused` - the client refused where it should have installed.
    * `:miss` - a dependency compiled because no precompiled build was found;
      reported, not an error.
    * `:disagreement` - the client says one thing, the harness's own check
      another.
    * `:not_exercised` - the check never ran, so it proves nothing.
    * `:rerun` - production moved under the run (a new batch between
      step 1 and step 2); run again.
  """

  @enforce_keys [:step, :check, :class]
  defstruct [:step, :check, :class, detail: "", ms: 0, cause: nil]

  @type class :: :pass | :fail | :refused | :miss | :disagreement | :not_exercised | :rerun
  @type t :: %__MODULE__{
          step: atom(),
          check: String.t(),
          class: class(),
          detail: String.t(),
          ms: non_neg_integer(),
          cause: cause()
        }

  @typedoc """
  Why a result has its class, where a later step needs to know without
  reading the detail (which can carry untrusted text). `:batch_mismatch`:
  a disagreement only because the batch checked against is not the one the
  client used. `:unavailable`: the batch could not be fetched at all (an
  HTTP error status, a transport error or a timeout), as opposed to fetched
  and rejected.
  """
  @type cause :: nil | :batch_mismatch | :unavailable

  @classes [:pass, :fail, :refused, :miss, :disagreement, :not_exercised, :rerun]
  @failing [:fail, :refused, :disagreement, :not_exercised]

  @doc "Every result class."
  @spec classes() :: [class()]
  def classes(), do: @classes

  @doc "The process exit code: 1 when any result is a failing class, else 0."
  @spec exit_code([t()]) :: 0 | 1
  def exit_code(results) do
    if Enum.any?(results, &(&1.class in @failing)), do: 1, else: 0
  end

  @doc "Runs `fun` and returns `{value, elapsed_ms}`."
  @spec timed((-> value)) :: {value, non_neg_integer()} when value: term()
  def timed(fun) do
    started = System.monotonic_time(:millisecond)
    value = fun.()
    {value, System.monotonic_time(:millisecond) - started}
  end
end
