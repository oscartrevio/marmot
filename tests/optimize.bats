#!/usr/bin/env bats
# mm optimize: orphan detection/kill guards, terminal-only confirmations, apt subset safety,
# swap reset restoring every device, and a dry run that changes nothing.

setup() {
  load helpers/common
  mm_test_setup
  export MM_CMD=optimize MM_OPTIMIZE_ORPHAN_AGE=0
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
}
teardown() {
  local p
  for p in ${EXTRA_PIDS:-}; do kill $(pgrep -P "$p") "$p" 2>/dev/null; done
  mm_test_teardown
}

# load_optimize — core + optimize into the test shell; orphan scans see only this test's sandbox
# (other processes on the machine are never candidates, let alone signalled).
load_optimize() {
  mm_core
  # shellcheck source=../cmd/optimize.sh
  . "$MM_SRC/cmd/optimize.sh"
  eval "$(declare -f _optimize_orphans | sed '1s/_optimize_orphans/_optimize_orphans_all/')"
  _optimize_orphans() { _optimize_orphans_all | grep -F "$SB/"; }
}

# orphan_in DIR CMD... — start CMD with cwd DIR, then delete DIR. Prints nothing; pid in $ORPHAN.
orphan_in() {
  local dir="$SB/$1"; shift
  mkdir -p "$dir"
  mm_test_bg "$dir" "$@"
  ORPHAN=${MM_TEST_PIDS[-1]}
  rm -r -- "$dir"
}

# record_offers — mm_confirm/mm_pick doubles that record what was offered and accept nothing.
record_offers() {
  mm_confirm() { printf 'confirm %s\n' "$1" >>"$CALLS"; return 1; }
  mm_pick() { sed 's/^/pick /' >>"$CALLS"; }
}

