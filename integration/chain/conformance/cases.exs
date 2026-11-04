# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Conformance cases for `mix chain_conformance`. The format is described in
# ChainTest.Conformance.Case and in README.md, "Conformance".
[
  %{
    id: "T0",
    description:
      "The mirror serves the snapshot unchanged: the client installs every build the snapshot holds.",
    transform: {ChainTest.Mirror.Identity, %{}},
    client: %{default: :snapshot, deps: %{}},
    harness: %{}
  },
  %{
    id: "N5-manifest-500",
    description:
      "The mirror answers 500 for jason's manifest: the client compiles jason and says why.",
    transform:
      {ChainTest.Mirror.Status,
       %{paths: ["v2/manifests/jason.json", "manifests/jason.json"], status: 500}},
    client: %{default: :snapshot, deps: %{jason: {:miss, "manifest unavailable: Status 500"}}},
    harness: %{"build/hit:jason" => :fail}
  }
]
