#!/usr/bin/env bats
# mm update: a local bare repository plays the remote (no network). $SRC is the user's checkout
# marmot was installed from; $DEV is a second clone that publishes new commits.

setup() {
  load helpers/common
  mm_test_setup
  export MARMOT_PREFIX="$SB/share/marmot" MARMOT_BIN="$SB/bin"
  REMOTE="$SB/remote.git" SRC="$SB/src" DEV="$SB/dev"
  mm_test_checkout "$SB/seed"
  git clone -q --bare "$SB/seed" "$REMOTE"
  git clone -q "$REMOTE" "$SRC"
  git clone -q "$REMOTE" "$DEV"
  "$SRC/install.sh" >/dev/null
  LOCK="$XDG_STATE_HOME/marmot/update.lock"
}
teardown() { mm_test_teardown; }

# commit DIR MESSAGE — a commit that leaves MESSAGE in lib/core.sh.
commit() { echo "# $2" >>"$1/lib/core.sh"; mm_test_git "$1" commit -qam "$2"; }
publish() { commit "$DEV" "$1"; git -C "$DEV" push -q; }
installed() { awk -F= '$1 == "commit" { print $2 }' "$MARMOT_PREFIX/.install-source"; }
head_of() { git -C "$1" rev-parse HEAD; }

# on_tty ANSWER CMD... — run CMD on a pseudo-terminal, typing ANSWER at the prompt.
on_tty() {
  local answer=$1 cmd; shift
  cmd=$(printf '%q ' env -u MM_TTY "$@")
  run env SHELL=/bin/bash bash -c "printf '%s\n' $(printf %q "$answer") | timeout 60 script -qec $(printf %q "$cmd") /dev/null"
}

# unchanged OLD_SRC OLD_INSTALLED — neither the checkout nor the install moved.
unchanged() {
  [ "$(head_of "$SRC")" = "$1" ]
  [ "$(installed)" = "$2" ]
}

@test "up to date: says so and exits 0, with and without --check" {
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 0 ]
  run "$MARMOT_BIN/mm" update
  [ "$status" -eq 0 ]
  [ "$(installed)" = "$(head_of "$SRC")" ]
}

@test "behind: confirmed update fast-forwards, reinstalls, and keeps the launchers" {
  local old new
  old=$(head_of "$SRC")
  publish "new upstream work"
  new=$(head_of "$DEV")
  on_tty y "$MARMOT_BIN/mm" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"new upstream work"* ]]
  [ "$(head_of "$SRC")" = "$new" ]
  [ "$(installed)" = "$new" ]
  grep -qx '# new upstream work' "$MARMOT_PREFIX/lib/core.sh"
  [ "$(readlink -f "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  [ "$(readlink -f "$MARMOT_BIN/marmot")" = "$MARMOT_PREFIX/marmot" ]
  run "$MARMOT_BIN/mm" --version
  [[ "$output" == *"(${new:0:7})" ]]
  [ "$(mm_log_rows run | cut -f1 | wc -l)" -eq 2 ]
  [ "$old" != "$new" ]
}

@test "behind: declining the prompt changes nothing" {
  local old; old=$(head_of "$SRC")
  publish "new upstream work"
  on_tty n "$MARMOT_BIN/mm" update
  [ "$status" -eq 0 ]
  unchanged "$old" "$old"
}

@test "--check reports an update with exit 10 and changes nothing" {
  local old; old=$(head_of "$SRC")
  publish "one"; publish "two"
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 10 ]
  [[ "$output" == *"one"* ]]
  [[ "$output" == *"two"* ]]
  unchanged "$old" "$old"
  on_tty y "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 10 ]
  unchanged "$old" "$old"
}

@test "--check exits non-zero but not 10 when the checkout cannot be updated" {
  git -C "$SRC" branch -q --unset-upstream
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
}

@test "without a terminal it only reports, even when an update is available" {
  local old; old=$(head_of "$SRC")
  publish "new upstream work"
  run "$MARMOT_BIN/mm" update
  [ "$status" -eq 10 ]
  unchanged "$old" "$old"
  [ -z "$(mm_log_rows run)" ]
}

