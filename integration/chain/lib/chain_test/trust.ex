# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Trust do
  @moduledoc """
  Step 1: the harness's own verification of the root and the current batch.

  This is the second opinion: nothing here calls the client library. The
  envelope is `{"payload": base64url(bytes), "signatures": [{"keyid", "sig"}]}`,
  each `sig` an Ed25519 signature over the raw payload bytes, each `keyid` the
  lowercase hex sha256 of the raw public key. A root names its keys and, per
  role (`root`, `batch`), the key ids and a threshold.

  The root used is the harness's own pinned copy (`priv/root.json`), never
  the one the source serves.

  Checks, in order:

    * `root_pin` - the pinned root is byte-identical to the library's
      `priv/precompiled/root.json`.
    * `root_signature` - the pinned root verifies under its own root role.
    * `root_expiry` - the pinned root has not expired.
    * `served_root` - `<source>/root.json` matches the pinned root; a
      different or unavailable served root is a `:miss`, and the pinned root
      is used either way.
    * `batch_signature` - `<source>/batch.json` (or `batch_path`, e.g.
      `batches/<sequence>.json`, under the source) carries at least one valid
      signature from a key the batch role names, and none from such a key
      that fails to verify.
    * `batch_threshold` - the distinct valid batch-role signatures meet the
      role's threshold.
    * `batch_format` - the payload is a version-1 batch with a sequence,
      issue and expiry instants, and sha256-named manifests.
    * `batch_expiry` - `expires` is in the future.
    * `batch_freshness` - issued within the last 24 h and not more than
      300 s ahead.
    * `batch_lifetime` - `expires - issued` is positive and at most 24 h, the portal's
      signing policy (the client accepts more; the harness holds the portal
      to what it promises).

  A check whose input could not be trusted is `:not_exercised`.
  """

  alias ChainTest.{HTTP, Result}

  @max_age_us 24 * 3600 * 1_000_000
  @max_future_us 300 * 1_000_000
  @max_lifetime_us 24 * 3600 * 1_000_000
  @timeout_ms 15_000

  @pinned_root Path.expand("../../priv/root.json", __DIR__)
  @library_root Path.expand("../../../../priv/precompiled/root.json", __DIR__)

  @batch_checks ~w(batch_signature batch_threshold batch_format batch_expiry batch_freshness
                   batch_lifetime)

  @type info :: %{
          sequence: integer(),
          root_version: integer(),
          manifests: %{String.t() => String.t()},
          manifests_v2: %{String.t() => String.t()} | nil
        }

  @type config :: %{
          required(:source) => String.t(),
          optional(:root_path) => Path.t(),
          optional(:library_root_path) => Path.t(),
          optional(:batch_path) => String.t(),
          optional(:timeout_ms) => pos_integer()
        }

  @doc "The harness's pinned root."
  @spec pinned_root_path() :: Path.t()
  def pinned_root_path, do: @pinned_root

  @doc "The root the library ships, which the pinned root must equal."
  @spec library_root_path() :: Path.t()
  def library_root_path, do: @library_root

  @doc "`cfg` with the defaults filled in."
  @spec config(config()) :: map()
  def config(cfg) do
    defaults = %{
      root_path: @pinned_root,
      library_root_path: @library_root,
      batch_path: "batch.json",
      timeout_ms: @timeout_ms
    }

    given = cfg |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
    Map.merge(defaults, given)
  end

  @doc """
  Runs every check. The info map is `nil` when the batch could not be
  trusted (pinned root invalid, batch unavailable, threshold not met, or a
  malformed payload); otherwise it is returned even when a date check
  failed, which the results already report.
  """
  @spec check(config()) :: {[Result.t()], info() | nil}
  def check(cfg) do
    cfg = config(cfg)
    source = String.trim_trailing(cfg.source, "/")
    now = DateTime.utc_now()

    pinned = File.read(cfg.root_path)
    pin = root_pin(cfg, pinned)
    {root_results, root} = verify_root(cfg.root_path, pinned, now)
    served = served_root(source, pinned, cfg.timeout_ms)

    {batch_results, info} =
      case root do
        nil -> {not_exercised(@batch_checks, "the pinned root did not verify"), nil}
        root -> verify_batch(source <> "/" <> cfg.batch_path, root, now, cfg.timeout_ms)
      end

    {[pin | root_results] ++ [served | batch_results], info}
  end

  @doc """
  The sha and directory of `name`'s manifest in a verified batch: the
  format-2 document under `v2/manifests` when the batch names one, else the
  format-1 one under `manifests`, as the client chooses. `nil` when the
  batch names neither.
  """
  @spec manifest_sha(info(), String.t()) :: {String.t(), String.t()} | nil
  def manifest_sha(info, name) do
    v2 = Map.get(info, :manifests_v2)

    cond do
      is_map(v2) and is_binary(v2[name]) -> {v2[name], "v2/manifests"}
      is_binary(info.manifests[name]) -> {info.manifests[name], "manifests"}
      true -> nil
    end
  end

  # root

  defp root_pin(cfg, pinned) do
    case {pinned, File.read(cfg.library_root_path)} do
      {{:ok, same}, {:ok, same}} ->
        result("root_pin", :pass, "#{cfg.root_path} equals #{cfg.library_root_path}")

      {{:ok, _}, {:ok, _}} ->
        result(
          "root_pin",
          :fail,
          "pinned root #{cfg.root_path} differs from the library's #{cfg.library_root_path}"
        )

      {{:error, r}, _} ->
        result("root_pin", :fail, "#{cfg.root_path}: #{:file.format_error(r)}")

      {_, {:error, r}} ->
        result("root_pin", :fail, "#{cfg.library_root_path}: #{:file.format_error(r)}")
    end
  end

  defp verify_root(path, {:error, r}, _now) do
    {[
       result("root_signature", :fail, "#{path}: #{:file.format_error(r)}"),
       result("root_expiry", :not_exercised, "no pinned root")
     ], nil}
  end

  defp verify_root(path, {:ok, body}, now) do
    with {:ok, payload, sigs} <- parse_envelope(body),
         {:ok, root} <- decode_object(payload),
         {:ok, keys, threshold} <- role(root, "root") do
      valid = valid_keyids(sigs, payload, keys)

      if length(valid) >= threshold do
        sig =
          result(
            "root_signature",
            :pass,
            "root version #{inspect(root["version"])} verifies under its own root role " <>
              "(#{length(valid)} of threshold #{threshold})"
          )

        {[sig, root_expiry(root, now)], root}
      else
        {[
           result(
             "root_signature",
             :fail,
             "#{path}: #{length(valid)} valid root-role signatures, threshold #{threshold}"
           ),
           result("root_expiry", :not_exercised, "the pinned root did not verify")
         ], nil}
      end
    else
      {:error, why} ->
        {[
           result("root_signature", :fail, "#{path}: #{why}"),
           result("root_expiry", :not_exercised, "the pinned root did not verify")
         ], nil}
    end
  end

  defp root_expiry(root, now) do
    case instant(root["expires"]) do
      {:ok, exp} ->
        if DateTime.compare(exp, now) == :gt,
          do: result("root_expiry", :pass, "expires #{DateTime.to_iso8601(exp)}"),
          else: result("root_expiry", :fail, "pinned root expired at #{DateTime.to_iso8601(exp)}")

      :error ->
        result(
          "root_expiry",
          :fail,
          "pinned root has no valid expires: #{inspect(root["expires"])}"
        )
    end
  end

  defp served_root(source, pinned, timeout_ms) do
    url = source <> "/root.json"
    {fetched, ms} = Result.timed(fn -> HTTP.get(url, timeout_ms) end)

    {class, detail} =
      case {fetched, pinned} do
        {{:ok, body}, {:ok, pin}} ->
          if same_json?(body, pin),
            do: {:pass, "#{url} matches the pinned root"},
            else: {:miss, "served root differs; pinned root used"}

        {{:ok, _}, {:error, _}} ->
          {:miss, "no pinned root to compare #{url} with"}

        {{:error, why}, _} ->
          {:miss, "served root unavailable (#{why}); pinned root used"}
      end

    result("served_root", class, detail, ms)
  end

  defp same_json?(a, b) do
    case {decode(a), decode(b)} do
      {{:ok, x}, {:ok, x}} -> true
      _ -> false
    end
  end

  # batch

  defp verify_batch(url, root, now, timeout_ms) do
    {fetched, ms} = Result.timed(fn -> HTTP.get(url, timeout_ms) end)

    with {:fetch, {:ok, body}} <- {:fetch, fetched},
         {:envelope, {:ok, payload, sigs}} <- {:envelope, parse_envelope(body)},
         {:role, {:ok, keys, threshold}} <- {:role, role(root, "batch")} do
      verdicts = Enum.map(sigs, &verdict(&1, payload, keys))
      sig = signature_result(verdicts, ms)
      valid = verdicts |> Enum.flat_map(fn {v, k} -> if v == :valid, do: [k], else: [] end)
      valid = Enum.uniq(valid)

      if length(valid) >= threshold do
        thr =
          result(
            "batch_threshold",
            :pass,
            "#{length(valid)} valid batch-role signatures, threshold #{threshold}"
          )

        {rest, info} = batch_payload(payload, root, now)
        {[sig, thr | rest], info}
      else
        thr =
          result(
            "batch_threshold",
            :fail,
            "#{length(valid)} valid batch-role signatures, threshold #{threshold}"
          )

        {[sig, thr | not_exercised(Enum.drop(@batch_checks, 2), "batch threshold not met")], nil}
      end
    else
      {:fetch, {:error, why}} ->
        untrusted("batch unavailable: #{why}", ms)

      {:envelope, {:error, why}} ->
        untrusted("batch envelope malformed: #{why}", ms)

      {:role, {:error, why}} ->
        untrusted("pinned root has no usable batch role: #{why}", ms)
    end
  end

  defp untrusted(why, ms) do
    {[result("batch_signature", :fail, why, ms) | not_exercised(tl(@batch_checks), why)], nil}
  end

  defp signature_result(verdicts, ms) do
    valid = for {:valid, k} <- verdicts, do: short(k)
    bad = for {:invalid, k} <- verdicts, do: short(k)
    unnamed = for {:unnamed, k} <- verdicts, do: short(k)
    malformed = Enum.count(verdicts, &match?({:malformed, _}, &1))

    notes =
      Enum.reject(
        [
          bad != [] && "signature by #{Enum.join(bad, ", ")} does not verify",
          unnamed != [] && "signed by #{Enum.join(unnamed, ", ")}: not named by the batch role",
          malformed > 0 && "#{malformed} malformed signature entries"
        ],
        &(&1 == false)
      )

    cond do
      verdicts == [] ->
        result("batch_signature", :fail, "batch carries no signatures", ms)

      valid != [] and bad == [] and malformed == 0 ->
        detail = Enum.join(["valid signature by #{Enum.join(valid, ", ")}" | notes], "; ")
        result("batch_signature", :pass, detail, ms)

      valid == [] ->
        detail = Enum.join(["no valid signature from a batch-role key" | notes], "; ")
        result("batch_signature", :fail, detail, ms)

      true ->
        result("batch_signature", :fail, Enum.join(notes, "; "), ms)
    end
  end

  defp batch_payload(payload, root, now) do
    case batch_fields(payload) do
      {:ok, b} ->
        fmt =
          result(
            "batch_format",
            :pass,
            "sequence #{b.sequence}, #{map_size(b.manifests)} manifests" <>
              if(b.manifests_v2, do: ", #{map_size(b.manifests_v2)} v2 manifests", else: "")
          )

        info = %{
          sequence: b.sequence,
          root_version: root["version"],
          manifests: b.manifests,
          manifests_v2: b.manifests_v2
        }

        {[fmt, expiry(b, now), freshness(b, now), lifetime(b)], info}

      {:error, why} ->
        {[
           result("batch_format", :fail, "batch payload malformed: #{why}")
           | not_exercised(Enum.drop(@batch_checks, 3), "batch payload malformed")
         ], nil}
    end
  end

  defp batch_fields(payload) do
    with {:ok, m} <- decode_object(payload),
         :ok <- field(m["version"] == 1, "version is not 1"),
         :ok <- field(is_integer(m["sequence"]), "sequence is not an integer"),
         {:ok, issued} <- instant_field(m["issued"], "issued"),
         {:ok, expires} <- instant_field(m["expires"], "expires"),
         :ok <- sha_map(m["manifests"], "manifests"),
         :ok <-
           if(is_nil(m["manifests_v2"]),
             do: :ok,
             else: sha_map(m["manifests_v2"], "manifests_v2")
           ) do
      {:ok,
       %{
         sequence: m["sequence"],
         issued: issued,
         expires: expires,
         manifests: m["manifests"],
         manifests_v2: m["manifests_v2"]
       }}
    end
  end

  defp field(true, _), do: :ok
  defp field(false, why), do: {:error, why}

  defp instant_field(v, name) do
    case instant(v) do
      {:ok, dt} -> {:ok, dt}
      :error -> {:error, "#{name} is not an ISO 8601 instant: #{inspect(v)}"}
    end
  end

  defp sha_map(m, name) when is_map(m) do
    bad =
      Enum.reject(m, fn {k, v} ->
        is_binary(k) and is_binary(v) and v =~ ~r/\A[0-9a-f]{64}\z/
      end)

    case bad do
      [] -> :ok
      [{k, v} | _] -> {:error, "#{name}[#{inspect(k)}] is not a sha256: #{inspect(v)}"}
    end
  end

  defp sha_map(_, name), do: {:error, "#{name} is not an object"}

  defp expiry(b, now) do
    exp = DateTime.to_iso8601(b.expires)

    if DateTime.compare(b.expires, now) == :gt,
      do: result("batch_expiry", :pass, "expires #{exp}"),
      else: result("batch_expiry", :fail, "batch expired at #{exp}")
  end

  defp freshness(b, now) do
    age = DateTime.diff(now, b.issued, :microsecond)
    issued = DateTime.to_iso8601(b.issued)

    cond do
      -age > @max_future_us ->
        result(
          "batch_freshness",
          :fail,
          "batch issued #{issued} is more than 300 s ahead of this clock"
        )

      age > @max_age_us ->
        result("batch_freshness", :fail, "batch issued #{issued}, more than 24 h ago")

      true ->
        result("batch_freshness", :pass, "issued #{issued} (#{div(age, 1_000_000)} s ago)")
    end
  end

  defp lifetime(b) do
    life = DateTime.diff(b.expires, b.issued, :microsecond)
    detail = "issued #{DateTime.to_iso8601(b.issued)}, expires #{DateTime.to_iso8601(b.expires)}"

    cond do
      life <= 0 ->
        result("batch_lifetime", :fail, "expires is not after issued: #{detail}")

      life > @max_lifetime_us ->
        result(
          "batch_lifetime",
          :fail,
          "lifetime #{div(life, 1_000_000)} s is over the portal's 24 h: #{detail}"
        )

      true ->
        result("batch_lifetime", :pass, "#{div(life, 1_000_000)} s: #{detail}")
    end
  end

  # envelope and keys

  defp parse_envelope(body) do
    with {:ok, %{"payload" => p, "signatures" => sigs}} when is_binary(p) and is_list(sigs) <-
           decode(body),
         {:ok, payload} <- b64(p) do
      {:ok, payload, sigs}
    else
      {:ok, _} -> {:error, "not an envelope object with payload and signatures"}
      :error -> {:error, "payload is not base64url"}
      {:error, why} -> {:error, why}
    end
  end

  # {:ok, %{keyid => raw public key}, threshold}: only ed25519 keys whose id
  # is the sha256 of their public bytes.
  defp role(root, name) do
    with %{"keyids" => ids, "threshold" => t} when is_list(ids) and is_integer(t) and t > 0 <-
           get_in_map(root, ["roles", name]) do
      keys = root["keys"]

      resolved =
        for id <- ids,
            is_binary(id),
            is_map(keys),
            %{"type" => "ed25519", "public" => pub} when is_binary(pub) <- [keys[id]],
            {:ok, raw} <- [b64(pub)],
            byte_size(raw) == 32,
            sha256_hex(raw) == id,
            into: %{},
            do: {id, raw}

      {:ok, resolved, t}
    else
      _ -> {:error, "role #{name} missing or malformed"}
    end
  end

  defp get_in_map(m, [k | rest]) when is_map(m), do: get_in_map(m[k], rest)
  defp get_in_map(v, []), do: v
  defp get_in_map(_, _), do: nil

  defp valid_keyids(sigs, payload, keys) do
    for({:valid, k} <- Enum.map(sigs, &verdict(&1, payload, keys)), do: k) |> Enum.uniq()
  end

  defp verdict(%{"keyid" => kid, "sig" => sig}, payload, keys)
       when is_binary(kid) and is_binary(sig) do
    case keys do
      %{^kid => pub} ->
        with {:ok, raw} <- b64(sig),
             64 <- byte_size(raw),
             true <- :crypto.verify(:eddsa, :none, payload, raw, [pub, :ed25519]) do
          {:valid, kid}
        else
          _ -> {:invalid, kid}
        end

      _ ->
        {:unnamed, kid}
    end
  end

  defp verdict(_, _, _), do: {:malformed, nil}

  defp b64(s), do: Base.url_decode64(s, padding: false)

  defp sha256_hex(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp short(kid), do: String.slice(kid, 0, 12)

  defp decode(bin) do
    case JSON.decode(bin) do
      {:ok, v} -> {:ok, v}
      {:error, _} -> {:error, "not JSON"}
    end
  end

  defp decode_object(bin) do
    case decode(bin) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, _} -> {:error, "not a JSON object"}
      error -> error
    end
  end

  defp instant(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp instant(_), do: :error

  defp not_exercised(checks, why), do: Enum.map(checks, &result(&1, :not_exercised, why))

  defp result(check, class, detail, ms \\ 0),
    do: %Result{step: :trust, check: check, class: class, detail: detail, ms: ms}
end
