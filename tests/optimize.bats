#!/usr/bin/env bats
# mm optimize: orphan detection/kill guards, orphaned headless browsers, terminal-only
# confirmations, apt subset safety, swap reset restoring every device, and a dry run that changes
# nothing.

setup() {
  load helpers/common
  mm_test_setup
  export MM_CMD=optimize MM_OPTIMIZE_ORPHAN_AGE=0
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
}
teardown() {
  local p
  for p in ${EXTRA_PIDS:-}; do kill $(mm_test_pids --parent "$p") "$p" 2>/dev/null; done
  for p in ${FAKE_PIDS:-}; do kill -KILL "$p" 2>/dev/null; done
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

@test "an orphaned agent helper is offered as that agent's helper, not as a session" {
  load_optimize
  # `omp __omp_worker_lsp_mux`: a copy of bash named omp running that script, blocked on a FIFO.
  mkdir -p "$SB/bin" "$SB/wt"
  cp "$(command -v bash)" "$SB/bin/omp"
  mkfifo "$SB/wt/fifo"
  printf 'read -r _ <>fifo\n' >"$SB/wt/__omp_worker_lsp_mux"
  mm_test_bg "$SB/wt" "$SB/bin/omp" __omp_worker_lsp_mux
  ORPHAN=${MM_TEST_PIDS[-1]}
  # The folder goes once the script holds the FIFO (bash has read it by then). Under a loaded
  # parallel run this takes seconds: wait up to 20, and fail here rather than on a missing offer.
  local held=0
  for _ in $(seq 200); do find "/proc/$ORPHAN/fd" -lname "$SB/wt/fifo" 2>/dev/null | grep -q . && { held=1; break; }; sleep 0.1; done
  (( held ))
  rm -r -- "$SB/wt"
  record_offers
  MM_TTY=1 _optimize_orphan_task
  grep -q "^confirm Send SIGTERM to $ORPHAN .*omp \[oh-my-pi helper\]" "$CALLS"
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
  for i in 1 2 3 4 5 6 7 8 9 10; do p=$(mm_test_pids --cmdline 'sleep 61' | head -1); [[ -n "$p" ]] && break; sleep 0.2; done
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
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_orphan_task
  dead "$victim"
  alive "$keep"
  [ "$(mm_log_rows run | cut -f1)" = "kill -TERM $victim (sleep)" ]
}

@test "what the picker returns is listed and confirmed before any SIGTERM; declining signals nothing" {
  load_optimize
  orphan_in wt sleep 60
  local a=$ORPHAN
  orphan_in wt2 sleep 60
  _optimize_have_fzf() { return 0; }
  mm_pick() { head -n 1; }   # Enter with nothing marked: fzf --multi returns the highlighted row
  mm_confirm() { printf 'confirm %s\n' "$1" >>"$CALLS"; return 1; }
  MM_TTY=1 run _optimize_orphan_task
  alive "$a"; alive "$ORPHAN"
  [ "$(grep -c '^confirm' "$CALLS")" -eq 1 ]
  [ -z "$(mm_log_rows run)" ]
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

@test "without sudo, upgrades are skipped as needing it and apt-get never runs or asks" {
  load_optimize
  fake_apt "Inst curl [1] (2 Ubuntu:24.04/noble-updates [amd64])"
  mm_apt_busy() { return 1; }
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_updates
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs sudo"* ]]
  [ ! -s "$CALLS" ]
}

@test "disruptive upgrades are held back when only the safe set is accepted" {
  load_optimize
  fake_apt "Inst curl [1] (2)"
  mm_sudo() { "$@"; }; mm_can_sudo() { return 0; }
  mm_confirm() { [[ "$1" == "Install "* ]]; }   # yes to the safe set, no to docker
  MM_TTY=1 run _optimize_apt_upgrade curl docker-ce containerd.io
  grep -qx 'apt-get .* install --only-upgrade curl' "$CALLS"
  lacks 'docker-ce\|containerd' "$CALLS"
  lacks 'apt-get .* upgrade$' "$CALLS"
}

@test "openssh-server, zerotier-one and podman upgrades need their own confirmation" {
  load_optimize
  fake_apt "Inst curl [1] (2)"
  mm_sudo() { "$@"; }; mm_can_sudo() { return 0; }
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

# ---------------------------------------------------------------- orphaned automation browsers

# load_browsers — load_optimize, with browser scans limited to this test's fake browsers.
load_browsers() {
  load_optimize
  eval "$(declare -f _optimize_browsers | sed '1s/_optimize_browsers/_optimize_browsers_all/')"
  _optimize_browsers() { _optimize_browsers_all | awk -F'\t' -v ok=" ${FAKES:-} " 'index(ok, " " $1 " ")'; }
}

# TEST_REAPER — a subreaper named tini (comm and argv[0]) that runs its arguments, then adopts
# whatever they leave behind and reaps it when it exits. Orphans of the test go to it, not to
# whichever subreaper runs the suite (systemd --user, a container init, an agent's node or bun
# process, bats itself), whose name decides what optimize may treat as orphaned.
TEST_REAPER='import ctypes, signal, subprocess, sys
libc = ctypes.CDLL(None)
if libc.prctl(36, 1) or libc.prctl(15, b"tini"):   # PR_SET_CHILD_SUBREAPER, PR_SET_NAME
    sys.exit("prctl failed")
subprocess.run(sys.argv[1:], close_fds=False)
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
while True:
    signal.pause()'

# fake_browser orphan|attached|stubborn ARGS... — a fake Chromium: a copy of bash named chrome
# whose argv carries ARGS, with one --type=renderer child that exits when its parent does (like
# Chromium's). orphan/stubborn: started through setsid -f under TEST_REAPER, so its parent exits
# at once and the reaper adopts it; stubborn also ignores SIGTERM. attached: a child of the test
# shell. Sets BROWSER and RENDERER.
fake_browser() {
  local mode=$1 hold="$BATS_TEST_TMPDIR/hold" id i p body reaper=""
  shift
  command -v python3 >/dev/null || skip "python3 not installed"
  # The id names this test's sandbox: fakes left by other runs never match it.
  FAKES_N=$(( ${FAKES_N:-0} + 1 )); id="$SB/$FAKES_N"
  mkdir -p "$SB/bin"
  [[ -x "$SB/bin/chrome" ]] || cp "$(command -v bash)" "$SB/bin/chrome"
  [[ -p "$hold" ]] || mkfifo "$hold"
  body='[[ $FAKE_MODE == stubborn ]] && trap "" TERM
exec 4> >(exec "$0" -c "read -r" "$0" --type=renderer); read -t 600 -u 3'
  if [[ "$mode" == attached ]]; then
    FAKE_MODE=$mode "$SB/bin/chrome" -c "$body" "$SB/bin/chrome" "$@" "--fake-id=$id" 3<>"$hold" </dev/null >/dev/null 2>&1 &
  else
    (FAKE_MODE=$mode exec -a tini python3 -c "$TEST_REAPER" setsid -f "$SB/bin/chrome" -c "$body" \
      "$SB/bin/chrome" "$@" "--fake-id=$id" 3<>"$hold" </dev/null >/dev/null 2>&1) &
    reaper=$!
    FAKE_PIDS+=" $reaper"
  fi
  BROWSER="" RENDERER=""
  for ((i = 0; i < 100; i++)); do
    for p in $(mm_test_pids --comm chrome --cmdline-has "--fake-id=$id"); do
      RENDERER=$(mm_test_pids --parent "$p" --cmdline-has --type=renderer)
      [[ -n "$RENDERER" ]] && { BROWSER=$p; break 2; }
    done
    sleep 0.05
  done
  [[ -n "$BROWSER" ]] || { echo "fake browser did not start" >&2; return 1; }
  FAKES+=" $BROWSER" FAKE_PIDS="$BROWSER $RENDERER $FAKE_PIDS"
  if [[ -n "$reaper" && "$(_optimize_stat_field "$BROWSER" 2)" != "$reaper" ]]; then
    echo "fake browser $BROWSER was not adopted by the test reaper $reaper" >&2; return 1
  fi
}

@test "browsers: an orphaned headless browser is found, only its main process, with its renderer in its tree" {
  load_browsers
  fake_browser orphan --headless=new --user-data-dir="$SB/prof"
  run _optimize_browsers
  [ "$(cut -f1 <<<"$output")" = "$BROWSER" ]
  [[ "$output" == *$'\t'"$SB/prof"$'\t'* ]]
  [[ "$(cut -f8 <<<"$output")" == "$RENDERER:"* ]]
}

@test "browsers: Playwright and Puppeteer profiles mark automation browsers even without --headless" {
  load_browsers
  fake_browser orphan --user-data-dir="$SB/tmp/playwright_chromiumdev_profile-Xy12"
  local pw=$BROWSER
  fake_browser orphan --user-data-dir="$SB/tmp/puppeteer_dev_chrome_profile-Ab34/"
  run _optimize_browsers
  [ "$(cut -f1 <<<"$output" | sort)" = "$(printf '%s\n' "$pw" "$BROWSER" | sort)" ]
}

@test "browsers: one still attached to its launcher, or a headed browser on its own profile, is kept" {
  load_browsers
  fake_browser attached --headless --user-data-dir="$SB/tmp/playwright_chromiumdev_profile-a"
  fake_browser orphan --user-data-dir="$SB/my-profile"
  run _optimize_browsers
  [ -z "$output" ]
}

@test "browsers: an orphan younger than the age threshold is kept" {
  load_browsers
  fake_browser orphan --headless
  MM_OPTIMIZE_ORPHAN_AGE=3600 run _optimize_browsers
  [ -z "$output" ]
  mm_test_clock 1
  MM_OPTIMIZE_ORPHAN_AGE=3600 run _optimize_browsers
  [ "$(cut -f1 <<<"$output")" = "$BROWSER" ]
}

@test "browsers: the picked browser gets SIGTERM and its whole tree stops" {
  load_browsers
  fake_browser orphan --headless
  local renderer=$RENDERER
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_browser_task
  [ "$status" -eq 0 ]
  dead "$BROWSER"
  dead "$renderer"
  [ "$(mm_log_rows run | cut -f1)" = "kill -TERM $BROWSER (chrome)" ]
}

@test "browsers: only the browsers marked in the picker are stopped" {
  load_browsers
  fake_browser orphan --headless
  local keep=$BROWSER
  fake_browser orphan --headless
  local victim=$BROWSER
  _optimize_have_fzf() { return 0; }
  mm_pick() { grep "^$victim "; }
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_browser_task
  dead "$victim"
  alive "$keep"
}

@test "browsers: what the picker returns is listed and confirmed before any signal; declining stops nothing" {
  load_browsers
  fake_browser orphan --headless
  local a=$BROWSER
  fake_browser orphan --headless
  _optimize_have_fzf() { return 0; }
  mm_pick() { head -n 1; }   # Enter with nothing marked: fzf --multi returns the highlighted row
  mm_confirm() { printf 'confirm %s\n' "$1" >>"$CALLS"; return 1; }
  MM_TTY=1 run _optimize_browser_task
  alive "$a"; alive "$BROWSER"
  [ "$(grep -c '^confirm' "$CALLS")" -eq 1 ]
  [ -z "$(mm_log_rows run)" ]
}

@test "browsers: one that ignores SIGTERM gets SIGKILL" {
  load_browsers
  fake_browser stubborn --headless
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_browser_task
  dead "$BROWSER"
  mm_log_rows run | cut -f1 | grep -qx "kill -KILL $BROWSER (chrome)"
}

@test "browsers: a pid whose start time differs from the scan is never signalled" {
  load_browsers
  fake_browser orphan --headless
  # The scan saw another process under this pid (same pid, other start time).
  _optimize_browsers() { _optimize_browsers_all | awk -F'\t' -v OFS='\t' -v ok=" $FAKES " 'index(ok, " " $1 " ") { $2 = $2 "1"; print }'; }
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_browser_task
  alive "$BROWSER"
  [ -z "$(mm_log_rows run)" ]
}

@test "browsers: without a terminal, or in a dry run, nothing is offered or signalled" {
  load_browsers
  fake_browser orphan --headless
  record_offers
  run _optimize_browser_task
  [ "$status" -eq 0 ]
  MM_DRY_RUN=1 MM_TTY=1 run _optimize_browser_task
  [[ "$output" == *"$BROWSER"* ]]
  [ ! -s "$CALLS" ]
  alive "$BROWSER"
  [ -z "$(mm_log_rows run)" ]
}

# ---------------------------------------------------------------- containers

@test "in a container the swap reset, TRIM and reboot check are skipped, each with its reason" {
  load_optimize
  # Swap in use with RAM to spare, a TRIM due, a newer kernel installed: all would act on a host.
  _optimize_meminfo() { echo $((4 << 30)); }
  mm_test_fake systemctl 'exit 0'
  mm_test_fake journalctl 'exit 0'
  mm_test_fake fstrim 'exit 0'
  mm_test_fake dpkg-query "printf 'install ok installed\tlinux-image-99.0.0-1-generic\n'"
  export MM_DRY_RUN=1 MM_CONTAINER=1
  run _optimize_swap
  [[ "$output" == *"Swap reset · skipped (in a container: swap belongs to the host)"* ]]
  run _optimize_disk
  [[ "$output" == *"SSD TRIM · skipped (in a container: the disk belongs to the host)"* ]]
  run _optimize_reboot
  [[ "$output" == *"Reboot · skipped (in a container: the kernel belongs to the host)"* ]]
  [[ "$output" != *"Reboot pending"* ]]
  # The same machine outside a container: TRIM and the pending reboot come back.
  MM_CONTAINER=0
  run _optimize_disk
  [[ "$output" == *"Would TRIM free blocks on /"* ]]
  run _optimize_reboot
  [[ "$output" == *"Reboot pending: linux-image-99.0.0-1-generic"* ]]
}

@test "in a container the diagnosis gives load and swap as the host's and memory against the limit" {
  load_optimize
  local cg="$SB/cg"
  mkdir -p "$cg"
  echo "cpu memory" >"$cg/cgroup.controllers"
  echo 536870912 >"$cg/memory.max"; echo $((300 << 20)) >"$cg/memory.current"
  printf 'inactive_file %d\n' $((100 << 20)) >"$cg/memory.stat"
  export MM_TEST_CGROUP_FS=$cg MM_CONTAINER=1
  run _optimize_diagnose
  [[ "$output" == *"Load (host) "* && "$output" != *"! Load"* && "$output" != *"! Swap"* ]]
  [[ "$output" == *"Memory · 312.0MB available of 512.0MB (container limit)"* ]]
  MM_CONTAINER=0 run _optimize_diagnose
  [[ "$output" != *"(host)"* && "$output" != *"container limit"* ]]
}
