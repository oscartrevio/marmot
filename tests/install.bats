#!/usr/bin/env bats
# install.sh: per-user install, update, refusal to overwrite foreign folders, uninstall.

setup() {
  load helpers/common
  mm_test_setup
  export MARMOT_PREFIX="$SB/share/marmot" MARMOT_BIN="$SB/bin"
  # --uninstall runs `mm schedule disable`, which asks systemd where its unit folder is; these
  # tests run without a user systemd (tests that need one install their own double).
  mm_test_fake systemctl 'exit 1'
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

# payload DIR — a copy of what install.sh installs, without git metadata.
payload() {
  mkdir -p "$1"
  cp -R "$MM_SRC/marmot" "$MM_SRC/install.sh" "$MM_SRC/lib" "$MM_SRC/cmd" "$MM_SRC/completion" "$1/"
}

# listing DIR — every path under DIR, sorted, on one line.
listing() { (cd "$1" && find . | LC_ALL=C sort | tr '\n' ' '); }

@test "a reinstall replaces the files of the previous copy, including ones this copy lacks" {
  payload "$SB/src"
  echo '# retired' >"$SB/src/cmd/retired.sh"
  "$SB/src/install.sh" >/dev/null
  [ -f "$MARMOT_PREFIX/cmd/retired.sh" ]
  rm "$SB/src/cmd/retired.sh"
  echo '# new' >>"$SB/src/lib/core.sh"
  run "$SB/src/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_PREFIX/cmd/retired.sh" ]
  [ "$(tail -1 "$MARMOT_PREFIX/lib/core.sh")" = '# new' ]
  [ -f "$MARMOT_PREFIX/marmot" ]
}

@test "reinstall and --uninstall remove only what the install copied, keeping your files there" {
  export MARMOT_PREFIX="$HOME/bin"
  "$MM_SRC/install.sh" >/dev/null
  echo 'echo my backup' >"$MARMOT_PREFIX/backup.sh"
  mkdir -p "$MARMOT_PREFIX/personal" "$MARMOT_PREFIX/empty"
  echo notes >"$MARMOT_PREFIX/personal/notes.txt"
  echo mine >"$MARMOT_PREFIX/lib/mine.sh"
  run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$MARMOT_PREFIX/lib/core.sh" ]
  [ "$(cat "$MARMOT_PREFIX/backup.sh")" = 'echo my backup' ]
  [ "$(cat "$MARMOT_PREFIX/personal/notes.txt")" = notes ]
  [ "$(cat "$MARMOT_PREFIX/lib/mine.sh")" = mine ]
  run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_BIN/mm" ]
  [ "$(listing "$MARMOT_PREFIX")" = ". ./backup.sh ./empty ./lib ./lib/mine.sh ./personal ./personal/notes.txt " ]
}

@test "a reinstall never overwrites your file where the new copy puts one" {
  payload "$SB/src"
  "$SB/src/install.sh" >/dev/null
  echo mine >"$MARMOT_PREFIX/cmd/new.sh"
  echo '# upstream' >"$SB/src/cmd/new.sh"
  run "$SB/src/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cmd/new.sh"* ]]
  [ "$(cat "$MARMOT_PREFIX/cmd/new.sh")" = mine ]
  [ -f "$MARMOT_PREFIX/lib/core.sh" ]
}

@test "an install from before the manifest is replaced or removed when it holds only marmot's files" {
  payload "$MARMOT_PREFIX"
  echo "source=$SB/gone" >"$MARMOT_PREFIX/.install-source"
  run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  grep -qxF "source=$MM_SRC" "$MARMOT_PREFIX/.install-source"
  rm -f "$MARMOT_PREFIX"/.install-manifest
  run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_PREFIX" ]
}

