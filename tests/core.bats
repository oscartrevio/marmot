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
  mm_frees() { mv "$1" "$1.moved"; mkdir "$1"; echo 0; }
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

@test "pickers work with fzf older than 0.34 (Ubuntu 22.04) and newer ones" {
  local v
  for v in "0.29 (devel)" "0.38.0 (debian)" "0.56.3 (af3d7e5)"; do
    # an fzf of version v that rejects what that version does not know, and picks every line
    mm_test_fake fzf "[[ \$1 == --version ]] && { echo '$v'; exit 0; }
      for a; do [[ \$a == --height=~* && '$v' == 0.29* ]] && { echo 'not a valid number: ~60' >&2; exit 2; }; done
      cat"
    [ "$(printf 'a\nb\n' | MM_TTY=1 mm_pick header)" = $'a\nb' ]
  done
}

@test "log rows stay one line per operation even for odd names" {
  MM_DRY_RUN=0 mm_log remove "$SB/a"$'\n'"b"$'\t'"c" 5 "why"$'\n'"not"
  [ "$(wc -l <"$XDG_STATE_HOME/marmot/operations.log")" -eq 1 ]
  [ "$(awk -F'\t' '{ print NF }' "$XDG_STATE_HOME/marmot/operations.log")" -eq 6 ]
}

@test "the operations log moves to operations.log.old once it is past MM_LOG_MAX_BYTES" {
  local log="$XDG_STATE_HOME/marmot/operations.log"
  MM_DRY_RUN=0 mm_log remove "$SB/a" 1
  MM_DRY_RUN=0 mm_log remove "$SB/b" 1
  MM_LOG_MAX_BYTES=$(stat -c %s "$log") MM_DRY_RUN=0 mm_log remove "$SB/c" 1   # at the limit: kept
  [ ! -e "$log.old" ]
  MM_LOG_MAX_BYTES=$(( $(stat -c %s "$log") - 1 )) MM_DRY_RUN=0 mm_log remove "$SB/d" 1
  [ "$(cut -f4 "$log.old" | tr '\n' ,)" = "$SB/a,$SB/b,$SB/c," ]
  [ "$(cut -f4 "$log")" = "$SB/d" ]
  MM_LOG_MAX_BYTES=1 MM_DRY_RUN=0 mm_log remove "$SB/e" 1                       # replaces the older .old
  [ "$(cut -f4 "$log.old")" = "$SB/d" ]
  [ "$(cut -f4 "$log")" = "$SB/e" ]
}

@test "sizes above 2 GiB come back as exact integers" {
  mm_test_fake du 'printf "3000000001\t%s\n3000000001\ttotal\n" "$4"'
  mm_test_fake df 'printf "Avail\n5000000003\n"'
  [ "$(mm_size "$SB/root")" = 3000000001 ]
  [ "$(mm_free_bytes /)" = 5000000003 ]
  mm_test_fake find 'printf "1:2 1 5859375002 f\n"'
  [ "$(mm_size_frees "$SB/root")" = "3000000001024 3000000001024" ]
}

@test "frees counts only files whose every hard link is inside; mm_rm frees exactly that" {
  mkdir -p "$SB/root/a" "$SB/store"
  head -c 40960 /dev/urandom >"$SB/store/shared"; ln "$SB/store/shared" "$SB/root/a/shared"
  head -c 8192 /dev/urandom >"$SB/root/a/own"; ln "$SB/root/a/own" "$SB/root/a/own-too"
  local shared size frees before after
  shared=$(( $(stat -c %b "$SB/store/shared") * 512 ))
  read -r size frees < <(mm_size_frees "$SB/root/a")
  [ "$size" -eq "$(du -sB1 "$SB/root/a" | cut -f1)" ]
  [ "$frees" -eq $(( size - shared )) ]
  [ "$(mm_frees "$SB/root/a")" -eq "$frees" ]
  before=$(du -sxB1 "$SB" | cut -f1)
  mm_inuse_refresh
  MM_DRY_RUN=0 mm_rm "$SB/root/a" "$SB/root"
  after=$(du -sxB1 "$SB" | cut -f1)
  [ "$MM_FREED" -eq "$frees" ]
  [ $(( before - after )) -eq "$MM_FREED" ]
  [ -f "$SB/store/shared" ]
}

