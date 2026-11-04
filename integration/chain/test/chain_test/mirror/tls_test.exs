# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.Mirror.TlsTest do
  use ExUnit.Case, async: true

  alias ChainTest.Mirror.{Downgrade, Identity, Transform}

  @sha String.duplicate("ab", 32)

  describe "the runner's tls and trust_ca args" do
    test "tls names a certificate kind; trust_ca only goes with tls" do
      for kind <- [:ip, :self_signed, :wrong_host] do
        assert Transform.valid?({Identity, %{tls: kind}})
        assert Transform.tls({Identity, %{tls: kind}}) == kind
      end

      assert Transform.valid?({Identity, %{tls: :ip, trust_ca: true}})
      assert Transform.valid?({Identity, %{tls: :wrong_host, trust_ca: true}})
      assert Transform.trust_ca?({Identity, %{tls: :ip, trust_ca: true}})

      # a self-signed certificate has no CA to trust
      refute Transform.valid?({Identity, %{tls: :self_signed, trust_ca: true}})

      refute Transform.valid?({Identity, %{tls: :other}})
      refute Transform.valid?({Identity, %{trust_ca: true}})
      refute Transform.valid?({Identity, %{tls: :ip, trust_ca: false}})
      refute Transform.valid?({ChainTest.TestTransform, %{mirrors: 2, tls: :ip}})
    end

    test "a plain case has no tls and trusts no CA" do
      assert Transform.tls({Identity, %{}}) == nil
      refute Transform.trust_ca?({Identity, %{}})
    end
  end

  describe "Downgrade" do
    test "takes only paths over a trusted :ip mirror" do
      for paths <- [:files, :manifests],
          do: assert(Transform.valid?({Downgrade, %{paths: paths, tls: :ip, trust_ca: true}}))

      refute Transform.valid?({Downgrade, %{paths: :files}})
      refute Transform.valid?({Downgrade, %{paths: :files, tls: :ip}})
      refute Transform.valid?({Downgrade, %{paths: :batch, tls: :ip, trust_ca: true}})
      refute Transform.valid?({Downgrade, %{paths: :files, tls: :self_signed, trust_ca: true}})
    end

    test "redirects the named paths to plain http on the same host and port, serves the rest" do
      args = %{paths: :files, tls: :ip, trust_ca: true}

      assert Downgrade.transform("files/" <> @sha, "x", args) ==
               {:redirect, 302, {:scheme, "http"}}

      assert Downgrade.transform("v2/manifests/jason.json", "m", args) == {200, "m"}
      assert Downgrade.transform("batch.json", "b", args) == {200, "b"}

      args = %{args | paths: :manifests}

      assert Downgrade.transform("v2/manifests/jason.json", "m", args) ==
               {:redirect, 302, {:scheme, "http"}}

      assert Downgrade.transform("files/" <> @sha, "x", args) == {200, "x"}
    end
  end
end
