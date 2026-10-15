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

@test "-y/--yes is rejected everywhere except mm purge" {
  local args
  for args in "clean -y" "clean --yes" "-y clean" "uninstall --yes ncdu" "optimize -y" "analyze -y" "history -y" "update -y" "update --yes"; do
    # shellcheck disable=SC2086
    run mm $args
    [ "$status" -ne 0 ] || { echo "accepted: mm $args"; false; }
  done
  run mm purge --yes --dry-run "$SB"
  [ "$status" -eq 0 ]
}

@test "history with no log says so" {
  run mm history
  [ "$status" -eq 0 ]
  [[ "$output" == "No operations recorded yet"* ]]
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

@test "history --limit/-l returns only the newest rows (-n stays the global --dry-run)" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-12T10:00:00+00:00\tclean\tremove\t/tmp/a\t1\t' \
    $'2026-10-12T11:00:00+00:00\tclean\tremove\t/tmp/b\t1\t' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history -l 1 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.target) | join(",")' <<<"$output")" = "/tmp/b" ]
  run mm history --limit 1 --json
  [ "$(jq -r 'map(.target) | join(",")' <<<"$output")" = "/tmp/b" ]
}

@test "history reads the rotated log before the current one" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-12T10:00:00+00:00\tclean\tremove\t/tmp/a\t1\t' >"$XDG_STATE_HOME/marmot/operations.log.old"
  printf '%s\n' $'2026-10-13T10:00:00+00:00\tclean\tremove\t/tmp/b\t1\t' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.target) | join(",")' <<<"$output")" = "/tmp/a,/tmp/b" ]
  run mm history -l 1 --json
  [ "$(jq -r 'map(.target) | join(",")' <<<"$output")" = "/tmp/b" ]
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
