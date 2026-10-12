# shellcheck shell=bash
# Known AI coding agent CLIs, shared by every command that needs to recognize them:
#   - their state (settings, credentials, session transcripts) is whitelisted and only reported;
#   - their processes count as agent sessions in `mm status`;
#   - tools that keep every installed version get old versions pruned by `mm clean`
#     (the active one, resolved through its launcher symlink, plus one previous are kept).
# Paths that do not exist on a machine are simply ignored. Add an agent by adding a row.
#
# Row fields, separated by '|':
#   name | process names | state dirs/files | session dirs | versions dir | active-version symlink
MM_AGENTS_TABLE='
Claude Code|claude|~/.claude ~/.claude.json|~/.claude/projects ~/.claude/sessions|~/.local/share/claude/versions|~/.local/bin/claude
Codex CLI|codex|~/.codex|~/.codex/sessions||
Gemini CLI|gemini|~/.gemini|~/.gemini/tmp||
Cursor Agent|cursor-agent|~/.cursor|~/.cursor/chats ~/.cursor/projects|~/.local/share/cursor-agent/versions|~/.local/bin/cursor-agent
GitHub Copilot CLI|copilot|~/.copilot/session-state ~/.copilot/config.json|~/.copilot/session-state|~/.copilot/pkg/universal|~/.local/bin/copilot
Aider|aider|~/.aider ~/.aider.conf.yml|||
opencode|opencode|~/.local/share/opencode ~/.config/opencode|~/.local/share/opencode/storage||
Amp|amp|~/.amp ~/.local/share/amp ~/.config/amp|~/.local/share/amp||
Goose|goose|~/.local/share/goose ~/.config/goose|~/.local/share/goose/sessions||
Crush|crush|~/.local/share/crush ~/.config/crush|||
Qwen Code|qwen|~/.qwen|~/.qwen/tmp||
Cline|cline|~/.cline|||
oh-my-pi|omp|~/.omp|~/.omp/agent/sessions||
'

MM_AGENT_NAME=() MM_AGENT_PROCS=() MM_AGENT_STATE=() MM_AGENT_SESSIONS=() MM_AGENT_VERSIONS=() MM_AGENT_ACTIVE=()

# _mm_tilde_list WORDS — expand a leading ~ in each space-separated word.
_mm_tilde_list() {
  local w words=()
  for w in $1; do [[ "$w" == "~"* ]] && w="$HOME${w:1}"; words+=("$w"); done
  printf '%s' "${words[*]}"
}

_mm_agents_load() {
  local name procs state sessions versions active
  while IFS='|' read -r name procs state sessions versions active; do
    [[ -n "$name" ]] || continue
    MM_AGENT_NAME+=("$name")
    MM_AGENT_PROCS+=("$procs")
    MM_AGENT_STATE+=("$(_mm_tilde_list "$state")")
    MM_AGENT_SESSIONS+=("$(_mm_tilde_list "$sessions")")
    MM_AGENT_VERSIONS+=("$(_mm_tilde_list "$versions")")
    MM_AGENT_ACTIVE+=("$(_mm_tilde_list "$active")")
  done <<<"$MM_AGENTS_TABLE"
}
_mm_agents_load

# mm_agent_procs — every agent process name, one per line.
mm_agent_procs() { printf '%s\n' "${MM_AGENT_PROCS[@]}" | tr ' ' '\n' | awk 'NF && !seen[$0]++'; }

# mm_agent_state_paths — every agent state path (dirs and files), one per line, with ~ unexpanded
# back to ~ so it reads well in the whitelist file.
mm_agent_state_paths() {
  local s p
  for s in "${MM_AGENT_STATE[@]}"; do
    for p in $s; do printf '%s\n' "~${p#"$HOME"}"; done
  done
}
