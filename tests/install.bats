#!/usr/bin/env bats
# install.sh: per-user install, update, refusal to overwrite foreign folders, uninstall.

setup() {
  load helpers/common
  mm_test_setup
  export MARMOT_PREFIX="$SB/share/marmot" MARMOT_BIN="$SB/bin"
}
teardown() { mm_test_teardown; }

@test "installs a copy and links mm and marmot to it" {
  run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$MARMOT_PREFIX/lib/core.sh" ]
  [ -f "$MARMOT_PREFIX/completion/mm.bash" ]
  [ ! -e "$MARMOT_PREFIX/tests" ]
  [ ! -e "$MARMOT_PREFIX/.git" ]
  [ "$(readlink -f "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  [ "$(readlink -f "$MARMOT_BIN/marmot")" = "$MARMOT_PREFIX/marmot" ]
  run "$MARMOT_BIN/mm" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "marmot "* ]]
}

@test "re-running updates the existing install" {
  "$MM_SRC/install.sh" >/dev/null
  echo stale >"$MARMOT_PREFIX/stale-file"
  run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_PREFIX/stale-file" ]
  [ -f "$MARMOT_PREFIX/marmot" ]
}

@test "refuses to replace a folder that is not a marmot install" {
  mkdir -p "$MARMOT_PREFIX"; echo mine >"$MARMOT_PREFIX/precious"
  run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$MARMOT_PREFIX/precious")" = mine ]
  [ ! -e "$MARMOT_BIN/mm" ]
}

@test "--uninstall removes only its links and copy, keeping config, history and the Trash" {
  "$MM_SRC/install.sh" >/dev/null
  mkdir -p "$XDG_CONFIG_HOME/marmot" "$XDG_STATE_HOME/marmot" "$XDG_DATA_HOME/Trash/files"
  echo w >"$XDG_CONFIG_HOME/marmot/whitelist"; echo l >"$XDG_STATE_HOME/marmot/operations.log"
  ln -s /bin/true "$MARMOT_BIN/other-tool"
  run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_BIN/mm" ]
  [ ! -e "$MARMOT_BIN/marmot" ]
  [ ! -e "$MARMOT_PREFIX" ]
  [ -L "$MARMOT_BIN/other-tool" ]
  [ -f "$XDG_CONFIG_HOME/marmot/whitelist" ]
  [ -f "$XDG_STATE_HOME/marmot/operations.log" ]
  [ -d "$XDG_DATA_HOME/Trash/files" ]
}

@test "--uninstall leaves a launcher that points somewhere else" {
  mkdir -p "$MARMOT_BIN"; ln -s /bin/true "$MARMOT_BIN/mm"
  run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ -L "$MARMOT_BIN/mm" ]
}

@test "the installed copy can uninstall itself" {
  "$MM_SRC/install.sh" >/dev/null
  run "$MARMOT_PREFIX/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_BIN/mm" ]
  [ ! -e "$MARMOT_PREFIX" ]
}

@test "--uninstall never deletes a git checkout used as the install folder" {
  mm_test_checkout "$MARMOT_PREFIX"
  "$MARMOT_PREFIX/install.sh" >/dev/null
  run "$MARMOT_PREFIX/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_BIN/mm" ]
  [ -f "$MARMOT_PREFIX/marmot" ]
}

@test "records the source checkout, its commit and the launcher folder; --version shows the commit" {
  mm_test_checkout "$SB/src"
  local sha; sha=$(git -C "$SB/src" rev-parse HEAD)
  "$SB/src/install.sh" >/dev/null
  grep -qxF "source=$SB/src" "$MARMOT_PREFIX/.install-source"
  grep -qxF "commit=$sha" "$MARMOT_PREFIX/.install-source"
  grep -qxF "bin=$MARMOT_BIN" "$MARMOT_PREFIX/.install-source"
  run "$MARMOT_BIN/mm" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^marmot\ [0-9.]+\ \(${sha:0:7}\)$ ]]
}

@test "a git checkout used as the install folder gets no record and stays clean" {
  mm_test_checkout "$MARMOT_PREFIX"
  "$MARMOT_PREFIX/install.sh" >/dev/null
  [ ! -e "$MARMOT_PREFIX/.install-source" ]
  [ -z "$(git -C "$MARMOT_PREFIX" status --porcelain)" ]
  run "$MARMOT_BIN/mm" --version
  [[ "$output" == *"($(git -C "$MARMOT_PREFIX" rev-parse --short=7 HEAD))" ]]
}

@test "refuses to replace a prefix that is a marmot git checkout, leaving it intact" {
  mm_test_checkout "$MARMOT_PREFIX"
  echo mine >"$MARMOT_PREFIX/notes"
  run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git checkout"*"MARMOT_PREFIX"* ]]
  [ -d "$MARMOT_PREFIX/.git" ]
  [ "$(cat "$MARMOT_PREFIX/notes")" = mine ]
}

@test "an existing file at bin/mm is not replaced and install fails naming it" {
  mkdir -p "$MARMOT_BIN"; echo mine >"$MARMOT_BIN/mm"
  run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$MARMOT_BIN/mm"* ]]
  [ "$(cat "$MARMOT_BIN/mm")" = mine ]
}

@test "a foreign bin/marmot is kept with a warning while mm is linked" {
  mkdir -p "$MARMOT_BIN"; ln -s /bin/true "$MARMOT_BIN/marmot"
  run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept $MARMOT_BIN/marmot"* ]]
  [ "$(readlink "$MARMOT_BIN/marmot")" = /bin/true ]
  [ "$(readlink -f "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  run "$MM_SRC/install.sh" --uninstall
  [ ! -e "$MARMOT_BIN/mm" ]
  [ "$(readlink "$MARMOT_BIN/marmot")" = /bin/true ]
}

@test "--uninstall disables the schedule mm schedule enable created" {
  export CALLS="$BATS_TEST_TMPDIR/calls"; : >"$CALLS"
  mm_test_fake systemctl 'echo "systemctl $*" >>"$CALLS"'
  mm_test_fake loginctl 'echo Linger=yes'
  "$MM_SRC/install.sh" >/dev/null
  "$MARMOT_BIN/mm" schedule enable >/dev/null
  local units="$XDG_CONFIG_HOME/systemd/user"
  [ -f "$units/marmot-schedule.timer" ]
  run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"schedule"* ]]
  [ ! -e "$units/marmot-schedule.timer" ]
  [ ! -e "$units/marmot-schedule.service" ]
  grep -qx 'systemctl --user disable --now marmot-schedule.timer' "$CALLS"
  [ ! -e "$MARMOT_PREFIX" ]
}

@test "installs without git, and says where to put bin on PATH" {
  local tools="$BATS_TEST_TMPDIR/tools" c
  mkdir -p "$tools"
  for c in bash env find awk sed grep stat realpath du df uname dirname readlink cp mkdir ln cat; do
    ln -s "$(command -v "$c")" "$tools/$c"
  done
  PATH="$tools" SHELL=/bin/zsh run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  [[ "$output" == *"~/.zshrc"* || "$output" == *"$HOME/.zshrc"* ]]
  [[ "$output" == *"export PATH=\"$MARMOT_BIN:\$PATH\""* || "$output" == *'export PATH="$HOME/'* ]]
}
