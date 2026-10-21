#!/usr/bin/env bats
# mm analyze: ncdu is always read-only; deletion only through marmot's Trash picker (mm_rm --trash).

setup() {
  load helpers/common
  mm_test_setup
  export MM_CMD=analyze MM_ANALYZE_TIMEOUT=3
  NCDU_ARGS="$BATS_TEST_TMPDIR/ncdu.args" CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  # ncdu double: records each launch (not the --help feature probe).
  mm_test_fake ncdu "[[ \"\$1\" == --help ]] && exit 0; printf '%s\n' \"\$*\" >>'$NCDU_ARGS'"
}
teardown() { mm_test_teardown; }

lacks() { ! grep -q -- "$1" "$2"; }

# load_analyze — core + analyze into the test shell, with a tree to pick from.
load_analyze() {
  mm_core
  # shellcheck source=../cmd/analyze.sh
  . "$MM_SRC/cmd/analyze.sh"
  mkdir -p "$SB/root/big" "$SB/root/keep" "$(dirname "$MM_WHITELIST_FILE")"
  head -c 300000 /dev/urandom >"$SB/root/big/blob"
  echo keep >"$SB/root/keep/f"
  mm_confirm() { printf 'confirm %s\n' "$1" >>"$CALLS"; return 0; }
}

# pick REL... — mm_pick double selecting the rows whose relative path is exactly REL.
pick() {
  PICKS=("$@")
  mm_pick() {
    local line r
    while IFS= read -r line; do
      for r in "${PICKS[@]}"; do [[ "${line#*$'\t'}" == "$r" ]] && printf '%s\n' "$line"; done
    done
    echo picker >>"$CALLS"
  }
}

@test "ncdu opens read-only for a user-owned path" {
  load_analyze; mm_confirm() { return 1; }   # no Trash afterwards
  mkdir -p "$SB/mine"
  MM_TTY=1 run mm_cmd_main "$SB/mine"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$NCDU_ARGS")" -eq 1 ]
  [[ " $(cat "$NCDU_ARGS") " == *" -r "* ]]
  [[ "$(cat "$NCDU_ARGS")" == *"-- $SB/mine" ]]
}

@test "ncdu opens read-only for root-owned and unreadable locations" {
  load_analyze; mm_confirm() { return 1; }
  MM_NO_SUDO=1 MM_TTY=1 run mm_cmd_main /var/log
  mkdir -p "$SB/locked"; chmod 000 "$SB/locked"
  MM_NO_SUDO=1 MM_TTY=1 run mm_cmd_main "$SB/locked"
  chmod 700 "$SB/locked"
  [ "$(wc -l <"$NCDU_ARGS")" -eq 2 ]
  [ "$(grep -c -- ' -r ' "$NCDU_ARGS")" -eq 2 ]
}

@test "a location opened as root through sudo is still read-only" {
  load_analyze
  mm_test_fake sudo "[[ \"\$*\" == '-n true' ]] && exit 0; printf 'sudo %s\n' \"\$*\" >>'$NCDU_ARGS'"
  mkdir -p "$SB/locked"; chmod 000 "$SB/locked"
  MM_TTY=1 run mm_cmd_main "$SB/locked"
  chmod 700 "$SB/locked"
  [[ "$(cat "$NCDU_ARGS")" == "sudo -n ncdu "*" -r "*"-- $SB/locked" ]]
}

@test "without a terminal, mm analyze PATH lists the largest entries instead of starting ncdu" {
  load_analyze
  run mm analyze "$SB/root"
  [ "$status" -eq 0 ]
  [ ! -e "$NCDU_ARGS" ]
  [[ "$output" == *"$SB/root/big"* ]]
  [ -f "$SB/root/big/blob" ]
}

@test "--json returns every overview entry with numeric bytes" {
  run mm analyze --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.entries | length) > 0
    and all(.entries[]; (.bytes | type) == "number" and (.name | length) > 0)
    and (.free_bytes | type) == "number"'
  echo "$output" | jq -e --arg h "$HOME" 'any(.entries[]; .path == $h)'
}

@test "--json draws no spinner even on a terminal, and stdout carries only the JSON" {
  command -v script >/dev/null || skip "needs script (util-linux)"
  MM_TTY=1 script -qec "mm analyze --json >'$SB/out'" /dev/null >"$SB/tty"
  jq -e . "$SB/out" >/dev/null
  [ "$(grep -c '⠋\|⠙\|⠹\|Measuring' "$SB/tty")" = 0 ]
}

# entry NAME — the JSON overview entry called NAME (from $output).
entry() { echo "$output" | jq -c --arg n "$1" '.entries[] | select(.name == $n)'; }

@test "the overview has a report-only Agent state row when agent state exists" {
  run mm analyze --json
  [ -z "$(entry "Agent state")" ]
  mkdir -p "$HOME/.claude/projects" "$HOME/.codex"
  head -c 200000 /dev/urandom >"$HOME/.claude/projects/s.jsonl"
  head -c 100000 /dev/urandom >"$HOME/.codex/x"
  echo '{}' >"$HOME/.claude.json"
  run mm analyze --json
  [ "$status" -eq 0 ]
  local e; e=$(entry "Agent state")
  [ -n "$e" ]
  echo "$e" | jq -e '.report_only == true and .bytes >= 300000'
  echo "$e" | jq -e --arg p "$HOME/.claude" '.path == $p'
}

