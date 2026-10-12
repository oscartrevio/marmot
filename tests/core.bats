#!/usr/bin/env bats
# lib/core.sh: HOME handling, prompts and pickers, process age, the operations log.

setup() {
  load helpers/common
  mm_test_setup
  mm_core
}
teardown() { mm_test_teardown; }

@test "HOME that is / or missing stops marmot before anything runs" {
  run env HOME=/ bash -c '. "$1/lib/core.sh"; echo reached' _ "$MM_SRC"
  [ "$status" -ne 0 ]; [[ "$output" != *reached* ]]
  run env HOME="$SB/missing" bash -c '. "$1/lib/core.sh"; echo reached' _ "$MM_SRC"
  [ "$status" -ne 0 ]; [[ "$output" != *reached* ]]
}

@test "process age is right for names with spaces and parentheses" {
  cp "$(command -v sleep)" "$SB/tmux: server (x)"
  mm_test_bg "$SB" "./tmux: server (x)" 30
  local pid=${MM_TEST_PIDS[-1]} age
  age=$(mm_proc_age "$pid")
  (( age >= 0 && age < 30 ))
}

@test "without a terminal, pickers select nothing and confirmations decline" {
  MM_TTY=0
  [ -z "$(printf 'a\nb\n' | mm_pick header)" ]
  run mm_confirm "delete everything?"
  [ "$status" -ne 0 ]
}

@test "log rows stay one line per operation even for odd names" {
  MM_DRY_RUN=0 mm_log remove "$SB/a"$'\n'"b"$'\t'"c" 5 "why"$'\n'"not"
  [ "$(wc -l <"$XDG_STATE_HOME/marmot/operations.log")" -eq 1 ]
  [ "$(awk -F'\t' '{ print NF }' "$XDG_STATE_HOME/marmot/operations.log")" -eq 6 ]
}
