# shellcheck shell=bash
# marmot core library: UI, formatting, sudo, history.
# Sourced by the `mm` entry point. Every state-changing action MUST go through mm_run, which
# honors MM_DRY_RUN.

# Path rules compare realpath'd targets against $HOME-based paths, so HOME must be canonical
# too: no symlinks, no trailing slash.
_mm_home=$(realpath -e -- "${HOME:?HOME is not set}" 2>/dev/null)
if [[ -z "$_mm_home" || "$_mm_home" == / ]]; then echo "marmot: HOME ($HOME) must resolve to a real directory other than /" >&2; exit 1; fi
HOME=$_mm_home; unset _mm_home

MM_VERSION="0.2.0"
MM_HOME="${MM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MM_CONFIG_DIR="${MM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/marmot}"
MM_STATE_DIR="${MM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/marmot}"
MM_LOG_FILE="${MM_LOG_FILE:-$MM_STATE_DIR/operations.log}"

: "${MM_DRY_RUN:=0}" "${MM_DEBUG:=0}"
MM_CMD="${MM_CMD:-marmot}"
# MM_TTY=1 when the user ran marmot from a terminal (stdin is a tty and /dev/tty opens). Decided once
# here, at startup: inside pipelines and $(...) stdin/stdout are not the terminal, so later -t
# checks lie. Prompts and pickers talk to /dev/tty directly.
if [[ -z "${MM_TTY:-}" ]]; then
  if [[ -t 0 ]] && { : </dev/tty; } 2>/dev/null; then MM_TTY=1; else MM_TTY=0; fi
fi

# ---------------------------------------------------------------- UI

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m' C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_RESET=""
fi
MM_RULE="======================================================================"

# mm_header TITLE — command title plus a one-line system summary.
mm_header() {
  printf '\n%s%s%s' "$C_BOLD" "$1" "$C_RESET"
  [[ "$MM_DRY_RUN" == 1 ]] && printf '  %s(dry run: nothing will change)%s' "$C_YELLOW" "$C_RESET"
  printf '\n\n%s⚙%s %s\n' "$C_CYAN" "$C_RESET" "$(mm_sysline)"
}
mm_section() { printf '\n%s➤ %s%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }
# mm_ok LABEL [DETAIL]
mm_ok()   { printf '  %s✓%s %s%s\n' "$C_GREEN" "$C_RESET" "$1" "${2:+ · $2}"; }
# mm_skip LABEL REASON
mm_skip() { printf '  %s◎%s %s · %sskipped (%s)%s\n' "$C_DIM" "$C_RESET" "$1" "$C_DIM" "$2" "$C_RESET"; }
mm_act()  { printf '  %s→%s %s\n' "$C_CYAN" "$C_RESET" "$1"; }
mm_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
mm_err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
mm_info() { printf '  %s\n' "$1"; }
mm_debug() { [[ "$MM_DEBUG" == 1 ]] && printf '  %s[debug] %s%s\n' "$C_DIM" "$1" "$C_RESET" >&2; return 0; }
mm_die()  { mm_err "$1"; exit "${2:-1}"; }

# mm_banner TITLE LINE... — closing summary block.
mm_banner() {
  local title="$1"; shift
  printf '\n%s\n%s%s%s\n' "$MM_RULE" "$C_BOLD" "$title" "$C_RESET"
  local line; for line in "$@"; do printf '%s\n' "$line"; done
  printf '%s\n' "$MM_RULE"
}

# mm_bar PERCENT [WIDTH] — "█████░░░░" colored by threshold (>=90 red, >=75 yellow).
mm_bar() {
  local pct=${1%.*} width=${2:-20} fill color
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  fill=$(( (pct * width + 50) / 100 ))
  if (( pct >= 90 )); then color=$C_RED; elif (( pct >= 75 )); then color=$C_YELLOW; else color=$C_GREEN; fi
  printf '%s' "$color"
  local i; for ((i = 0; i < fill; i++)); do printf '█'; done
  printf '%s' "$C_DIM"
  for ((i = fill; i < width; i++)); do printf '░'; done
  printf '%s' "$C_RESET"
}

# mm_confirm QUESTION — y/N prompt on the terminal. There is no auto-accept: without a terminal
# (cron, pipes, scripts) every confirmation declines, so unattended runs never escalate.
mm_confirm() {
  [[ "$MM_TTY" == 1 ]] || return 1
  local reply
  printf '%s?%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$1" >/dev/tty
  read -r reply </dev/tty || return 1
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------- formatting

# mm_human BYTES — 1.2GB / 340.0MB / 12KB.
mm_human() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%dB", b; else if (i == 2) printf "%dKB", b; else printf "%.1f%s", b, u[i]
  }'
}

