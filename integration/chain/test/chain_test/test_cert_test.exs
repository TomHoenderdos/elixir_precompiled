# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.TestCertTest do
  use ExUnit.Case, async: true

  alias ChainTest.TestCert

  @san {2, 5, 29, 17}

  defp sans(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    exts = elem(tbs, 10)
    for {:Extension, @san, _, names} <- exts, name <- names, do: name
  end

  defp verify(der, ca) do
    :public_key.pkix_path_validation(ca, [der], [])
  end

  test ":ip is a leaf for 127.0.0.1 issued by a CA of its own, which the server does not send" do
    %{ssl: ssl, ca: ca} = TestCert.server(:ip)

    assert sans(ssl[:cert]) == [iPAddress: <<127, 0, 0, 1>>]
    assert {:ok, _} = verify(ssl[:cert], ca)
    refute :public_key.pkix_is_self_signed(ssl[:cert])
    assert {:ECPrivateKey, key} = ssl[:key]
    assert is_binary(key)
  end

  test ":wrong_host names another host only, under a CA of its own" do
    %{ssl: ssl, ca: ca} = TestCert.server(:wrong_host)

    assert sans(ssl[:cert]) == [dNSName: ~c"wrong-host.invalid"]
    assert {:ok, _} = verify(ssl[:cert], ca)
  end

  test ":self_signed is its own issuer, for 127.0.0.1, with no CA to trust" do
    %{ssl: ssl, ca: ca} = TestCert.server(:self_signed)

    assert ca == nil
    assert :public_key.pkix_is_self_signed(ssl[:cert])
    assert sans(ssl[:cert]) == [iPAddress: <<127, 0, 0, 1>>]
  end

  test "every call makes new keys and a new CA" do
    a = TestCert.server(:ip)
    b = TestCert.server(:ip)
    refute a.ca == b.ca
    refute a.ssl[:key] == b.ssl[:key]
    assert {:error, _} = verify(a.ssl[:cert], b.ca)
  end

  test "pem/1 is a PEM certificate the store loader reads back" do
    %{ca: ca} = TestCert.server(:ip)
    pem = TestCert.pem(ca)
    assert pem =~ "-----BEGIN CERTIFICATE-----"
    assert [{:Certificate, ^ca, :not_encrypted}] = :public_key.pem_decode(pem)
  end

  test "kinds/0 names the three" do
    assert Enum.sort(TestCert.kinds()) == [:ip, :self_signed, :wrong_host]
  end
end
