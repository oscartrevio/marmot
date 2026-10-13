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

# fake_ss LISTENERS CONNS [CONNS_LATER] — an `ss` double: listener queries (-l) print LISTENERS;
# `state established` queries print CONNS the first time and CONNS_LATER (default CONNS) after,
# so counters can grow between the two samples a snapshot takes. Lines as `ss -H` prints them.
fake_ss() {
  local d=$BATS_TEST_TMPDIR
  printf '%s\n' "$1" >"$d/ss.listen"
  printf '%s\n' "$2" >"$d/ss.est1"
  printf '%s\n' "${3:-$2}" >"$d/ss.est2"
  mm_test_fake ss "case \"\$*\" in
  *established*) if [[ -e '$d/ss.seen' ]]; then cat '$d/ss.est2'; else : >'$d/ss.seen'; cat '$d/ss.est1'; fi ;;
  *l*) cat '$d/ss.listen' ;;
esac"
  rm -f "$d/ss.seen"
}

# conn LOCAL PEER INFO — one established connection as `ss -Htin` prints it (info on its own line).
conn() { printf '0      0      %s   %s\n\t cubic wscale:7,7 rto:204 %s mss:1448 lastsnd:10 lastack:20\n' "$1" "$2" "$3"; }

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
  for _ in 1 2 3 4 5 6 7 8 9 10; do sub=$(pgrep -P "$busy" -x codex) && break; sleep 0.1; done
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
  for p in $(pgrep -f "$SB/bin/hog.py"); do rss=$((rss + $(awk '/^VmRSS:/ { print $2 }' "/proc/$p/status"))); done
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
  # Room for every panel and no client link coming and going: rows only change by their values.
  fake_ss "$LISTEN_SSH" ""
  LIVE_ROWS=70 live 'sleep 5; printf q'
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
    rttvar_ms: 4.1, retrans_delta: 0, laggy: false }' <<<"$JSON"
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
  jq -e '.client.address == "198.51.100.4" and .client.rtt_ms == 80' <<<"$JSON"
  status_json -u SSH_CONNECTION SSH_CLIENT='198.51.100.4 60000 22'
  jq -e '.client.address == "198.51.100.4"' <<<"$JSON"
  status_json SSH_CONNECTION='192.0.2.1 1234 10.0.0.5 22'
  jq -e '.client.address == "192.0.2.1" and .client.rtt_ms == null and (.client.laggy | not)' <<<"$JSON"
}

@test "client: a Tailscale peer is named, with its path; no inbound connection means null" {
  needs_jq
  mm_test_fake tailscale 'printf "%s\n" "{\"Peer\": {\"n1\": {\"HostName\": \"laptop\",
    \"TailscaleIPs\": [\"100.101.102.103\", \"fd7a:115c:a1e0::1\"], \"CurAddr\": \"\", \"Relay\": \"fra\"}}}"'
  fake_ss "$LISTEN_SSH" "$(conn 100.88.0.2:22 100.101.102.103:50000 'rtt:30/3 lastrcv:5 minrtt:25')"
  status_json "${NO_SSH[@]}"
  jq -e '.client | .name == "laptop" and .path == "Tailscale relay fra"' <<<"$JSON"
  fake_ss "$LISTEN_SSH" "$(conn 10.0.0.5:40001 203.0.113.9:443 'rtt:9/1 lastrcv:3 minrtt:9')"
  status_json "${NO_SSH[@]}"
  jq -e '.client == null' <<<"$JSON"
  fake_ss "$LISTEN_SSH" ""
  run env "${NO_SSH[@]}" mm status --once
  [[ "$output" == *"no remote session detected"* ]]
}

@test "checks: all fine is one line of ✓ items, pending updates a note there, not a problem" {
  mm_test_fake docker 'printf "running\nexited\n"'
  mm_test_fake dpkg-query 'exit 0'
  mm_test_fake unattended-upgrade 'exit 0'
  run mm status --once
  [ "$status" -eq 0 ]
  local row
  row=$(grep -E '^Checks ' <<<"$output")
  [[ "$row" == *"✓ kernel"*"✓ units"*"✓ docker"*"✓ unattended"*"1 update"* ]]
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
  run mm status --once
  [ "$status" -eq 0 ]
  grep -E '^ +! 1 failed unit: foo\.service: systemctl --failed$' <<<"$output"
  grep -E '^ +! kernel 99\.0\.0-1 installed, running .*: sudo reboot$' <<<"$output"
  grep -E '^ +! docker daemon not reachable: docker info$' <<<"$output"
  # Too long for one 80-column line: the command follows on the next line, whole.
  grep -A1 -E '^ +! unattended-upgrades inactive:' <<<"$output" | grep -E ' sudo systemctl enable --now unattended-upgrades$'
  [ "$(grep -cE '✓ (kernel|units|docker|unattended)' <<<"$output")" -eq 0 ]
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