@test "a size bash cannot count is refused before anything is removed" {
  mkdir -p "$SB/root/big"
  mm_inuse_refresh
  mm_frees() { echo 2.14748e+09; }
  run try_rm "$SB/root/big" "$SB/root"
  [ "$output" = "1 size unreadable" ]
  [ -d "$SB/root/big" ]
}

@test "a size walk that fails or outlasts MM_SIZE_TIMEOUT is unknown to the gate, and mm_rm keeps the path" {
  mkdir -p "$SB/root/slow"; echo x >"$SB/root/slow/f"
  mm_inuse_refresh
  mm_test_fake du 'exec sleep 5'; mm_test_fake find 'exec sleep 5'; hash -r
  MM_SIZE_TIMEOUT=0.2
  run mm_size "$SB/root/slow"
  [ "$status" -eq 124 ]; [ -z "$output" ]
  run mm_frees "$SB/root/slow"
  [ "$status" -eq 124 ]; [ -z "$output" ]
  [ "$(mm_size_human "$SB/root/slow")" = "size unknown" ]
  run try_rm "$SB/root/slow" "$SB/root"
  [ "$output" = "1 size unknown (timed out)" ]
  [ "$(mm_log_rows refused)" = "$SB/root/slow"$'\t'"size unknown (timed out)" ]
  [ -f "$SB/root/slow/f" ]
  # du could read part of the tree: reports show that much; the gate still refuses to guess.
  mm_test_fake du 'echo "4096 total"; exit 1'; mm_test_fake find 'exit 1'
  [ "$(mm_size "$SB/root/slow")" = 4096 ]
  mm_test_fake du 'exit 1'
  run mm_size "$SB/root/slow"
  [ "$status" -eq 1 ]; [ -z "$output" ]
  run try_rm "$SB/root/slow" "$SB/root"
  [ "$output" = "1 size unreadable" ]
  [ -f "$SB/root/slow/f" ]
  [ "$(mm_size "$SB/root/missing")" = 0 ]
}

