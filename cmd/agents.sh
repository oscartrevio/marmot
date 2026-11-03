# shellcheck shell=bash
# shellcheck disable=SC2153 # MM_AGENT_* and MM_CAT_* are set by lib/agents.sh and lib/catalog.sh
# mm agents [--json] — what every coding agent and harness on this machine (lib/agents.sh, plus
# your rows) has installed, keeps and leaves behind, and what marmot does about each piece.
# Read-only: it measures and names the command that cleans a piece, or says that nothing does.
#
# Per agent: the install (version, when, the command that updates it), running processes and the
# ones on replaced code, state, sessions (files, size, oldest), logs, old versions, worktrees,
# and folders named after it in ~/.cache, ~/.local/share, ~/.local/state and /tmp. Then what
# agents leave around them: the npx and uvx caches MCP servers run from, browser builds and
# automation profiles, and your files in /tmp.

# shellcheck source=../lib/catalog.sh
. "$MM_HOME/lib/catalog.sh"

_AGENTS_TMP_OLD_DAYS=7

_agents_usage() {
  cat <<EOF
Usage: mm agents [--json]

Shows, for every coding agent and harness marmot knows (and your rows in $MM_CONFIG_DIR/agents),
what it has installed, keeps and leaves behind, read-only:

  install    version, when it was installed, the command that updates it (mm optimize runs it)
  running    its processes, and those still on code an update replaced (restart them)
  state      its settings, credentials and memory: never removed; the largest folders inside
  sessions   transcripts: count, size, oldest (mm clean --sessions N moves old ones to the Trash)
  logs       its own logs (mm clean removes those older than 7 days)
  versions   installed releases (mm clean keeps the active one and the previous one)
  worktrees  git worktrees it made (mm purge removes finished ones)
  other      folders named after it in ~/.cache, ~/.local/share, ~/.local/state and /tmp

Then what agents leave around them: the npx and uvx caches MCP servers run from, browser builds
and automation profiles, and your files in /tmp. Each row says which marmot command cleans it,
or that none does.

Options:
  --json     Print it as JSON (needs jq); sizes in bytes, null where unknown
  -h, --help Show this help
EOF
}

# _agents_size PATH... — REPLY: bytes on disk of PATHs together (each counted once), "" unknown.
_agents_size() { REPLY=$(mm_size "$@") || REPLY=""; }

