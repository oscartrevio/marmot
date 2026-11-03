#!/usr/bin/env bats
# lib/out.sh: how every command prints. All commands go through the same primitives: titles, aligned
# rows, a card that closes the run; in a pipe without escape codes or carriage returns, and within
# the terminal's width.

setup() {
  load helpers/common
  mm_test_setup
  mkdir -p "$SB/tmp"
}
teardown() { mm_test_teardown; }

# quiet_host — doubles for every tool the guard would stop: found nowhere, nothing to report.
quiet_host() {
  local t
  for t in npm pnpm pipx bun yarn uv conda brew apt apt-get apt-mark snap systemctl journalctl fstrim swapon resolvectl; do mm_test_fake "$t" 'exit 0'; done
  mm_test_fake docker 'exit 1'
}

# prims COLS — every primitive once, in a fresh bash on a pipe.
prims() {
  COLUMNS=$1 MM_HOME="$MM_SRC" MM_CMD=clean bash -c '
    . "$MM_HOME/lib/core.sh"
    mm_sysline() { echo "Debian 13 | 8 cores | 16GB RAM"; }
    mm_header "Clean your system"
    mm_prog_plan 2
    mm_prog_step "Developer caches"
    mm_section "Developer caches"
    mm_ok "npm cache" "150.0MB"
    mm_ok "A very long label that has to be cut from the left to fit the narrow terminal at all" "1 item, 40.0MB"
    mm_skip "System cleanup" "needs sudo"
    mm_warn "In-use check is partial: running without sudo, only your own processes are checked"
    mm_info "An informational line that is long enough to need wrapping on a narrow terminal"
    mm_err "something failed" 2>&1
    MM_FREED=1500000000
    mm_banner "Cleanup complete" "Space freed: 1.4GB | Items cleaned: 3" "Biggest win: Developer caches, 830.0MB" "Free space: 37.0GB (+1.4GB)" "Run it again."
    mm_result info "Report" "*total" "330.9MB" "next" "mm uninstall --dry-run NAME..."
    mm_done_empty "Nothing to clean right now."
    mm_die "unknown option: --bogus (see mm clean --help)"
  ' 2>&1
}

@test "MM_OUT_STYLE and MM_OUT_ON from the environment change nothing" {
  quiet_host
  mkdir -p "$XDG_STATE_HOME/marmot"
  printf '%s\n' $'2026-10-13T10:00:00+00:00\tclean\tremove\t/tmp/a\t4096' >"$XDG_STATE_HOME/marmot/operations.log"
  local plain; plain=$(mm history; mm schedule status)
  [ "$(MM_OUT_STYLE=3 mm history; MM_OUT_STYLE=3 mm schedule status)" = "$plain" ]
  [ "$(MM_OUT_ON=1 mm history; MM_OUT_ON=1 mm schedule status)" = "$plain" ]
  [[ "$plain" == *╭* ]]
}

@test "--verbose is not a marmot flag" {
  run mm history --verbose
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option: --verbose"* ]]
}

