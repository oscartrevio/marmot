# shellcheck shell=bash
# Known AI coding agent CLIs and the orchestrators that run them, shared by every command that
# needs to recognize them:
#   - their state (settings, credentials, session transcripts) is whitelisted and only reported,
#     except old session files when the user opts in to retention (`mm clean --sessions DAYS`);
#   - their own diagnostic logs (*.log files in their logs dirs) older than 7 days are removed by
#     `mm clean`: logs, not conversations;
#   - their processes count as agent sessions in `mm status`, except the tool's own helper
#     processes (see helpers below);
#   - tools that keep every installed version get old versions pruned by `mm clean`
#     (the active one, resolved through its launcher symlink, plus one previous are kept);
#   - `mm purge` looks for git worktrees in their worktree dirs.
# Paths that do not exist on a machine are simply ignored. Add an agent by adding a row.
#
# Any other tool: add rows in the same format to $MM_CONFIG_DIR/agents (default
# ~/.config/marmot/agents), one per line; blank lines and lines starting with # are ignored. They
# load after the built-in rows and a row named like a built-in one replaces it. A user row needs a
# name and process names, and every path in it (state, sessions, versions, active symlink,
# worktrees, logs, helper prefixes) must be ~/... or an absolute path strictly inside the home
# folder, also once symlinks are resolved, with no . or .. segment, glob or control character.
# Rows that break a rule are ignored and listed ("<file>:<line>: <reason>") in MM_AGENT_REJECTED.
#   My Tool|mytool mytool-cli|~/.mytool ~/.config/mytool|~/.mytool/sessions||||~/.mytool/logs
#
# Row fields, separated by '|':
#   name | process names | state dirs/files | session dirs | versions dir | active-version symlink
#   | worktree dirs | logs dirs | helpers | session file globs
# Trailing fields may be left out: a shorter row loads with them empty.
#
# Session file globs name the files that are this tool's transcripts, for the opt-in retention
# sweep (`mm clean --sessions DAYS`): with them set, nothing else in a session dir is touched.
# Claude Code writes its auto memory as Markdown next to the transcripts
# (~/.claude/projects/<project>/memory/*.md, code.claude.com/docs/en/memory), so only its *.jsonl
# transcripts count. Without globs every file in a session dir counts, as before. Memory folders,
# agent worktrees and git checkouts are never entered, whatever the globs say.
#
# Helpers are processes a tool starts for itself under the same process name (language-server
# hubs, daemon brokers, completion daemons): they are not sessions. A pattern starting with ~/ or
# / is a working-directory prefix (the process runs in or below it); any other is a glob matched
# against the process's first argument (argv[1]). `mm status` counts them on a separate helpers
# line, with everything they started, and `mm optimize` labels them as helpers. For example,
# oh-my-pi's row lists `__omp_worker_*` (its language-server hub, daemon broker and word-completion
# workers run as `omp __omp_worker_<kind>`) and ~/.omp/run/daemons/ (where its daemons run).
#
# Worktree dirs are where a tool creates git worktrees by default (users can move them). They are
# hints for discovery only: purge acts on a directory there only if its .git file points into a
# repository's worktrees dir (<repo>/.git/worktrees/<name>) and that repository lists it. Tools
# that keep worktrees inside the repository (Claude Code's <repo>/.claude/worktrees, Crystal's
# <repo>/worktrees) or next to it need no entry: purge finds every worktree registered to a
# repository it scans. Inside such a worktree, purge may remove the worktree itself (git
# worktree remove) and its build artifacts; the rest of the tool's state dir stays protected.
#
# Logs dirs are listed only where the tool documents them (default locations; sources below), and
# never at, inside or above a session dir. Left out: Claude Code (~/.claude/debug holds .txt files
# and Claude Code sweeps it itself), Crush (logs per project in ./.crush/logs), Gemini CLI, Qwen
# Code, Cursor Agent, Amp and Aider (no documented logs dir in the home folder).
#   Codex CLI   ~/.codex/log: codex-tui.log of earlier releases (current ones log only with log_dir)
#               https://github.com/openai/codex/blob/ae110493973d5b72f60d42efe2fae91d51ca9c0e/codex-rs/tui/src/lib.rs#L414-L418
#   Copilot CLI ~/.copilot/logs: process-<timestamp>-<pid>.log, plus logs/extensions/
#               https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference#logs
#   opencode    ~/.local/share/opencode/log: <timestamp>.log
#               https://github.com/anomalyco/opencode/blob/13afea6a1a76360936bbaa7677cff600ad52d452/packages/web/src/content/docs/troubleshooting.mdx#L10-L18
#   Goose       ~/.local/state/goose/logs: cli/<date>/, server/<date>/, extension logs
#               https://github.com/aaif-goose/goose/blob/0505d4bd2d915832d83418b188fa1df630217fc9/documentation/docs/guides/logs.md#L14
#   Cline       ~/.cline/data/logs: cline.log (CLINE_LOG_PATH default <CLINE_DATA_DIR>/logs/cline.log)
#               https://github.com/cline/cline/blob/789f79e46d3ba579717e8dc8be35fe28af935b06/apps/cli/README.md#L265
#   oh-my-pi    ~/.omp/logs: omp.<date>.<pid>.log
#               https://github.com/can1357/oh-my-pi/blob/d0362782e2107c3c49e5fa1cd05d1dd823697a3a/packages/utils/src/dirs.ts#L637-L657
MM_AGENTS_TABLE='
Claude Code|claude|~/.claude ~/.claude.json|~/.claude/projects ~/.claude/sessions|~/.local/share/claude/versions|~/.local/bin/claude||||*.jsonl
Codex CLI|codex|~/.codex|~/.codex/sessions|||~/.codex/worktrees|~/.codex/log
Gemini CLI|gemini|~/.gemini|~/.gemini/tmp|||
Cursor Agent|cursor-agent|~/.cursor|~/.cursor/chats ~/.cursor/projects|~/.local/share/cursor-agent/versions|~/.local/bin/cursor-agent|~/.cursor/worktrees
GitHub Copilot CLI|copilot|~/.copilot/session-state ~/.copilot/config.json|~/.copilot/session-state|~/.copilot/pkg/universal|~/.local/bin/copilot||~/.copilot/logs
Aider|aider|~/.aider ~/.aider.conf.yml||||
opencode|opencode|~/.local/share/opencode ~/.config/opencode|~/.local/share/opencode/project||||~/.local/share/opencode/log
Amp|amp|~/.amp ~/.local/share/amp ~/.config/amp|~/.local/share/amp|||
Goose|goose|~/.local/share/goose ~/.config/goose ~/.local/state/goose|~/.local/share/goose/sessions||||~/.local/state/goose/logs
Crush|crush|~/.local/share/crush ~/.config/crush||||
Qwen Code|qwen|~/.qwen|~/.qwen/tmp ~/.qwen/projects|||
Cline|cline|~/.cline|||||~/.cline/data/logs
oh-my-pi|omp|~/.omp|~/.omp/agent/sessions||||~/.omp/logs|__omp_worker_* ~/.omp/run/daemons/
Paseo|paseo|~/.paseo|~/.paseo/agents|||~/.paseo/worktrees
T3 Code|t3|~/.t3||||~/.t3/worktrees
Claude Squad|cs claude-squad|~/.claude-squad||||~/.claude-squad/worktrees
Crystal|crystal|~/.crystal||||
Container Use|container-use cu|~/.config/container-use||||~/.config/container-use/worktrees
uzi|uzi|~/.local/share/uzi||||~/.local/share/uzi/worktrees
'