@test "Dev caches sums the XDG cache and the toolchain caches that exist" {
  mkdir -p "$XDG_CACHE_HOME" "$HOME/.npm/_cacache" "$HOME/.cargo/registry/cache"
  head -c 100000 /dev/urandom >"$XDG_CACHE_HOME/a"
  head -c 200000 /dev/urandom >"$HOME/.npm/_cacache/b"
  head -c 300000 /dev/urandom >"$HOME/.cargo/registry/cache/c"
  run mm analyze --json
  [ "$status" -eq 0 ]
  entry "Dev caches" | jq -e --arg p "$HOME/.cargo/registry" '.bytes >= 600000 and .report_only == false and .path == $p'
}

@test "old downloads are found in the XDG download directory" {
  mkdir -p "$HOME/Dl" "$XDG_CONFIG_HOME"
  echo 'XDG_DOWNLOAD_DIR="$HOME/Dl"' >"$XDG_CONFIG_HOME/user-dirs.dirs"
  head -c 100000 /dev/urandom >"$HOME/Dl/old.iso"
  mm_age "$HOME/Dl/old.iso" 120
  run mm analyze --json
  entry "Old Downloads (90d+)" | jq -e --arg p "$HOME/Dl" '.path == $p and .bytes >= 100000'
}

@test "without ncdu, exploring a path lists its largest entries" {
  local bin="$SB/bin" f
  mkdir -p "$bin" "$SB/root/big"
  head -c 300000 /dev/urandom >"$SB/root/big/blob"
  for f in /usr/bin/* /usr/sbin/*; do [[ "${f##*/}" == ncdu ]] || ln -sf "$f" "$bin/${f##*/}"; done
  rm "$BATS_TEST_TMPDIR/stubs/ncdu"
  PATH="$BATS_TEST_TMPDIR/stubs:$bin" run mm analyze "$SB/root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SB/root/big"* ]]
  [ ! -e "$NCDU_ARGS" ]
}

@test "the overview's scratch directory is removed" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  run mm analyze --json
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "the Trash picker moves exactly the picked item, with a .trashinfo" {
  load_analyze
  pick big
  MM_TTY=1 run _analyze_trash_offer "$SB/root"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/root/big" ]
  [ -d "$SB/root/keep" ]
  [ -f "$MM_TRASH_DIR/files/big/blob" ]
  grep -qx "Path=$SB/root/big" "$MM_TRASH_DIR/info/big.trashinfo"
  [ "$(mm_log_rows trash | cut -f1)" = "$SB/root/big" ]
}

@test "the Trash picker refuses whitelisted and in-use picks" {
  load_analyze
  mkdir -p "$SB/root/wl" "$SB/root/busy"
  echo data >"$SB/root/wl/f"; echo data >"$SB/root/busy/f"
  mm_whitelist_init
  echo "$SB/root/wl" >>"$MM_WHITELIST_FILE"
  mm_test_bg "$SB/root/busy" sleep 60
  pick wl busy
  MM_TTY=1 run _analyze_trash_offer "$SB/root"
  [ -f "$SB/root/wl/f" ]; [ -f "$SB/root/busy/f" ]
  [ ! -e "$MM_TRASH_DIR/files/wl" ]; [ ! -e "$MM_TRASH_DIR/files/busy" ]
  [ "$(mm_log_rows refused | cut -f2 | sort | tr '\n' ,)" = "in use,whitelisted," ]
}

@test "dry run: the Trash picker moves nothing" {
  load_analyze
  pick big
  MM_DRY_RUN=1 MM_TTY=1 run _analyze_trash_offer "$SB/root"
  [ "$status" -eq 0 ]
  grep -qx picker "$CALLS"
  [ -f "$SB/root/big/blob" ]
  [ ! -e "$MM_TRASH_DIR/files/big" ]
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}

@test "without a terminal there is no Trash offer at all" {
  load_analyze
  pick big
  run _analyze_trash_offer "$SB/root"
  [ ! -s "$CALLS" ]
  run mm analyze "$SB/root"
  [ "$status" -eq 0 ]
  [ -f "$SB/root/big/blob" ]
  [ ! -e "$MM_TRASH_DIR/files" ]
}

@test "after ncdu quits on a writable folder, the Trash picker is offered" {
  load_analyze
  pick big
  MM_TTY=1 run _analyze_launch "$SB/root" user
  [ "$status" -eq 0 ]
  grep -qx picker "$CALLS"
  [ ! -e "$SB/root/big" ]
}

@test "no Trash offer after exploring a non-writable or root-owned location" {
  load_analyze
  pick big
  mm_can_sudo() { return 1; }
  chmod 555 "$SB/root"
  MM_TTY=1 run _analyze_launch "$SB/root" user
  chmod 755 "$SB/root"
  MM_TTY=1 run _analyze_launch "$SB/root" root
  [ ! -s "$CALLS" ]
  [ "$(wc -l <"$NCDU_ARGS")" -eq 2 ]
}