@test "--dry-run on a terminal reports and changes nothing" {
  local old; old=$(head_of "$SRC")
  publish "new upstream work"
  on_tty y "$MARMOT_BIN/mm" update --dry-run
  [ "$status" -eq 10 ]
  unchanged "$old" "$old"
}

@test "a checkout with uncommitted changes is refused and left as it was" {
  local old; old=$(head_of "$SRC")
  publish "new upstream work"
  echo "# my edit" >>"$SRC/cmd/update.sh"
  on_tty y "$MARMOT_BIN/mm" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"cmd/update.sh"* ]]
  unchanged "$old" "$old"
  grep -qx '# my edit' "$SRC/cmd/update.sh"
}

@test "a checkout that diverged from upstream is refused" {
  local old mine
  old=$(head_of "$SRC")
  publish "upstream work"
  commit "$SRC" "local work"
  mine=$(head_of "$SRC")
  on_tty y "$MARMOT_BIN/mm" update
  [ "$status" -eq 1 ]
  unchanged "$mine" "$old"
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 1 ]
}

@test "local commits ahead of upstream are kept: nothing to pull, the install catches up" {
  commit "$SRC" "local work"
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 10 ]
  on_tty y "$MARMOT_BIN/mm" update
  [ "$status" -eq 0 ]
  [ "$(installed)" = "$(head_of "$SRC")" ]
  grep -qx '# local work' "$MARMOT_PREFIX/lib/core.sh"
}

@test "an install that lags its checkout is reinstalled at the checkout's commit" {
  publish "pulled by hand"
  git -C "$SRC" pull -q --ff-only
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 10 ]
  on_tty y "$MARMOT_BIN/mm" update
  [ "$status" -eq 0 ]
}

@test "marmot running from its own checkout updates that checkout in place" {
  "$SRC/install.sh" >/dev/null 2>&1 || true
  local inplace="$SB/inplace"
  git clone -q "$REMOTE" "$inplace"
  MARMOT_PREFIX="$inplace" "$inplace/install.sh" >/dev/null
  [ ! -e "$inplace/.install-source" ]
  publish "new upstream work"
  on_tty y "$inplace/marmot" update
  [ "$status" -eq 0 ]
  [ "$(head_of "$inplace")" = "$(head_of "$DEV")" ]
  [ -z "$(git -C "$inplace" status --porcelain)" ]
}

@test "a second update while one runs is refused (flock)" {
  local old fd; old=$(head_of "$SRC")
  publish "new upstream work"
  mkdir -p "$(dirname "$LOCK")"
  exec {fd}>>"$LOCK"
  flock -n "$fd"
  run "$MARMOT_BIN/mm" update --check
  exec {fd}>&-
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  unchanged "$old" "$old"
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -eq 10 ]
}

@test "without flock a lock directory guards the update and is removed afterwards" {
  export MM_HOME="$MARMOT_PREFIX"
  mm_core; . "$MM_SRC/cmd/update.sh"
  _update_have_flock() { return 1; }
  mkdir -p "$LOCK.d"
  run _update_lock
  [ "$status" -ne 0 ]
  rmdir "$LOCK.d"
  run _update_lock
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK.d" ]
}

@test "an install from a folder that is not a git checkout explains why it cannot update" {
  local tarball="$SB/marmot-0.2.0"
  mkdir -p "$tarball"
  cp -R "$SRC/marmot" "$SRC/install.sh" "$SRC/lib" "$SRC/cmd" "$SRC/completion" "$tarball/"
  "$tarball/install.sh" >/dev/null
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  [[ "$output" == *"$tarball"*"not a git checkout"* ]]
  run "$MARMOT_BIN/mm" --version
  [[ "$output" =~ ^marmot\ [0-9.]+$ ]]
}

@test "an install without a record says how to get one" {
  rm "$MARMOT_PREFIX/.install-source"
  run "$MARMOT_BIN/mm" update --check
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  [[ "$output" == *"install.sh"* ]]
}
