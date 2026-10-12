#!/usr/bin/env bats
# lib/core.sh: the deletion gate (mm_rm), Trash, in-use detection, whitelist, HOME handling.

setup() {
  load helpers/common
  mm_test_setup
  mm_core
  mkdir -p "$SB/root" "$SB/outside" "$(dirname "$MM_WHITELIST_FILE")"
}
teardown() { mm_test_teardown; }

# try_rm ARGS... — "<rc> <reason>" for one mm_rm call.
try_rm() { local rc=0; mm_rm "$@" >/dev/null 2>&1 || rc=$?; printf '%s %s\n' "$rc" "$MM_SKIP_REASON"; }

@test "every path in the dangerous-paths corpus is refused" {
  mm_inuse_refresh
  local p n=0 bad=()
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    p=${p//@HOME@/$HOME}; n=$((n + 1))
    MM_DRY_RUN=1 mm_rm "$p" "$(dirname -- "$p")" >/dev/null 2>&1 && bad+=("$p")
    MM_DRY_RUN=1 mm_rm "$p" / >/dev/null 2>&1 && bad+=("$p (root /)")
  done <"$MM_SRC/tests/fixtures/dangerous_paths.txt"
  (( n >= 60 ))
  [[ ${#bad[@]} -eq 0 ]] || { printf 'accepted: %s\n' "${bad[@]}"; false; }
}

@test "a removable path is removed and logged" {
  mkdir -p "$SB/root/old"; echo x >"$SB/root/old/f"
  mm_inuse_refresh
  run try_rm "$SB/root/old" "$SB/root"
  [ "$output" = "0 " ]
  [ ! -e "$SB/root/old" ]
  [[ "$(mm_log_rows remove)" == "$SB/root/old"* ]]
}

@test "dry-run removes nothing and logs nothing" {
  mkdir -p "$SB/root/a" "$SB/root/b"
  mm_inuse_refresh
  MM_DRY_RUN=1 mm_rm "$SB/root/a" "$SB/root"
  MM_DRY_RUN=1 mm_rm --trash "$SB/root/b" "$SB/root"
  MM_DRY_RUN=1 mm_rm "$SB/outside" "$SB/root" || true
  [ -d "$SB/root/a" ]; [ -d "$SB/root/b" ]
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}

@test "names with control characters are refused" {
  mkdir -p "$SB/root/a"$'\n'"b" "$SB/root/t"$'\t'"x"
  mm_inuse_refresh
  run try_rm "$SB/root/a"$'\n'"b" "$SB/root"
  [ "$output" = "1 control characters in name" ]
  run try_rm "$SB/root/t"$'\t'"x" "$SB/root"
  [ "$output" = "1 control characters in name" ]
  [ -d "$SB/root/a"$'\n'"b" ]
}

@test "a symlink is removed as a link; its target survives" {
  echo keep >"$SB/outside/f"
  ln -s "$SB/outside" "$SB/root/link"
  mkdir -p "$SB/root/dir"; ln -s "$SB/outside" "$SB/root/dir/inner"
  mm_inuse_refresh
  run try_rm "$SB/root/link" "$SB/root";  [ "$output" = "0 " ]
  run try_rm "$SB/root/dir" "$SB/root";   [ "$output" = "0 " ]
  [ "$(cat "$SB/outside/f")" = keep ]
}

@test "a symlinked parent cannot carry a path outside the allowed root" {
  echo keep >"$SB/outside/f"
  ln -s "$SB/outside" "$SB/root/esc"
  mm_inuse_refresh
  run try_rm "$SB/root/esc/f" "$SB/root"
  [ "$output" = "1 outside $SB/root" ]
  [ -f "$SB/outside/f" ]
}

@test "the allowed root itself, relative paths and dot segments are refused" {
  mm_inuse_refresh
  run try_rm "$SB/root" "$SB/root";            [[ "$output" == "1 outside"* ]]
  run try_rm "root/x" "$SB";                   [ "$output" = "1 not an absolute path" ]
  run try_rm "$SB/root/../outside" "$SB/root"; [ "$output" = "1 path has . or .. segments" ]
  run try_rm "$SB/root/x" "";                  [ "$output" = "1 allowed root too broad" ]
}

@test "whitelist protects the entry, everything under it, and every folder above it" {
  mkdir -p "$SB/root/proj/data/keep/deep" "$SB/root/proj/other" "$SB/root/g/a/b"
  echo x >"$SB/root/g/a/b/precious.txt"
  printf '%s\n' "$SB/root/proj/data/keep" "$SB/root/g/**/precious*" >"$MM_WHITELIST_FILE"
  mm_inuse_refresh
  run try_rm "$SB/root/proj/data/keep/deep" "$SB/root"; [ "$output" = "1 whitelisted" ]
  run try_rm "$SB/root/proj/data" "$SB/root";           [ "$output" = "1 whitelisted" ]
  run try_rm "$SB/root/proj" "$SB/root";                [ "$output" = "1 whitelisted" ]
  run try_rm "$SB/root/g/a" "$SB/root";                 [ "$output" = "1 whitelisted" ]
  run try_rm "$SB/root/proj/other" "$SB/root";          [ "$output" = "0 " ]
  [ -d "$SB/root/proj/data/keep/deep" ]; [ -f "$SB/root/g/a/b/precious.txt" ]
}

@test "an unreadable whitelist refuses instead of protecting nothing" {
  mkdir -p "$SB/root/x"
  MM_WHITELIST_FILE=/proc/nonexistent/whitelist
  mm_inuse_refresh
  run try_rm "$SB/root/x" "$SB/root"
  [ "$output" = "1 whitelisted" ]
  [ -d "$SB/root/x" ]
}

@test "credentials, ~/.config and agent state stay protected with an empty whitelist file" {
  : >"$MM_WHITELIST_FILE"
  mkdir -p "$HOME/.aws" "$HOME/.config/gh" "$HOME/.claude/projects/p" "$HOME/.codex/sessions" \
    "$HOME/.local/share/opencode/storage" "$HOME/.cursor/chats"
  echo k >"$HOME/.aws/credentials"
  mm_inuse_refresh
  local p
  for p in "$HOME/.aws/credentials" "$HOME/.config/gh" "$HOME/.claude/projects/p" "$HOME/.claude" \
           "$HOME/.codex/sessions" "$HOME/.local/share/opencode/storage" "$HOME/.cursor/chats"; do
    run try_rm "$p" "$HOME"
    [ "$output" = "1 whitelisted" ] || { echo "not protected: $p ($output)"; false; }
  done
}

@test "MM_KEEP_AGENT_STATE=0 waives agent state only, never credentials or the whitelist file" {
  mkdir -p "$HOME/.cursor/worktrees/wt" "$HOME/.ssh/k" "$HOME/.config/x" "$HOME/mine/keep"
  printf '%s\n' "$HOME/mine/keep" >"$MM_WHITELIST_FILE"
  mm_inuse_refresh
  MM_KEEP_AGENT_STATE=0 MM_DRY_RUN=1 run try_rm "$HOME/.cursor/worktrees/wt" "$HOME"
  [ "$output" = "0 " ]; [ -d "$HOME/.cursor/worktrees/wt" ]
  MM_KEEP_AGENT_STATE=0 run try_rm "$HOME/.ssh/k" "$HOME";       [ "$output" = "1 protected" ]
  MM_KEEP_AGENT_STATE=0 run try_rm "$HOME/.config/x" "$HOME";    [ "$output" = "1 whitelisted" ]
  MM_KEEP_AGENT_STATE=0 run try_rm "$HOME/mine/keep" "$HOME";    [ "$output" = "1 whitelisted" ]
  run try_rm "$HOME/.cursor/worktrees/wt" "$HOME";               [ "$output" = "1 whitelisted" ]
}

@test "paths in use are refused: cwd, open file, bound unix socket, backslash name" {
  mkdir -p "$SB/root/cwd" "$SB/root/fd" "$SB/root/sock" "$SB/root/bs/a\\tb"
  echo x >"$SB/root/fd/f"
  mm_test_bg "$SB/root/cwd" sleep 30
  mm_test_bg "$SB" bash -c 'exec 7<"$1"; sleep 30' _ "$SB/root/fd/f"
  mm_test_bg "$SB" python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(30)' "$SB/root/sock/s"
  mm_test_bg "$SB/root/bs/a\\tb" sleep 30
  sleep 0.5
  mm_inuse_refresh
  run try_rm "$SB/root/cwd" "$SB/root";  [ "$output" = "1 in use" ]
  run try_rm "$SB/root/fd" "$SB/root";   [ "$output" = "1 in use" ]
  run try_rm "$SB/root/sock" "$SB/root"; [ "$output" = "1 in use" ]
  run try_rm "$SB/root/bs" "$SB/root";   [ "$output" = "1 in use" ]
}

@test "a folder containing a bind mount is refused and the mounted data survives" {
  unshare -rm true 2>/dev/null || skip "unprivileged mount namespaces unavailable"
  mkdir -p "$SB/src/data" "$SB/root/x/mnt"; echo precious >"$SB/src/data/f"
  run unshare -rm bash -c '
    . "$1/lib/core.sh"; /usr/bin/mount --bind "$2/src/data" "$2/root/x/mnt" || exit 3
    mm_inuse_refresh >/dev/null 2>&1
    rc=0; mm_rm "$2/root/x" "$2/root" >/dev/null 2>&1 || rc=$?
    echo "$rc $MM_SKIP_REASON"; /usr/bin/umount "$2/root/x/mnt"' _ "$MM_SRC" "$SB"
  [ "$output" = "1 in use" ]
  [ "$(cat "$SB/src/data/f")" = precious ]
}

@test "an empty in-use snapshot fails closed" {
  mkdir -p "$SB/root/x"
  MM_INUSE_TAKEN=1 MM_INUSE=""
  run try_rm "$SB/root/x" "$SB/root"
  [ "$output" = "1 in use" ]
}

@test "a target swapped while it is being sized is refused" {
  mkdir -p "$SB/root/x"; echo original >"$SB/root/x/f"
  mm_inuse_refresh
  mm_size() { mv "$1" "$1.moved"; mkdir "$1"; echo 0; }
  run try_rm "$SB/root/x" "$SB/root"
  [ "$output" = "1 changed while sizing" ]
  [ -d "$SB/root/x" ]; [ -f "$SB/root/x.moved/f" ]
}

@test "--trash moves the item into the XDG Trash with a valid .trashinfo" {
  mkdir -p "$SB/root/my doc"; echo x >"$SB/root/my doc/f"
  mm_inuse_refresh
  mm_rm --trash "$SB/root/my doc" "$SB/root"
  [ ! -e "$SB/root/my doc" ]
  [ -f "$MM_TRASH_DIR/files/my doc/f" ]
  grep -qx "Path=${SB// /%20}/root/my%20doc" "$MM_TRASH_DIR/info/my doc.trashinfo"
  grep -qE '^DeletionDate=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$' "$MM_TRASH_DIR/info/my doc.trashinfo"
  (( MM_TRASHED > 0 && MM_FREED == 0 && MM_COUNT == 1 ))
  [[ "$(mm_log_rows trash)" == "$SB/root/my doc"$'\t'"$MM_TRASH_DIR/files/my doc" ]]
}

@test "--trash never overwrites an earlier item with the same name" {
  mkdir -p "$SB/root/a" "$SB/root/b"; echo one >"$SB/root/a/x"; echo two >"$SB/root/b/x"
  mm_inuse_refresh
  mm_rm --trash "$SB/root/a/x" "$SB/root"
  mm_rm --trash "$SB/root/b/x" "$SB/root"
  [ "$(cat "$MM_TRASH_DIR/files/x")" = one ]
  [ "$(cat "$MM_TRASH_DIR/files/x.2")" = two ]
  [ -f "$MM_TRASH_DIR/info/x.2.trashinfo" ]
}

@test "--trash refuses (never deletes) when the item is on another filesystem" {
  unshare -rm true 2>/dev/null || skip "unprivileged mount namespaces unavailable"
  mkdir -p "$SB/root/other"
  run unshare -rm bash -c '
    . "$1/lib/core.sh"; /usr/bin/mount -t tmpfs none "$2/root/other" || exit 3
    echo keep >"$2/root/other/f"
    mm_inuse_refresh >/dev/null 2>&1
    rc=0; mm_rm --trash "$2/root/other/f" "$2/root" >/dev/null 2>&1 || rc=$?
    echo "$rc $MM_SKIP_REASON $(cat "$2/root/other/f")"' _ "$MM_SRC" "$SB"
  [ "$output" = "1 Trash is on another filesystem keep" ]
}

@test "--trash refuses a symlinked Trash" {
  mkdir -p "$SB/root/x" "$SB/elsewhere" "$(dirname "$MM_TRASH_DIR")"
  ln -s "$SB/elsewhere" "$MM_TRASH_DIR"
  mm_inuse_refresh
  run try_rm --trash "$SB/root/x" "$SB/root"
  [[ "$output" == "1 Trash unusable"* ]]
  [ -d "$SB/root/x" ]
}

@test "refusals are logged with their reason; missing paths are not" {
  mkdir -p "$SB/root/x"
  printf '%s\n' "$SB/root/x" >"$MM_WHITELIST_FILE"
  mm_inuse_refresh
  mm_rm "$SB/root/x" "$SB/root" || true
  mm_rm "$SB/root/gone" "$SB/root" || true
  [ "$(mm_log_rows refused)" = "$SB/root/x"$'\t'"whitelisted" ]
}

@test "HOME given as a symlink or with a trailing slash still protects ~/.ssh and the whitelist" {
  mkdir -p "$SB/realhome/.ssh" "$SB/realhome/.omp"; echo k >"$SB/realhome/.ssh/id"; echo s >"$SB/realhome/.omp/d"
  ln -s "$SB/realhome" "$SB/linkhome"
  local h
  for h in "$SB/linkhome" "$SB/realhome/"; do
    run env HOME="$h" XDG_CONFIG_HOME= XDG_STATE_HOME= XDG_DATA_HOME= bash -c '
      . "$1/lib/core.sh"; mm_inuse_refresh >/dev/null 2>&1
      MM_DRY_RUN=1 mm_rm "$2/.ssh/id" "$2" >/dev/null 2>&1; a="$? $MM_SKIP_REASON"
      MM_DRY_RUN=1 mm_rm "$2/.omp/d" "$2" >/dev/null 2>&1; echo "$a|$? $MM_SKIP_REASON|$HOME"' _ "$MM_SRC" "$h"
    [ "$output" = "1 protected|1 whitelisted|$SB/realhome" ]
  done
}

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
