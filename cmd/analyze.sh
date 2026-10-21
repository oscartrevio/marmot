# shellcheck shell=bash
# mm analyze [PATH] — disk explorer. With PATH: ncdu on it (or a largest-entries list without
# ncdu). Without: a quick overview of the usual space hogs on a dev/agent machine (sizes measured
# in parallel, time-boxed), then pick one to explore.

# Access modes of an overview row: user (yours: Trash offer after exploring), root (needs sudo to
# read; never offered), keep (agent state: reported only, never offered for removal).

# _analyze_row LABEL ACCESS PATH... — one location line: label<TAB>access<TAB>paths (\x1f-joined).
_analyze_row() {
  local label=$1 access=$2; shift 2
  local IFS=$'\x1f'
  printf '%s\t%s\t%s\n' "$label" "$access" "$*"
}

# _analyze_downloads_dir — the XDG download directory (user-dirs.dirs), else ~/Downloads.
_analyze_downloads_dir() {
  local d="" f="${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
  [[ -r "$f" ]] && d=$(sed -n 's/^XDG_DOWNLOAD_DIR="\(.*\)"$/\1/p' "$f" | tail -1)
  d=${d//\$HOME/$HOME}
  [[ "$d" == /* && "$d" != "$HOME" ]] || d="$HOME/Downloads"
  printf '%s' "$d"
}

# _analyze_locations — the overview rows. Paths that do not exist are skipped when measuring.
_analyze_locations() {
  local s p agent=() gopath=${GOPATH:-$HOME/go}
  for s in "${MM_AGENT_STATE[@]}"; do for p in $s; do agent+=("$p"); done; done
  _analyze_row "Home" user "$HOME"
  _analyze_row "Dev caches" user "${XDG_CACHE_HOME:-$HOME/.cache}" "$HOME/.npm" "$HOME/.cargo/registry" \
    "${gopath%%:*}/pkg" "$HOME/.gradle/caches"
  _analyze_row "Agent state" keep "${agent[@]}"
  _analyze_row "User data" user "${XDG_DATA_HOME:-$HOME/.local/share}"
  _analyze_row "Temp" user /tmp
  _analyze_row "Containers" root /var/lib/docker /var/lib/containerd /var/lib/containers
  _analyze_row "System" user /usr
  _analyze_row "Logs" root /var/log
  _analyze_row "Old Downloads (90d+)" user "$(_analyze_downloads_dir)"
}

# _analyze_du SUDO PATH — "bytes<TAB>status" where status is complete|partial. On timeout the
# size is a lower bound: the sum of every directory du finished (depth <= 3) not inside another.
_analyze_du() {
  local -a pre=(); [[ "$1" == 1 ]] && (( EUID != 0 )) && sudo -n true 2>/dev/null && pre=(sudo -n)
  local out rc
  out=$(timeout "${MM_ANALYZE_TIMEOUT:-20}" "${pre[@]}" stdbuf -oL du -xB1 -d3 -- "$2" 2>/dev/null); rc=$?
  awk -F'\t' -v root="$2" -v rc="$rc" '
    { s[$2] = $1 }
    END {
      if (root in s) { print s[root] "\t" (rc == 0 ? "complete" : "partial"); exit }
      for (k in s) { d = k; sub(/\/[^\/]*$/, "", d); if (!(d in s)) t += s[k] }
      printf "%.0f\tpartial\n", t
    }' <<<"$out"
}

# _analyze_old_downloads DIR — "bytes<TAB>status" for files not modified in 90+ days.
_analyze_old_downloads() {
  local out rc
  out=$(timeout "${MM_ANALYZE_TIMEOUT:-20}" find "$1" -xdev -type f -mtime +90 -printf '%b\n' 2>/dev/null); rc=$?
  awk -v rc="$rc" '{ t += $1 * 512 } END { printf "%.0f\t%s\n", t, (rc == 0 ? "complete" : "partial") }' <<<"$out"
}

# _analyze_measure IDX LABEL ACCESS PATHS OUTDIR — writes one overview row to OUTDIR/IDX:
# label<TAB>bytes<TAB>status<TAB>target<TAB>access, where target is the largest existing directory.
# Paths nested inside another listed path are not counted twice. Writes nothing if none exists.
_analyze_measure() {
  local idx=$1 label=$2 access=$3 dir=$5 p q res bytes total=0 status=complete target="" best=-1
  local -a paths=()
  IFS=$'\x1f' read -r -a paths <<<"$4"
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] || continue
    for q in "${paths[@]}"; do [[ "$p" == "$q"/* && -e "$q" ]] && continue 2; done
    if [[ "$label" == Old\ Downloads* ]]; then
      [[ -d "$p" ]] || continue
      res=$(_analyze_old_downloads "$p")
    else
      res=$(_analyze_du "$([[ "$access" == root ]] && echo 1 || echo 0)" "$p")
    fi
    bytes=${res%%$'\t'*}
    total=$((total + bytes))
    [[ "${res#*$'\t'}" == partial ]] && status=partial
    [[ -d "$p" ]] && (( bytes > best )) && { best=$bytes; target=$p; }
  done
  [[ -n "$target" ]] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$total" "$status" "$target" "$access" >"$dir/$idx.tmp"
  mv "$dir/$idx.tmp" "$dir/$idx"
}

# _analyze_overview_rows — measures every location in parallel (spinner on stderr) and prints
# rows sorted by size, largest first.
_analyze_overview_rows() {
  local dir label sudo paths i=0 n frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' f=0
  dir=$(mktemp -d -t marmot-analyze.XXXXXX)
  while IFS=$'\t' read -r label sudo paths; do
    i=$((i + 1))
    _analyze_measure "$i" "$label" "$sudo" "$paths" "$dir" &
  done < <(_analyze_locations)
  if [[ -t 2 ]]; then
    while [[ -n "$(jobs -rp)" ]]; do
      n=$(find "$dir" -maxdepth 1 -type f ! -name '*.tmp' | wc -l)
      printf '\r  %s%s%s Measuring %d locations… %d done ' "$C_CYAN" "${frames:f++%10:1}" "$C_RESET" "$i" "$n" >&2
      sleep 0.1
    done
    printf '\r\e[K' >&2
  fi
  wait
  cat "$dir"/[0-9]* 2>/dev/null | sort -t$'\t' -k2,2nr
  [[ "$dir" == "${TMPDIR:-/tmp}"/marmot-analyze.* ]] && rm -rf -- "$dir" # SAFE: this function's own mktemp -d scratch dir
}

# _analyze_bar BYTES MAX — 24-wide bar scaled to the largest row.
_analyze_bar() {
  local fill=0 i bar=""
  (( $2 > 0 )) && fill=$(( ($1 * 24 + $2 / 2) / $2 ))
  for ((i = 0; i < 24; i++)); do if (( i < fill )); then bar+="█"; else bar+=" "; fi; done
  printf '%s%s%s' "$C_CYAN" "$bar" "$C_RESET"
}

# _analyze_render USED ROWS... — numbered lines with a usage bar; percent is of used disk space.
_analyze_render() {
  local used=$1; shift
  local max=0 row label bytes status target access n=0 size pct mark note
  (( $# )) && { IFS=$'\t' read -r _ max _ <<<"$1"; }
  for row in "$@"; do
    IFS=$'\t' read -r label bytes status target access <<<"$row"
    n=$((n + 1))
    pct=$(awk -v b="$bytes" -v u="$used" 'BEGIN { printf "%.1f", (u > 0 ? b * 100 / u : 0) }')
    size=$(mm_human "$bytes"); [[ "$status" == partial ]] && size+="+"
    mark="  "; (( n == 1 )) && mark="${C_GREEN}▶${C_RESET} "
    note=""
    [[ "$label" == Old\ Downloads* ]] && note="  ${C_DIM}>3mo${C_RESET}"
    [[ "$access" == keep ]] && note="  ${C_DIM}report only${C_RESET}"
    mm_tilde "$target"
    printf ' %s%2d. %s %5s%%  |  %-22s %9s  %s%s%s%s\n' "$mark" "$n" "$(_analyze_bar "$bytes" "$max")" \
      "$pct" "$label" "$size" "$C_DIM" "$REPLY" "$C_RESET" "$note"
  done
}

# _analyze_launch PATH [ACCESS] — explore PATH: ncdu, always read-only (ncdu's own delete would
# bypass marmot's checks), or a largest-entries list when ncdu is missing or there is no terminal
# for it. ACCESS root opens as root when sudo is available. Afterwards, on a terminal, a
# user-writable PATH (ACCESS user) gets the offer to move picked entries to the Trash via mm_rm.
_analyze_launch() {
  local path=$1 access=${2:-user} note="read-only" offer=0
  local -a pre=()
  if [[ "$access" == root ]] && (( EUID != 0 )); then
    if mm_can_sudo; then pre=(sudo); note="read-only, opened as root"
    else mm_warn "No sudo: some folders under $path will be unreadable"; fi
  fi
  [[ "$MM_TTY" == 1 && "$access" == user && -w "$path" ]] && offer=1
  (( offer )) && note+="; afterwards marmot offers to move picked items to the Trash"
  [[ "$access" == keep ]] && note+="; agent state is reported, never removed"
  if [[ "$MM_TTY" == 1 ]] && command -v ncdu >/dev/null; then
    local -a cmd=(ncdu -x -r --color dark)
    ncdu --help 2>&1 | grep -q -- '--exclude-kernfs' && cmd+=(--exclude-kernfs)
    printf '\n  %sKeys:%s g graph · q quit  %s(%s)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$note" "$C_RESET"
    printf '  %sOpening %s in ncdu%s\n' "$C_DIM" "$path" "$C_RESET"
    sleep 0.5
    "${pre[@]}" "${cmd[@]}" -- "$path"
  else
    local why="install ncdu for an interactive browser"
    [[ "$MM_TTY" == 1 ]] || why="no terminal: the ncdu explorer needs one"
    printf '\n%sLargest entries under %s%s  %s(%s)%s\n\n' "$C_BOLD" "$path" "$C_RESET" "$C_DIM" "$why" "$C_RESET"
    local line as=""
    [[ ${#pre[@]} -gt 0 ]] && sudo -n true 2>/dev/null && as=sudo
    while IFS= read -r line; do
      printf '  %9s  %s\n' "$(mm_human "${line%%$'\t'*}")" "${line#*$'\t'}"
    done < <(_analyze_candidates "$path" "$as" | head -25)
  fi
  (( offer )) && _analyze_trash_offer "$path"
  return 0
}

# _analyze_candidates ROOT [sudo] — "bytes<TAB>path" for the largest entries up to 3 levels below
# ROOT (ROOT itself excluded; names with control characters skipped: mm_rm refuses them anyway).
_analyze_candidates() {
  local -a pre=(); [[ "${2:-}" == sudo ]] && pre=(sudo -n)
  timeout "${MM_ANALYZE_TIMEOUT:-20}" "${pre[@]}" du -0xB1 --max-depth=3 -- "$1" 2>/dev/null |
    MM_ROOT="$1" awk -v RS='\0' 'BEGIN { root = ENVIRON["MM_ROOT"] }
      { tab = index($0, "\t"); p = substr($0, tab + 1) }
      p != root && p !~ /[[:cntrl:]]/ { print substr($0, 1, tab - 1) "\t" p }' |
    sort -t$'\t' -k1,1nr | head -300
}

# _analyze_trash_offer ROOT — terminal only: pick entries under ROOT (fzf), confirm, and move each
# to the Trash with mm_rm --trash (all of marmot's refusal rules apply). Dry-run only reports.
_analyze_trash_offer() {
  local root=${1%/} line rel bytes picks=() rows=()
  [[ "$MM_TTY" == 1 ]] || return 0
  printf '\n'
  mm_tilde "$root"
  mm_confirm "Move something under $REPLY to the Trash?" || return 0
  mapfile -t rows < <(_analyze_candidates "$root")
  (( ${#rows[@]} )) || { mm_info "Nothing to pick under $root"; return 0; }
  mapfile -t picks < <(for line in "${rows[@]}"; do
      bytes=${line%%$'\t'*} rel=${line#*$'\t'}; rel=${rel#"$root"/}
      printf '%9s\t%s\n' "$(mm_human "$bytes")" "$rel"
    done | mm_pick "TAB: mark items to move to the Trash · Enter: continue · Esc: none")
  (( ${#picks[@]} )) || { mm_info "Nothing selected"; return 0; }

  printf '\n'
  for line in "${picks[@]}"; do mm_info "${line%%$'\t'*}  ${line#*$'\t'}"; done
  if [[ "$MM_DRY_RUN" != 1 ]] && ! mm_confirm "Move these ${#picks[@]} items to the Trash?"; then
    mm_info "Nothing moved"; return 0
  fi
  mm_inuse_refresh
  local before=$MM_TRASHED
  for line in "${picks[@]}"; do
    rel=${line#*$'\t'}
    if mm_rm --trash "$root/$rel" "$root"; then mm_ok "$rel" "$(mm_human "$MM_LAST_BYTES")"
    else mm_skip "$rel" "$MM_SKIP_REASON"; fi
  done
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_info "Would move to Trash: $(mm_human $((MM_TRASHED - before))) (dry run: nothing moved)"
  else
    mm_info "Moved to Trash: $(mm_human $((MM_TRASHED - before))) (restore: trash-restore)"
  fi
}

# _analyze_json USED FREE ROWS... — the overview as JSON (no jq needed).
_analyze_json() {
  local used=$1 free=$2; shift 2
  printf '%s\n' "$@" | awk -F'\t' -v used="$used" -v free="$free" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[[:cntrl:]]/, "?", s); return s }
    BEGIN { printf "{\"free_bytes\":%.0f,\"used_bytes\":%.0f,\"entries\":[", free, used }
    NF >= 5 {
      printf "%s{\"name\":\"%s\",\"path\":\"%s\",\"bytes\":%.0f,\"scan_status\":\"%s\",\"report_only\":%s,\"percent_of_used\":%.1f}",
        sep, esc($1), esc($4), $2, $3, ($5 == "keep" ? "true" : "false"), (used > 0 ? $2 * 100 / used : 0)
      sep = ","
    }
    END { print "]}" }'
}

_analyze_usage() {
  cat <<EOF
Usage: mm analyze [PATH] [--json]

  mm analyze          overview: home, dev caches, agent state, user data, /tmp, containers,
                      /usr, logs, old downloads; pick one to explore
  mm analyze PATH     explore PATH (same filesystem only)
  mm analyze --json   print the overview as JSON

Sizes ending in + are lower bounds (scan hit the ${MM_ANALYZE_TIMEOUT:-20}s limit or unreadable folders).
Exploring uses ncdu, always read-only (root-owned locations as root, when sudo is available);
without ncdu or without a terminal the largest entries are listed. Afterwards, for a folder of
yours, marmot offers to move picked items to the Trash (fzf; same safety checks as mm clean;
dry-run only reports).
Agent state (Claude Code, Codex, ... see lib/agents.sh) is reported only.
Environment: MM_ANALYZE_TIMEOUT (seconds per location).
EOF
}

mm_cmd_main() {
  local json=0 path=""
  while (( $# )); do
    case "$1" in
      --json) json=1 ;;
      -h|--help) _analyze_usage; return 0 ;;
      -*) mm_die "unknown option: $1 (see mm analyze --help)" ;;
      *) [[ -z "$path" ]] || mm_die "only one PATH allowed"; path=$1 ;;
    esac
    shift
  done

  if [[ -n "$path" ]]; then
    (( json )) && mm_die "--json prints the overview and takes no PATH"
    [[ -d "$path" ]] || mm_die "not a directory: $path"
    path=$(realpath -e -- "$path")
    local access=user; [[ -r "$path" && -x "$path" ]] || access=root
    _analyze_launch "$path" "$access"
    return
  fi

  local used free rows=()
  read -r used free < <(df -B1 --output=used,avail / | awk 'NR == 2 { print $1, $2 }')
  mapfile -t rows < <(_analyze_overview_rows)
  if (( json )); then _analyze_json "$used" "$free" "${rows[@]}"; return; fi

  local header
  header="Analyze Disk  ($(mm_human "$free") free)"
  if [[ "$MM_TTY" == 1 && -t 1 ]] && command -v fzf >/dev/null && (( ${#rows[@]} )); then
    local pick
    pick=$(_analyze_render "$used" "${rows[@]}" | fzf --ansi --reverse --no-multi --no-sort \
      --height=$(( ${#rows[@]} + 4 )) --prompt='filter> ' \
      --header="$header · Enter: open in ncdu · Esc: quit (% of used disk)")
    if [[ -z "$pick" ]]; then
      printf '\n%s%s%s\n\n' "$C_BOLD" "$header" "$C_RESET"
      _analyze_render "$used" "${rows[@]}"
      return 0
    fi
    [[ "$pick" =~ ([0-9]+)\. ]] || return 0
  else
    printf '\n%s%s%s\nSelect a location to explore (%% of used disk):\n\n' "$C_BOLD" "$header" "$C_RESET"
    _analyze_render "$used" "${rows[@]}"
    [[ "$MM_TTY" == 1 && -t 1 ]] && (( ${#rows[@]} )) || return 0
    local reply
    printf '\n%s?%s Explore which? [1-%d, Enter to quit] ' "$C_YELLOW" "$C_RESET" "${#rows[@]}"
    read -r reply </dev/tty
    [[ "$reply" =~ ^([0-9]+)$ ]] || return 0
  fi
  local n=${BASH_REMATCH[1]}
  (( n >= 1 && n <= ${#rows[@]} )) || mm_die "no such entry: $n"
  local label bytes status target access
  IFS=$'\t' read -r label bytes status target access <<<"${rows[n - 1]}"
  _analyze_launch "$target" "$access"
}
