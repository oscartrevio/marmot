#!/usr/bin/env bash
# Run marmot's checks: shellcheck on every shell source, then the bats suite (or the .bats files
# given as arguments). Tests never touch the real machine: see tests/helpers/common.bash.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

command -v bats >/dev/null || { echo "bats is not installed: sudo apt-get install bats" >&2; exit 1; }
command -v shellcheck >/dev/null || { echo "shellcheck is not installed: sudo apt-get install shellcheck" >&2; exit 1; }

sources=()
for f in marmot install.sh lib/*.sh cmd/*.sh completion/*.bash tests/run.sh; do
  [[ -f "$f" ]] && sources+=("$f")
done
shellcheck -x "${sources[@]}"

jobs=()
command -v parallel >/dev/null && jobs=(--jobs "$(nproc)")
if (( $# )); then bats "${jobs[@]}" "$@"; else bats "${jobs[@]}" tests; fi