# mm_size PATH... — total bytes on disk (0 if missing). Uses sudo when MM_SIZE_SUDO=1.
mm_size() {
  (( $# )) || { echo 0; return; }
  local -a pre=(); [[ "${MM_SIZE_SUDO:-0}" == 1 ]] && pre=(sudo -n)
  "${pre[@]}" du -scB1 --one-file-system -- "$@" 2>/dev/null | awk 'END { print $1 + 0 }'
}

# mm_free_bytes [MOUNT] — available bytes on the filesystem holding MOUNT (default /).
mm_free_bytes() { df -B1 --output=avail "${1:-/}" 2>/dev/null | awk 'NR == 2 { print $1 + 0 }'; }

# mm_idle_days PATH — whole days since the newest activity anywhere in PATH's tree: mtime and
# ctime of every entry (ctime catches fresh extractions/moves that keep old mtimes) and atime of
# regular files (reads). Directory atimes are ignored: our own scans would refresh them.
mm_idle_days() {
  local newest
  newest=$(find "$1" -xdev \( -type f -printf '%A@\n' -o -true \) -printf '%T@\n%C@\n' 2>/dev/null |
    sort -n | tail -1)
  [[ -n "$newest" ]] || { echo 0; return; }
  echo $(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
}

# mm_sysline — "Ubuntu 24.04.5 LTS · 8 cores · 31GB RAM | Free: 37.0GB | Up 3h".
mm_sysline() {
  local os mem up
  os=$(. /etc/os-release && echo "$PRETTY_NAME")
  mem=$(awk '/MemTotal/ { printf "%dGB", $2 / 1048576 + 0.5 }' /proc/meminfo)
  up=$(uptime -p | sed 's/^up //; s/ days\?/d/; s/ hours\?/h/; s/ minutes\?/m/; s/,//g')
  printf '%s · %s cores · %s RAM | Free: %s | Up %s' "$os" "$(nproc)" "$mem" "$(mm_human "$(mm_free_bytes /)")" "$up"
}

# ---------------------------------------------------------------- sudo

# mm_can_sudo — 0 if root, passwordless sudo works, or we can prompt on a tty.
mm_can_sudo() { (( EUID == 0 )) || sudo -n true 2>/dev/null || [[ "$MM_TTY" == 1 ]]; }
# mm_sudo CMD... — run as root; prompts only when needed.
mm_sudo() {
  if (( EUID == 0 )); then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else sudo "$@"; fi
}

# mm_proc_age PID — seconds since process start. Fields are counted after the last ") " because
# comm may contain spaces and parentheses ("tmux: server").
mm_proc_age() {
  local start hz boot
  start=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{ print $20 }')
  [[ "$start" =~ ^[0-9]+$ ]] || return 1
  hz=$(getconf CLK_TCK); boot=$(awk '/^btime/ { print $2 }' /proc/stat)
  echo $(( $(date +%s) - boot - start / hz ))
}

# ---------------------------------------------------------------- history

# mm_log ACTION TARGET [BYTES] [DETAIL] — append to the operations log (real runs only, never dry-run).
# ACTION: remove | trash | refused | failed | run. DETAIL: refusal reason or Trash location.
mm_log() {
  [[ "$MM_DRY_RUN" == 1 ]] && return 0
  mkdir -p "$MM_STATE_DIR"
  # Control characters (tab/newline in a file name) would break the TSV rows.
  local target="${2//[[:cntrl:]]/?}" detail="${4:-}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$MM_CMD" "$1" "$target" "${3:-0}" \
    "${detail//[[:cntrl:]]/?}" >>"$MM_LOG_FILE"
}

# ---------------------------------------------------------------- safe actions

# mm_run DESCRIPTION CMD... — run a state-changing command; in dry-run only reports it.
# Output goes to stderr in debug mode, otherwise is captured and shown only on failure.
mm_run() {
  local desc="$1"; shift
  if [[ "$MM_DRY_RUN" == 1 ]]; then mm_debug "would run: $*"; return 0; fi
  local out rc
  out=$("$@" 2>&1); rc=$?
  [[ "$MM_DEBUG" == 1 && -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
  if (( rc != 0 )); then
    mm_err "$desc failed (exit $rc)"
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2
  else
    mm_log run "$desc"
  fi
  return "$rc"
}

# mm_proc_running NAME — 0 if NAME runs: exact comm, or a script whose argv names it (node-shebang
# tools like pnpm/npm/yarn run as comm "node"/"MainThread"). Used for "<tool> busy" skips.
mm_proc_running() {
  pgrep -x "$1" >/dev/null 2>&1 || pgrep -f "(^|/)$1(\\.c?js)?( |\$)" >/dev/null 2>&1
}

# mm_pick HEADER < lines — fzf multi-select on the terminal (TAB marks). Prints selected lines.
# No terminal or no fzf selects nothing; there is no way to select everything unattended.
mm_pick() {
  if [[ "$MM_TTY" != 1 ]] || ! command -v fzf >/dev/null; then
    cat >/dev/null
    [[ "$MM_TTY" == 1 ]] && mm_warn "fzf is not installed: nothing selected" >&2
    return 0
  fi
  fzf --multi --ansi --reverse --height=~60% --header="$1" --header-first \
      --bind 'ctrl-a:select-all,ctrl-d:deselect-all' --prompt='filter> '
}