@test "an install from before the manifest that holds other files is refused, naming them" {
  export MARMOT_PREFIX="$HOME/bin"
  payload "$MARMOT_PREFIX"
  echo 'echo my backup' >"$MARMOT_PREFIX/backup.sh"
  run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup.sh"* ]]
  [ "$(cat "$MARMOT_PREFIX/backup.sh")" = 'echo my backup' ]
  [ -f "$MARMOT_PREFIX/lib/core.sh" ]
  [ ! -e "$MARMOT_BIN/mm" ]
  mkdir -p "$MARMOT_BIN"
  ln -s "$MARMOT_PREFIX/marmot" "$MARMOT_BIN/mm"
  run "$MM_SRC/install.sh" --uninstall
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup.sh"* ]]
  [ "$(cat "$MARMOT_PREFIX/backup.sh")" = 'echo my backup' ]
  [ -f "$MARMOT_PREFIX/lib/core.sh" ]
  [ -L "$MARMOT_BIN/mm" ]
}

@test "refuses a prefix inside a git work tree, leaving that checkout as it was" {
  local proj="$SB/proj"
  payload "$proj/tools/marmot"
  git -C "$proj" init -q -b main
  git -C "$proj" add -A
  mm_test_git "$proj" commit -qm vendor
  echo '# my local patch' >>"$proj/tools/marmot/lib/core.sh"
  echo 'my notes' >"$proj/tools/marmot/NOTES.local"
  local before; before=$(git -C "$proj" status --porcelain)
  MARMOT_PREFIX="$proj/tools/marmot" run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$proj"* ]]
  [ "$(tail -1 "$proj/tools/marmot/lib/core.sh")" = '# my local patch' ]
  [ "$(cat "$proj/tools/marmot/NOTES.local")" = 'my notes' ]
  [ "$(git -C "$proj" status --porcelain)" = "$before" ]
  MARMOT_PREFIX="$proj/tools/new/marmot" run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$proj/tools/new" ]
  MARMOT_PREFIX="$proj/tools/marmot" run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$proj/tools/marmot/lib/core.sh")" = '# my local patch' ]
  [ "$(git -C "$proj" status --porcelain)" = "$before" ]
}

@test "refuses a symlinked prefix, with or without a trailing slash, leaving its target as it was" {
  local mine="$SB/mywork-marmot" before
  payload "$mine"
  echo precious >"$mine/mine.txt"
  mkdir -p "$(dirname "$MARMOT_PREFIX")"
  ln -s "$mine" "$MARMOT_PREFIX"
  before=$(listing "$mine")
  MARMOT_PREFIX="$MARMOT_PREFIX/" run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [ "$(listing "$mine")" = "$before" ]
  run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  MARMOT_PREFIX="$MARMOT_PREFIX/" run "$MM_SRC/install.sh" --uninstall
  [ "$(listing "$mine")" = "$before" ]
  [ -L "$MARMOT_PREFIX" ]
}

@test "a trailing slash on the prefix installs and uninstalls the same folder" {
  MARMOT_PREFIX="$MARMOT_PREFIX//" run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  MARMOT_PREFIX="$MARMOT_PREFIX/" run "$MM_SRC/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$MARMOT_BIN/mm" ]
  [ ! -e "$MARMOT_PREFIX" ]
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
  for c in bash env find awk sed grep stat realpath du df uname dirname readlink cp mkdir ln cat mktemp mv; do
    ln -s "$(command -v "$c")" "$tools/$c"
  done
  PATH="$tools" SHELL=/bin/zsh run "$MM_SRC/install.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$MARMOT_BIN/mm")" = "$MARMOT_PREFIX/marmot" ]
  [[ "$output" == *"~/.zshrc"* || "$output" == *"$HOME/.zshrc"* ]]
  [[ "$output" == *"export PATH=\"$MARMOT_BIN:\$PATH\""* || "$output" == *'export PATH="$HOME/'* ]]
  mkdir -p "$SB/proj/.git"
  MARMOT_PREFIX="$SB/proj/tools/marmot" PATH="$tools" run "$MM_SRC/install.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$SB/proj/tools" ]
}