# _agents_files DIR [GLOB...] — REPLY: "count bytes oldest_epoch" of the files under DIR (those
# matching a GLOB when given; memory folders, worktrees and git checkouts left out, as the
# session sweep does), "" when none.
_agents_files() {
  local dir=$1 g
  local -a names=() filt=()
  shift
  for g in "$@"; do ((${#names[@]})) && names+=(-o); names+=(-name "$g"); done
  ((${#names[@]})) && filt=(\( "${names[@]}" \))
  REPLY=$(find "$dir" \( -name memory -o -name worktrees -o -name .git \) -prune -o -type f \
    "${filt[@]}" -printf '%T@ %s\n' 2>/dev/null |
    awk '{ n++; b += $2; t = int($1); if (o == "" || t < o) o = t } END { if (n) printf "%d %.0f %.0f\n", n, b, o }')
}

# _agents_dir DIR — one du walk of DIR: REPLY "bytes<TAB>its three largest entries" ("projects
# 1.2GB, plugins 200MB, ..."); the size is empty when du did not finish.
_agents_dir() {
  REPLY=$(timeout "${MM_SIZE_TIMEOUT:-300}" du -B1 -d1 --one-file-system -- "$1" 2>/dev/null |
    awk -F'\t' -v d="$1" "$MM_AWK_HUMAN"'
      $2 == d { total = $1; next }
      { n = $2; sub(/.*\//, "", n); s[n] = $1 }
      END { for (k = 0; k < 3; k++) { best = ""; for (n in s) if (best == "" || s[n] > s[best]) best = n
              if (best == "" || s[best] == 0) break
              out = out (out ? ", " : "") best " " human(s[best]); delete s[best] }
            printf "%s\t%s\n", total, out }')
}

# _agents_cleaner PATH — REPLY: what marmot does with PATH: "mm clean" for a catalog cache or
# browser-build folder, "reported by mm clean" for a catalog report row, else empty.
_agents_cleaner() {
  local i p
  REPLY=""
  for i in "${!MM_CAT_PATH[@]}"; do
    p=${MM_CAT_PATH[i]}
    [[ "$1" == "$p" || "$1" == "$p"/* ]] || continue
    case "${MM_CAT_KIND[i]}" in
      cache | revisions | versions) REPLY="mm clean" ;;
      *) REPLY="reported by mm clean" ;;
    esac
    return 0
  done
}

# _agents_emit AGENT PART PATH BYTES DETAIL ACTION — one row of the report, kept in _AG_ROWS.
_agents_emit() { _AG_ROWS+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"$'\x1f'"$5"$'\x1f'"$6"); }

# _agents_known PATH — 0 if PATH is, holds or lies in a folder some agent row names (state,
# sessions, versions, logs, worktrees): it shows under that part already.
_agents_known() {
  local p
  for p in "${_AG_KNOWN[@]}"; do
    [[ "$1" == "$p" || "$1" == "$p"/* || "$p" == "$1"/* ]] && return 0
  done
  return 1
}

# _agents_collect — measure every agent's pieces into _AG_ROWS, the agents that have any in
# _AG_ORDER, and the shared leftovers under the agent "*".
_agents_collect() {
  local i p e n b o d pat name lname now running stale sess part
  local -a pats=() inst=() list=()
  local -A procs=() outdated=() claimed=() has=()
  _AG_ROWS=() _AG_ORDER=() _AG_KNOWN=()
  now=$(date +%s)
  mm_catalog_load
  for i in "${!MM_AGENT_NAME[@]}"; do
    for p in ${MM_AGENT_STATE[i]} ${MM_AGENT_SESSIONS[i]} ${MM_AGENT_VERSIONS[i]} ${MM_AGENT_LOGS[i]} ${MM_AGENT_WORKTREES[i]}; do
      _AG_KNOWN+=("$p")
    done
  done
  mapfile -t inst < <(mm_installs)
  mm_installs_agent_index "$(printf '%s\n' "${inst[@]}")"
  while IFS=$'\t' read -r i p; do
    procs[$i]+=" $p"
    mm_proc_outdated "$p" "$i" && outdated[$i]+=" $p"
  done < <(mm_agent_procs)

  for i in "${!MM_AGENT_NAME[@]}"; do
    name=${MM_AGENT_NAME[i]}
    local kind cmd ver at upd how
    if [[ -n "${MM_AGENT_INSTALL[$i]:-}" ]]; then
      IFS=$MM_FS read -r kind cmd ver at upd how _ _ p <<<"${MM_AGENT_INSTALL[$i]}"
      mm_days_ago "$at" "$now"
      e="$cmd${ver:+ $ver} · $how · installed $(mm_ago $((now - at)))"
      ((REPLY > MM_TOOL_OLD_DAYS)) && e+=" (old)"
      _agents_emit "$name" install "$p" "" "$e" "${upd:+mm optimize ($upd)}"
      has[$i]=1
    fi
    if [[ -n "${procs[$i]:-}" ]]; then
      read -r -a list <<<"${procs[$i]}"
      running=${#list[@]}
      e="$running process$( ((running > 1)) && echo es)"
      stale=""
      if [[ -n "${outdated[$i]:-}" ]]; then
        read -r -a list <<<"${outdated[$i]}"
        e+=", ${#list[@]} on replaced code (pids ${list[*]:0:5})"
        stale="restart them to load the update"
      fi
      _agents_emit "$name" running "" "" "$e" "$stale"
      has[$i]=1
    fi
    for p in ${MM_AGENT_STATE[i]}; do
      [[ -e "$p" ]] || continue
      e=""
      if [[ -d "$p" ]]; then
        _agents_dir "$p"
        b=${REPLY%%$'\t'*} e=${REPLY#*$'\t'} e=${e:+largest: $e}
      else
        _agents_size "$p"; b=$REPLY
      fi
      _agents_emit "$name" state "$p" "$b" "$e" "kept: agent state"
      has[$i]=1
    done
    for p in ${MM_AGENT_SESSIONS[i]}; do
      [[ -d "$p" ]] || continue
      read -r -a pats <<<"${MM_AGENT_SESSION_FILES[i]:-}"
      _agents_files "$p" "${pats[@]}"
      [[ -n "$REPLY" ]] || continue
      read -r n b o <<<"$REPLY"
      mm_days_ago "$o" "$now"
      sess="$n files · oldest ${REPLY}d"
      _agents_emit "$name" sessions "$p" "$b" "$sess" "mm clean --sessions N (to the Trash)"
      has[$i]=1
    done
    for p in ${MM_AGENT_LOGS[i]}; do
      [[ -d "$p" ]] || continue
      _agents_files "$p" '*.log'
      [[ -n "$REPLY" ]] || continue
      read -r n b o <<<"$REPLY"
      _agents_emit "$name" logs "$p" "$b" "$n log files" "mm clean (older than 7 days)"
      has[$i]=1
    done
    p=${MM_AGENT_VERSIONS[i]:-}
    if [[ -n "$p" && -d "$p" ]]; then
      n=$(find "$p" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
      if ((n)); then
        _agents_size "$p"
        _agents_emit "$name" versions "$p" "$REPLY" "$n installed" "mm clean (keeps the active and the previous)"
        has[$i]=1
      fi
    fi
    for p in ${MM_AGENT_WORKTREES[i]}; do
      [[ -d "$p" ]] || continue
      n=$(find "$p" -mindepth 1 -maxdepth 3 -name .git -type f 2>/dev/null | wc -l)
      ((n)) || continue
      _agents_size "$p"
      _agents_emit "$name" worktrees "$p" "$REPLY" "$n worktrees" "mm purge (finished ones)"
      has[$i]=1
    done

    # Folders named after it elsewhere: its process names and its own name ("claude",
    # "claude-cli-nodejs", "cursor-compile-cache"), each claimed by the first agent that matches.
    lname=${name,,} lname=${lname// /-}
    pats=()
    for e in ${MM_AGENT_PROCS[i]} "$lname" "${lname%%-*}"; do
      ((${#e} >= 3)) || continue
      [[ " ${pats[*]} " == *" $e "* ]] || pats+=("$e")
    done
    list=()
    for d in "$HOME/.cache" "${XDG_DATA_HOME:-$HOME/.local/share}" "${XDG_STATE_HOME:-$HOME/.local/state}" "${TMPDIR:-/tmp}"; do
      for pat in "${pats[@]}"; do
        for p in "$d/$pat" "$d/$pat"[-_.]*; do
          [[ -e "$p" && ! -L "$p" && -O "$p" && -z "${claimed[$p]:-}" ]] || continue
          claimed[$p]=1
          _agents_known "$p" && continue
          # Its files in /tmp make one row; they are scratch, often one per task.
          if [[ "$d" == "${TMPDIR:-/tmp}" ]]; then list+=("$p"); continue; fi
          _agents_size "$p"; b=$REPLY
          _agents_cleaner "$p"
          _agents_emit "$name" other "$p" "$b" "" "${REPLY:-not cleaned by marmot}"
          has[$i]=1
        done
      done
    done
    if ((${#list[@]})); then
      _agents_size "${list[@]}"; b=$REPLY
      e="${#list[@]} entr$( ((${#list[@]} > 1)) && echo ies || echo y): ${list[0]##*/}"
      ((${#list[@]} > 1)) && e+=", ${list[1]##*/}"
      ((${#list[@]} > 2)) && e+=" +$((${#list[@]} - 2)) more"
      _agents_emit "$name" temp "${TMPDIR:-/tmp}" "$b" "$e" "mm analyze ${TMPDIR:-/tmp} (explore, pick what goes)"
      has[$i]=1
    fi
    [[ -n "${has[$i]:-}" ]] && _AG_ORDER+=("$name")
  done
  _agents_shared "$now"
  _agents_mcp
}

# _agents_shared NOW — what agents leave around them, under the agent "*": the caches MCP servers
# run from, browser builds and automation profiles, and this user's files in /tmp.
_agents_shared() {
  local now=$1 p n b o row tmp=${TMPDIR:-/tmp}
  local cache=${XDG_CACHE_HOME:-$HOME/.cache}
  local -a list=()
  for row in "npx (MCP servers started with npx)|$HOME/.npm/_npx" "uv (MCP servers started with uvx)|$cache/uv" \
    "Playwright browsers|$cache/ms-playwright" "Puppeteer browsers|$cache/puppeteer" \
    "agent-browser Chrome builds|$HOME/.agent-browser/browsers"; do
    p=${row#*|}
    [[ -d "$p" ]] || continue
    _agents_size "$p"; b=$REPLY
    _agents_cleaner "$p"
    _agents_emit "*" "${row%%|*}" "$p" "$b" "" "${REPLY:-not cleaned by marmot}"
  done
  mapfile -t list < <(find "$tmp" -mindepth 1 -maxdepth 1 -user "$(id -u)" \
    \( -name 'playwright_*' -o -name 'puppeteer_dev_*' -o -name 'playwright-artifacts-*' -o -name '.org.chromium.*' \) 2>/dev/null)
  if ((${#list[@]})); then
    _agents_size "${list[@]}"
    _agents_emit "*" "browser profiles in $tmp" "$tmp" "$REPLY" "${#list[@]} automation profiles" "mm clean (browser temp files)"
  fi
  # Everything of yours directly in /tmp: agents write scratch files there under random names.
  read -r n o < <(find "$tmp" -mindepth 1 -maxdepth 1 -user "$(id -u)" -printf '%T@\n' 2>/dev/null |
    awk -v cut=$((now - _AGENTS_TMP_OLD_DAYS * 86400)) '{ n++; if ($1 < cut) o++ } END { printf "%d %d\n", n, o }')
  if ((n)); then
    # One du walk: each entry's size, their sum and the three largest.
    mapfile -t list < <(find "$tmp" -mindepth 1 -maxdepth 1 -user "$(id -u)" 2>/dev/null)
    IFS=$'\t' read -r b e < <(timeout "${MM_SIZE_TIMEOUT:-300}" du -sB1 --one-file-system -- "${list[@]}" 2>/dev/null |
      sort -nr | awk -F'\t' "$MM_AWK_HUMAN"'
        { t += $1; if (NR <= 3) { n = $2; sub(/.*\//, "", n); top = top (top ? ", " : "") n " " human($1) } }
        END { printf "%.0f\t%s\n", t, top }')
    _agents_emit "*" "your files in $tmp" "$tmp" "$b" "$n entries, $o untouched for ${_AGENTS_TMP_OLD_DAYS}+ days${e:+; largest: $e}" \
      "mm analyze $tmp (explore, pick what goes)"
  fi
}

# _AGENTS_MCP_FILES — where agents and editors keep user-scope MCP server lists (relative to the
# home): Claude Code (also per project, inside the same file), Cursor, Gemini CLI, Qwen Code,
# Copilot CLI, opencode, Windsurf, VS Code, Kimi CLI, Codex CLI (TOML).
_AGENTS_MCP_FILES=(.claude.json .cursor/mcp.json .gemini/settings.json .qwen/settings.json
  .copilot/mcp-config.json .config/opencode/opencode.json .codeium/windsurf/mcp_config.json
  .config/Code/User/mcp.json .kimi/mcp.json .codex/config.toml)

# _agents_mcp_list FILE — "name command args url" (MM_FS-separated) for each MCP server FILE
# configures: the entries of every mcpServers, mcp_servers, servers or mcp object that have a command or a url
# (a command may be an array, opencode's form). JSON needs jq; Codex's TOML is read with awk.
_agents_mcp_list() {
  if [[ "$1" == *.toml ]]; then
    awk '
      function flush() { if (name != "") printf "%s\037%s\037%s\037%s\n", name, cmd, args, url; name = "" }
      function strs(s,   out, a, n, i) { n = split(s, a, "\""); for (i = 2; i <= n; i += 2) out = out (out ? " " : "") a[i]; return out }
      /^\[/ { flush(); if ($0 ~ /^\[mcp_servers\.[^].]+\]/) { name = $0; sub(/^\[mcp_servers\./, "", name); sub(/\].*/, "", name); gsub(/"/, "", name); cmd = args = url = "" } next }
      name != "" && /^[[:space:]]*command[[:space:]]*=/ { cmd = strs($0) }
      name != "" && /^[[:space:]]*args[[:space:]]*=/ { args = strs($0) }
      name != "" && /^[[:space:]]*url[[:space:]]*=/ { url = strs($0) }
      END { flush() }' "$1" 2>/dev/null
    return 0
  fi
  command -v jq >/dev/null || return 0
  jq -r '[.. | objects | to_entries[] | select(.key == "mcpServers" or .key == "mcp_servers" or .key == "servers" or .key == "mcp")
      | .value | objects | to_entries[] | select(.value | type == "object" and (has("command") or has("url")))
      | [.key, (.value.command | if type == "array" then .[0] else . end // ""),
         (((.value.command | if type == "array" then .[1:] else [] end) + (.value.args // [])) | map(tostring) | join(" ")),
         (.value.url // "")] | map(gsub("[[:cntrl:]]"; " "))] | unique[] | join("\u001f")' "$1" 2>/dev/null
}

# _agents_mcp_risk COMMAND ARGS URL — REPLY: why a server deserves a look, empty when nothing
# stands out: a package runner (npx, bunx, pnpm dlx, uvx, ...) given a package with no version
# fetches whatever was published last at every start; a container image with no tag or :latest
# likewise; a remote server over plain http outside this machine sends its traffic in the clear.
_agents_mcp_risk() {
  local cmd=${1##*/} a spec="" runner=0 skip=0
  local -a args=()
  REPLY=""
  read -r -a args <<<"$2"
  if [[ -n "$3" ]]; then
    [[ "$3" == http://* && ! "$3" =~ ^http://(localhost|127\.|\[::1\]) ]] && REPLY="plain http to a remote server: traffic and tokens in the clear"
    return 0
  fi
  case "$cmd" in
    npx | bunx | pnpx | uvx) runner=1 ;;
    pnpm | yarn) [[ "${args[0]:-}" == dlx ]] && { runner=1; args=("${args[@]:1}"); } ;;
    npm) [[ "${args[0]:-}" == exec ]] && { runner=1; args=("${args[@]:1}"); } ;;
    bun) [[ "${args[0]:-}" == x ]] && { runner=1; args=("${args[@]:1}"); } ;;
    docker | podman)
      [[ "${args[0]:-}" == run ]] || return 0
      for a in "${args[@]:1}"; do
        if ((skip)); then skip=0; continue; fi
        case "$a" in -e | -v | -p | --env | --name | --network | --mount | -w | --entrypoint | --user | -u) skip=1; continue ;; -*) continue ;; esac
        spec=$a; break
      done
      [[ -n "$spec" && ( "${spec##*/}" != *:* || "$spec" == *:latest ) && "$spec" != *@sha256:* ]] &&
        REPLY="runs image $spec with no fixed tag: whatever is pushed last"
      return 0 ;;
  esac
  ((runner)) || return 0
  for a in "${args[@]}"; do
    if ((skip)); then skip=0; continue; fi
    case "$a" in
      --from) continue ;;
      -p | --package | --with | --python) skip=1; continue ;;
      -*) continue ;;
    esac
    spec=$a
    break
  done
  [[ -n "$spec" ]] || return 0
  # npm specs: name@1.2.3 or @scope/name@1.2.3; Python: name==1.2 or name@1.2.
  a=${spec#@}
  if [[ "$a" == *@latest || "$a" == *@next || ( "$a" != *@[0-9~^]* && "$a" != *==* ) ]]; then
    REPLY="$cmd runs $spec with no version: fetches whatever was published last, at every start"
  fi
  return 0
}

# _agents_mcp — the MCP servers in _AGENTS_MCP_FILES as rows of the agent "mcp".
_agents_mcp() {
  local f name cmd args url t
  for f in "${_AGENTS_MCP_FILES[@]}"; do
    f=$HOME/$f
    [[ -f "$f" ]] || continue
    while IFS=$MM_FS read -r name cmd args url; do
      [[ -n "$name" ]] || continue
      _agents_mcp_risk "$cmd" "$args" "$url"
      t=$url
      [[ -n "$t" ]] || t="$cmd${args:+ $args}"
      ((${#t} > 80)) && t="${t:0:77}..."
      _agents_emit mcp "$name" "$f" "" "$t" "${REPLY:+review: $REPLY}"
    done < <(_agents_mcp_list "$f")
  done
}

# _agents_print — the report for people.
_agents_print() {
  local name row a part p b det act total=0 label t
  local -a paths=()
  for name in "${_AG_ORDER[@]}" "*" mcp; do
    case "$name" in
      "*") mm_section "Around the agents" ;;
      mcp) [[ " ${_AG_ROWS[*]} " == *" mcp"$'\x1f'* || "${_AG_ROWS[*]}" == mcp$'\x1f'* ]] || continue; mm_section "MCP servers" ;;
      *) mm_section "$name" ;;
    esac
    for row in "${_AG_ROWS[@]}"; do
      IFS=$'\x1f' read -r a part p b det act <<<"$row"
      [[ "$a" == "$name" ]] || continue
      label=$part t=""
      [[ -n "$p" && "$part" != install ]] && { mm_tilde "$p"; t=$REPLY; }
      [[ "$a" == mcp ]] && t+=" · $det" det=""
      [[ -n "$b" ]] && t+="${t:+ · }$(mm_human "$b")"
      [[ -n "$det" ]] && t+="${t:+ · }$det"
      [[ -n "$act" ]] && t+="${t:+ · }→ $act"
      if [[ "$act" == restart* || "$act" == review* || "$det" == *"(old)"* ]]; then mm_warn "$label: $t"
      elif [[ "$act" != "mm clean"* && "$act" != "mm purge"* && "$act" != "mm optimize"* ]]; then mm_skip "$label" "$t"
      else mm_ok "$label" "$t"; fi
      [[ -n "$p" && -n "$b" && "$a" != "*" && "$a" != mcp && "$part" != install && "$part" != temp ]] && paths+=("$p"$'\t'"$b")
    done
  done
  # On disk: the agents' own rows, a row inside another one (sessions in state) counted once.
  local q inner
  for row in "${paths[@]}"; do
    p=${row%%$'\t'*} inner=0
    for q in "${paths[@]}"; do q=${q%%$'\t'*}; [[ "$p" == "$q"/* ]] && { inner=1; break; }; done
    ((inner)) || total=$((total + ${row#*$'\t'}))
  done
  mm_result info "Agent footprint" "*agents" "${#_AG_ORDER[@]} found" "on disk" "$(mm_human "$total") in their own folders" \
    "next" "mm clean --dry-run · mm purge --dry-run · mm optimize"
}

# _agents_json — the report as JSON.
_agents_json() {
  printf '%s\n' "${_AG_ROWS[@]}" | jq -Rn '
    [inputs | select(length > 0) | split("\u001f") | {agent: .[0], part: .[1], path: (if .[2] == "" then null else .[2] end),
      bytes: (if .[3] == "" then null else (.[3] | tonumber) end), detail: (if .[4] == "" then null else .[4] end),
      action: (if .[5] == "" then null else .[5] end)}]
    | { agents: (map(select(.agent != "*" and .agent != "mcp")) | group_by(.agent) | map({ name: .[0].agent, parts: map(del(.agent)) })),
        around: map(select(.agent == "*") | del(.agent)),
        mcp_servers: map(select(.agent == "mcp") | { name: .part, config: .path, command: .detail,
          risk: (.action // "" | sub("^review: "; "") | if . == "" then null else . end) }) }'
}

mm_cmd_main() {
  local json=0
  while (($#)); do
    case "$1" in
      --json) json=1 ;;
      -h | --help) _agents_usage; return 0 ;;
      *) mm_die "unknown option: $1 (see mm agents --help)" ;;
    esac
    shift
  done
  if ((json)); then
    command -v jq >/dev/null || mm_die "jq is required for --json"
    _agents_collect
    _agents_json
    return 0
  fi
  mm_header "Agents"
  _agents_collect
  _agents_print
}
