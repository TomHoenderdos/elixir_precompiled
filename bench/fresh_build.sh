#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
# Times this library's own share of a fresh `_build`: compiling it
# (`deps.compile precompiled`) and running its check (`precompiled.deps`),
# from the Mix task timings MIX_DEBUG=1 prints.
#
#     bench/fresh_build.sh PROJECT_DIR [RUNS]
#
# PROJECT_DIR has this library as a dependency and the `deps.loadpaths`
# alias. Its `_build` is deleted before every run. Prints one line per run
# and the medians, in milliseconds.
set -euo pipefail

project=${1:?usage: bench/fresh_build.sh PROJECT_DIR [RUNS]}
runs=${2:-5}
log=$(mktemp)
trap 'rm -f "$log"' EXIT

compile=()
check=()

for i in $(seq 1 "$runs"); do
  rm -rf "$project/_build"
  (cd "$project" && MIX_DEBUG=1 mix deps.loadpaths >"$log" 2>&1)
  c=$(grep -m1 -E '^<- Ran mix deps.compile in [0-9]+ms' "$log" | grep -oE '[0-9]+ms' | tr -d ms)
  k=$(grep -m1 -E '^<- Ran mix precompiled.deps in [0-9]+ms' "$log" | grep -oE '[0-9]+ms' | tr -d ms)
  compile+=("$c")
  check+=("$k")
  echo "run $i: compile ${c}ms check ${k}ms"
done

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
echo "median: compile $(median "${compile[@]}")ms check $(median "${check[@]}")ms"