@test "in a pipe: no escape codes, no carriage returns, nothing wider than the terminal" {
  local w line
  for w in 50 84; do
    run prims "$w"
    [[ "$output" != *$'\e'* ]] || { echo "at $w: escape code"; false; }
    [[ "$output" != *$'\r'* ]] || { echo "at $w: carriage return"; false; }
    [[ "$output" == *"unknown option: --bogus"* ]]
    while IFS= read -r line; do
      (( ${#line} <= w )) || { echo "at $w: ${#line} wide: $line"; false; }
    done <<<"$output"
  done
}

@test "a change ends in a card, a report in a card, an empty run in a card and an error in a card" {
  run prims 84
  [[ "$output" == *"╭─ Cleanup complete"* ]]
  [[ "$output" == *"freed"*"1.4GB"* ]]
  [[ "$output" == *"╭─ Report"* ]]
  [[ "$output" == *"╭─ Nothing to do"* ]]
  [[ "$output" == *"╭─ ✗ Stopped"* ]]
  [[ "$output" == *"mm clean --help"* ]]
}

# closing BYTES DRY — the closing card of a run that freed BYTES (a dry run when DRY is 1), on a
# terminal (MM_TTY=1), with the festive calendar off so no greeting slips in.
closing() {
  MM_TTY=1 COLUMNS=80 MM_HOME="$MM_SRC" MM_CMD=clean MM_DRY_RUN=$2 FREED=$1 bash -c '
    . "$MM_HOME/lib/core.sh"
    mm_festive() { return 1; }
    MM_FREED=$FREED
    if [[ "$MM_DRY_RUN" == 1 ]]; then mm_banner "Dry run complete" "Would free: 2.0GB | Items to clean: 3"
    else mm_banner "Cleanup complete" "Space freed: 2.0GB | Items cleaned: 3"; fi
  ' 2>&1
}

@test "a real run on a terminal closes with the marmot over its card, proud from 1GB freed" {
  run closing 2147483648 0
  [[ "$output" == *"(mm)--UU--(mm)"* ]]
  [[ "$output" == *"^    ^"* ]]
  [[ "$output" == *"+*"* ]]
  # the marmot comes before the card
  [[ "${output%%╭─*}" == *"(mm)--UU--(mm)"* ]]
  run closing 1048576 0
  [[ "$output" == *"^    ^"* && "$output" != *"+*"* ]]
}

@test "the marmot over the card says nothing: the day's greeting is the card's, once" {
  mm_test_now '2026-12-25 12:00'
  MM_TTY=1 COLUMNS=80 MM_HOME="$MM_SRC" MM_CMD=clean MM_DRY_RUN=0 run bash -c '
    . "$MM_HOME/lib/core.sh"
    MM_FREED=1048576
    mm_banner "Cleanup complete" "Space freed: 1.0MB | Items cleaned: 1" "$(MM_RUN_ID=X mm_greeting; echo "$REPLY")"
  '
  [[ "$output" == *"(mm)--UU--(mm)"* ]]
  [ "$(grep -cF "Merry Christmas" <<<"$output")" -eq 1 ]
}

@test "a dry run, a pipe and a failed run close without the marmot" {
  run closing 2147483648 1
  [[ "$output" == *"╭─ Dry run complete"* && "$output" != *"(mm)"* ]]
  run prims 84
  [[ "$output" == *"╭─ Cleanup complete"* && "$output" != *"(mm)"* ]]
}

@test "mm clean --dry-run: the totals, as a card, without escape codes" {
  mkdir -p "$HOME/.cache/pip"; head -c 3000000 /dev/zero >"$HOME/.cache/pip/blob"
  mm_age "$HOME/.cache" 60
  quiet_host
  export MM_NO_SUDO=1
  run mm clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Clean your system"*"dry run: nothing will change"* ]]
  [[ "$output" == *"✓ pip cache"* ]]
  [[ "$output" == *"╭─ Dry run complete"* ]]
  [[ "$output" =~ would\ free\ +[0-9.]+MB ]]
  [[ "$output" == *"free space"*"now"*"after"* ]]
  [[ "$output" != *$'\e'* ]]
}

@test "mm purge --dry-run and mm history: the list, then the card" {
  mkdir -p "$SB/p/node_modules" "$XDG_STATE_HOME/marmot"
  echo '{}' >"$SB/p/package.json"; head -c 4096 /dev/zero >"$SB/p/node_modules/blob"
  mm_age "$SB/p" 40
  printf '%s\n' $'2026-10-13T10:00:00+00:00\tpurge\tremove\t/tmp/a\t4096\t\tR1' \
    $'2026-10-13T10:00:01+00:00\tpurge\trefused\t/x/node_modules\t0\tin use\tR1' >"$XDG_STATE_HOME/marmot/operations.log"
  run mm purge --dry-run "$SB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 1 artifact"* ]]
  [[ "$output" == *"/p/node_modules"* ]]
  [[ "$output" == *"╭─ Dry run complete"* ]]
  run mm history
  [ "$status" -eq 0 ]
  [[ "$output" == *"purge"*"1 removed"* ]]
  [[ "$output" == *"refused"*"in use"* ]]
  [[ "$output" == *"╭─ Since 2026-10-13"* ]]
}

@test "mm status --once and mm schedule status: rows with a mark each, then a card; never the dashboard's bars" {
  quiet_host
  run mm status --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"Health "* ]]
  [[ "$output" == *"cpu"* && "$output" == *"memory"* && "$output" == *"disk"* ]]
  [[ "$output" != *"AGENTS"* ]]
  # the dashboard's marmot peeks over the rows, as plain text without color
  mm_test_now '2026-06-10 12:00'
  run env NO_COLOR=1 TERM=dumb COLUMNS=80 mm status --once
  [[ "$output" == *"mm status  ● "*"--(mm)--UU--(mm)--"*"Status"*"Health "* && "$output" != *$'\e'* ]]
  run mm schedule status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not scheduled"* ]]
  [[ "$output" == *"╭─ Scheduled cleanup"* ]]
}

@test "mm analyze PATH lists the biggest entries; --json is untouched" {
  mkdir -p "$SB/a/big"; head -c 200000 /dev/zero >"$SB/a/big/blob"
  run mm analyze "$SB/a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Largest entries"*"big"* ]]
  [[ "$output" == *"╭─ Largest entries"* ]]
  [ "$(mm analyze --json | head -c 1)" = "{" ]
}

@test "an error says what stopped and where to look" {
  run mm purge --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
  run mm nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: nope"* ]]
}

@test "mm optimize --dry-run and mm uninstall --list" {
  quiet_host
  mm_test_fake apt-mark 'case "$1" in showmanual) printf "curl\njq\n" ;; esac; exit 0'
  run mm optimize --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"╭─ Dry run complete"* ]]
  [[ "$output" == *"Would apply"*"optimizations"* ]]
  run mm uninstall --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removable packages"* ]]
}