@test "root's own runs clean inside /root like any home; /root itself and its keys stay protected" {
  as_home() {
    HOME=$1 bash -c '. "$1/lib/core.sh"; shift
      for p; do printf "%s %s\n" "$p" "$(mm_protected "$p" || echo removable)"; done' _ "$MM_SRC" "${@:2}"
  }
  run as_home /root /root /root/.ssh/id_ed25519 /root/.gnupg/x /root/.cache/pip /root/project/node_modules /home/u /etc/x
  [ "$status" -eq 0 ]
  [ "$output" = "/root protected
/root/.ssh/id_ed25519 protected
/root/.gnupg/x protected
/root/.cache/pip removable
/root/project/node_modules removable
/home/u protected (a home directory)
/etc/x protected" ]
  run as_home "$HOME" /root/.cache/pip "$HOME/.cache/pip"
  [ "$output" = "/root/.cache/pip protected
$HOME/.cache/pip removable" ]
}

@test "process checks read /proc and work without procps or psmisc" {
  local c
  for c in pgrep pidof ps fuser uptime; do mm_test_fake "$c" "echo \"$c \$*\" >>'$BATS_TEST_TMPDIR/procps'; exit 97"; done
  mkdir -p "$SB/bin"
  printf 'sleep 30\n' >"$SB/bin/fake-tool.cjs"
  mm_test_bg "$SB" sleep 30
  mm_test_bg "$SB" bash "$SB/bin/fake-tool.cjs"
  mm_test_bg "$SB" bash -c 'sleep 31 & wait'
  local parent=${MM_TEST_PIDS[-1]} kids="" i
  mm_proc_running sleep
  mm_proc_running fake-tool
  run mm_proc_running no-such-tool
  [ "$status" -eq 1 ]
  for i in $(seq 50); do kids=$(mm_proc_children "$parent"); [[ -n "$kids" ]] && break; sleep 0.1; done
  [ "$(tr '\0' ' ' <"/proc/$kids/cmdline")" = "sleep 31 " ]
  [[ "$(mm_sysline)" =~ \|\ Up\ ([0-9]+d\ )?([0-9]+h\ )?[0-9]+m$ ]]
  [ ! -e "$BATS_TEST_TMPDIR/procps" ]
}

@test "apt is busy during an unattended-upgrade run, not because its shutdown helper waits" {
  mkdir -p "$SB/u"
  printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/u/unattended-upgrade-shutdown"
  printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/u/unattended-upgrade"
  chmod +x "$SB/u/"*
  # passwordless sudo that runs as this user: the lock check sees no holder
  mm_test_fake sudo '[[ "$1" == -n ]] && shift; [[ "$*" == true ]] && exit 0; exec "$@"'
  if mm_proc_match 'apt|apt-get|aptitude|dpkg' '/unattended-upgrade( |$)'; then
    skip "apt is really running on this host"
  fi
  mm_test_bg "$SB" "$SB/u/unattended-upgrade-shutdown" --wait-for-signal
  run mm_apt_busy
  [ "$status" -eq 1 ]
  mm_test_bg "$SB" "$SB/u/unattended-upgrade"
  run mm_apt_busy
  [ "$status" -eq 0 ]
  [ "$output" = "apt is running" ]
}

@test "apt locks that cannot be read count as busy only when an apt step could run" {
  # The host's own apt can start at any moment (apt-daily on a freshly booted CI runner): this test
  # is about lock files nobody can read, so no apt process is running here.
  mm_proc_match() { return 1; }
  # sudo is installed but needs a password, and the password is refused
  mm_test_fake sudo '[[ "$1" == -n ]] && exit 1; echo "sudo $*" >>"$BATS_TEST_TMPDIR/sudo"; exit 1'
  MM_TTY=1 run mm_apt_busy
  [ "$status" -eq 0 ]
  [ "$output" = "apt locks not visible without sudo" ]
  MM_TTY=1 MM_DRY_RUN=1 run mm_apt_busy
  [ "$status" -eq 1 ]
  MM_TTY=0 run mm_apt_busy
  [ "$status" -eq 1 ]
}

@test "without a sudo binary only root counts as able to sudo" {
  (( EUID != 0 )) || skip "root can always sudo"
  command() { if [[ "$*" == "-v sudo" ]]; then return 1; fi; builtin command "$@"; }   # sudo not installed
  MM_TTY=1 run mm_can_sudo
  [ "$status" -eq 1 ]
}

@test "MM_NO_SUDO=1 never runs sudo: no sudo checks, mm_sudo fails, in-use sees your own processes" {
  (( EUID != 0 )) || skip "root needs no sudo"
  mm_test_fake sudo "printf '%s\n' \"\$*\" >>'$SB/sudo.calls'; exit 0"   # passwordless sudo
  MM_NO_SUDO=1
  MM_TTY=1 run mm_can_sudo
  [ "$status" -eq 1 ]
  run mm_sudo true
  [ "$status" -ne 0 ]
  mm_inuse_refresh >/dev/null
  [ "$MM_INUSE_PARTIAL" = 1 ]
  [ ! -e "$SB/sudo.calls" ]
}

@test "skips and errors of a run are collected for its summary, failed deletes included" {
  mkdir -p "$SB/root/x"
  mm_skip "Thing" "needs sudo" >/dev/null
  mm_err "it broke" 2>/dev/null
  [ "${MM_SKIPS[0]}" = $'Thing\tneeds sudo' ]
  [ "${MM_ERRORS[0]}" = "it broke" ]
  mm_inuse_refresh
  rm() { return 1; }   # the delete itself fails
  local rc=0
  mm_rm "$SB/root/x" "$SB/root" || rc=$?
  unset -f rm
  [ "$rc" -eq 2 ]
  [ "${#MM_ERRORS[@]}" -eq 2 ]
  [[ "${MM_ERRORS[1]}" == "$SB/root/x"*"rm failed"* ]]
}

# ---------------------------------------------------------------- agent waiver and config

@test "MM_AGENT_WAIVER acts inside the one agent directory given as the allowed root" {
  local s="$HOME/.claude/projects" c="$HOME/.codex/sessions"
  mkdir -p "$s/p" "$c" "$HOME/mine"; echo x >"$s/p/a.jsonl"; echo y >"$c/b.jsonl"; echo z >"$HOME/mine/f"
  mm_inuse_refresh
  run try_rm "$s/p/a.jsonl" "$s";                                  [ "$output" = "1 whitelisted" ]
  MM_DRY_RUN=1 MM_AGENT_WAIVER="$s" run try_rm "$s/p/a.jsonl" "$s"; [ "$output" = "0 " ]
  MM_AGENT_WAIVER="$s" run try_rm "$c/b.jsonl" "$c";               [ "${output%% *}" = 1 ]   # waiver is another agent's dir
  MM_AGENT_WAIVER="$s" run try_rm "$s/p/a.jsonl" "$HOME/.claude";  [ "${output%% *}" = 1 ]   # waiver is not the allowed root
  MM_AGENT_WAIVER="$HOME/mine" run try_rm "$HOME/mine/f" "$HOME/mine"; [ "${output%% *}" = 1 ]   # not an agent dir
  MM_AGENT_WAIVER="$s/p" run try_rm "$s/p/a.jsonl" "$s/p";         [ "${output%% *}" = 1 ]   # below an agent dir
  [ -e "$s/p/a.jsonl" ]
  [ -e "$c/b.jsonl" ]
  [ -e "$HOME/mine/f" ]
}

@test "the agent waiver never touches credentials, whitelisted paths, ~/.config or files in use" {
  local s="$HOME/.claude" o="$HOME/.config/opencode"
  mkdir -p "$s/debug" "$s/keep" "$s/dir" "$o/log" "$HOME/.codex"
  echo t >"$s/.credentials.json"; echo t >"$s/dir/auth.json"; echo k >"$s/keep/f"; echo l >"$o/log/x.log.1"
  echo l >"$s/debug/open.log.1"; echo l >"$s/debug/old.log.1"; echo t >"$HOME/.codex/auth.json"
  printf '%s\n' "$s/keep" >"$MM_WHITELIST_FILE"
  mm_test_bg "$s/debug" tail -f "$s/debug/open.log.1"
  mm_inuse_refresh
  local p
  for p in "$s/.credentials.json" "$s/dir" "$s/keep/f" "$s/debug/open.log.1"; do
    MM_AGENT_WAIVER="$s" run try_rm "$p" "$s"
    [ "${output%% *}" = 1 ] || { echo "removed $p ($output)"; false; }
  done
  MM_AGENT_WAIVER="$HOME/.codex" run try_rm "$HOME/.codex/auth.json" "$HOME/.codex"; [ "${output%% *}" = 1 ]
  MM_AGENT_WAIVER="$o" run try_rm "$o/log/x.log.1" "$o";           [ "$output" = "1 whitelisted" ]   # ~/.config stays built in
  MM_AGENT_WAIVER="$s" run try_rm "$s/debug/old.log.1" "$s";       [ "$output" = "0 " ]
  [ ! -e "$s/debug/old.log.1" ]
  [ -e "$s/.credentials.json" ]
  [ -e "$s/dir/auth.json" ]
  [ -e "$HOME/.codex/auth.json" ]
}

@test "config file: key=value, comments and spaces ignored, last line wins, missing key fails" {
  mkdir -p "$(dirname "$MM_CONFIG_FILE")"
  printf '# marmot\n sessions_keep_days = 14  # two weeks\nother=1\nsessions_keep_days=30\n#sessions_keep_days=1\n' >"$MM_CONFIG_FILE"
  [ "$(mm_config sessions_keep_days)" = 30 ]
  [ "$(mm_config other)" = 1 ]
  run mm_config nope
  [ "$status" -ne 0 ]
  rm "$MM_CONFIG_FILE"
  run mm_config sessions_keep_days
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------- carve-outs

# gcloud_tree — $G: a gcloud config folder, credentials next to a logs folder with one day folder.
gcloud_tree() {
  G="$HOME/.config/gcloud"
  mkdir -p "$G/logs/2026.01.01" "$G/configurations" "$G/legacy_credentials/me@example.com"
  echo log >"$G/logs/2026.01.01/10.00.00.000000.log"
  echo c >"$G/credentials.db"; echo t >"$G/access_tokens.db"
  echo '[core]' >"$G/configurations/config_default"; echo '{}' >"$G/legacy_credentials/me@example.com/adc.json"
}

# refused_all ROOT PATH... — mm_rm refuses every PATH as whitelisted, and each survives.
refused_all() {
  local root="$1" p out; shift
  for p; do
    out=$(try_rm "$p" "$root")
    [ "$out" = "1 whitelisted" ] || { echo "not protected: $p ($out)"; return 1; }
    [ -e "$p" ] || { echo "gone: $p"; return 1; }
  done
}

@test "carve-out: a gcloud log can go, never credentials, configurations or the logs folder itself" {
  gcloud_tree
  mkdir -p "$HOME/.config/other"; echo x >"$HOME/.config/other/f"
  mm_inuse_refresh
  run try_rm "$G/logs/2026.01.01/10.00.00.000000.log" "$G/logs"
  [ "$output" = "0 " ]
  [ ! -e "$G/logs/2026.01.01/10.00.00.000000.log" ]
  run try_rm "$G/logs/2026.01.01" "$G/logs"
  [ "$output" = "0 " ]
  refused_all "$G" "$G/credentials.db" "$G/access_tokens.db" "$G/legacy_credentials" "$G/configurations" "$G/logs"
  refused_all "$HOME" "$G/logs" "$G"
  run try_rm "$G/logs" "$G/logs"
  [[ "$output" == "1 outside"* ]]
  refused_all "$HOME/.config" "$HOME/.config/other"
  refused_all "$HOME/.config/other" "$HOME/.config/other/f"
}

@test "carve-out: names that look like credentials are refused inside the logs folder too" {
  gcloud_tree
  local f out
  mkdir -p "$G/logs/x/configurations" "$G/logs/y/legacy_credentials" "$G/logs/z" "$G/logs/2026.01.02" "$G/logs/u/locked"
  for f in access_tokens.db credentials.db Credentials.json my_token.txt key.pem server.key auth-cache.json; do
    echo s >"$G/logs/$f"
  done
  echo s >"$G/logs/z/ACCESS_TOKENS.DB"; echo l >"$G/logs/2026.01.02/a.log"
  echo c >"$G/logs/x/configurations/config_default"; echo c >"$G/logs/y/legacy_credentials/adc.json"
  mm_inuse_refresh
  refused_all "$G/logs" "$G/logs/access_tokens.db" "$G/logs/credentials.db" "$G/logs/Credentials.json" \
    "$G/logs/my_token.txt" "$G/logs/key.pem" "$G/logs/server.key" "$G/logs/auth-cache.json" \
    "$G/logs/x/configurations" "$G/logs/x" "$G/logs/y" "$G/logs/z" "$G/logs/z/ACCESS_TOKENS.DB" \
    "$G/logs/x/configurations/config_default" "$G/logs/y/legacy_credentials/adc.json"
  run try_rm "$G/logs/2026.01.02" "$G/logs"
  [ "$output" = "0 " ]
  if (( EUID != 0 )); then   # root reads any folder
    chmod 000 "$G/logs/u/locked"
    out=$(try_rm "$G/logs/u" "$G/logs"); chmod 755 "$G/logs/u/locked"
    [ "$out" = "1 whitelisted" ]   # what an unreadable folder holds is unknown: kept
  fi
}

@test "carve-out: the whitelist file, in-use checks and agent state still apply inside one" {
  gcloud_tree
  mkdir -p "$G/logs/2026.01.02" "$HOME/.config/opencode/logs"
  echo l >"$G/logs/2026.01.02/a.log"; echo l >"$HOME/.config/opencode/logs/a.log"
  printf '%s\n' "$G/logs/2026.01.01" >"$MM_WHITELIST_FILE"
  mm_test_bg "$G/logs/2026.01.02" sleep 30
  mm_inuse_refresh
  refused_all "$G/logs" "$G/logs/2026.01.01/10.00.00.000000.log" "$G/logs/2026.01.01"
  run try_rm "$G/logs/2026.01.02" "$G/logs"
  [ "$output" = "1 in use" ]
  MM_CLEAN_CARVEOUTS+=("$HOME/.config/opencode/logs")   # opencode keeps its state in ~/.config/opencode
  refused_all "$HOME/.config/opencode/logs" "$HOME/.config/opencode/logs/a.log"
}

@test "carve-out: one array entry opens another cache folder, never its neighbours" {
  mkdir -p "$HOME/.kube/cache/discovery/host"; echo k >"$HOME/.kube/config"; echo d >"$HOME/.kube/cache/discovery/host/v1.json"
  mm_inuse_refresh
  refused_all "$HOME/.kube/cache" "$HOME/.kube/cache/discovery"
  MM_CLEAN_CARVEOUTS+=("$HOME/.kube/cache")
  run try_rm "$HOME/.kube/cache/discovery" "$HOME/.kube/cache"
  [ "$output" = "0 " ]
  refused_all "$HOME/.kube" "$HOME/.kube/config" "$HOME/.kube/cache"
}

@test "carve-out: symlinks widen nothing (linked logs folder, link inside it, linked CLOUDSDK_CONFIG)" {
  mkdir -p "$HOME/.config/gcloud" "$HOME/.aws"; echo c >"$HOME/.aws/config"
  ln -s "$HOME/.aws" "$HOME/.config/gcloud/logs"
  mm_inuse_refresh
  run mm_whitelisted "$HOME/.config/gcloud/logs/config"
  [ "$status" -eq 0 ]
  refused_all "$HOME/.config/gcloud/logs" "$HOME/.config/gcloud/logs/config"
  unlink "$HOME/.config/gcloud/logs"

  gcloud_tree
  ln -s "$HOME/.aws" "$G/logs/d"
  run mm_whitelisted "$G/logs/d/config"
  [ "$status" -eq 0 ]
  run try_rm "$G/logs/d/config" "$G/logs"
  [[ "$output" == "1 "* ]]
  [ -e "$HOME/.aws/config" ]

  ln -s "$G" "$HOME/gc"
  CLOUDSDK_CONFIG="$HOME/gc" mm_core
  refused_all "$HOME/gc/logs" "$G/logs/2026.01.01/10.00.00.000000.log"
}

# ---------------------------------------------------------------- agent waiver in logs dirs

@test "the agent waiver acts in a logs dir outside agent state; credentials and open files there stay" {
  local g="$HOME/.local/state/goose/logs"
  mkdir -p "$g/cli/2026-01-01"
  echo l >"$g/cli/2026-01-01/a.log"; echo t >"$g/oauth-token.log"; echo l >"$g/open.log"; echo l >"$g/cli/b.log"
  mm_test_bg "$g" tail -f "$g/open.log"
  mm_inuse_refresh
  MM_AGENT_WAIVER="$g" run try_rm "$g/cli/2026-01-01/a.log" "$g";    [ "${output%% *}" = 0 ]
  MM_AGENT_WAIVER="$g" run try_rm "$g/oauth-token.log" "$g";         [ "${output%% *}" = 1 ]
  MM_AGENT_WAIVER="$g" run try_rm "$g/open.log" "$g";                [ "${output%% *}" = 1 ]
  MM_AGENT_WAIVER="$g/cli" run try_rm "$g/cli/b.log" "$g/cli";       [ "${output%% *}" = 1 ]   # below a logs dir
  [ ! -e "$g/cli/2026-01-01/a.log" ]
  [ -e "$g/oauth-token.log" ]
  [ -e "$g/open.log" ]
  [ -e "$g/cli/b.log" ]
}

# ---------------------------------------------------------------- kubectl cache carve-out

@test "carve-out: kubectl's discovery and HTTP caches open; ~/.kube/config and plugin caches stay shut" {
  local k="$HOME/.kube"
  mkdir -p "$k/cache/discovery/api.example.com_443/apps/v1" "$k/cache/http" "$k/cache/oidc-login" "$k/cache/kubelogin"
  echo 'apiVersion: v1' >"$k/config"; echo '{}' >"$k/cache/discovery/api.example.com_443/apps/v1/serverresources.json"
  echo r >"$k/cache/http/0a1b2c"; echo t >"$k/cache/oidc-login/abc"; echo t >"$k/cache/kubelogin/def.json"
  echo s >"$k/cache/discovery/server.key"
  mm_inuse_refresh
  run try_rm "$k/cache/discovery/api.example.com_443" "$k/cache/discovery"
  [ "$output" = "0 " ]
  run try_rm "$k/cache/http/0a1b2c" "$k/cache/http"
  [ "$output" = "0 " ]
  refused_all "$k" "$k/config" "$k/cache" "$k/cache/discovery" "$k/cache/http"
  refused_all "$k/cache" "$k/cache/oidc-login" "$k/cache/oidc-login/abc" "$k/cache/kubelogin/def.json"
  refused_all "$k/cache/discovery" "$k/cache/discovery/server.key"
}

# ---------------------------------------------------------------- containers

# fake_cgroup DIR — a cgroup v2 mount stand-in for MM_TEST_CGROUP_FS. Its root stands for the cgroup
# of this process and all its ancestors: the walk up from the real cgroup path passes over the
# levels the fake lacks.
fake_cgroup() { mkdir -p "$1"; echo "cpu memory" >"$1/cgroup.controllers"; export MM_TEST_CGROUP_FS=$1; }

@test "MM_CONTAINER=1 and MM_CONTAINER=0 override container detection" {
  MM_CONTAINER=1 mm_in_container
  run env MM_CONTAINER=0 bash -c '. "$1/lib/core.sh"; mm_in_container' _ "$MM_SRC"
  [ "$status" -eq 1 ]
}

@test "cgroup limits: the tightest memory.max and cpu.max on the way up; 'max' means none" {
  local cg="$SB/cg" rel
  fake_cgroup "$cg"
  echo max >"$cg/memory.max"; echo "max 100000" >"$cg/cpu.max"
  mm_cgroup_limits
  [ -z "$MM_CG_MEM_MAX" ]
  [ -z "$MM_CG_CPU_MILLI" ]
  echo 1073741824 >"$cg/memory.max"; echo "200000 100000" >"$cg/cpu.max"
  # A tighter limit nearer this process (its own cgroup path inside the fake) wins.
  rel=$(awk -F: '$1 == 0 { print $3 }' /proc/self/cgroup)
  [[ "$rel" == /?* ]] || skip "no cgroup v2 path below the root"
  mkdir -p "$cg$rel"
  echo 536870912 >"$cg$rel/memory.max"; echo "50000 100000" >"$cg$rel/cpu.max"
  mm_cgroup_limits
  [ "$MM_CG_MEM_MAX" -eq 536870912 ]
  [ "$MM_CG_MEM_DIR" = "$cg$rel" ]
  [ "$MM_CG_CPU_MILLI" -eq 500 ]
  echo "300000 100000" >"$cg$rel/cpu.max"
  mm_cgroup_limits
  [ "$MM_CG_CPU_MILLI" -eq 2000 ]
  [ "$MM_CG_CPU_DIR" = "$cg" ]
}

@test "cgroup limits: a fake tree outside the test sandbox is ignored" {
  fake_cgroup "$SB/cg"
  echo 536870912 >"$SB/cg/memory.max"
  mkdir -p "$SB/box"
  BATS_TEST_TMPDIR="$SB/box" mm_cgroup_limits
  [ -z "$MM_CG_MEM_MAX" ]
  mm_cgroup_limits
  [ "$MM_CG_MEM_MAX" -eq 536870912 ]
}

@test "the header line says container and shows the cgroup limits instead of the host's" {
  fake_cgroup "$SB/cg"
  echo 536870912 >"$SB/cg/memory.max"; echo "150000 100000" >"$SB/cg/cpu.max"
  [ "$(mm_cg_cores 1500)" = 1.5 ]
  [ "$(mm_cg_cores 2000)" = 2 ]
  [ "$(mm_cg_cores 250)" = 0.25 ]
  run env MM_CONTAINER=1 bash -c '. "$1/lib/core.sh"; mm_sysline' _ "$MM_SRC"
  [[ "$output" == *" · container · 1.5 of $(nproc) cores · 512.0MB RAM limit | Free: "* ]]
  run env MM_CONTAINER=0 bash -c '. "$1/lib/core.sh"; mm_sysline' _ "$MM_SRC"
  [[ "$output" != *container* && "$output" == *" · $(nproc) cores · "*"GB RAM | Free: "* ]]
}