MM_AGENT_NAME=() MM_AGENT_PROCS=() MM_AGENT_STATE=() MM_AGENT_SESSIONS=() MM_AGENT_VERSIONS=() MM_AGENT_ACTIVE=()
MM_AGENT_WORKTREES=() MM_AGENT_LOGS=() MM_AGENT_HELPERS=() MM_AGENT_SESSION_FILES=()
MM_AGENT_REJECTED=()   # "<file>:<line>: <reason>" for user rows that were not accepted

# _mm_tilde_list WORDS — the space-separated WORDS in REPLY, single-spaced, a leading ~ of each
# expanded. No subshell: it runs for every field of every row at each start.
_mm_tilde_list() {
  local -a w=()
  read -r -a w <<<"$1"
  w=("${w[@]/#\~/$HOME}")
  REPLY=${w[*]}
}

# _mm_agent_path_problem WORD — 0 with the reason in REPLY when WORD (a path of a user row) is not
# strictly inside $HOME as written and once symlinks are resolved, or has a . or .. segment or a
# glob character; 1 when it is fine.
_mm_agent_path_problem() {
  local p=$1 real
  [[ "$p" == \~/* ]] && p="$HOME${p:1}"
  if [[ "/$p/" == */../* || "/$p/" == */./* ]]; then REPLY="path '$1' has . or .. segments"; return 0; fi
  if [[ "$p" == *[\*?[]* ]]; then REPLY="path '$1' has glob characters"; return 0; fi
  real=$(realpath -m -- "$p" 2>/dev/null)
  [[ "$p" == "$HOME"/?* && "$real" == "$HOME"/?* ]] && return 1
  REPLY="'$1' is not inside your home folder"
}

# _mm_agents_parse ORIGIN — read rows from stdin and load them; a row named like a loaded one
# replaces it. Rows of the user's file (ORIGIN is its name) are validated first.
_mm_agents_parse() {
  local origin=$1 line n=0 i j w where bad name procs state sessions versions active worktrees logs helpers files
  local -a words=() more=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=${line//$'\t'/ }
    read -r line <<<"$line"
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS='|' read -r name procs state sessions versions active worktrees logs helpers files <<<"$line"
    read -r name <<<"$name"
    if [[ "$origin" != builtin ]]; then
      where="$origin:$n"
      if [[ "$line" == *[[:cntrl:]]* ]]; then MM_AGENT_REJECTED+=("$where: control characters"); continue; fi
      if [[ -z "$name" ]]; then MM_AGENT_REJECTED+=("$where: no name"); continue; fi
      if [[ -z "${procs// /}" ]]; then MM_AGENT_REJECTED+=("$where: no process names"); continue; fi
      read -r -a words <<<"$versions"
      read -r -a more <<<"$active"
      if ((${#words[@]} > 1 || ${#more[@]} > 1)); then
        MM_AGENT_REJECTED+=("$where: one versions dir and one active symlink at most"); continue
      fi
      read -r -a words <<<"$state $sessions $versions $active $worktrees $logs"
      read -r -a more <<<"$helpers"
      for w in "${more[@]}"; do [[ "$w" == \~/* || "$w" == /* ]] && words+=("$w"); done
      bad=""
      for w in "${words[@]}"; do _mm_agent_path_problem "$w" && { bad=$REPLY; break; }; done
      if [[ -n "$bad" ]]; then MM_AGENT_REJECTED+=("$where: $bad"); continue; fi
    fi
    [[ -n "$name" ]] || continue
    i=${#MM_AGENT_NAME[@]}
    for j in "${!MM_AGENT_NAME[@]}"; do [[ "${MM_AGENT_NAME[j]}" == "$name" ]] && { i=$j; break; }; done
    MM_AGENT_NAME[i]=$name
    MM_AGENT_PROCS[i]=$procs
    _mm_tilde_list "$state"; MM_AGENT_STATE[i]=$REPLY
    _mm_tilde_list "$sessions"; MM_AGENT_SESSIONS[i]=$REPLY
    _mm_tilde_list "$versions"; MM_AGENT_VERSIONS[i]=$REPLY
    _mm_tilde_list "$active"; MM_AGENT_ACTIVE[i]=$REPLY
    _mm_tilde_list "$worktrees"; MM_AGENT_WORKTREES[i]=$REPLY
    _mm_tilde_list "$logs"; MM_AGENT_LOGS[i]=$REPLY
    MM_AGENT_HELPERS[i]=$helpers
    read -r files <<<"$files"; MM_AGENT_SESSION_FILES[i]=$files
  done
}

# _mm_agents_load — the built-in table, then the user's agents file. lib/core.sh sets
# MM_CONFIG_DIR only after sourcing this file, hence the same default here.
_mm_agents_load() {
  local user="${MM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/marmot}/agents"
  _mm_agents_parse builtin <<<"$MM_AGENTS_TABLE"
  if [[ -f "$user" && -r "$user" ]]; then _mm_agents_parse "${user/#$HOME/\~}" <"$user"; fi
}
_mm_agents_load

# mm_agent_worktree_dirs — every agent worktree dir (~ expanded), one per line.
mm_agent_worktree_dirs() { printf '%s\n' "${MM_AGENT_WORKTREES[@]}" | tr ' ' '\n' | awk 'NF && !seen[$0]++'; }

# mm_agent_helper IDX PID — 0 if PID is a helper process of agent IDX (its helpers field): argv[1]
# matches one of the globs, or its working directory lies in or below one of the ~/ or / prefixes.
# Sets REPLY to the helper's kind: that argv[1], else the working directory's last component.
mm_agent_helper() {
  local p cwd="" arg
  local -a pats=() argv=()
  REPLY=""
  read -r -a pats <<<"${MM_AGENT_HELPERS[$1]:-}"
  ((${#pats[@]})) || return 1
  mapfile -d '' -t -n 2 argv 2>/dev/null <"/proc/$2/cmdline" || return 1
  arg=${argv[1]:-}
  for p in "${pats[@]}"; do
    case "$p" in
      \~/* | /*)
        [[ "$p" == \~/* ]] && p="$HOME${p:1}"
        p=${p%/}
        [[ -n "$cwd" ]] || cwd=$(readlink "/proc/$2/cwd" 2>/dev/null) || return 1
        if [[ "$cwd" == "$p" || "$cwd" == "$p"/* ]]; then REPLY=${cwd##*/}; return 0; fi
        ;;
      *)
        # shellcheck disable=SC2053 # the pattern is a glob on purpose
        if [[ -n "$arg" && "$arg" == $p ]]; then REPLY=$arg; return 0; fi
        ;;
    esac
  done
  return 1
}

# mm_agent_state_paths — every agent state path (dirs and files), one per line, with ~ unexpanded
# back to ~ so it reads well in the whitelist file.
mm_agent_state_paths() {
  local s p
  for s in "${MM_AGENT_STATE[@]}"; do
    for p in $s; do printf '%s\n' "~${p#"$HOME"}"; done
  done
}

# mm_agent_dir PATH — 0 if the resolved PATH is exactly one known agent's session, state or logs
# directory (not a file, not a folder above or below one) and lies strictly inside $HOME.
mm_agent_dir() {
  local s p r
  for s in "${MM_AGENT_SESSIONS[@]}" "${MM_AGENT_STATE[@]}" "${MM_AGENT_LOGS[@]}"; do
    for p in $s; do
      r=$(realpath -e -- "$p" 2>/dev/null) && [[ -d "$r" && "$r" == "$1" && "$r" == "$HOME"/?* ]] && return 0
    done
  done
  return 1
}
