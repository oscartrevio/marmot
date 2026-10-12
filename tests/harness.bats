#!/usr/bin/env bats
# The test harness itself: every test must be sandboxed and must not reach the real machine.

setup() {
  load helpers/common
  mm_test_setup
}
teardown() { mm_test_teardown; }

@test "HOME, XDG dirs and the scratch dir live inside the bats temp dir" {
  local sandbox; sandbox=$(realpath "$BATS_TEST_TMPDIR")
  [ "$HOME" = "$sandbox/home" ]
  [[ "$XDG_CONFIG_HOME" == "$HOME"/* ]]
  [[ "$XDG_DATA_HOME" == "$HOME"/* ]]
  [[ "$XDG_STATE_HOME" == "$HOME"/* ]]
  [[ "$SB" == "$sandbox"/* ]]
  [ "$MM_TTY" = 0 ]
}

@test "a stubbed command fails loudly and is recorded for teardown" {
  run apt-get install something
  [ "$status" -eq 97 ]
  grep -qx 'UNSTUBBED apt-get install something' "$MM_TEST_UNSTUBBED_LOG"
  run mm_test_teardown
  [ "$status" -ne 0 ]
  : >"$MM_TEST_UNSTUBBED_LOG"   # let this test's own teardown pass
}

@test "sudo -n true answers no quietly; any other sudo use is recorded" {
  run sudo -n true
  [ "$status" -eq 1 ]
  [ ! -s "$MM_TEST_UNSTUBBED_LOG" ]
  run sudo rm -rf /
  [ "$status" -eq 97 ]
  [ -s "$MM_TEST_UNSTUBBED_LOG" ]
  : >"$MM_TEST_UNSTUBBED_LOG"
}

@test "mm_test_fake replaces a stub for the current test only" {
  mm_test_fake docker 'echo "fake $*"'
  run docker ps
  [ "$output" = "fake ps" ]
  [ ! -s "$MM_TEST_UNSTUBBED_LOG" ]
}

@test "background processes started with mm_test_bg are stopped at teardown" {
  mm_test_bg "$SB" sleep 300
  local pid=${MM_TEST_PIDS[-1]}
  kill -0 "$pid"
  mm_test_teardown
  sleep 0.2
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}
