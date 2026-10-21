#!/usr/bin/env bats
# The `mm` entry point and `mm history`.

setup() {
  load helpers/common
  mm_test_setup
}
teardown() { mm_test_teardown; }

@test "unknown commands and path-like command names are rejected" {
  run mm nope
  [ "$status" -ne 0 ]
  run mm ../lib/core
  [ "$status" -ne 0 ]
}

@test "-y/--yes is rejected everywhere except mm purge, where it may come before the command" {
  local args
  for args in "clean -y" "clean --yes" "-y clean" "uninstall --yes ncdu" "optimize -y" "analyze -y" "history -y" \
    "update -y" "update --yes" "-y" "--yes --help"; do
    # shellcheck disable=SC2086
    run mm $args
    [ "$status" -ne 0 ] || { echo "accepted: mm $args"; false; }
  done
  mkdir -p "$SB/p/node_modules"; echo '{}' >"$SB/p/package.json"; mm_age "$SB" 30
  for args in "purge --yes --dry-run" "--yes purge --dry-run" "-n -y purge"; do
    # shellcheck disable=SC2086
    run mm $args "$SB"
    [ "$status" -eq 0 ] || { echo "refused: mm $args"; false; }
  done
  [ -d "$SB/p/node_modules" ]   # every run was a dry run
  run mm -y purge "$SB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/p/node_modules" ]   # --yes before the command still means unattended
}

@test "history with no log says so; --json prints an empty array, even without jq" {
  run mm history
  [ "$status" -eq 0 ]
  [[ "$output" == "No operations recorded yet"* ]]
  mkdir -p "$SB/bin"
  local d f
  for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do [[ "${f##*/}" == jq || -e "$SB/bin/${f##*/}" ]] || ln -s "$f" "$SB/bin/${f##*/}"; done
  done
  PATH="$BATS_TEST_TMPDIR/stubs:$SB/bin" run mm history --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "history reads old 5-column and new 6-column rows, as text and JSON" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' \
    $'2026-10-12T17:05:39+00:00\tclean\tremove\t/tmp/old\t4096' \
    $'2026-10-13T10:00:00+00:00\tclean\ttrash\t/tmp/doc\t8192\t/home/u/.local/share/Trash/files/doc' \
    $'2026-10-13T10:00:01+00:00\tpurge\trefused\t/x/node_modules\t0\tin use' \
    >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history
  [ "$status" -eq 0 ]
  [[ "$output" == *"/x/node_modules"*"(in use)"* ]]
  run mm history --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.action) | join(",")' <<<"$output")" = "remove,trash,refused" ]
  [ "$(jq -r '.[0].detail + "|" + .[2].detail + "|" + (.[1].bytes | tostring)' <<<"$output")" = "|in use|8192" ]
}

@test "history --limit/-l returns only the newest runs (-n stays the global --dry-run)" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-12T10:00:00+00:00\tclean\tremove\t/tmp/a\t1\t\tR1' \
    $'2026-10-12T11:00:00+00:00\tpurge\tremove\t/tmp/b\t1\t\tR2' \
    $'2026-10-12T11:00:01+00:00\tpurge\tremove\t/tmp/c\t1\t\tR2' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history -l 1 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.target) | join(",")' <<<"$output")" = "/tmp/b,/tmp/c" ]
  run mm history --limit 1 --json
  [ "$(jq -r 'map(.target) | join(",")' <<<"$output")" = "/tmp/b,/tmp/c" ]
  run mm history -l 1
  [[ "$output" == *"/tmp/b"*"/tmp/c"* && "$output" != *"/tmp/a"* ]]
}

