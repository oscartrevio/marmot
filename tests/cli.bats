#!/usr/bin/env bats
# The `mm` entry point.

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

@test "-y/--yes is rejected for every command" {
  local args
  for args in "clean -y" "clean --yes" "-y clean" "uninstall --yes ncdu" "optimize -y" "analyze -y" "history -y"; do
    # shellcheck disable=SC2086
    run mm $args
    [ "$status" -ne 0 ] || { echo "accepted: mm $args"; false; }
  done
}