# alive PID — running (a killed child of the test shell lingers as a zombie until reaped).
alive() { [[ -d /proc/$1 && "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]]; }
dead() { ! alive "$1"; }
# lacks PATTERN FILE — FILE has no line matching PATTERN (bats ignores a bare `! cmd` failure).
lacks() { ! grep -q -- "$1" "$2"; }

@test "a plain process stranded in a deleted directory is detected" {
  load_optimize
  orphan_in wt sleep 60
  run _optimize_orphans
  [[ "$output" == "$ORPHAN"$'\t'* ]]
  [[ "$output" == *$'\t'"$SB/wt"$'\t'* ]]
}

@test "a process whose directory still exists is never a candidate" {
  load_optimize
  mkdir -p "$SB/live"
  mm_test_bg "$SB/live" sleep 60
  run _optimize_orphans
  [ -z "$output" ]
}

@test "a multiplexer named 'tmux: server' (comm with spaces) is never offered" {
  load_optimize
  mkdir -p "$SB/bin"
  cp "$(command -v sleep)" "$SB/bin/tmux: server"
  orphan_in wt "$SB/bin/tmux: server" 60
  [ "$(cat "/proc/$ORPHAN/comm")" = "tmux: server" ]
  orphan_in wt2 sleep 60
  local plain=$ORPHAN
  record_offers
  MM_TTY=1 _optimize_orphan_task
  grep -q "$plain" "$CALLS"
  lacks "tmux: server" "$CALLS"
}

@test "a process named 'screen' in a deleted directory is never offered" {
  load_optimize
  mkdir -p "$SB/bin"
  cp "$(command -v sleep)" "$SB/bin/screen"
  orphan_in wt "$SB/bin/screen" 60
  local scr=$ORPHAN
  orphan_in wt2 sleep 60
  record_offers
  MM_TTY=1 _optimize_orphan_task
  grep -q "$ORPHAN" "$CALLS"
  lacks "$scr" "$CALLS"
  alive "$scr"
}

@test "an orphaned agent process is offered with its agent name" {
  load_optimize
  mkdir -p "$SB/bin"
  cp "$(command -v sleep)" "$SB/bin/claude"
  orphan_in wt "$SB/bin/claude" 60
  record_offers
  MM_TTY=1 _optimize_orphan_task
  grep -q "^confirm Send SIGTERM to $ORPHAN .*claude \[Claude Code\]" "$CALLS"
}

@test "without fzf every orphan gets its own confirmation" {
  load_optimize
  _optimize_have_fzf() { return 1; }
  orphan_in wt sleep 60
  local a=$ORPHAN
  orphan_in wt2 sleep 60
  record_offers
  MM_TTY=1 _optimize_orphan_task
  [ "$(grep -c '^confirm Send SIGTERM' "$CALLS")" -eq 2 ]
  lacks '^pick' "$CALLS"
  alive "$a"; alive "$ORPHAN"
}

@test "a process attached to a live terminal session is never offered" {
  load_optimize
  mkdir -p "$SB/tty"
  # script gives the shell a pty; the held stdin keeps script (and the session) alive.
  (sleep 30 | script -qfc "cd '$SB/tty' && sleep 61" /dev/null >/dev/null 2>&1) &
  EXTRA_PIDS="$!"
  local p="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do p=$(pgrep -fx 'sleep 61' | head -1); [[ -n "$p" ]] && break; sleep 0.2; done
  [ -n "$p" ]
  EXTRA_PIDS+=" $p"
  [ "$(_optimize_stat_field "$p" 5)" != 0 ]   # really has a controlling tty
  rm -r -- "$SB/tty"
  _optimize_cwd_deleted "$p"
  record_offers
  MM_TTY=1 _optimize_orphan_task
  lacks "$p" "$CALLS"
  alive "$p"
}

@test "without a terminal nothing is offered or signalled" {
  load_optimize
  orphan_in wt sleep 60
  local a=$ORPHAN
  orphan_in wt2 sleep 60
  record_offers
  run _optimize_orphan_task
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  alive "$a"; alive "$ORPHAN"
  [ -z "$(mm_log_rows run)" ]
}

@test "only the processes picked in the picker get SIGTERM" {
  load_optimize
  orphan_in wt sleep 60
  local keep=$ORPHAN
  orphan_in wt2 sleep 60
  local victim=$ORPHAN
  mm_pick() { grep "^$victim "; }
  MM_TTY=1 run _optimize_orphan_task
  dead "$victim"
  alive "$keep"
  [ "$(mm_log_rows run | cut -f1)" = "kill -TERM $victim (sleep)" ]
}

@test "dry run lists orphans but signals nothing" {
  load_optimize
  orphan_in wt sleep 60
  record_offers
  MM_DRY_RUN=1 MM_TTY=1 run _optimize_orphan_task
  [[ "$output" == *"$ORPHAN"* ]]
  [ ! -s "$CALLS" ]
  alive "$ORPHAN"
}

# fake_apt [SIMULATION] — apt-get double: -s prints SIMULATION, anything else is recorded.
fake_apt() {
  mm_test_fake apt-get "if [[ \" \$* \" == *' -s '* ]]; then printf '%s\n' '${1:-}'; else echo \"apt-get \$*\" >>'$CALLS'; fi"
  mm_test_fake apt-mark "echo \"apt-mark \$*\" >>'$CALLS'"
  mm_test_fake snap "echo 'All snaps up to date.'"
}

@test "without a terminal apt never upgrades (nor runs apt-get update)" {
  load_optimize
  fake_apt "Inst curl [1] (2 Ubuntu:24.04/noble-updates [amd64])"
  mm_apt_busy() { return 1; }
  run _optimize_updates
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "disruptive upgrades are held back when only the safe set is accepted" {
  load_optimize
  fake_apt "Inst curl [1] (2)"
  mm_sudo() { "$@"; }
  mm_confirm() { [[ "$1" == "Install "* ]]; }   # yes to the safe set, no to docker
  MM_TTY=1 run _optimize_apt_upgrade curl docker-ce containerd.io
  grep -qx 'apt-get .* install --only-upgrade curl' "$CALLS"
  lacks 'docker-ce\|containerd' "$CALLS"
  lacks 'apt-get .* upgrade$' "$CALLS"
}

@test "openssh-server, zerotier-one and podman upgrades need their own confirmation" {
  load_optimize
  fake_apt "Inst curl [1] (2)"
  mm_sudo() { "$@"; }
  mm_confirm() { printf 'confirm %s\n' "$1" >>"$CALLS"; [[ "$1" == "Install "* ]]; }
  MM_TTY=1 run _optimize_apt_upgrade curl openssh-server zerotier-one podman
  grep -qx 'confirm Install 1 upgrades?' "$CALLS"
  grep -q '^confirm Also upgrade openssh-server zerotier-one podman' "$CALLS"
  grep -qx 'apt-get .* install --only-upgrade curl' "$CALLS"
  lacks 'apt-get .*\(openssh\|zerotier\|podman\)' "$CALLS"
}

@test "a partial upgrade that would remove a package is refused" {
  load_optimize
  fake_apt $'Inst curl [1] (2)\nRemv libfoo1 [1]'
  mm_sudo() { "$@"; }
  run _optimize_apt_upgrade_subset 1 docker-ce curl
  [ ! -s "$CALLS" ]
}

@test "without a terminal the swap reset is skipped" {
  load_optimize
  mm_can_sudo() { return 0; }   # get past the sudo gate: only the terminal check may stop it
  mm_sudo() { "$@"; }
  _optimize_meminfo() {   # 3 GiB swapped out, 20 GiB available
    case "$1" in SwapTotal) echo $((8 << 30)) ;; SwapFree) echo $((5 << 30)) ;; MemAvailable) echo $((20 << 30)) ;; esac
  }
  run _optimize_swap
  [ "$status" -eq 0 ]   # swapoff/swapon stubs would fail teardown if called
}

@test "swap reset re-enables devices that swapon -a does not restore" {
  load_optimize
  local state="$BATS_TEST_TMPDIR/swapstate"
  printf '/swap.img -2\n/dev/zram0 100\n' >"$state"
  mm_test_fake swapoff ": >'$state'; echo \"swapoff \$*\" >>'$CALLS'"
  mm_test_fake swapon "case \"\$1\" in
    --show=NAME,PRIO) cat '$state' ;;
    --show=NAME) cut -d' ' -f1 '$state' ;;
    -a) echo '/swap.img -2' >>'$state'; echo 'swapon -a' >>'$CALLS' ;;
    -p) echo \"\$4 \$2\" >>'$state'; echo \"swapon \$*\" >>'$CALLS' ;;
  esac"
  mm_sudo() { "$@"; }
  _optimize_swap_total() { echo $(( $(wc -l <"$state") << 30 )); }
  run _optimize_swap_reset $((3 << 30))
  grep -qx 'swapon -p 100 -- /dev/zram0' "$CALLS"
  [ "$(sort "$state")" = "$(printf '/dev/zram0 100\n/swap.img -2')" ]
}

@test "mm optimize --dry-run runs no state-changing command" {
  orphan_in wt sleep 60
  # Read-only probes answer; any other use is recorded as a mutation. fstrim, resolvectl,
  # swapon/swapoff, apt-mark and sudo stay fail-loud stubs (teardown fails if they ran).
  mm_test_fake apt-get "if [[ \" \$* \" == *' -s '* ]]; then echo 'Inst curl [1] (2)'; else echo \"MUTATION apt-get \$*\" >>'$CALLS'; fi"
  mm_test_fake systemctl "case \"\$*\" in show*|*--failed*|is-active*) exit 0 ;; *) echo \"MUTATION systemctl \$*\" >>'$CALLS'; exit 1 ;; esac"
  mm_test_fake journalctl "[[ \"\$*\" == --disk-usage ]] && echo 'Archived and active journals take up 8.0M in the file system.' || echo \"MUTATION journalctl \$*\" >>'$CALLS'"
  mm_test_fake snap "[[ \"\$*\" == 'refresh --list' ]] && echo 'All snaps up to date.' || echo \"MUTATION snap \$*\" >>'$CALLS'"
  run mm optimize --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  alive "$ORPHAN"
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}
