# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.TestBatch do
  @moduledoc """
  Layer 2, batch and root cases (T2, T3, T5, T7, T8, R9-R11, R17, R18): the
  test batch re-signed at request time, as only a key holder could. Only
  with a test root (`ChainTest.TestKey`); args, at least one:

    * `signers` - the keys that sign it, in order, repeats kept
      (`ChainTest.TestKey.signer_names/0`; default `[:batch]`, the test
      root's own batch key);
    * `issued_ahead` - `issued` set to the moment of the request plus this
      many seconds, `expires` moved with it (the lifetime kept);
    * `lifetime` - `expires` set this many seconds after `issued`;
    * `root` - `:unchained`: `root.json` is the test root v2 that v1 did not
      sign (T7); `:withheld`: `root.json` is a 404, as a mirror hiding a
      newer root (R18).

  Without `issued_ahead` or `lifetime`, the payload is the real batch's,
  byte for byte. Everything else is served unchanged.
  """
  @behaviour ChainTest.Mirror.Transform

  alias ChainTest.TestKey

  @keys [:signers, :issued_ahead, :lifetime, :root]

  @doc "Only for a case pinned to a test root."
  @spec test_root_only?() :: true
  def test_root_only?(), do: true

  @impl true
  def valid_args?(args) when is_map(args) and map_size(args) > 0 do
    Enum.all?(args, fn
      {:signers, [_ | _] = s} -> Enum.all?(s, &(&1 in TestKey.signer_names()))
      {:issued_ahead, s} -> is_integer(s)
      {:lifetime, s} -> is_integer(s) and s > 0
      {:root, r} -> r in [:unchained, :withheld]
      {_key, _value} -> false
    end) and Enum.all?(Map.keys(args), &(&1 in @keys))
  end

  def valid_args?(_args), do: false

  @impl true
  def transform("batch.json", bytes, %{case: %{snapshot: snap}} = args) do
    test = TestKey.test!(snap)
    payload = bytes |> TestKey.payload!() |> retime(args)
    {200, TestKey.envelope(test, payload, Map.get(args, :signers, [:batch]))}
  end

  def transform("root.json", _bytes, %{root: :unchained, case: %{snapshot: snap}}),
    do: {200, TestKey.test!(snap).unchained_v2}

  def transform("root.json", _bytes, %{root: :withheld}), do: {404, ""}

  def transform(_path, bytes, _args), do: {200, bytes}

  defp retime(payload, args)
       when not is_map_key(args, :issued_ahead) and
              not is_map_key(args, :lifetime),
       do: payload

  defp retime(payload, args) do
    batch = JSON.decode!(payload)
    {issued, expires} = {instant!(batch["issued"]), instant!(batch["expires"])}

    new_issued =
      case args do
        %{issued_ahead: s} -> DateTime.add(DateTime.utc_now(), s, :second)
        _ -> issued
      end

    life = Map.get(args, :lifetime, DateTime.diff(expires, issued, :second))

    batch
    |> Map.put("issued", DateTime.to_iso8601(new_issued))
    |> Map.put("expires", DateTime.to_iso8601(DateTime.add(new_issued, life, :second)))
    |> JSON.encode!()
  end

  defp instant!(s) do
    case DateTime.from_iso8601(to_string(s)) do
      {:ok, dt, _} -> dt
      _ -> raise ArgumentError, "the test batch has no instant #{inspect(s)}"
    end
  end
end
