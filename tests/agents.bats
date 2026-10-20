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
  [ "${#MM_AGENT_SESSION_FILES[@]}" -eq "$n" ]
}

@test "session file globs load unexpanded; only Claude Code limits its sessions to transcripts" {
  local c
  c=$(agent "Claude Code")
  [ "${MM_AGENT_SESSION_FILES[c]}" = '*.jsonl' ]
  [ -z "${MM_AGENT_SESSION_FILES[$(agent "Codex CLI")]}" ]
  [ -z "${MM_AGENT_HELPERS[c]}" ]
}

@test "Kimi CLI and OpenHands are known, so their state and conversations are protected" {
  mm_core
  mkdir -p "$HOME/.kimi/sessions/a1b2/0001" "$HOME/.kimi/credentials" "$HOME/.openhands/conversations/c1/events"
  echo '{}' >"$HOME/.kimi/sessions/a1b2/0001/context.jsonl"
  echo '{}' >"$HOME/.openhands/conversations/c1/events/event-0.json"
  echo '{}' >"$HOME/.openhands/agent_settings.json"
  mm_inuse_refresh
  local p
  for p in "$HOME/.kimi" "$HOME/.kimi/sessions/a1b2" "$HOME/.openhands" "$HOME/.openhands/conversations/c1"; do
    MM_DRY_RUN=1 run mm_rm "$p" "$HOME"
    [ "$status" -eq 1 ] || { echo "not refused: $p"; false; }
  done
  [ -e "$HOME/.kimi/sessions/a1b2/0001/context.jsonl" ]
  [ -e "$HOME/.openhands/conversations/c1/events/event-0.json" ]
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

@test "a row without the worktree, logs and helpers columns still loads, with none of them" {
  MM_AGENTS_TABLE='
Tool|tool|~/.tool|~/.tool/sessions|~/.tool/versions|~/.local/bin/tool
'
  MM_AGENT_NAME=() MM_AGENT_PROCS=() MM_AGENT_STATE=() MM_AGENT_SESSIONS=() MM_AGENT_VERSIONS=() MM_AGENT_ACTIVE=()
  MM_AGENT_WORKTREES=() MM_AGENT_LOGS=() MM_AGENT_HELPERS=() MM_AGENT_SESSION_FILES=()
  _mm_agents_load
  [ "${#MM_AGENT_LOGS[@]}" -eq 1 ]
  [ "${#MM_AGENT_HELPERS[@]}" -eq 1 ]
  [ "${MM_AGENT_ACTIVE[0]}" = "$HOME/.local/bin/tool" ]
  [ -z "${MM_AGENT_LOGS[0]}" ]
  [ -z "${MM_AGENT_HELPERS[0]}" ]
  run mm_agent_helper 0 $$
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------- helpers

@test "the helpers column loads aligned and unexpanded (globs stay globs)" {
  [ "${#MM_AGENT_HELPERS[@]}" -eq "${#MM_AGENT_NAME[@]}" ]
  local o
  o=$(agent oh-my-pi)
  [ "${MM_AGENT_HELPERS[o]}" = '__omp_worker_* ~/.omp/run/daemons/' ]
  [ -z "${MM_AGENT_HELPERS[$(agent "Claude Code")]}" ]
}

@test "mm_agent_helper: argv[1] globs and working-directory prefixes mark helpers, sessions are not" {
  local o
  o=$(agent oh-my-pi)
  mkdir -p "$SB/bin" "$SB/proj" "$HOME/.omp/run/daemons/global/text-predict"
  cp "$(command -v sleep)" "$SB/bin/omp"
  # A helper: argv[1] is __omp_worker_lsp_mux (a copy of bash running that script, blocked on a
  # FIFO).
  cp "$(command -v bash)" "$SB/bin/omp-bash"
  mkfifo "$SB/proj/fifo"
  printf 'read -r _ <>fifo\n' >"$SB/proj/__omp_worker_lsp_mux"
  mm_test_bg "$SB/proj" "$SB/bin/omp-bash" __omp_worker_lsp_mux
  local mux=${MM_TEST_PIDS[-1]}
  mm_test_bg "$HOME/.omp/run/daemons/global/text-predict" "$SB/bin/omp" 30
  local daemon=${MM_TEST_PIDS[-1]}
  mm_test_bg "$SB/proj" "$SB/bin/omp" 30
  local session=${MM_TEST_PIDS[-1]}
  # Run where a file matches the glob: the pattern must stay a glob, not become that file name.
  mkdir -p "$SB/decoy"
  : >"$SB/decoy/__omp_worker_decoy"
  cd "$SB/decoy"
  mm_agent_helper "$o" "$mux"
  [ "$REPLY" = __omp_worker_lsp_mux ]
  mm_agent_helper "$o" "$daemon"
  [ "$REPLY" = text-predict ]
  run mm_agent_helper "$o" "$session"
  [ "$status" -ne 0 ]
  # A row without helpers has none.
  run mm_agent_helper "$(agent "Claude Code")" "$mux"
  [ "$status" -ne 0 ]
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

# ---------------------------------------------------------------- user rows ($MM_CONFIG_DIR/agents)

# user_agents ROWS... — write ROWS, one per line, to the user's agents file and reload marmot.
user_agents() {
  mkdir -p "$HOME/.config/marmot"
  printf '%s\n' "$@" >"$HOME/.config/marmot/agents"
  mm_core
}

@test "a user row protects its state: mm_rm refuses it, a folder outside it goes" {
  user_agents '# my tools' '' 'My Tool|mytool|~/.mytool ~/.mytool.json|~/.mytool/sessions'
  mkdir -p "$HOME/.mytool/sessions/s1" "$HOME/.other"
  : >"$HOME/.mytool.json"
  mm_inuse_refresh
  local p
  for p in "$HOME/.mytool" "$HOME/.mytool/sessions/s1" "$HOME/.mytool.json"; do
    ! MM_DRY_RUN=1 mm_rm "$p" "$HOME" >/dev/null 2>&1 || { echo "removable: $p"; false; }
    [[ "$MM_SKIP_REASON" == whitelisted || "$MM_SKIP_REASON" == protected ]] || { echo "$p: $MM_SKIP_REASON"; false; }
  done
  [ -d "$HOME/.mytool/sessions/s1" ]
  MM_DRY_RUN=1 run mm_rm "$HOME/.other" "$HOME"
  [ "$status" -eq 0 ]
  [ "${#MM_AGENT_REJECTED[@]}" -eq 0 ]
}

@test "user rows with a path outside HOME, a .. segment or no process are rejected with file:line" {
  user_agents 'Good|good|~/.good' 'Etc|etc|/etc' 'Dots|dots|~/.dots/../.ssh' 'Tmp|tmp|~/.tmp||||||/tmp/x' \
    'NoProc||~/.noproc' 'Home|home|~'
  ln -s /etc "$HOME/.link"
  printf 'Link|link|~/.link/sub\n' >>"$HOME/.config/marmot/agents"
  mm_core
  [ "${#MM_AGENT_REJECTED[@]}" -eq 6 ]
  local r
  for r in 2 3 4 5 6 7; do
    printf '%s\n' "${MM_AGENT_REJECTED[@]}" | grep -q "^~/.config/marmot/agents:$r: " || { echo "line $r not rejected"; false; }
  done
  agent Good
  for r in Etc Dots Tmp NoProc Home Link; do ! agent "$r" || { echo "loaded: $r"; false; }; done
  run mm_agent_state_paths
  ! grep -qx -e /etc -e '~/.ssh' <<<"$output"
}

@test "a user row named like a built-in one replaces it" {
  local n=${#MM_AGENT_NAME[@]}
  user_agents 'Claude Code|my-claude|~/.my-claude'
  [ "${#MM_AGENT_NAME[@]}" -eq "$n" ]
  local c
  c=$(agent "Claude Code")
  [ "${MM_AGENT_PROCS[c]}" = my-claude ]
  [ "${MM_AGENT_STATE[c]}" = "$HOME/.my-claude" ]
  [ -z "${MM_AGENT_VERSIONS[c]}" ]
  [[ " ${MM_AGENT_PROCS[*]} " == *" my-claude "* ]]
  [[ " ${MM_AGENT_PROCS[*]} " != *" claude "* ]]
}
