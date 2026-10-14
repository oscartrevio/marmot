# shellcheck shell=bash
# marmot core library: UI, formatting, sudo, in-use detection, whitelist, safe removal, history.
# Sourced by the `mm` entry point. Every deletion MUST go through mm_rm; every
# state-changing non-path action MUST go through mm_run. Both honor MM_DRY_RUN.

# Path rules compare realpath'd targets against $HOME-based paths, so HOME must be canonical
# too: no symlinks, no trailing slash.
_mm_home=$(realpath -e -- "${HOME:?HOME is not set}" 2>/dev/null)
if [[ -z "$_mm_home" || "$_mm_home" == / ]]; then echo "marmot: HOME ($HOME) must resolve to a real directory other than /" >&2; exit 1; fi
HOME=$_mm_home; unset _mm_home

MM_VERSION="0.2.0"
MM_HOME="${MM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=agents.sh
. "$MM_HOME/lib/agents.sh"
MM_CONFIG_DIR="${MM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/marmot}"
MM_STATE_DIR="${MM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/marmot}"
MM_WHITELIST_FILE="${MM_WHITELIST_FILE:-$MM_CONFIG_DIR/whitelist}"
MM_LOG_FILE="${MM_LOG_FILE:-$MM_STATE_DIR/operations.log}"
# XDG Trash (freedesktop.org spec): items moved here keep a .trashinfo, so `trash-restore`
# (trash-cli) or any desktop file manager can put them back.
MM_TRASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"

: "${MM_DRY_RUN:=0}" "${MM_DEBUG:=0}"
MM_CMD="${MM_CMD:-marmot}"
# Byte counts below are what a delete really releases (mm_frees): files hard-linked from outside
# the item (pnpm's store, cp -al copies) stay on disk and are not counted.
MM_FREED=0     # bytes permanently freed (or that would be, in dry-run) by mm_rm
MM_TRASHED=0   # bytes moved to the Trash (or that would be) by mm_rm --trash; not freed yet
MM_COUNT=0     # items removed or trashed by mm_rm
MM_SKIPPED=0   # items refused by mm_rm
MM_SKIP_REASON=""
MM_LAST_BYTES=0  # bytes the last successful mm_rm freed (or moved to the Trash)
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

# Every awk that hands a number back to bash prints it with printf "%.0f": mawk 1.3.4-20200120
# (Debian 12, Ubuntu 22.04) prints integers above 2^31-1 as 2.14748e+09 and clamps %d to
# 2147483647, which bash arithmetic rejects or miscounts. %.0f is exact up to 2^53.

