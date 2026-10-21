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

@test "a mistyped command names the one probably meant; mm help COMMAND shows that command's help" {
  run mm cleen
  [ "$status" -ne 0 ]
  [[ "$output" == *"clean?"* ]]
  run mm analize
  [[ "$output" == *"analyze?"* ]]
  run mm zzzzzzzz
  [ "$status" -ne 0 ]
  [[ "$output" != *"?"* ]]                       # nothing close: no suggestion
  local want; want=$(mm purge --help)
  run mm help purge
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  run mm help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: mm"* ]]
  run mm help cleen
  [ "$status" -ne 0 ]
  [[ "$output" == *"clean?"* ]]
}

@test "colors only go to a terminal stream, never with TERM=dumb or NO_COLOR" {
  command -v script >/dev/null || skip "needs script (util-linux)"
  unset NO_COLOR
  # stdout is a terminal, stderr a file: the error message carries no escape codes
  TERM=xterm script -qec "mm nope 2>'$SB/err'" /dev/null >"$SB/out" || true
  grep -q 'unknown command' "$SB/err"
  [ "$(grep -c $'\e' "$SB/err")" = 0 ]
  TERM=xterm script -qec "mm --help" /dev/null >"$SB/out"
  [ "$(grep -c $'\e\\[1m' "$SB/out")" -gt 0 ]   # the control: a terminal does get color
  TERM=dumb script -qec "mm --help" /dev/null >"$SB/out"
  [ "$(grep -c $'\e\\[1m' "$SB/out")" = 0 ]
}

@test "bare mm opens its menu with fzf older than 0.34 (Ubuntu 22.04) and newer ones" {
  local v
  for v in "0.29 (devel)" "0.38.0 (debian)"; do
    # an fzf of version v that rejects what that version does not know, and picks "history"
    mm_test_fake fzf "[[ \$1 == --version ]] && { echo '$v'; exit 0; }
      for a; do [[ \$a == --height=~* && '$v' == 0.29* ]] && { echo 'not a valid number: ~40' >&2; exit 2; }; done
      grep '^history '"
    MM_TTY=1 run mm
    [ "$status" -eq 0 ]
    [[ "$output" == "No operations recorded yet"* ]] || { echo "fzf $v: menu did not run history"; false; }
  done
}

