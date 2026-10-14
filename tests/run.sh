#!/usr/bin/env bash
# Run marmot's checks: shellcheck on every shell source, then the bats suite (or the .bats files
# given as arguments). Tests never touch the real machine: see tests/helpers/common.bash.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

command -v bats >/dev/null || { echo "bats is not installed: sudo apt-get install bats" >&2; exit 1; }
# The suite needs bats-core 1.5+; Ubuntu 22.04 ships 1.2, which lacks BATS_TEST_TMPDIR.
bats_version=$(bats --version | awk '{ print $2 }')
if [[ "$(printf '%s\n' 1.5.0 "$bats_version" | sort -V | head -1)" != 1.5.0 ]]; then
  echo "bats-core 1.5 or newer is required (found $bats_version). Install a pinned release:" >&2
  echo "  git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core /tmp/bats-core" >&2
  echo "  sudo /tmp/bats-core/install.sh /usr/local" >&2
  exit 1
fi
command -v shellcheck >/dev/null || { echo "shellcheck is not installed: sudo apt-get install shellcheck" >&2; exit 1; }

sources=()
for f in marmot install.sh lib/*.sh cmd/*.sh completion/*.bash tests/run.sh; do
  [[ -f "$f" ]] && sources+=("$f")
done
shellcheck -x "${sources[@]}"

jobs=()
command -v parallel >/dev/null && jobs=(--jobs "$(nproc)")
if (( $# )); then bats "${jobs[@]}" "$@"; else bats "${jobs[@]}" tests; fi
