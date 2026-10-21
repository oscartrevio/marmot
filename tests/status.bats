#!/usr/bin/env bats
# mm status: read-only dashboard. JSON shape, agent sessions (by name and by interpreter argv),
# orphans in deleted dirs, lingering dev processes and old listeners (age via
# MM_STATUS_LINGER_AGE), VPN rows only for interfaces that exist, inode penalty, its own processes
# kept out of the top lists, live-mode rendering in a pty, the marmot's face, and no terminal
# needed for a snapshot.
# Every external tool it calls must be a read-only query.

setup() {
  load helpers/common
  mm_test_setup
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  # Read-only doubles for the slow probes; each records its argv so tests can check the verbs.
  local rec="printf '%s %s\n' \"\${0##*/}\" \"\$*\" >>'$CALLS'"
  mm_test_fake apt "$rec
[[ \"\$1 \$2\" == 'list --upgradable' ]] && printf 'Listing...\nfoo/stable 2.0 amd64 [upgradable from: 1.0]\n'
exit 0"
  mm_test_fake systemctl "$rec
[[ \"\$1\" == is-active ]] && echo active
exit 0"
  mm_test_fake docker "$rec
exit 1"
  mkdir -p "$SB/bin"
  DETACHED_PIDS=()
  # The terminal bats runs in (if any) is the developer's: tests see "no terminal" unless they
  # run mm in a pty of their own (script) and unset this.
  export MM_TEST_NO_TTY=1
}

teardown() {
  local p
  # Background helpers may have children of their own (a fake agent running a server).
  for p in "${MM_TEST_PIDS[@]}" "${DETACHED_PIDS[@]}"; do kill $(mm_test_pids --parent "$p") 2>/dev/null; done
  for p in "${DETACHED_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  mm_test_teardown
}

# detached DIR CMD... — start CMD with cwd DIR outside this process tree (reparented to init or the
# user's service manager), like a server whose terminal or agent is gone. The test itself runs
# under whatever launched bats (possibly an agent), and agent descendants never count as
# lingering. Pid in $DETACHED; killed at teardown.
detached() {
  local dir=$1 pidf="$BATS_TEST_TMPDIR/detached.$RANDOM" i
  shift
  (cd "$dir" && setsid -f bash -c 'echo $$ >"$0"; exec "$@"' "$pidf" "$@" >/dev/null 2>&1)
  for ((i = 0; i < 30; i++)); do [[ -s "$pidf" ]] && break; sleep 0.1; done
  DETACHED=$(<"$pidf")
  DETACHED_PIDS+=("$DETACHED")
  sleep 0.3
}

needs_jq() { command -v jq >/dev/null || skip "jq not installed"; }
needs_python() { command -v python3 >/dev/null || skip "python3 not installed"; }

# fake_agent NAME — a copy of sleep named NAME (its comm is NAME, like a native agent binary).
fake_agent() { cp "$(command -v sleep)" "$SB/bin/$1"; }

# listening PID — wait (up to 3s) until PID has a socket open.
listening() {
  local i
  for ((i = 0; i < 30; i++)); do
    find "/proc/$1/fd" -lname 'socket:*' 2>/dev/null | grep -q . && return 0
    sleep 0.1
  done
  return 1
}

status_json() {
  run env "$@" mm status --json
  [ "$status" -eq 0 ]
  JSON=$output
}

# fake_ss LISTENERS CONNS [CONNS_LATER [UDP]] — an `ss` double: listener queries (-l) print
# LISTENERS; `state established` queries print CONNS the first time and CONNS_LATER (default
# CONNS) after, so counters can grow between the two samples a snapshot takes; UDP queries (-u)
# print UDP. Lines as `ss -H` prints them.
fake_ss() {
  local d=$BATS_TEST_TMPDIR
  printf '%s\n' "$1" >"$d/ss.listen"
  printf '%s\n' "$2" >"$d/ss.est1"
  printf '%s\n' "${3:-$2}" >"$d/ss.est2"
  printf '%s\n' "${4:-}" >"$d/ss.udp"
  mm_test_fake ss "case \"\$*\" in
  *established*) if [[ -e '$d/ss.seen' ]]; then cat '$d/ss.est2'; else : >'$d/ss.seen'; cat '$d/ss.est1'; fi ;;
  -Hu*) cat '$d/ss.udp' ;;
  *l*) cat '$d/ss.listen' ;;
esac"
  rm -f "$d/ss.seen"
}

# conn LOCAL PEER INFO [INODE] — one established connection as `ss -Htine` prints it (info on its
# own line); the socket's inode when given.
conn() {
  printf '0      0      %s   %s%s\n\t cubic wscale:7,7 rto:204 %s mss:1448 lastsnd:10 lastack:20\n' \
    "$1" "$2" "${4:+ uid:1000 ino:$4 sk:1}" "$3"
}

NO_SSH=(-u SSH_CONNECTION -u SSH_CLIENT)
LISTEN_SSH='LISTEN 0      4096         0.0.0.0:22        0.0.0.0:*
LISTEN 0      4096       127.0.0.1:5432      0.0.0.0:*'

# status_lib SNIPPET — run SNIPPET in a fresh bash with lib/core.sh and cmd/status.sh sourced, in
# a new session (no controlling terminal: sizes come from LINES/COLUMNS, as on CI).
status_lib() { run setsid -w bash -c '. "$1/lib/core.sh"; . "$1/cmd/status.sh"; eval "$2"' _ "$MM_SRC" "$1"; }

# live KEYS [ARGS...] — run `mm status --interval 1 ARGS` in a pty (script(1)) of LIVE_ROWS
# (default 40) by 100 columns; KEYS is a shell snippet whose stdout is typed into it (e.g.
# 'sleep 4; printf q'). Exit status in $LIVE_STATUS, raw output in $LIVE_OUT, the output with
# escape sequences stripped in $LIVE_TEXT.
live() {
  command -v script >/dev/null || skip "script(1) not installed"
  local keys=$1 cmd=""
  shift
  (($#)) && printf -v cmd ' %q' "$@"
  LIVE_OUT="$BATS_TEST_TMPDIR/live.out" LIVE_STATUS=0
  { eval "$keys"; sleep 2; } |
    timeout 40 script -qfec "stty rows ${LIVE_ROWS:-40} cols 100; env -u MM_TTY mm status --interval 1$cmd" /dev/null \
      >"$LIVE_OUT" || LIVE_STATUS=$?
  LIVE_TEXT=$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LIVE_OUT" | tr -d '\r')
}

@test "--json is valid and carries agents, lingering, orphans, ports, inodes and network kinds" {
  needs_jq
  status_json
  jq -e '
    (.health_score | type == "number")
    and ((["count", "longest_age_seconds", "rss_swap_bytes", "orphan_count", "sessions"] - (.system.agents | keys)) == [])
    and ((["min_age_seconds", "count", "rss_swap_bytes", "processes"] - (.system.lingering | keys)) == [])
    and (.system.orphans | type == "array")
    and ((["min_age_seconds", "total_listening", "count", "oldest_age_seconds", "ports"] - (.system.listening_ports | keys)) == [])
    and (.disks[] | select(.mount == "/") | has("inodes_used_percent"))
    and (.network | all(.kind == "default" or .kind == "vpn"))
    and (.system.lingering.min_age_seconds == 86400)
    and (.system.upgradable_packages == 1)
  ' <<<"$JSON"
}

@test "a process named after an agent CLI is counted as that agent's session" {
  needs_jq
  fake_agent claude
  mkdir -p "$SB/work"
  detached "$SB/work" "$SB/bin/claude" 30
  local pid=$DETACHED
  status_json
  jq -e --argjson p "$pid" --arg d "$SB/work" '.system.agents.sessions
    | any(.pid == $p and .agent == "Claude Code" and .process == "claude" and (.orphan | not)
      and .cwd == $d and (.busy | not))' <<<"$JSON"
  jq -e '.system.agents.count >= 1' <<<"$JSON"
}

@test "an agent CLI run by an interpreter (python3 .../gemini) is counted by its script name" {
  needs_jq
  needs_python
  printf 'import time\ntime.sleep(30)\n' >"$SB/bin/gemini"
  detached "$SB" python3 "$SB/bin/gemini"
  local pid=$DETACHED
  [ "$(cat "/proc/$pid/comm")" = python3 ]
  status_json
  jq -e --argjson p "$pid" '.system.agents.sessions | any(.pid == $p and .agent == "Gemini CLI")' <<<"$JSON"
}

@test "a tool from the user's agents file is counted as an agent session; a bad row is reported on stderr" {
  needs_jq
  mkdir -p "$HOME/.config/marmot" "$SB/work"
  printf '%s\n' 'My Tool|mytool|~/.mytool' 'Bad|claude|/etc' >"$HOME/.config/marmot/agents"
  fake_agent mytool
  detached "$SB/work" "$SB/bin/mytool" 30
  local pid=$DETACHED err="$BATS_TEST_TMPDIR/err"
  JSON=$(mm status --json 2>"$err")
  jq -e --argjson p "$pid" '.system.agents.sessions | any(.pid == $p and .agent == "My Tool" and .process == "mytool")' <<<"$JSON"
  grep -F 'agents row ignored: ~/.config/marmot/agents:2: ' "$err"
}

@test "a session is the top-level agent: its tree's CPU and memory count, sub-agents are not extra" {
  needs_jq
  fake_agent codex
  mkdir -p "$HOME/proj/idle" "$HOME/proj/busy"
  detached "$HOME/proj/idle" "$SB/bin/codex" 30
  local idle=$DETACHED
  # A busy session: the agent itself sleeps; a child it started burns CPU; a sub-agent runs too.
  printf '#!/bin/bash\nbash -c "while :; do :; done" &\n%s 30 &\nwait\n' "$SB/bin/codex" >"$SB/bin/claude"
  chmod +x "$SB/bin/claude"
  detached "$HOME/proj/busy" "$SB/bin/claude"
  local busy=$DETACHED sub
  for _ in 1 2 3 4 5 6 7 8 9 10; do sub=$(mm_test_pids --parent "$busy" --comm codex); [[ -n "$sub" ]] && break; sleep 0.1; done
  [ -n "$sub" ]
  status_json
  jq -e --argjson b "$busy" --argjson i "$idle" --argjson s "$sub" '.system.agents.sessions as $all
    | ($all | map(.pid) | index($b)) as $bi | ($all | map(.pid) | index($i)) as $ii
    | $bi != null and $ii != null and $bi < $ii
      and ($all[$bi] | .busy and .cpu_percent >= 2 and .rss_swap_bytes > 0)
      and ($all[$ii] | (.busy | not))
      and ($all | all(.pid != $s))' <<<"$JSON"
  run mm status --once
  # Busy sorts first, so this row is shown whatever else runs on the host.
  grep -E "claude +~/proj/busy .* busy " <<<"$output"
}

@test "a session's memory counts pages its processes share once (proportional, not RSS)" {
  needs_jq
  needs_python
  # 128 MiB written, then forked: parent and child each have it resident, shared copy-on-write.
  cat >"$SB/bin/hog.py" <<'EOF'
import os, sys, time
b = bytearray(b"\x01") * (128 << 20)
os.fork()
open("%s.%d" % (sys.argv[1], os.getpid()), "w").close()
time.sleep(30)
EOF
  printf '#!/bin/bash\npython3 %q %q &\nwait\n' "$SB/bin/hog.py" "$SB/ready" >"$SB/bin/claude"
  chmod +x "$SB/bin/claude"
  detached "$SB" "$SB/bin/claude"
  local agent=$DETACHED p rss=0 n
  for _ in $(seq 50); do n=$(compgen -G "$SB/ready.*" | wc -l); ((n == 2)) && break; sleep 0.1; done
  [ "$n" -eq 2 ]
  for p in $(mm_test_pids --cmdline-has "$SB/bin/hog.py"); do rss=$((rss + $(awk '/^VmRSS:/ { print $2 }' "/proc/$p/status"))); done
  # The premise: summed RSS counts the shared 128 MiB twice.
  ((rss >= 256 * 1024))
  status_json
  jq -e --argjson a "$agent" '.system.agents.sessions[] | select(.pid == $a)
    | .rss_swap_bytes >= 128 * 1048576 and .rss_swap_bytes < 192 * 1048576' <<<"$JSON"
}

@test "agent rows fit the width whatever the age and CPU (10h 37m, over 999%)" {
  mm_core
  # shellcheck source=../cmd/status.sh
  . "$MM_SRC/cmd/status.sh"
  local t=$'\t' row
  ST_PANEL=()
  ST_AGENTS=("101${t}Claude Code${t}claude${t}38220${t}2306867${t}0${t}10930${t}1${t}/srv/agents/a-rather-long-project-folder/with/depth"
             "102${t}Codex CLI${t}codex${t}120${t}102400${t}0${t}5${t}0${t}/srv/x")
  _status_agent_rows "  " 80 5 8
  [ "${#ST_PANEL[@]}" -eq 2 ]
  for row in "${ST_PANEL[@]}"; do
    (( ${#row} <= 80 )) || { echo "too wide (${#row}): $row"; false; }
  done
  [[ "${ST_PANEL[0]}" == *" 10h 37m "*"1093% "* ]]
  [[ "${ST_PANEL[1]}" == *" 2m "* ]]
}

@test "an agent whose working directory was deleted is an orphan and costs health" {
  needs_jq
  fake_agent codex
  mkdir -p "$SB/gone"
  detached "$SB/gone" "$SB/bin/codex" 30
  local pid=$DETACHED
  rm -r -- "$SB/gone"
  status_json
  jq -e --argjson p "$pid" --arg d "$SB/gone" '
    (.system.orphans | any(.pid == $p and .kind == "agent" and .deleted_cwd == $d))
    and (.system.agents.sessions | any(.pid == $p and .orphan))
    and (.system.agents.orphan_count >= 1)
    and (.health_reasons | any(test("orphan")))' <<<"$JSON"
  run mm status --once
  grep -E "orphan +codex $pid in deleted " <<<"$output"
}

@test "a dev server in a deleted directory past the linger age is a lingering orphan" {
  needs_jq
  needs_python
  mkdir -p "$SB/old-worktree"
  detached "$SB/old-worktree" python3 -m http.server 0 --bind 127.0.0.1
  local pid=$DETACHED
  rm -r -- "$SB/old-worktree"
  status_json MM_STATUS_LINGER_AGE=0
  jq -e --argjson p "$pid" '
    (.system.lingering.processes | any(.pid == $p and .orphan))
    and (.system.orphans | any(.pid == $p and .kind == "lingering"))' <<<"$JSON"
}

@test "a listener older than the linger age shows in ports; a younger one does not" {
  needs_jq
  needs_python
  detached "$SB" python3 -m http.server 0 --bind 127.0.0.1
  local pid=$DETACHED
  listening "$pid"
  status_json MM_STATUS_LINGER_AGE=0
  jq -e --argjson p "$pid" '
    (.system.listening_ports.ports | any(.pid == $p and .address == "127.0.0.1" and .port > 0 and (.name | test("python"))))
    and (.system.listening_ports.min_age_seconds == 0)
    and (.system.lingering.processes | any(.pid == $p))' <<<"$JSON"
  run env MM_STATUS_LINGER_AGE=0 mm status --once --view full
  [[ "$output" == *"listening >0s · oldest"* ]]
  status_json
  jq -e --argjson p "$pid" '
    (.system.listening_ports.ports | all(.pid != $p))
    and (.system.listening_ports.total_listening >= 1)
    and (.system.lingering.processes | all(.pid != $p))' <<<"$JSON"
}

@test "a dev server started by a live agent belongs to its session, not to lingering" {
  needs_jq
  needs_python
  printf '#!/bin/bash\npython3 -m http.server 0 --bind 127.0.0.1 &\nwait\n' >"$SB/bin/claude"
  chmod +x "$SB/bin/claude"
  detached "$SB" "$SB/bin/claude"
  local agent=$DETACHED child
  [ "$(cat "/proc/$agent/comm")" = claude ]
  for _ in 1 2 3 4 5 6 7 8 9 10; do child=$(mm_test_pids --parent "$agent" --comm python3); [[ -n "$child" ]] && break; sleep 0.1; done
  [ -n "$child" ]
  listening "$child"
  status_json MM_STATUS_LINGER_AGE=0
  jq -e --argjson a "$agent" --argjson c "$child" '
    (.system.agents.sessions | any(.pid == $a))
    and (.system.lingering.processes | all(.pid != $c))
    and (.system.listening_ports.ports | any(.pid == $c))' <<<"$JSON"
}

# fake_omp_helpers — oh-my-pi's helpers as lib/agents.sh describes them, beside a real session.
# "omp" is a copy of bash (comm omp) running the script its argv[1] names:
#   MUX     `omp __omp_worker_lsp_mux` with a child dev process (a copy of sleep named tsc, pid
#           in TSC);
#   DAEMON  a copy of sleep named omp working in ~/.omp/run/daemons/global/text-predict;
#   SESSION `omp -c …` working in a project folder, which started INNER, its own
#           `omp __omp_worker_daemon_broker` (blocked on a FIFO).
fake_omp_helpers() {
  mkdir -p "$SB/omp" "$SB/proj" "$SB/work" "$HOME/.omp/run/daemons/global/text-predict"
  cp "$(command -v bash)" "$SB/omp/omp"
  fake_agent omp
  cp "$(command -v sleep)" "$SB/bin/tsc"
  printf '%q 30 &\nwait\n' "$SB/bin/tsc" >"$SB/proj/__omp_worker_lsp_mux"
  detached "$SB/proj" "$SB/omp/omp" __omp_worker_lsp_mux
  MUX=$DETACHED
  for _ in 1 2 3 4 5 6 7 8 9 10; do TSC=$(mm_test_pids --parent "$MUX" --comm tsc); [[ -n "$TSC" ]] && break; sleep 0.1; done
  [ -n "$TSC" ]
  detached "$HOME/.omp/run/daemons/global/text-predict" "$SB/bin/omp" 30
  DAEMON=$DETACHED
  mkfifo "$SB/work/fifo"
  printf 'read -r _ <>fifo\n' >"$SB/work/__omp_worker_daemon_broker"
  detached "$SB/work" "$SB/omp/omp" -c "$SB/omp/omp __omp_worker_daemon_broker & wait"
  SESSION=$DETACHED
  for _ in 1 2 3 4 5 6 7 8 9 10; do INNER=$(mm_test_pids --parent "$SESSION" --comm omp); [[ -n "$INNER" ]] && break; sleep 0.1; done
  [ -n "$INNER" ]
  [ "$(cat "/proc/$MUX/comm" "/proc/$DAEMON/comm" "/proc/$SESSION/comm" "/proc/$INNER/comm" | sort -u)" = omp ]
}

@test "an agent's own helpers are not sessions: a helpers line counts them and what they started" {
  needs_jq
  fake_omp_helpers
  status_json MM_STATUS_LINGER_AGE=0
  jq -e --argjson m "$MUX" --argjson d "$DAEMON" --argjson s "$SESSION" --argjson i "$INNER" --argjson t "$TSC" '
    .system.agents as $a
    | ($a.sessions | any(.pid == $s and .agent == "oh-my-pi" and .process == "omp"))
    and ($a.sessions | all(.pid != $m and .pid != $d and .pid != $i and .pid != $t))
    and ($a.count == ($a.sessions | length))
    and ($a.helpers | any(.pid == $m and .agent == "oh-my-pi" and .process == "omp"
      and .kind == "__omp_worker_lsp_mux" and .rss_swap_bytes > 0))
    and ($a.helpers | any(.pid == $d and .kind == "text-predict"))
    and ($a.helpers | any(.pid == $i and .kind == "__omp_worker_daemon_broker"))
    and ($a.helper_count == ($a.helpers | length)) and $a.helper_count >= 3
    and ($a.helper_rss_swap_bytes == ($a.helpers | map(.rss_swap_bytes) | add))
    and (.system.lingering.processes | all(.pid != $t))' <<<"$JSON"
  run env MM_STATUS_LINGER_AGE=0 mm status --agent
  [ "$status" -eq 0 ]
  grep -E "^  omp $SESSION " <<<"$output"
  [ "$(grep -cE "^  omp ($MUX|$DAEMON|$INNER) " <<<"$output")" -eq 0 ]
  grep -E '^agent helpers: omp [0-9]+ · [0-9.]+[KMG]B$' <<<"$output"
  [[ "$output" != *"(pid $TSC)"* ]]
  run env MM_STATUS_LINGER_AGE=0 mm status --once
  grep -E '^  omp helpers · [0-9]+ · [0-9.]+[KMG]B$' <<<"$output"
  [[ "$output" != *"tsc $TSC"* ]]
  run env MM_STATUS_LINGER_AGE=0 COLUMNS=120 mm status --once --view full
  grep -E '^omp helpers · [0-9]+ · [0-9.]+[KMG]B$' <<<"$output"
}

@test "a helper that retitled itself (omp daemon brok) is known by argv[0] and heads its tree" {
  needs_jq
  needs_python
  cp "$(command -v sleep)" "$SB/bin/tsc"
  mkdir -p "$SB/brk"
  cat >"$SB/brk/__omp_worker_daemon_broker" <<EOF
import ctypes, subprocess, time
ctypes.CDLL(None).prctl(15, b"omp daemon brok", 0, 0, 0)
subprocess.Popen(["$SB/bin/tsc", "30"])
time.sleep(30)
EOF
  detached "$SB/brk" bash -c 'exec -a omp python3 __omp_worker_daemon_broker'
  local broker=$DETACHED tsc
  for _ in 1 2 3 4 5 6 7 8 9 10; do tsc=$(mm_test_pids --parent "$broker" --comm tsc); [[ -n "$tsc" ]] && break; sleep 0.1; done
  [ -n "$tsc" ]
  [ "$(cat "/proc/$broker/comm")" = "omp daemon brok" ]
  status_json MM_STATUS_LINGER_AGE=0
  jq -e --argjson b "$broker" --argjson t "$tsc" '
    (.system.agents.helpers | any(.pid == $b and .kind == "__omp_worker_daemon_broker"))
    and (.system.agents.sessions | all(.pid != $b))
    and (.system.lingering.processes | all(.pid != $t))' <<<"$JSON"
}

@test "no VPN rows when no VPN interface exists; an existing one gets a row" {
  needs_jq
  status_json MM_STATUS_VPN_IFACES='no-such-vpn*'
  jq -e '.network | all(.kind != "vpn")' <<<"$JSON"
  run env MM_STATUS_VPN_IFACES='no-such-vpn*' mm status --once --view full
  [ "$(grep -cE '^VPN ' <<<"$output")" -eq 0 ]
  # lo always exists and is up: treating it as a VPN proves rows follow what is detected.
  status_json MM_STATUS_VPN_IFACES=lo
  jq -e '.network | any(.interface == "lo" and .kind == "vpn" and (.default_route | not))' <<<"$JSON"
  run env MM_STATUS_VPN_IFACES=lo mm status --once --view full
  grep -qE '^VPN +lo ' <<<"$output"
}

@test "root inodes at 95% cost health; at 85% they only warn" {
  needs_jq
  mm_test_fake df 'printf "Mounted on 1B-blocks Used Avail Inodes IUsed\n/ 1000 100 900 1000 ${MM_FAKE_IUSED:-950}\n"'
  status_json
  jq -e '(.disks[] | select(.mount == "/") | .inodes_used_percent == 95)
    and (.health_reasons | any(test("inodes")))
    and .health_score <= 80' <<<"$JSON"
  status_json MM_FAKE_IUSED=850
  jq -e '.health_reasons | all(test("inodes") | not)' <<<"$JSON"
}

@test "a full disk names its fix in the compact, full and --agent views" {
  mm_test_fake df 'printf "Mounted on 1B-blocks Used Avail Inodes IUsed\n/ 1000 910 90 1000 0\n"'
  run env COLUMNS=80 mm status --once
  [ "$status" -eq 0 ]
  grep -qF "→ mm clean --dry-run, then mm purge --dry-run" <<<"$output"
  run env COLUMNS=120 mm status --once --view full
  grep -qF "→ mm clean --dry-run, then mm purge --dry-run" <<<"$output"
  run env -u NO_COLOR mm status --agent
  grep -qxF -- "- disk / 91% full: mm clean --dry-run, then mm purge --dry-run" <<<"$output"
}

@test "no fix is named while the disk has room" {
  mm_test_fake df 'printf "Mounted on 1B-blocks Used Avail Inodes IUsed\n/ 1000 100 900 1000 0\n"'
  run env COLUMNS=80 mm status --once
  [[ "$output" != *"→ mm clean"* ]]
  run env -u NO_COLOR mm status --agent
  [[ "$output" != *"disk / "* ]]
}

@test "marmot's own processes never make the top CPU or memory lists" {
  needs_jq
  # The apt probe runs under mm status: make it the busiest process on the machine while sampled.
  mm_test_fake apt "echo \$\$ >'$BATS_TEST_TMPDIR/apt.pid'
end=\$((SECONDS + 2)); while ((SECONDS < end)); do :; done"
  status_json
  local pid
  pid=$(<"$BATS_TEST_TMPDIR/apt.pid")
  jq -e --argjson p "$pid" '[.processes.top_cpu[], .processes.top_memory[] | .pid] | all(. != $p)' <<<"$JSON"
}

@test "sparklines hold only the samples taken so far: no padding gap before them" {
  status_lib '_status_init; _status_first 0; _status_sample; _status_derive; _status_frame_full 80
    _status_cleanup; printf "%s\n" "${ST_FRAME[@]}"'
  [ "$status" -eq 0 ]
  local rows
  rows=$(grep -E '^(Trend|Down|Up) ' <<<"$output")
  grep -q '[▁▂▃▄▅▆▇█]' <<<"$rows"
  [ "$(grep -cE ' {6,}[▁▂▃▄▅▆▇█]' <<<"$rows")" -eq 0 ]
}

@test "top processes working under HOME are named with their project folder" {
  mkdir -p "$HOME/src/alpha/beta"
  mm_test_bg "$HOME/src/alpha/beta" bash -c 'while :; do :; done'
  local pid=${MM_TEST_PIDS[-1]}
  run mm status --once --view full
  [ "$status" -eq 0 ]
  grep -E "bash \(alpha/beta\) +$pid " <<<"$output"
}

@test "live mode: refreshes rewrite only changed rows, the footer ends its line, q quits" {
  # Room for every panel and no client link coming and going: rows only change by their values.
  fake_ss "$LISTEN_SSH" ""
  LIVE_ROWS=70 live 'sleep 5; printf q' --view full
  # 124 would mean q did not quit before the timeout.
  [ "$LIVE_STATUS" -eq 0 ]
  # The CPU trend grows every refresh, so it is rewritten each time: several frames were drawn.
  [ "$(grep -c '^Trend ' <<<"$LIVE_TEXT")" -ge 2 ]
  # A panel title never changes: written by the first frame, again only if the layout shifts
  # (the header gains a health reason under load), never on every refresh.
  [ "$(grep -c '⚙ CPU' <<<"$LIVE_TEXT")" -lt "$(grep -c '^Trend ' <<<"$LIVE_TEXT")" ]
  [ "$(grep -c 'q quit' <<<"$LIVE_TEXT")" -ge 1 ]
  # Stripped of escapes, a footer glued to whatever is written next reads "...5mmm status".
  [ "$(grep -cE 'q quit.*(mm status|Trend|Total)' <<<"$LIVE_TEXT")" -eq 0 ]
}

@test "painting: unchanged rows are skipped, leftover rows cleared, a resize repaints all" {
  status_lib '
    ST_INTERVAL=1
    ST_FRAME=(a b c d e) ST_REPAINT=1; _status_paint >/dev/null
    ST_FRAME=(a B c); _status_paint >"$HOME/shrink"
    _status_paint >"$HOME/same"
    _status_init; _status_first 0
    COLUMNS=100 LINES=40 _status_draw >/dev/null
    COLUMNS=100 LINES=40 _status_draw >"$HOME/again"
    COLUMNS=80 LINES=40 _status_draw >"$HOME/resized"
    _status_cleanup'
  [ "$status" -eq 0 ]
  # Only row 2 changed: rewritten; rows 4 and 5 are no longer used: cleared.
  [ "$(<"$HOME/shrink")" = $'\e[2;1HB\e[K\n\e[4;1H\e[K\e[5;1H\e[K' ]
  [ ! -s "$HOME/same" ]
  [ ! -s "$HOME/again" ]
  [[ "$(<"$HOME/resized")" == $'\e[H\e[2J'* ]]
}

@test "client: the inbound peer to a listening port; loopback, outbound and local-only ports ignored" {
  needs_jq
  local conns
  conns=$(conn 10.0.0.5:22 203.0.113.7:51234 'rtt:23.5/4.1 retrans:0/3 lastrcv:500 minrtt:21.2'
    conn 10.0.0.5:22 127.0.0.1:40000 'rtt:0.1/0.05 lastrcv:1 minrtt:0.1'
    conn 10.0.0.5:5432 203.0.113.8:5555 'rtt:5/1 lastrcv:2 minrtt:5'
    conn 10.0.0.5:40001 203.0.113.9:443 'rtt:9/1 lastrcv:3 minrtt:9')
  fake_ss "$LISTEN_SSH" "$conns"
  status_json "${NO_SSH[@]}"
  jq -e '.client == { address: "203.0.113.7", name: null, path: null, rtt_ms: 23.5, min_rtt_ms: 21.2,
    rttvar_ms: 4.1, retrans_delta: 0, laggy: false, via: null, transport: "direct", tty: null,
    last_input_seconds: null }' <<<"$JSON"
  fake_ss "$LISTEN_SSH" "$conns"
  run env "${NO_SSH[@]}" mm status --once
  [[ "$output" == *"203.0.113.7"*"rtt 24 ms (best 21)"* && "$output" != *laggy* ]]
}

@test "client: high RTT, jittery RTT or new retransmits flag a laggy link without costing health" {
  needs_jq
  local calm laggy
  calm=$(conn 10.0.0.5:22 203.0.113.7:51234 'rtt:20/2 retrans:0/50 lastrcv:5 minrtt:18')
  fake_ss "$LISTEN_SSH" "$calm"
  status_json "${NO_SSH[@]}"
  jq -e '.client.laggy == false and .client.retrans_delta == 0' <<<"$JSON"
  # Lifetime retransmits do not count; ones since the previous sample do.
  fake_ss "$LISTEN_SSH" "$calm" "$(conn 10.0.0.5:22 203.0.113.7:51234 'rtt:20/2 retrans:0/55 lastrcv:5 minrtt:18')"
  status_json "${NO_SSH[@]}"
  jq -e '.client.laggy and .client.retrans_delta == 5' <<<"$JSON"
  # "Without costing health": no health reason is about the link. (The score itself is not compared
  # across runs: it moves with the host's own load between two samples.)
  for laggy in 'rtt:435.2/30 lastrcv:5 minrtt:21' 'rtt:60/120 lastrcv:5 minrtt:21'; do
    fake_ss "$LISTEN_SSH" "$(conn 10.0.0.5:22 203.0.113.7:51234 "$laggy")"
    status_json "${NO_SSH[@]}"
    jq -e '.client.laggy and (.health_reasons | all(test("link|rtt|lag") | not))' <<<"$JSON"
  done
  fake_ss "$LISTEN_SSH" "$(conn 10.0.0.5:22 203.0.113.7:51234 'rtt:435.2/30 lastrcv:5 minrtt:21')"
  run env "${NO_SSH[@]}" mm status --once
  [[ "$(head -3 <<<"$output")" == *"link to you is laggy"* ]]
}

@test "client: SSH_CONNECTION's address wins over more recent peers, even without TCP stats" {
  needs_jq
  fake_ss "$LISTEN_SSH" "$(conn 10.0.0.5:22 203.0.113.7:51234 'rtt:20/2 lastrcv:5 minrtt:18'
    conn 10.0.0.5:22 198.51.100.4:60000 'rtt:80/5 lastrcv:900 minrtt:70')"
  status_json SSH_CONNECTION='198.51.100.4 60000 10.0.0.5 22'
  jq -e '.client.address == "198.51.100.4" and .client.rtt_ms == 80 and .client.transport == "ssh"' <<<"$JSON"
  status_json -u SSH_CONNECTION SSH_CLIENT='198.51.100.4 60000 22'
  jq -e '.client.address == "198.51.100.4"' <<<"$JSON"
  status_json SSH_CONNECTION='192.0.2.1 1234 10.0.0.5 22'
  jq -e '.client.address == "192.0.2.1" and .client.rtt_ms == null and (.client.laggy | not)' <<<"$JSON"
}

@test "client: a Tailscale peer is named, with its path; no terminal and no inbound peer is none" {
  needs_jq
  mm_test_fake tailscale 'printf "%s\n" "{\"Peer\": {\"n1\": {\"HostName\": \"laptop\",
    \"TailscaleIPs\": [\"100.101.102.103\", \"fd7a:115c:a1e0::1\"], \"CurAddr\": \"\", \"Relay\": \"fra\"}}}"'
  fake_ss "$LISTEN_SSH" "$(conn 100.88.0.2:22 100.101.102.103:50000 'rtt:30/3 lastrcv:5 minrtt:25')"
  status_json "${NO_SSH[@]}"
  jq -e '.client | .name == "laptop" and .path == "Tailscale relay fra"' <<<"$JSON"
  fake_ss "$LISTEN_SSH" "$(conn 10.0.0.5:40001 203.0.113.9:443 'rtt:9/1 lastrcv:3 minrtt:9')"
  status_json "${NO_SSH[@]}"
  jq -e '.client | .transport == "none" and .address == null and .via == null and .tty == null
    and .last_input_seconds == null and (.laggy | not)' <<<"$JSON"
  fake_ss "$LISTEN_SSH" ""
  run env "${NO_SSH[@]}" mm status --once
  grep -E '^YOU +no terminal \(run from a script\)$' <<<"$output"
  [[ "$output" != *"no remote session"* ]]
  run env "${NO_SSH[@]}" mm status --agent
  grep -xF 'client: none (no terminal: run from a script)' <<<"$output"
}

@test "client: inside a terminal of its own (script), the link is a local terminal via script" {
  needs_jq
  command -v script >/dev/null || skip "script(1) not installed"
  local out
  # jq colors its output on a terminal: strip that.
  out=$(script -qfec "env -u MM_TEST_NO_TTY mm status --json" /dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')
  jq -e '.client | .transport == "local" and .via == "script" and (.tty | test("^/dev/pts/[0-9]+$"))
    and (.last_input_seconds | type == "number" and . >= 0) and .address == null and .rtt_ms == null
    and (.laggy | not)' <<<"$out"
  out=$(script -qfec "env -u MM_TEST_NO_TTY COLUMNS=100 mm status --once" /dev/null | tr -d '\r')
  grep -E '^YOU +local terminal \(script\)$' <<<"$out"
  out=$(script -qfec "env -u MM_TEST_NO_TTY mm status --agent" /dev/null | tr -d '\r')
  grep -E '^client: local terminal \(script\) · last input (<10s|[0-9]+s)$' <<<"$out"
}

@test "client: a terminal host marmot has no label for is shown under its process name" {
  needs_jq
  command -v script >/dev/null || skip "script(1) not installed"
  cp "$(command -v script)" "$SB/bin/myterm"
  local out
  out=$("$SB/bin/myterm" -qfec "env -u MM_TEST_NO_TTY mm status --json" /dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')
  jq -e '.client | .transport == "local" and .via == "myterm"' <<<"$out"
}

@test "client: the terminal host's own sockets decide direct, relay, udp or local; sshd and mosh name the peer" {
  local conns udp
  conns=$(conn 10.0.0.5:22 203.0.113.7:51234 'rtt:23.5/4.1 lastrcv:5 minrtt:21.2' 101
    conn 10.0.0.5:40001 203.0.113.9:443 'rtt:9/1 lastrcv:3 minrtt:9' 202
    conn 10.0.0.5:40002 10.0.0.5:8080 'rtt:1/1 lastrcv:3 minrtt:1' 303
    conn 10.0.0.5:40003 127.0.0.1:5432 'rtt:1/1 lastrcv:3 minrtt:1' 404
    conn 10.0.0.5:22 198.51.100.4:60000 'rtt:80/5 lastrcv:900 minrtt:70' 707)
  udp='UNCONN 0      0            0.0.0.0:60001      0.0.0.0:* uid:1000 ino:505 sk:2
UNCONN 0      0          127.0.0.1:60002      0.0.0.0:* uid:1000 ino:606 sk:3'
  fake_ss "$LISTEN_SSH" "$conns" "$conns" "$udp"
  status_lib 'ST_SS=1
    declare -A ST_CL_PREV=()
    c() {
      ST_CL_ADDR="" ST_CL_RTT=""
      _status_classify "$@"
      echo "$2: $ST_CL_TRANSPORT ${ST_CL_ADDR:--} ${ST_CL_RTT:--}"
    }
    c host ttyd "" 202 101
    c host tern "" 202 606
    c host app "" 303 404
    c host app "" 505
    c host app "" 606
    c host app ""
    c host sshd "198.51.100.4 60000 10.0.0.5 22"
    c host sshd-session "203.0.113.7 51234 10.0.0.5 22" 101
    c host mosh-server "198.51.100.4 60000 10.0.0.5 22"
    c any "" ""'
  [ "$status" -eq 0 ]
  [ "$output" = "ttyd: direct 203.0.113.7 23.5
tern: relay - -
app: local - -
app: udp - -
app: local - -
app: local - -
sshd: ssh 198.51.100.4 80
sshd-session: ssh 203.0.113.7 23.5
mosh-server: udp 198.51.100.4 -
: direct 203.0.113.7 23.5" ]
}

@test "client: a tmux pane is followed to the server's most recently active client" {
  mm_test_fake tmux "printf '%s\n' \"\$*\" >'$BATS_TEST_TMPDIR/tmux.args'
printf '101 /dev/pts/7 1700000300\n102 /dev/pts/8 1700000900\n103 /dev/pts/9 1700000100\n'"
  # The pane's shell names the server's socket in TMUX.
  TMUX="$SB/tmux-sock,4242,0"
  export TMUX
  mm_test_bg "$SB" sleep 30
  unset TMUX
  local pane=${MM_TEST_PIDS[-1]}
  status_lib "_status_tmux_client $pane && echo \"\$REPLY\""
  [ "$status" -eq 0 ]
  [ "$output" = "102 /dev/pts/8" ]
  [[ "$(<"$BATS_TEST_TMPDIR/tmux.args")" == "-S $SB/tmux-sock list-clients -F "* ]]
}

@test "client: who and how, in one line through a relay, with the round trip when measured" {
  status_lib 'ST_SS=1 ST_RTTH=()
    show() { _status_you_lines 100; printf "%s\n" "${ST_YOU[@]}"; }
    ST_CL_TRANSPORT=relay ST_CL_VIA=tern ST_CL_ADDR="" ST_CL_RTT="" ST_CL_IDLE=3 ST_CL_TTY=/dev/pts/2
    show
    ST_CL_IDLE=42; show
    ST_CL_TRANSPORT=ssh ST_CL_VIA=SSH ST_CL_ADDR=203.0.113.7 ST_CL_NAME=laptop ST_CL_PATH="Tailscale direct"
    ST_CL_RTT=23.5 ST_CL_MIN=21.2 ST_CL_VAR=4 ST_CL_RETR=0 ST_CL_LAGGY=0 ST_CL_IDLE=2
    show
    ST_CL_TRANSPORT=local ST_CL_VIA=script; show
    ST_CL_VIA=console; show'
  [ "$status" -eq 0 ]
  [ "$output" = "via tern · relay · last input <10 s ago · round trip not measurable through a relay
via tern · relay · last input 42 s ago · round trip not measurable through a relay
via SSH · 203.0.113.7 laptop · Tailscale direct
rtt 24 ms (best 21) · last input <10 s ago
local terminal (script)
local console" ]
}

@test "checks: all fine is one line of ✓ items, pending updates a note there, not a problem" {
  mm_test_fake docker 'printf "running\nexited\n"'
  mm_test_fake dpkg-query 'exit 0'
  mm_test_fake unattended-upgrade 'exit 0'
  run mm status --once --view full
  [ "$status" -eq 0 ]
  local row
  row=$(grep -E '^Checks ' <<<"$output")
  if [[ -d /run/systemd/system ]]; then
    [[ "$row" == *"✓ kernel"*"✓ units"*"✓ docker"*"✓ unattended"*"1 update"* ]]
  else   # no systemd (containers): no unit or unattended-upgrades checks at all
    [[ "$row" == *"✓ kernel"*"✓ docker"*"1 update"* ]]
    [[ "$row" != *units* && "$row" != *unattended* ]]
  fi
  # The reboot flag is the host's own file: whichever way it is, it is reported.
  if [[ -e /var/run/reboot-required ]]; then grep -E '! reboot required.*: sudo reboot$' <<<"$output"
  else [[ "$row" == *"✓ reboot"* ]]; fi
  [ "$(grep -cE '! .*(kernel|unit|docker|unattended)' <<<"$output")" -eq 0 ]
}

@test "checks: each problem gets its own line with the command that addresses it" {
  mm_test_fake systemctl '[[ "$1" == is-active ]] && { echo inactive; exit 3; }
[[ "$1" == --failed ]] && echo "foo.service loaded failed failed Foo"
exit 0'
  mm_test_fake dpkg-query 'printf "ii  linux-image-99.0.0-1-generic\n"'
  mm_test_fake unattended-upgrade 'exit 0'
  run mm status --once --view full
  [ "$status" -eq 0 ]
  if [[ -d /run/systemd/system ]]; then
    grep -E '^ +! 1 failed unit: foo\.service: systemctl --failed$' <<<"$output"
    # Too long for one 80-column line: the command follows on the next line, whole.
    grep -A1 -E '^ +! unattended-upgrades inactive:' <<<"$output" | grep -E ' sudo systemctl enable --now unattended-upgrades$'
  fi
  grep -E '^ +! kernel 99\.0\.0-1 installed, running .*: sudo reboot$' <<<"$output"
  grep -E '^ +! docker daemon not reachable: docker info$' <<<"$output"
  [ "$(grep -cE '✓ (kernel|units|docker|unattended)' <<<"$output")" -eq 0 ]
}

@test "without a terminal, plain 'mm status' prints the agent format once and exits" {
  run mm status </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == "health: "*$'\n'"problems"* && "$output" == *$'\nagents: '* ]]
  [[ "$output" != *AGENTS* && "$output" != *$'\e'* ]]
  # --once stays the human snapshot.
  run mm status --once </dev/null
  [[ "$output" == *AGENTS* && "$output" == *CHECKS* && "$output" != *"problems:"* ]]
}

@test "--agent: plain text, problems first with their command, under 60 lines" {
  fake_agent codex
  mkdir -p "$SB/gone"
  detached "$SB/gone" "$SB/bin/codex" 30
  local pid=$DETACHED
  rm -r -- "$SB/gone"
  run env -u NO_COLOR mm status --agent
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e'* && "$output" != *[█░▁▂▃▄▅▆▇▮▯]* ]]
  [ "${#lines[@]}" -lt 60 ]
  # Problems come before everything but the health line; the orphan names its fix.
  [[ "${lines[0]}" == "health: "* && "${lines[1]}" == "problems:" ]]
  local probs
  probs=$(sed -n '/^problems:/,/^machine:/p' <<<"$output")
  grep -E "^- orphaned agent codex \(pid $pid\) in deleted .*: mm optimize$" <<<"$probs"
  # Every section after them is a stable "key: value" line or an indented table row.
  [ "$(sed -n '/^machine:/,$p' <<<"$output" | grep -cvE '^([a-z][a-z />0-9]*: |  )')" -eq 0 ]
  # On a terminal too: --agent never colors.
  if command -v script >/dev/null; then
    [[ "$(script -qfec 'env -u NO_COLOR TERM=xterm-256color mm status --agent' /dev/null)" != *$'\e'* ]]
  fi
}

@test "views: compact is the default, agents first, fitting 80 columns; full has every panel" {
  run env COLUMNS=80 mm status --once
  [ "$status" -eq 0 ]
  local labels line
  labels=$(grep -oE '^(AGENTS|YOU|CPU|MEM|DISK|NET|CHECKS|TOP) ' <<<"$output" | tr -d ' ' | paste -sd' ')
  [ "$labels" = "AGENTS YOU CPU MEM DISK NET CHECKS TOP" ]
  while IFS= read -r line; do ((${#line} <= 80)) || { echo "too wide: $line"; false; }; done <<<"$output"
  run env COLUMNS=80 mm status --once --view full
  [[ "$output" == *"⚙ CPU"* && "$output" == *"◆ System"* && "$output" != *"CHECKS "* ]]
  run mm status --once --view nope
  [ "$status" -ne 0 ]
}

@test "views: the compact agent list gives way to the terminal height with '… N more'" {
  local i
  fake_agent codex
  for i in 1 2 3 4 5 6; do mkdir -p "$SB/w$i"; detached "$SB/w$i" "$SB/bin/codex" 30; done
  status_lib '_status_init; _status_first 0; _status_frame_compact 80 14; _status_cleanup
    printf "%s\n" "${ST_FRAME[@]}"'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -le 14 ]
  [[ "$output" == *"… "*" more"* && "$output" == *TOP* ]]
}

@test "views: a short terminal drops the marmot before any agent session" {
  local i
  fake_agent codex
  for i in 1 2 3; do mkdir -p "$SB/w$i"; detached "$SB/w$i" "$SB/bin/codex" 30; done
  status_lib '_status_init; _status_first 0
    _status_frame_compact 80; printf "%s\n" "${ST_FRAME[@]}" >"$HOME/tall"
    _status_frame_compact 80 $((${#ST_FRAME[@]} - 1)); printf "%s\n" "${ST_FRAME[@]}" >"$HOME/short"
    _status_cleanup'
  [ "$status" -eq 0 ]
  [[ "$(<"$HOME/tall")" == *"--(mm)--UU--(mm)--"* ]]
  [[ "$(<"$HOME/short")" != *"(mm)--UU--(mm)"* && "$(<"$HOME/short")" != *" more"* ]]
  # Both frames list every agent session on the machine, not only these three.
  local n
  n=$(grep -cE '^  codex ' "$HOME/tall")
  [ "$n" -ge 3 ]
  [ "$(grep -cE '^  codex ' "$HOME/short")" -eq "$n" ]
}

# at DATE — epoch of DATE (local time), for ST_NOW.
at() { date -d "$1" +%s; }

@test "the marmot's face: health first, then a busy CPU, any health reason, then agents at work" {
  status_lib '
    ST_NOW='"$(at '2026-06-10 12:00')"'
    work=$(printf "1\tclaude\tclaude\t60\t9\t0\t300\t1\t/w") wait=$(printf "2\tcodex\tcodex\t60\t9\t0\t0\t0\t/w")
    face() { ST_SCORE=$1 ST_CPUH=($2) ST_REASONS=(${3:+"$3"}) ST_AGENTS=("${@:4}"); _status_mood; echo "$REPLY"; }
    face 59 100 "disk 95% full" "$work"
    face 60 100 "disk 95% full" "$work"
    face 79 "900 900 900" "CPU 90.0% sustained" "$work"
    face 80 "100 900 900 800" "CPU 87.5% sustained" "$work"
    face 100 "900 900 100" "" "$work"
    face 95 100 "1 orphaned process" "$work"
    face 100 100 "" "$wait" "$work"
    face 100 100 "" "$wait"
    face 100 100 ""'
  [ "$status" -eq 0 ]
  [ "${lines[*]}" = "dizzy alert alert squint happy neutral happy sleepy sleepy" ]
}

@test "the marmot's face: night shift, a long session, a recent big cleanup; cheeks when the disk is why" {
  status_lib '
    noon='"$(at '2026-06-10 12:00')"' night='"$(at '2026-06-10 03:30')"' dawn='"$(at '2026-06-10 06:00')"'
    busy=$(printf "1\tclaude\tclaude\t600\t9\t0\t300\t1\t/w") long=$(printf "1\tclaude\tclaude\t50000\t9\t0\t300\t1\t/w")
    idle=$(printf "2\tcodex\tcodex\t50000\t9\t0\t0\t0\t/w")
    face() { ST_NOW=$1 ST_SCORE=$2 ST_CPUH=(100) ST_REASONS=(${3:+"$3"}) ST_AGENTS=("${@:4}"); _status_mood; echo "$REPLY$ST_CHEEKS"; }
    face "$night" 100 "" "$busy"
    face "$night" 100 "" "$idle"
    face "$night" 95 "1 orphaned process" "$busy"
    face "$dawn" 100 "" "$busy"
    face "$noon" 100 "" "$long"
    face "$noon" 100 "" "$idle"
    ST_PROUD_AT=$((noon - 3600)) ST_PROUD_FREED=2147483648
    face "$noon" 100 "" "$busy"
    face "$noon" 100 ""
    face "$noon" 100 "" "$long"
    face "$noon" 95 "1 orphaned process"
    ST_PROUD_FREED=1000000000
    face "$noon" 100 "" "$busy"
    ST_PROUD_FREED=2147483648 ST_PROUD_AT=$((noon - 90000))
    face "$noon" 100 "" "$busy"
    ST_ROOT_PCT=950
    face "$noon" 75 "disk 95% full" "$busy"
    face "$noon" 50 "disk 95% full" "$busy"
    ST_ROOT_PCT=850
    face "$noon" 75 "memory 5% available" "$busy"'
  [ "$status" -eq 0 ]
  [ "${lines[*]}" = "night0 sleepy0 neutral0 happy0 tired0 sleepy0 proud0 proud0 tired0 neutral0 happy0 happy0 alert1 dizzy1 alert0" ]
}

@test "proud: the newer of the last scheduled run and the log's newest run, said by when it was" {
  mkdir -p "$XDG_STATE_HOME/marmot"
  local log="$XDG_STATE_HOME/marmot/operations.log"
  printf '%s\tclean\tremove\t/x/a\t1073741824\t\tR1\n' "$(date -Iseconds -d '2026-06-09 10:00')" >"$log"
  printf '%s\tschedule\tremove\t/x/b\t2147483648\t\tR2\n%s\tschedule\trefused\t/x/c\t0\tin use\tR2\n' \
    "$(date -Iseconds -d '2026-06-10 03:10')" "$(date -Iseconds -d '2026-06-10 03:11')" >>"$log"
  status_lib '
    proud() { ST_LAST=0; mm_schedule_last && ST_LAST=1; ST_NOW=$(date -d "$1" +%s) ST_DAY=${1% *}; _status_facts
      echo "$ST_PROUD_AT $ST_PROUD_FREED $ST_PROUD_NOTE"; }
    proud "2026-06-10 12:00"
    proud "2026-06-11 09:00"
    printf "{\n  \"finished_at\": \"x\",\n  \"finished_epoch\": %s,\n  \"duration_seconds\": 5,\n  \"trigger\": \"manual\",\n  \"freed_bytes\": 3221225472,\n  \"trashed_bytes\": 0,\n  \"items\": 2,\n  \"skipped\": [],\n  \"errors\": []\n}\n" \
      "$(date -d "2026-06-10 15:00" +%s)" >"$XDG_STATE_HOME/marmot/last-run.json"
    proud "2026-06-10 20:00"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(at '2026-06-10 03:11') 2147483648 freed 2.0GB last night" ]
  [ "${lines[1]}" = "$(at '2026-06-10 03:11') 2147483648 freed 2.0GB yesterday" ]
  [ "${lines[2]}" = "$(at '2026-06-10 15:00') 3221225472 freed 3.0GB this afternoon" ]
}

@test "the hard hat: a marmot cleanup at work; not a dry run, --help or another command" {
  status_lib '
    for a in "bash /x/mm clean" "/bin/bash /x/marmot purge --yes /w" "/x/mm schedule run" "bash /x/mm --debug optimize" \
      "bash /x/mm uninstall foo" "bash /x/mm clean --dry-run" "bash /x/mm -n purge" "bash /x/mm clean --help" \
      "bash /x/mm status" "bash /x/mm schedule status" "grep mm clean" "vim /x/mm" "bash /x/mm"; do
      read -r -a v <<<"$a"
      if _status_cleanup_argv "${v[@]}"; then echo yes; else echo no; fi
    done'
  [ "${lines[*]}" = "yes yes yes yes yes no no no no no no no no" ]
  # Other tests' cleanups may run alongside this one: only the positive case is checked here.
  mkdir -p "$SB/fake"
  printf '#!/bin/bash\nsleep 30\n' >"$SB/fake/mm"
  mm_test_bg "$SB" bash "$SB/fake/mm" clean
  status_lib '_status_init; _status_first 0; echo "$ST_ATWORK"; _status_frame_compact 200; _status_cleanup; echo "$MM_LOOK_HAT"'
  [ "${lines[*]}" = "1 hardhat" ]
}

@test "blink: the live view closes open eyes for a moment every 8-10 s; a snapshot never does" {
  (( $(nproc) > 1 )) || skip "one busy core would be all the CPU: squinting, not blinking"
  mm_test_now '2026-06-10 12:00'
  cp "$(command -v bash)" "$SB/bin/claude"
  detached "$SB" "$SB/bin/claude" -c 'while :; do :; done'
  fake_ss "$LISTEN_SSH" ""
  run env COLUMNS=100 mm status --once
  [ "$status" -eq 0 ]
  grep -qE '^   \|  [\^oO]    [\^oO]  \|' <<<"$output"
  [[ "$output" != *"|  -    -  |"* ]]
  live 'sleep 13; printf q'
  [ "$LIVE_STATUS" -eq 0 ]
  grep -qE '^   \|  [\^oO]    [\^oO]  \|' <<<"$LIVE_TEXT"
  grep -qF '   |  -    -  |' <<<"$LIVE_TEXT"
}

@test "the day's occasions dress the header; an ordinary day has none" {
  mm_test_now '2026-12-25 12:00'
  status_lib '_status_init; _status_first 0; _status_frame_compact 200; _status_cleanup
    echo "${ST_OCC[*]}|$MM_LOOK_HAT|${MM_LOOK_GREET:+greeting}"'
  [ "$status" -eq 0 ]
  # Another test's cleanup may be at work alongside: then the hard hat is the right hat.
  [[ "$output" == "christmas winter|santa|greeting" || "$output" == "christmas winter|hardhat|greeting" ]]
  mm_test_now '2026-06-10 12:00'
  status_lib '_status_init; _status_first 0; _status_frame_compact 200; _status_cleanup
    echo "${ST_OCC[*]}|${MM_LOOK_GREET:+greeting}"'
  [ "$output" = "|" ]
}

@test "views: v switches live between compact and full, repainting the screen" {
  fake_ss "$LISTEN_SSH" ""
  LIVE_ROWS=70 live 'sleep 4; printf v; sleep 2.5; printf q'
  [ "$LIVE_STATUS" -eq 0 ]
  [[ "$LIVE_TEXT" == *"AGENTS"*"v full view"*"◉ Agents"*"v compact view"* ]]
  [ "$(grep -o $'\e\\[2J' "$LIVE_OUT" | wc -l)" -ge 3 ]
}

@test "status is read-only: only query verbs reach apt/systemctl/docker and nothing is logged" {
  needs_jq
  status_json
  [ -s "$CALLS" ]
  local cmd
  while IFS= read -r cmd; do
    case "$cmd" in
      "apt list --upgradable" | "systemctl --failed --no-legend --plain" | \
        "systemctl is-active unattended-upgrades" | "docker ps -a --format {{.State}}") ;;
      *) echo "unexpected call: $cmd"; false ;;
    esac
  done <"$CALLS"
  run mm status --once
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}

@test "a bad MM_STATUS_LINGER_AGE is refused" {
  run env MM_STATUS_LINGER_AGE=1d mm status --once
  [ "$status" -ne 0 ]
}

# fake_cgroup — a cgroup v2 stand-in (MM_TEST_CGROUP_FS) limiting this process to 512 MiB, 200 MiB of
# it in use after reclaimable page cache, and 1.5 CPUs; its root stands for every ancestor cgroup.
fake_cgroup() {
  local cg="$SB/cg"
  mkdir -p "$cg"
  echo "cpu memory" >"$cg/cgroup.controllers"
  echo 536870912 >"$cg/memory.max"
  echo $((300 << 20)) >"$cg/memory.current"
  printf 'anon 1\ninactive_file %d\n' $((100 << 20)) >"$cg/memory.stat"
  echo "150000 100000" >"$cg/cpu.max"
  echo "usage_usec 1000" >"$cg/cpu.stat"
  export MM_TEST_CGROUP_FS=$cg
}

@test "container: memory and CPU follow the cgroup limits; reboot and kernel checks are left out" {
  needs_jq
  fake_cgroup
  mm_test_fake dpkg-query 'printf "ii  linux-image-99.0.0-1-generic\n"'
  # The cgroup burns 0.75 CPU (cpu.stat rewritten as time passes): half of its 1.5-CPU quota. The
  # writer can stall on a loaded machine, so the check is a band: measured against the quota it is
  # ~50%, measured against the host's cores it would be ~9%.
  (while :; do
    echo "usage_usec $((${EPOCHREALTIME/./} * 3 / 4))" >"$SB/cg/cpu.stat.new" && mv -f "$SB/cg/cpu.stat.new" "$SB/cg/cpu.stat"
    sleep 0.01
  done) &
  MM_TEST_PIDS+=("$!")
  status_json MM_CONTAINER=1
  jq -e '
    .container == { memory_limit_bytes: 536870912, cpu_limit_cores: 1.5 }
    and .memory.total == 536870912 and .memory.used == 209715200
    and .cpu.usage >= 25 and .cpu.usage <= 75
    and .system.reboot_required == null and .system.kernel_update_pending == null
    and (.health_reasons | map(select(startswith("load") or startswith("reboot"))) == [])
  ' <<<"$JSON"
  # Wide enough that health reasons (a host disk over 80% on CI runners) never cut the container
  # details out of the header.
  run env MM_CONTAINER=1 COLUMNS=400 mm status --once --view full
  [ "$status" -eq 0 ]
  [[ "$(grep -m1 -A1 -F 'mm status' <<<"$output")" == *" · container · "*"512.0MB limit"* ]]
  [[ "$output" == *"of 1.5-core limit"* && "$output" == *"(host, "* ]]
  [[ "$output" != *"✓ kernel"* && "$output" != *"! kernel"* && "$output" != *"✓ reboot"* ]]
  run env MM_CONTAINER=1 mm status --agent
  grep -E "^machine: [^ ]+ · container · .* · 1\.5 of [0-9]+ cores · 512\.0MB RAM limit · " <<<"$output"
  grep -E '^cpu: [0-9.]+% of a 1\.5-core limit · host load ' <<<"$output"
  grep -E '^memory: 39% used of a 512\.0MB limit · ' <<<"$output"
}

@test "outside a container the cgroup limits change nothing" {
  needs_jq
  fake_cgroup
  status_json
  jq -e '.container == null and .memory.total != 536870912 and (.system.reboot_required | type == "boolean")' <<<"$JSON"
  run mm status --once
  [[ "$(grep -m1 -A1 -F 'mm status' <<<"$output")" != *container* ]]
}
