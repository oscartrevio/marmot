# shellcheck shell=bash
# Known AI coding agent CLIs and the orchestrators that run them, shared by every command that
# needs to recognize them:
#   - their state (settings, credentials, session transcripts) is whitelisted and only reported,
#     except old session files when the user opts in to retention (`mm clean --sessions DAYS`);
#   - their processes count as agent sessions in `mm status`;
#   - tools that keep every installed version get old versions pruned by `mm clean`
#     (the active one, resolved through its launcher symlink, plus one previous are kept);
#   - `mm purge` looks for git worktrees in their worktree dirs.
# Paths that do not exist on a machine are simply ignored. Add an agent by adding a row.
#
# Row fields, separated by '|':
#   name | process names | state dirs/files | session dirs | versions dir | active-version symlink
#   | worktree dirs
# Worktree dirs are where a tool creates git worktrees by default (users can move them). They are
# hints for discovery only: purge acts on a directory there only if its .git file points into a
# repository's worktrees dir (<repo>/.git/worktrees/<name>) and that repository lists it. Tools
# that keep worktrees inside the repository (Claude Code's <repo>/.claude/worktrees, Crystal's
# <repo>/worktrees) or next to it need no entry: purge finds every worktree registered to a
# repository it scans. Inside such a worktree, purge may remove the worktree itself (git
# worktree remove) and its build artifacts; the rest of the tool's state dir stays protected.
MM_AGENTS_TABLE='
Claude Code|claude|~/.claude ~/.claude.json|~/.claude/projects ~/.claude/sessions|~/.local/share/claude/versions|~/.local/bin/claude|
Codex CLI|codex|~/.codex|~/.codex/sessions|||~/.codex/worktrees
Gemini CLI|gemini|~/.gemini|~/.gemini/tmp|||
Cursor Agent|cursor-agent|~/.cursor|~/.cursor/chats ~/.cursor/projects|~/.local/share/cursor-agent/versions|~/.local/bin/cursor-agent|~/.cursor/worktrees
GitHub Copilot CLI|copilot|~/.copilot/session-state ~/.copilot/config.json|~/.copilot/session-state|~/.copilot/pkg/universal|~/.local/bin/copilot|
Aider|aider|~/.aider ~/.aider.conf.yml||||
opencode|opencode|~/.local/share/opencode ~/.config/opencode|~/.local/share/opencode/project|||
Amp|amp|~/.amp ~/.local/share/amp ~/.config/amp|~/.local/share/amp|||
Goose|goose|~/.local/share/goose ~/.config/goose ~/.local/state/goose|~/.local/share/goose/sessions|||
Crush|crush|~/.local/share/crush ~/.config/crush||||
Qwen Code|qwen|~/.qwen|~/.qwen/tmp ~/.qwen/projects|||
Cline|cline|~/.cline||||
oh-my-pi|omp|~/.omp|~/.omp/agent/sessions|||
Paseo|paseo|~/.paseo|~/.paseo/agents|||~/.paseo/worktrees
T3 Code|t3|~/.t3||||~/.t3/worktrees
Claude Squad|cs claude-squad|~/.claude-squad||||~/.claude-squad/worktrees
Crystal|crystal|~/.crystal||||
Container Use|container-use cu|~/.config/container-use||||~/.config/container-use/worktrees
uzi|uzi|~/.local/share/uzi||||~/.local/share/uzi/worktrees
'

MM_AGENT_NAME=() MM_AGENT_PROCS=() MM_AGENT_STATE=() MM_AGENT_SESSIONS=() MM_AGENT_VERSIONS=() MM_AGENT_ACTIVE=()
MM_AGENT_WORKTREES=()

# _mm_tilde_list WORDS — expand a leading ~ in each space-separated word.
_mm_tilde_list() {
  local w words=()
  for w in $1; do [[ "$w" == "~"* ]] && w="$HOME${w:1}"; words+=("$w"); done
  printf '%s' "${words[*]}"
}

_mm_agents_load() {
  local name procs state sessions versions active worktrees
  while IFS='|' read -r name procs state sessions versions active worktrees; do
    [[ -n "$name" ]] || continue
    MM_AGENT_NAME+=("$name")
    MM_AGENT_PROCS+=("$procs")
    MM_AGENT_STATE+=("$(_mm_tilde_list "$state")")
    MM_AGENT_SESSIONS+=("$(_mm_tilde_list "$sessions")")
    MM_AGENT_VERSIONS+=("$(_mm_tilde_list "$versions")")
    MM_AGENT_ACTIVE+=("$(_mm_tilde_list "$active")")
    MM_AGENT_WORKTREES+=("$(_mm_tilde_list "$worktrees")")
  done <<<"$MM_AGENTS_TABLE"
}
_mm_agents_load

# mm_agent_procs — every agent process name, one per line.
mm_agent_procs() { printf '%s\n' "${MM_AGENT_PROCS[@]}" | tr ' ' '\n' | awk 'NF && !seen[$0]++'; }

# mm_agent_worktree_dirs — every agent worktree dir (~ expanded), one per line.
mm_agent_worktree_dirs() { printf '%s\n' "${MM_AGENT_WORKTREES[@]}" | tr ' ' '\n' | awk 'NF && !seen[$0]++'; }

# mm_agent_state_paths — every agent state path (dirs and files), one per line, with ~ unexpanded
# back to ~ so it reads well in the whitelist file.
mm_agent_state_paths() {
  local s p
  for s in "${MM_AGENT_STATE[@]}"; do
    for p in $s; do printf '%s\n' "~${p#"$HOME"}"; done
  done
}

# mm_agent_dir PATH — 0 if the resolved PATH is exactly one known agent's session or state
# directory (not a file, not a folder above or below one) and lies strictly inside $HOME.
mm_agent_dir() {
  local s p r
  for s in "${MM_AGENT_SESSIONS[@]}" "${MM_AGENT_STATE[@]}"; do
    for p in $s; do
      r=$(realpath -e -- "$p" 2>/dev/null) && [[ -d "$r" && "$r" == "$1" && "$r" == "$HOME"/?* ]] && return 0
    done
  done
  return 1
}
