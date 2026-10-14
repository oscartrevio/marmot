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
  [ "${#MM_AGENT_WORKTREES[@]}" -eq "$n" ]
}

@test "every agent has a process name and at least one state path, all under HOME" {
  local i p
  for i in "${!MM_AGENT_NAME[@]}"; do
    [ -n "${MM_AGENT_PROCS[i]}" ] || { echo "no process: ${MM_AGENT_NAME[i]}"; false; }
    [ -n "${MM_AGENT_STATE[i]}" ] || { echo "no state: ${MM_AGENT_NAME[i]}"; false; }
    for p in ${MM_AGENT_STATE[i]} ${MM_AGENT_SESSIONS[i]} ${MM_AGENT_VERSIONS[i]} ${MM_AGENT_ACTIVE[i]} ${MM_AGENT_WORKTREES[i]}; do
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

@test "mm_agent_worktree_dirs lists each worktree dir once, expanded" {
  run mm_agent_worktree_dirs
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output" | uniq -d)" = "" ]
  [ -z "$(grep -v "^$HOME/" <<<"$output")" ]
  grep -qxF "$HOME/.cursor/worktrees" <<<"$output"
}

# ---------------------------------------------------------------- logs dirs

# agent NAME — index of the agent called NAME.
agent() { local i; for i in "${!MM_AGENT_NAME[@]}"; do [[ "${MM_AGENT_NAME[i]}" == "$1" ]] && { echo "$i"; return 0; }; done; return 1; }

@test "the logs column loads aligned and leaves the columns before it as they were" {
  [ "${#MM_AGENT_LOGS[@]}" -eq "${#MM_AGENT_NAME[@]}" ]
  local c o
  c=$(agent "Claude Code"); o=$(agent oh-my-pi)
  [ "${MM_AGENT_ACTIVE[c]}" = "$HOME/.local/bin/claude" ]
  [ "${MM_AGENT_VERSIONS[c]}" = "$HOME/.local/share/claude/versions" ]
  [ -z "${MM_AGENT_LOGS[c]}" ]
  [ "${MM_AGENT_SESSIONS[o]}" = "$HOME/.omp/agent/sessions" ]
  [ -z "${MM_AGENT_ACTIVE[o]}" ]
  [ "${MM_AGENT_LOGS[o]}" = "$HOME/.omp/logs" ]
}

@test "a row without the worktree and logs columns still loads, with no logs dir" {
  MM_AGENTS_TABLE='
Tool|tool|~/.tool|~/.tool/sessions|~/.tool/versions|~/.local/bin/tool
'
  MM_AGENT_NAME=() MM_AGENT_PROCS=() MM_AGENT_STATE=() MM_AGENT_SESSIONS=() MM_AGENT_VERSIONS=() MM_AGENT_ACTIVE=()
  MM_AGENT_WORKTREES=() MM_AGENT_LOGS=()
  _mm_agents_load
  [ "${#MM_AGENT_LOGS[@]}" -eq 1 ]
  [ "${MM_AGENT_ACTIVE[0]}" = "$HOME/.local/bin/tool" ]
  [ -z "${MM_AGENT_LOGS[0]}" ]
}

@test "logs dirs are under HOME and never at, inside or above any session dir" {
  local i j l s
  for i in "${!MM_AGENT_NAME[@]}"; do
    for l in ${MM_AGENT_LOGS[i]}; do
      [[ "$l" == "$HOME"/?* ]] || { echo "not under HOME: $l"; false; }
      for j in "${!MM_AGENT_NAME[@]}"; do
        for s in ${MM_AGENT_SESSIONS[j]}; do
          [[ "$l" != "$s" && "$l" != "$s"/* && "$s" != "$l"/* ]] || { echo "$l overlaps session dir $s"; false; }
        done
      done
    done
  done
}

@test "mm_agent_dir accepts a logs dir, not a folder above or below it" {
  local g="$HOME/.local/state/goose/logs"
  mkdir -p "$g/cli"
  mm_agent_dir "$g"
  run mm_agent_dir "$g/cli"
  [ "$status" -ne 0 ]
  run mm_agent_dir "$HOME/.local/state"
  [ "$status" -ne 0 ]
}
