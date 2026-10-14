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
