#!/usr/bin/env bats
# mm status: read-only dashboard. JSON shape, agent sessions (by name and by interpreter argv),
# orphans in deleted dirs, lingering dev processes and old listeners (age via
# MM_STATUS_LINGER_AGE), VPN rows only for interfaces that exist, inode penalty, its own processes
# kept out of the top lists, live-mode rendering in a pty, and no terminal needed for a snapshot.
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
}

teardown() {
  local p
  # Background helpers may have children of their own (a fake agent running a server).
  for p in "${MM_TEST_PIDS[@]}" "${DETACHED_PIDS[@]}"; do kill $(pgrep -P "$p") 2>/dev/null; done
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

# status_lib SNIPPET — run SNIPPET in a fresh bash with lib/core.sh and cmd/status.sh sourced, in
# a new session (no controlling terminal: sizes come from LINES/COLUMNS, as on CI).
status_lib() { run setsid -w bash -c '. "$1/lib/core.sh"; . "$1/cmd/status.sh"; eval "$2"' _ "$MM_SRC" "$1"; }

# live KEYS [ARGS...] — run `mm status --interval 1 ARGS` in a 40x100 pty (script(1)); KEYS is a
# shell snippet whose stdout is typed into it (e.g. 'sleep 4; printf q'). Exit status in
# $LIVE_STATUS, raw output in $LIVE_OUT, the output with escape sequences stripped in $LIVE_TEXT.
live() {
  command -v script >/dev/null || skip "script(1) not installed"
  local keys=$1 cmd=""
  shift
  (($#)) && printf -v cmd ' %q' "$@"
  LIVE_OUT="$BATS_TEST_TMPDIR/live.out" LIVE_STATUS=0
  { eval "$keys"; sleep 2; } |
    timeout 40 script -qfec "stty rows 40 cols 100; env -u MM_TTY mm status --interval 1$cmd" /dev/null \
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
  mm_test_bg "$SB/work" "$SB/bin/claude" 30
  local pid=${MM_TEST_PIDS[-1]}
  status_json
  jq -e --argjson p "$pid" '.system.agents.sessions
    | any(.pid == $p and .agent == "Claude Code" and .process == "claude" and (.orphan | not))' <<<"$JSON"
  jq -e '.system.agents.count >= 1' <<<"$JSON"
}

@test "an agent CLI run by an interpreter (python3 .../gemini) is counted by its script name" {
  needs_jq
  needs_python
  printf 'import time\ntime.sleep(30)\n' >"$SB/bin/gemini"
  mm_test_bg "$SB" python3 "$SB/bin/gemini"
  local pid=${MM_TEST_PIDS[-1]}
  [ "$(cat "/proc/$pid/comm")" = python3 ]
  status_json
  jq -e --argjson p "$pid" '.system.agents.sessions | any(.pid == $p and .agent == "Gemini CLI")' <<<"$JSON"
}

@test "an agent whose working directory was deleted is an orphan and costs health" {
  needs_jq
  fake_agent codex
  mkdir -p "$SB/gone"
  mm_test_bg "$SB/gone" "$SB/bin/codex" 30
  local pid=${MM_TEST_PIDS[-1]}
  rm -r -- "$SB/gone"
  status_json
  jq -e --argjson p "$pid" --arg d "$SB/gone" '
    (.system.orphans | any(.pid == $p and .kind == "agent" and .deleted_cwd == $d))
    and (.system.agents.sessions | any(.pid == $p and .orphan))
    and (.system.agents.orphan_count >= 1)
    and (.health_reasons | any(test("orphan")))' <<<"$JSON"
  run mm status --once
  # The panel shows at most 3 orphan rows and other processes on the host may fill them; the JSON
  # check above pins this exact process. Here: the orphan surfaces in the human view at all.
  [[ "$output" == *"cwd deleted: "* ]]
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
  run env MM_STATUS_LINGER_AGE=0 mm status --once
  [[ "$output" == *"listening >0m · oldest"* ]]
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
  for _ in 1 2 3 4 5 6 7 8 9 10; do child=$(pgrep -P "$agent" python3) && break; sleep 0.1; done
  [ -n "$child" ]
  listening "$child"
  status_json MM_STATUS_LINGER_AGE=0
  jq -e --argjson a "$agent" --argjson c "$child" '
    (.system.agents.sessions | any(.pid == $a))
    and (.system.lingering.processes | all(.pid != $c))
    and (.system.listening_ports.ports | any(.pid == $c))' <<<"$JSON"
}

@test "no VPN rows when no VPN interface exists; an existing one gets a row" {
  needs_jq
  status_json MM_STATUS_VPN_IFACES='no-such-vpn*'
  jq -e '.network | all(.kind != "vpn")' <<<"$JSON"
  run env MM_STATUS_VPN_IFACES='no-such-vpn*' mm status --once
  [ "$(grep -cE '^VPN ' <<<"$output")" -eq 0 ]
  # lo always exists and is up: treating it as a VPN proves rows follow what is detected.
  status_json MM_STATUS_VPN_IFACES=lo
  jq -e '.network | any(.interface == "lo" and .kind == "vpn" and (.default_route | not))' <<<"$JSON"
  run env MM_STATUS_VPN_IFACES=lo mm status --once
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
  status_lib '_status_init; _status_first 0; _status_sample; _status_derive; _status_frame 80
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
  run mm status --once
  [ "$status" -eq 0 ]
  grep -E "bash \(alpha/beta\) +$pid " <<<"$output"
}

@test "live mode: refreshes rewrite only changed rows, the footer ends its line, q quits" {
  live 'sleep 5; printf q'
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

@test "without a terminal, plain 'mm status' prints one snapshot and exits" {
  run mm status </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Health"* && "$output" == *"Agents"* && "$output" == *"Ports"* ]]
  [[ "$output" != *$'\e[?1049h'* ]]
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