# mm_size PATH... — total bytes on disk (0 if missing). Uses sudo when MM_SIZE_SUDO=1.
mm_size() {
  (( $# )) || { echo 0; return; }
  local -a pre=(); [[ "${MM_SIZE_SUDO:-0}" == 1 ]] && pre=(sudo -n)
  "${pre[@]}" du -scB1 --one-file-system -- "$@" 2>/dev/null | awk 'END { printf "%.0f\n", $1 }'
}

# mm_size_frees PATH... — "SIZE FREES" in bytes for the trees at PATHs, from one walk (0 0 if
# missing). SIZE is disk usage with every inode counted once, like du. FREES is what deleting all
# of PATHs would release: directories, and files whose every hard link lies inside them. A pnpm
# node_modules hard-linked to the store is large in SIZE and nearly nothing in FREES. Uses sudo
# when MM_SIZE_SUDO=1.
mm_size_frees() {
  (( $# )) || { echo "0 0"; return; }
  local -a pre=(); [[ "${MM_SIZE_SUDO:-0}" == 1 ]] && pre=(sudo -n)
  "${pre[@]}" find "$@" -xdev -printf '%D:%i %n %b %y\n' 2>/dev/null | awk '
    $4 == "d" || $2 < 2 { s += $3; f += $3; next }
    { if (!($1 in seen)) s += $3; if (++seen[$1] == $2) f += $3 }
    END { printf "%.0f %.0f\n", s * 512, f * 512 }'
}

# mm_frees PATH... — the FREES half of mm_size_frees.
mm_frees() {
  local s f
  read -r s f < <(mm_size_frees "$@")
  printf '%s\n' "${f:-0}"
}

# mm_free_bytes [MOUNT] — available bytes on the filesystem holding MOUNT (default /).
mm_free_bytes() { df -B1 --output=avail "${1:-/}" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $1 }'; }

# mm_sysline — "Ubuntu 24.04.5 LTS · 8 cores · 31GB RAM | Free: 37.0GB | Up 3d 4h 12m".
mm_sysline() {
  local os mem s up=""
  os=$(. /etc/os-release && echo "$PRETTY_NAME")
  mem=$(awk '/MemTotal/ { printf "%dGB", $2 / 1048576 + 0.5 }' /proc/meminfo)
  read -r s _ </proc/uptime; s=${s%.*}
  (( s >= 86400 )) && up+="$((s / 86400))d "
  (( s % 86400 >= 3600 )) && up+="$((s % 86400 / 3600))h "
  up+="$((s % 3600 / 60))m"
  printf '%s · %s cores · %s RAM | Free: %s | Up %s' "$os" "$(nproc)" "$mem" "$(mm_human "$(mm_free_bytes /)")" "$up"
}

# ---------------------------------------------------------------- sudo

# mm_can_sudo — 0 if root, or sudo is installed and either works without a password or can prompt
# on a tty.
mm_can_sudo() {
  (( EUID == 0 )) && return 0
  command -v sudo >/dev/null && { sudo -n true 2>/dev/null || [[ "$MM_TTY" == 1 ]]; }
}
# mm_sudo CMD... — run as root; prompts only when needed.
mm_sudo() {
  if (( EUID == 0 )); then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else sudo "$@"; fi
}

# ---------------------------------------------------------------- in-use detection

MM_INUSE=""        # newline-separated snapshot; kept in memory so a killed run leaves no files
MM_INUSE_TAKEN=0
# mm_inuse_refresh — snapshot every path any process has as cwd, root, exe, open fd, mapping, or
# bound unix socket, plus every mount point and bind-mount source (per mount namespace), so a
# target containing a mount is never removed through it. Sees all processes with sudo; otherwise
# only this user's (MM_INUSE_PARTIAL=1, warned). An empty snapshot is fatal: it would mean "nothing
# is in use".
mm_inuse_refresh() {
  local script='declare -A ns=(); { for p in /proc/[0-9]*; do
      readlink "$p/cwd" "$p/root" "$p/exe"
      for f in "$p"/fd/*; do readlink "$f"; done
      awk '"'"'$6 ~ /^\// { print $6 }'"'"' "$p/maps"
      n=$(readlink "$p/ns/mnt") && [[ -z "${ns[$n]:-}" ]] && { ns[$n]=1; awk '"'"'{ print $4; print $5 }'"'"' "$p/mountinfo"; }
    done; awk '"'"'{ print $4; print $5 }'"'"' /proc/self/mountinfo
    awk '"'"'NR > 1 && $8 ~ /^\// { print $8 }'"'"' /proc/net/unix; } 2>/dev/null |
    sed "s/ (deleted)\$//" | grep "^/" | sort -u'
  MM_INUSE_PARTIAL=0
  if (( EUID == 0 )) || sudo -n true 2>/dev/null; then
    MM_INUSE=$(mm_sudo bash -c "$script")
  else
    MM_INUSE_PARTIAL=1
    MM_INUSE=$(bash -c "$script")
  fi
  MM_INUSE_TAKEN=1
  [[ -n "$MM_INUSE" ]] || mm_die "could not list in-use paths; refusing to delete anything"
  if [[ "$MM_INUSE_PARTIAL" == 1 && -z "${_MM_PARTIAL_WARNED:-}" ]]; then
    _MM_PARTIAL_WARNED=1
    mm_warn "No passwordless sudo: only your own processes are checked for in-use paths"
  fi
  mm_debug "in-use snapshot: $(mm_inuse_paths | wc -l) paths (partial=$MM_INUSE_PARTIAL)"
}

# mm_inuse_paths — print the current snapshot, one path per line (taking one if needed).
mm_inuse_paths() {
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh
  [[ -n "$MM_INUSE" ]] && printf '%s\n' "$MM_INUSE"
  return 0
}

# mm_in_use PATH — 0 if PATH or anything under it is in use per the last snapshot.
mm_in_use() {
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh
  [[ -n "$MM_INUSE" ]] || return 0   # no snapshot (e.g. refresh died in a subshell): fail closed
  MM_P="${1%/}" awk 'BEGIN { p = ENVIRON["MM_P"] }
    $0 == p || index($0, p "/") == 1 { found = 1; exit } END { exit !found }' <<<"$MM_INUSE"
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

# ---------------------------------------------------------------- whitelist

# Built-in protections: always on, not editable. Credentials and keys, app configuration, and
# every known agent's state (settings, credentials, session transcripts; see lib/agents.sh).
MM_BUILTIN_KEEP=(~/.ssh ~/.gnupg ~/.password-store ~/.local/share/keyrings ~/.pki ~/.netrc
  ~/.git-credentials ~/.aws ~/.azure ~/.kube ~/.docker ~/.config)

MM_DEFAULT_WHITELIST='# marmot whitelist: your own additions, one path or glob per line; ~ expands.
# Matching paths, anything under them, and every folder above them are never removed.
# Always protected (built in): ~/.ssh, ~/.gnupg, credentials (~/.aws, ~/.kube, ~/.docker,
# ~/.netrc, ...), ~/.config, and the state of known coding agents (~/.claude, ~/.codex, ...).
# Examples:
#   ~/datasets
#   ~/projects/*/fixtures
'

mm_whitelist_init() {
  mkdir -p "$MM_CONFIG_DIR"
  [[ -f "$MM_WHITELIST_FILE" ]] || printf '%s' "$MM_DEFAULT_WHITELIST" >"$MM_WHITELIST_FILE"
}

# mm_keep_patterns — every protection pattern: built-ins, agent state, then the whitelist file.
# MM_KEEP_AGENT_STATE=0 leaves agent state out; only for removing git worktrees that git reports
# clean (agents such as Cursor keep their worktrees inside their state dir).
mm_keep_patterns() {
  printf '%s\n' "${MM_BUILTIN_KEEP[@]}"
  [[ "${MM_KEEP_AGENT_STATE:-1}" == 0 ]] || mm_agent_state_paths
  cat -- "$MM_WHITELIST_FILE"
}

# mm_whitelisted PATH — 0 if removing PATH would touch a protected entry (built-in, agent state,
# or whitelist file): PATH or an ancestor matches it, or it lies under PATH. Globs follow [[ == ]]
# rules (* crosses /).
mm_whitelisted() {
  mm_whitelist_init 2>/dev/null
  # Fail closed: an unreadable whitelist must not mean "nothing is protected".
  [[ -r "$MM_WHITELIST_FILE" ]] || { mm_err "cannot read whitelist $MM_WHITELIST_FILE: refusing"; return 0; }
  local path="${1%/}" pat probe lit
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    pat="${pat%%#*}"; pat="${pat%"${pat##*[![:space:]]}"}"; pat="${pat#"${pat%%[![:space:]]*}"}"
    [[ -n "$pat" ]] || continue
    [[ "$pat" == "~"* ]] && pat="$HOME${pat:1}"
    pat="${pat%/}"
    probe="$path"
    while [[ -n "$probe" ]]; do
      # shellcheck disable=SC2053
      [[ "$probe" == $pat ]] && return 0
      [[ "$probe" == */* ]] || break
      probe="${probe%/*}"
    done
    lit="${pat%%[*?[]*}"
    [[ "$lit" == "$path"/* ]] && return 0
    # Glob whose literal prefix is above PATH: look for an actual match underneath.
    if [[ "$lit" != "$pat" && "$path/" == "$lit"* && -d "$path" ]] &&
       [[ -n "$(find "$path" -xdev -path "$pat" -print -quit 2>/dev/null)" ]]; then
      return 0
    fi
  done < <(mm_keep_patterns)
  return 1
}

mm_whitelist_edit() {
  mm_whitelist_init
  "${VISUAL:-${EDITOR:-nano}}" "$MM_WHITELIST_FILE"
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

MM_PROTECTED_EXACT=("/" "$HOME" "/home" "/root" "/tmp" "/var/tmp" "/var")
# Whole trees marmot never deletes inside: the OS, package-manager and service state (cleaned only
# through their own tools), other disks, and credentials. /root is one too, except for root's own
# runs: with HOME=/root its contents follow the same rules as a /home/<user> home (the folder
# itself stays protected above, its credentials below and through the built-in whitelist).
MM_PROTECTED_TREES=(/bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /run /sbin /sys /usr /snap
  /opt /srv /mnt /media /lost+found
  /var/lib /var/log /var/cache /var/spool /var/mail /var/backups /var/snap /var/opt /var/www /var/crash
  "$HOME/.ssh" "$HOME/.gnupg")
[[ "$HOME" == /root ]] || MM_PROTECTED_TREES+=(/root)

# mm_protected REAL — 0 (and prints why) if the resolved path REAL is a protected path, lies in a
# protected tree, or is a home directory under /home.
mm_protected() {
  local p
  for p in "${MM_PROTECTED_EXACT[@]}"; do [[ "$1" == "${p%/}" || "$1" == "$p" ]] && { echo protected; return 0; }; done
  for p in "${MM_PROTECTED_TREES[@]}"; do [[ "$1" == "$p" || "$1" == "$p"/* ]] && { echo protected; return 0; }; done
  [[ "$1" == /home/* && "${1#/home/}" != */* ]] && { echo "protected (a home directory)"; return 0; }
  return 1
}

# mm_identity PATH — "device:inode:ctime" of PATH itself (a final symlink is not followed).
mm_identity() { stat -c '%d:%i:%Z' -- "$1" 2>/dev/null; }

# mm_rm [--trash] PATH ALLOWED_ROOT — the only way marmot deletes or trashes files.
# Refuses unless PATH is strictly inside ALLOWED_ROOT (after resolving parent symlinks), has no
# control characters, is not protected, not whitelisted, not in use, and is still the same object
# (device/inode/ctime) and location after sizing. --trash moves it to the XDG Trash instead and
# never falls back to a permanent delete.
# Returns 0 done (or would be, in dry-run), 1 refused (MM_SKIP_REASON set), 2 action failed.
# Updates MM_FREED or MM_TRASHED (by mm_frees), MM_COUNT, MM_SKIPPED, MM_LAST_BYTES. Refusals
# other than "missing" and failures are written to the operations log.
mm_rm() {
  local mode=remove
  [[ "${1:-}" == --trash ]] && { mode=trash; shift; }
  local path="${1:-}" root="${2:-}" parent real bytes p id
  root="${root%/}"
  MM_SKIP_REASON="" MM_LAST_BYTES=0
  _mm_refuse() {
    MM_SKIP_REASON="$1"; MM_SKIPPED=$((MM_SKIPPED + 1)); mm_debug "refused $path: $1"
    [[ "$1" == missing ]] || mm_log refused "$path" 0 "$1"
    return 1
  }

  [[ -n "$root" ]] || { _mm_refuse "allowed root too broad"; return 1; }
  [[ "$path" == /* && "$root" == /* ]] || { _mm_refuse "not an absolute path"; return 1; }
  [[ "$path$root" == *[[:cntrl:]]* ]] && { _mm_refuse "control characters in name"; return 1; }
  [[ "/$path/" == */../* || "/$path/" == */./* ]] && { _mm_refuse "path has . or .. segments"; return 1; }
  [[ -e "$path" || -L "$path" ]] || { _mm_refuse "missing"; return 1; }
  path="${path%/}"
  parent=$(realpath -e -- "$(dirname -- "$path")" 2>/dev/null) || { _mm_refuse "parent unresolvable"; return 1; }
  real="$parent/$(basename -- "$path")"
  root=$(realpath -e -- "$root" 2>/dev/null) || { _mm_refuse "root missing"; return 1; }
  [[ "$real" == "$root"/* ]] || { _mm_refuse "outside $root"; return 1; }
  p=$(mm_protected "$real") && { _mm_refuse "$p"; return 1; }
  mm_whitelisted "$real" && { _mm_refuse "whitelisted"; return 1; }
  mm_in_use "$real" && { _mm_refuse "in use"; return 1; }

  id=$(mm_identity "$real") || { _mm_refuse "missing"; return 1; }
  bytes=$(mm_frees "$real")
  # The accounting below is bash arithmetic: validate now, so nothing fails after the rm.
  [[ "$bytes" =~ ^[0-9]+$ ]] || { _mm_refuse "size unreadable"; return 1; }
  # Sizing a large tree takes a while: act only if the same object is still at the same place.
  if [[ "$(realpath -e -- "$(dirname -- "$real")" 2>/dev/null)" != "$parent" || "$(mm_identity "$real")" != "$id" ]]; then
    _mm_refuse "changed while sizing"; return 1
  fi
  if [[ "$MM_DRY_RUN" != 1 ]]; then
    if [[ "$mode" == trash ]]; then
      _mm_trash "$real" "$bytes" || return $?
    else
      if ! rm -rf --one-file-system -- "$real" 2>/dev/null; then # SAFE: mm_rm's single sink, after every check above
        MM_SKIP_REASON="rm failed"; mm_log failed "$real" "$bytes" "rm failed"; return 2
      fi
      mm_log remove "$real" "$bytes"
    fi
  fi
  if [[ "$mode" == trash ]]; then MM_TRASHED=$((MM_TRASHED + bytes)); else MM_FREED=$((MM_FREED + bytes)); fi
  MM_COUNT=$((MM_COUNT + 1)) MM_LAST_BYTES=$bytes
  mm_debug "$([[ "$MM_DRY_RUN" == 1 ]] && echo 'would ')$mode $real ($(mm_human "$bytes"))"
  return 0
}

# _mm_url_encode PATH — percent-encode for a .trashinfo Path= line (bytes, keeps / and unreserved).
_mm_url_encode() {
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [A-Za-z0-9/._~-]) out+=$c ;;
      *) printf -v c '%02X' "'$c"; out+="%${c: -2}" ;;   # high bytes print sign-extended: keep 2 digits
    esac
  done
  printf '%s' "$out"
}

# _mm_trash REAL BYTES — move REAL into $MM_TRASH_DIR/files with a matching .trashinfo (created
# first, exclusively, to claim the name). Only a same-mount rename is used; anything that would
# need a copy, or an unusable Trash, is refused: 1 = refused, 2 = move failed. Never deletes.
_mm_trash() {
  local real="$1" bytes="$2" files="$MM_TRASH_DIR/files" info="$MM_TRASH_DIR/info" base name n=1 stamp enc
  (umask 077; mkdir -p "$files" "$info") 2>/dev/null   # Trash dirs are private (spec: 0700)
  if [[ -L "$MM_TRASH_DIR" || -L "$files" || -L "$info" || ! -d "$files" || ! -d "$info" || ! -w "$files" || ! -w "$info" ]]; then
    _mm_refuse "Trash unusable ($MM_TRASH_DIR)"; return 1
  fi
  if [[ "$(stat -c '%d %m' -- "$real" 2>/dev/null)" != "$(stat -c '%d %m' -- "$files" 2>/dev/null)" ]]; then
    _mm_refuse "Trash is on another filesystem"; return 1
  fi
  base=$(basename -- "$real") name=$base enc=$(_mm_url_encode "$real") stamp=$(date +%Y-%m-%dT%H:%M:%S)
  until [[ ! -e "$files/$name" && ! -L "$files/$name" ]] &&
        ( set -C; printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$enc" "$stamp" >"$info/$name.trashinfo" ) 2>/dev/null; do
    n=$((n + 1)) name="$base.$n"
    (( n > 1000 )) && { _mm_refuse "no free name in Trash"; return 1; }
  done
  if ! mv -T -- "$real" "$files/$name" 2>/dev/null; then
    rm -f -- "$info/$name.trashinfo" # SAFE: the .trashinfo this call just created
    MM_SKIP_REASON="move to Trash failed"; mm_log failed "$real" "$bytes" "move to Trash failed"; return 2
  fi
  mm_log trash "$real" "$bytes" "$files/$name"
}

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

# ---------------------------------------------------------------- processes
# Busy checks read /proc directly: procps and psmisc (pgrep, fuser) are missing from minimal
# images and containers, and a missing tool must never read as "nothing is running".

# mm_proc_match COMM_ERE [ARGV_ERE] — 0 if some process other than this shell has a name (comm,
# at most 15 characters) that COMM_ERE matches entirely, or a command line (arguments joined by
# spaces, like pgrep -f) that ARGV_ERE matches. An empty pattern matches nothing.
mm_proc_match() {
  local p comm IFS=' ' argv=()
  for p in /proc/[0-9]*; do
    [[ "${p#/proc/}" == "$$" || "${p#/proc/}" == "$BASHPID" ]] && continue
    if [[ -n "$1" ]] && { IFS= read -r comm <"$p/comm"; } 2>/dev/null && [[ "$comm" =~ ^($1)$ ]]; then
      return 0
    fi
    if [[ -n "${2:-}" ]] && { mapfile -d '' -t argv <"$p/cmdline"; } 2>/dev/null &&
       (( ${#argv[@]} )) && [[ "${argv[*]}" =~ $2 ]]; then
      return 0
    fi
  done
  return 1
}

# mm_proc_running NAME — 0 if NAME runs: exact comm, or a script whose argv names it (node-shebang
# tools like pnpm/npm/yarn run as comm "node"/"MainThread"). Used for "<tool> busy" skips.
mm_proc_running() { mm_proc_match "$1" "(^|/)$1(\\.c?js)?( |\$)"; }

# mm_proc_children PID — the PIDs whose parent is PID, one per line.
mm_proc_children() {
  local p st f=()
  for p in /proc/[0-9]*; do
    { IFS= read -r st <"$p/stat"; } 2>/dev/null || continue
    read -r -a f <<<"${st##*) }"   # comm may hold spaces and ")": fields start after the last ") "
    [[ "${f[1]:-}" == "$1" ]] && echo "${p#/proc/}"
  done
  return 0
}

# mm_apt_busy — 0, printing why, when apt, dpkg or an unattended-upgrade run is in progress, or a
# process holds one of the dpkg/apt lock files open. The holders are root's processes, so their
# open files are read as root; when that fails (sudo password refused) the answer is "busy": a
# step that runs apt must skip rather than race.
# (unattended-upgrade-shutdown waits for shutdown all day and shares the truncated comm
# "unattended-upgr" with the run itself, so the run is matched on its command line.)
mm_apt_busy() {
  if mm_proc_match 'apt|apt-get|aptitude|dpkg' '/unattended-upgrade( |$)'; then echo "apt is running"; return 0; fi
  local out locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  if (( EUID != 0 )) && ! { command -v sudo >/dev/null && sudo -n true 2>/dev/null; }; then
    # Without root, passwordless sudo, or a terminal to ask for a password, nothing can run apt as
    # root either (and a dry run runs nothing): there is no step to protect.
    [[ "$MM_DRY_RUN" != 1 && "$MM_TTY" == 1 ]] && command -v sudo >/dev/null || return 1
  fi
  out=$(mm_sudo bash -c 'if for f in /proc/[0-9]*/fd/*; do readlink "$f"; done 2>/dev/null |
    grep -qxF -f <(printf "%s\n" "$@"); then echo held; else echo free; fi' _ "${locks[@]}")
  case "$out" in
    free) return 1 ;;
    held) echo "a process holds the apt lock" ;;
    *) echo "apt locks not visible without sudo" ;;
  esac
  return 0
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
