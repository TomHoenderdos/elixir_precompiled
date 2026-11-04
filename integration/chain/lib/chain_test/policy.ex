# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Policy do
  @moduledoc """
  R20: the portal's signing policy, checked against its current batch.

  Read only: one `ChainTest.Trust` check of `<source>/batch.json` (and
  `root.json`) under the harness's pinned root; nothing else is fetched,
  no snapshot taken, nothing built. The batch must verify, else its dates
  mean nothing (`:fail`; `:not_exercised` when it could not be fetched at
  all). Then, by the portal's promise:

    * `expires - issued` is positive and at most 24 h;
    * `now - issued` is at most 15 minutes, `now` the time the response
      arrived (taken as soon as the fetch returns; a batch every
      15 minutes), and the batch is not issued more than 300 s ahead of
      this clock (the skew the harness allows elsewhere).

  One `%Result{step: :policy, check: "R20"}`, its detail naming the
  sequence, both instants, the lifetime and the age.
  """

  alias ChainTest.{Result, Trust}

  @max_lifetime_s 24 * 3600
  @max_age_s 15 * 60
  @max_ahead_s 300
  @signed ~w(root_pin root_signature root_expiry batch_signature batch_threshold batch_format)

  @doc """
  Checks the source's current batch. Input `%{source}`, optional
  `:trust_opts` (merged into the `ChainTest.Trust` config) and `:now`
  (default: the clock read as soon as the fetch returned, the time the
  response arrived).
  """
  @spec check(map()) :: Result.t()
  def check(%{source: source} = input) do
    cfg = Map.merge(Map.get(input, :trust_opts, %{}), %{source: source})
    {results, info} = Trust.check(cfg)
    now = Map.get_lazy(input, :now, &DateTime.utc_now/0)

    case verified(results, info) do
      :ok -> dates(info, now)
      {class, why} -> result(class, why)
    end
  end

  defp verified(results, info) do
    bad = for r <- results, r.check in @signed, r.class != :pass, do: r

    cond do
      Enum.any?(bad, &(&1.cause == :unavailable)) ->
        {:not_exercised, "the source's batch.json could not be fetched: " <> details(bad)}

      bad != [] or info == nil ->
        {:fail, "the source's batch does not verify, so its dates mean nothing: " <> details(bad)}

      true ->
        :ok
    end
  end

  defp details(rs), do: Enum.map_join(rs, "; ", &"#{&1.check} #{&1.class} (#{&1.detail})")

  defp dates(%{issued: issued, expires: expires, sequence: seq}, now) do
    lifetime = DateTime.diff(expires, issued, :second)
    age = DateTime.diff(now, issued, :second)

    problems =
      Enum.reject(
        [
          lifetime <= 0 && "expires is not after issued",
          lifetime > @max_lifetime_s && "lifetime #{lifetime} s exceeds #{@max_lifetime_s} s",
          age > @max_age_s && "age #{age} s exceeds #{@max_age_s} s when the response arrived",
          age < -@max_ahead_s &&
            "issued #{-age} s ahead of this clock (more than #{@max_ahead_s} s)"
        ],
        &(&1 == false)
      )

    facts =
      "batch #{seq}: issued #{DateTime.to_iso8601(issued)}, expires " <>
        "#{DateTime.to_iso8601(expires)}; lifetime #{lifetime} s (at most #{@max_lifetime_s}), " <>
        "age #{age} s when the response arrived (at most #{@max_age_s})"

    case problems do
      [] -> result(:pass, facts)
      _ -> result(:fail, Enum.join(problems, "; ") <> "; " <> facts)
    end
  end

  defp result(class, detail),
    do: %Result{step: :policy, check: "R20", class: class, detail: detail}
end