@test "the menu previews each command's --help" {
  # an fzf that runs its --preview command for the purge row, then picks nothing
  mm_test_fake fzf "[[ \$1 == --version ]] && { echo '0.29 (devel)'; exit 0; }
    while (( \$# )); do [[ \$1 == --preview ]] && p=\$2; shift; done
    cat >/dev/null
    bash -c \"\${p//\{1\}/purge}\" >'$SB/preview'; exit 130"
  MM_TTY=1 run mm
  [ "$status" -eq 0 ]
  [ "$(cat "$SB/preview")" = "$(mm purge --help)" ]
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
  local rows; rows=$(grep '^  ' <<<"$output")    # the listed rows (the closing story is all-time)
  [[ "$rows" == *"/tmp/b"*"/tmp/c"* && "$rows" != *"/tmp/a"* ]]
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

@test "history counts the bytes of run and worktree rows in each run's line and the total" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-13T10:00:00+00:00\tclean\trun\tnpm cache\t2048\t\tR1' \
    $'2026-10-13T10:00:01+00:00\tclean\trun\tapt-get update\t0\t\tR1' \
    $'2026-10-13T10:00:02+00:00\tclean\tremove\t/tmp/a\t2048\t\tR1' \
    $'2026-10-14T10:00:00+00:00\tpurge\tworktree\t/w\t4096\tfeat\tR2' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history
  [ "$status" -eq 0 ]
  grep -qx '2026-10-13 10:00:00+00:00  clean · 2 ran 2KB · 1 removed 2KB' <<<"$output"
  [[ "$output" == *"Since 2026-10-13: 2 runs · 8KB freed"* ]]
}

@test "history ends with the story so far: since when, runs, freed, Trash, refused, biggest wins" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-12T10:00:00+00:00\tclean\tremove\t'"$HOME"$'/.cache/big\t3145728\t\tR1' \
    $'2026-10-12T10:00:01+00:00\tclean\trefused\t/x/node_modules\t0\tin use\tR1' \
    $'2026-10-13T10:00:00+00:00\tclean\ttrash\t/tmp/doc\t2097152\t/t/doc\tR2' \
    $'2026-10-13T10:00:01+00:00\tclean\trun\tnpm cache\t1048576\t\tR2' \
    $'2026-10-14T10:00:00+00:00\tpurge\tremove\t/tmp/small\t1024\t\tR3' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm history
  [ "$status" -eq 0 ]
  grep -qx 'Since 2026-10-12: 3 runs · 4.0MB freed · 2.0MB to Trash (restore: trash-restore) · 1 refused (each with its reason above)' <<<"$output"
  grep -qx 'Biggest wins: ~/.cache/big 3.0MB, /tmp/doc 2.0MB, npm cache 1.0MB' <<<"$output"
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

# log_rows ROW... — write operations-log rows (TSV) to the log.
log_rows() { mkdir -p "$XDG_STATE_HOME/marmot"; printf '%s\n' "$@" >>"$XDG_STATE_HOME/marmot/operations.log"; }

@test "the first terminal run after scheduled runs says what they did, once; dry runs leave it" {
  mkdir -p "$SB/empty"
  log_rows "$(date -Iseconds -d '2 days ago')"$'\tschedule\tremove\t/x/a\t3145728\t\tS1' \
    "$(date -Iseconds -d '1 day ago')"$'\tschedule\ttrash\t/x/b\t1048576\t/t/b\tS2' \
    "$(date -Iseconds -d '1 day ago')"$'\tschedule\tfailed\t/x/c\t0\trm failed\tS2'
  local stamp="$XDG_STATE_HOME/marmot/schedule-seen"
  MM_TTY=1 run mm purge --dry-run "$SB/empty"
  [[ "$output" != *"While you were away"* ]]
  [ ! -e "$stamp" ]                                             # a dry run reports nothing, marks nothing
  run mm purge "$SB/empty"                                      # no terminal: the same
  [ ! -e "$stamp" ]
  MM_TTY=1 run mm purge "$SB/empty"
  grep -qx 'While you were away: 2 scheduled runs freed 3.0MB, moved 1.0MB to the Trash, 1 failed (mm schedule status)' <<<"$output"
  [ -s "$stamp" ]
  MM_TTY=1 run mm purge "$SB/empty"
  [[ "$output" != *"While you were away"* ]]                    # said once
}

@test "a run that carries the lifetime freed total across 10GB says so, once" {
  log_rows "2026-01-01T00:00:00+00:00"$'\tclean\tremove\t/x/old\t10737418000\t\tR0'   # just under 10GB
  mkdir -p "$SB/p/node_modules"; echo '{}' >"$SB/p/package.json"
  head -c 4096 /dev/urandom >"$SB/p/node_modules/blob"; mm_age "$SB" 30
  MM_TTY=1 run mm purge --dry-run --yes "$SB"
  [[ "$output" != *"has now freed"* ]]                           # never from a dry run
  MM_TTY=1 run mm purge --yes "$SB"
  [ ! -e "$SB/p/node_modules" ]
  grep -qx 'marmot has now freed 10GB on this machine' <<<"$output"
  mkdir -p "$SB/p/node_modules"; head -c 4096 /dev/urandom >"$SB/p/node_modules/blob"; mm_age "$SB" 30
  MM_TTY=1 run mm purge --yes "$SB"
  [ ! -e "$SB/p/node_modules" ]
  [[ "$output" != *"has now freed"* ]]                           # above it is not crossing it
}

@test "on an occasion mm --version on a terminal and a run with nothing to do add the day's greeting" {
  command -v script >/dev/null || skip "needs script (util-linux)"
  mkdir -p "$SB/empty"
  local ordinary
  mm_test_now '2026-06-10 12:00'
  run script -qec "mm --version" /dev/null
  [ "$(tr -d '\r' <<<"$output" | wc -l)" -eq 1 ]
  MM_TTY=1 run mm purge "$SB/empty"
  ordinary=$(grep '✓' <<<"$output")
  [ -n "$ordinary" ]
  mm_test_now '2026-12-25 12:00'
  run script -qec "mm --version" /dev/null
  [ "$(tr -d '\r' <<<"$output" | wc -l)" -eq 2 ]
  run mm --version                                              # for a script: the version alone
  [ "${#lines[@]}" -eq 1 ]
  MM_TTY=1 run mm purge "$SB/empty"
  [[ "$(grep '✓' <<<"$output")" == "$ordinary  "?* ]]
  run mm purge "$SB/empty"                                      # no terminal: no greeting
  [ "$(grep '✓' <<<"$output")" = "$ordinary" ]
}