@test "history groups rows by run: one line per run with its totals; old rows by command and time" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-12T10:00:00+00:00\tclean\tremove\t/tmp/old1\t1' \
    $'2026-10-12T10:00:05+00:00\tclean\tremove\t/tmp/old2\t1' \
    $'2026-10-12T12:00:00+00:00\tclean\tremove\t/tmp/old3\t1' \
    $'2026-10-13T10:00:00+00:00\tpurge\tremove\t/tmp/a\t2048\t\tR1' \
    $'2026-10-13T10:00:01+00:00\tpurge\ttrash\t/tmp/v\t4096\t/t/v\tR1' \
    $'2026-10-13T10:00:02+00:00\tpurge\trefused\t/tmp/b\t0\tin use\tR1' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history
  [ "$status" -eq 0 ]
  [ "$(grep -c '^2026-' <<<"$output")" -eq 3 ]   # old1+old2, old3 (2 hours later), R1
  grep -qx '2026-10-13 10:00:00+00:00  purge · 1 removed 2KB · 1 to Trash 4KB · 1 refused' <<<"$output"
}

@test "history prints 1000-1023 bytes as 1KB, like the rest of marmot" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-13T10:00:00+00:00\tclean\tremove\t/tmp/k\t1000\t\tR1' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history
  [ "$status" -eq 0 ]
  [[ "$output" == *"/tmp/k 1KB"* ]]
  [[ "$output" != *"0KB"* ]]
}

@test "history reads the rotated operations.log.old before the current log" {
  local log="$XDG_STATE_HOME/marmot/operations.log" i
  mkdir -p "$XDG_STATE_HOME/marmot" "$SB/p/node_modules"
  for i in $(seq 40); do printf '2026-10-01T10:00:00+00:00\tclean\tremove\t/tmp/before%s\t1\t\n' "$i"; done >"$log"
  echo '{}' >"$SB/p/package.json"; mm_age "$SB" 30
  MM_LOG_MAX_BYTES=$(( $(stat -c %s "$log") - 1 )) run mm purge --yes "$SB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/p/node_modules" ]
  grep -q /tmp/before40 "$log.old"
  grep -q "$SB/p/node_modules" "$log"
  run mm history --all --json
  [ "$(jq -r 'map(select(.target | test("before|node_modules"))) | length' <<<"$output")" -eq 41 ]
  run mm history --all
  [[ "$output" == *"/tmp/before1"*"$SB/p/node_modules"* ]]
}

@test "rows from one invocation share a run id; another invocation gets its own" {
  mkdir -p "$SB/one/a/node_modules" "$SB/one/b/node_modules" "$SB/two/c/node_modules"
  local d; for d in one/a one/b two/c; do echo '{}' >"$SB/$d/package.json"; done
  mm_age "$SB" 30
  run mm purge --yes "$SB/one"
  [ "$status" -eq 0 ]
  run mm purge --yes "$SB/two"
  [ "$status" -eq 0 ]
  run mm history --json
  [ "$status" -eq 0 ]
  local a b c
  a=$(jq -r --arg p "$SB/one/a/node_modules" 'map(select(.target == $p)) | .[0].run' <<<"$output")
  b=$(jq -r --arg p "$SB/one/b/node_modules" 'map(select(.target == $p)) | .[0].run' <<<"$output")
  c=$(jq -r --arg p "$SB/two/c/node_modules" 'map(select(.target == $p)) | .[0].run' <<<"$output")
  [ -n "$a" ] && [ "$a" != null ]
  [ "$a" = "$b" ]
  [ "$a" != "$c" ] && [ "$c" != null ]
}

@test "history --json without jq says jq is required" {
  mkdir -p "$XDG_STATE_HOME/marmot" "$SB/bin"
  printf '%s\n' $'2026-10-12T10:00:00+00:00\tclean\tremove\t/tmp/a\t1\t' >"$XDG_STATE_HOME/marmot/operations.log"
  local d f
  for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do [[ "${f##*/}" == jq || -e "$SB/bin/${f##*/}" ]] || ln -s "$f" "$SB/bin/${f##*/}"; done
  done
  PATH="$BATS_TEST_TMPDIR/stubs:$SB/bin" run mm history --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq is required for --json"* ]]
}
