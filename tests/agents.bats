#!/usr/bin/env bats
# lib/agents.sh: the table of known coding-agent CLIs.

setup() {
  load helpers/common
  mm_test_setup
  # shellcheck source=../lib/agents.sh
  . "$MM_SRC/lib/agents.sh"
}
teardown() { mm_test_teardown; }

@test "every row loads into aligned arrays" {
  local n=${#MM_AGENT_NAME[@]}
  (( n >= 10 ))
  [ "${#MM_AGENT_PROCS[@]}" -eq "$n" ]
  [ "${#MM_AGENT_STATE[@]}" -eq "$n" ]
  [ "${#MM_AGENT_SESSIONS[@]}" -eq "$n" ]
  [ "${#MM_AGENT_VERSIONS[@]}" -eq "$n" ]
  [ "${#MM_AGENT_ACTIVE[@]}" -eq "$n" ]
}

@test "every agent has a process name and at least one state path, all under HOME" {
  local i p
  for i in "${!MM_AGENT_NAME[@]}"; do
    [ -n "${MM_AGENT_PROCS[i]}" ] || { echo "no process: ${MM_AGENT_NAME[i]}"; false; }
    [ -n "${MM_AGENT_STATE[i]}" ] || { echo "no state: ${MM_AGENT_NAME[i]}"; false; }
    for p in ${MM_AGENT_STATE[i]} ${MM_AGENT_SESSIONS[i]} ${MM_AGENT_VERSIONS[i]} ${MM_AGENT_ACTIVE[i]}; do
      [[ "$p" == "$HOME"/* ]] || { echo "not under HOME: $p"; false; }
    done
  done
}

@test "version dirs are never inside protected agent state" {
  local i v s
  for i in "${!MM_AGENT_NAME[@]}"; do
    v=${MM_AGENT_VERSIONS[i]}
    [ -n "$v" ] || continue
    for s in ${MM_AGENT_STATE[i]}; do
      [[ "$v" != "$s" && "$v" != "$s"/* ]] || { echo "${MM_AGENT_NAME[i]}: $v is inside $s"; false; }
    done
  done
}

@test "mm_agent_procs lists each process name once" {
  run mm_agent_procs
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(sort <<<"$output" | uniq -d)" = "" ]
  grep -qx claude <<<"$output"
}

@test "mm_agent_state_paths prints paths relative to ~" {
  run mm_agent_state_paths
  [ "$status" -eq 0 ]
  [ -z "$(grep -v '^~/' <<<"$output")" ]
  grep -qx '~/.claude' <<<"$output"
}
