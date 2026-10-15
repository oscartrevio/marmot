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
MM_CONFIG_FILE="${MM_CONFIG_FILE:-$MM_CONFIG_DIR/config}"
MM_LOG_FILE="${MM_LOG_FILE:-$MM_STATE_DIR/operations.log}"
# XDG Trash (freedesktop.org spec): items moved here keep a .trashinfo, so `trash-restore`
# (trash-cli) or any desktop file manager can put them back.
MM_TRASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"

: "${MM_DRY_RUN:=0}" "${MM_DEBUG:=0}" "${MM_NO_SUDO:=0}"
MM_CMD="${MM_CMD:-marmot}"
# Byte counts below are what a delete really releases (mm_frees): files hard-linked from outside
# the item (pnpm's store, cp -al copies) stay on disk and are not counted.
MM_FREED=0     # bytes permanently freed (or that would be, in dry-run) by mm_rm
MM_TRASHED=0   # bytes moved to the Trash (or that would be) by mm_rm --trash; not freed yet
MM_COUNT=0     # items removed or trashed by mm_rm
MM_SKIPPED=0   # items refused by mm_rm
MM_SKIP_REASON=""
MM_LAST_BYTES=0  # bytes the last successful mm_rm freed (or moved to the Trash)
# Every mm_skip ("label<TAB>reason") and every error (mm_err, a failed mm_rm) of this run, for
# summaries an unattended run writes down (mm schedule run).
MM_SKIPS=() MM_ERRORS=()
# MM_TTY=1 when the user ran marmot from a terminal (stdin is a tty and /dev/tty opens). Decided once
# here, at startup: inside pipelines and $(...) stdin/stdout are not the terminal, so later -t
# checks lie. Prompts and pickers talk to /dev/tty directly.
if [[ -z "${MM_TTY:-}" ]]; then
  if [[ -t 0 ]] && { : </dev/tty; } 2>/dev/null; then MM_TTY=1; else MM_TTY=0; fi
fi

# ---------------------------------------------------------------- UI

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_RESET=""
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
# mm_skip LABEL REASON — also recorded in MM_SKIPS.
mm_skip() {
  MM_SKIPS+=("$1"$'\t'"$2")
  printf '  %s◎%s %s · %sskipped (%s)%s\n' "$C_DIM" "$C_RESET" "$1" "$C_DIM" "$2" "$C_RESET"
}
mm_act()  { printf '  %s→%s %s\n' "$C_CYAN" "$C_RESET" "$1"; }
mm_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
mm_err()  { MM_ERRORS+=("$1"); printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
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

# mm_ago SECONDS — a span as one unit: "16m" under an hour, "16h" under two days, else "3d".
mm_ago() {
  if (( $1 < 3600 )); then printf '%dm' $(( $1 / 60 ))
  elif (( $1 < 172800 )); then printf '%dh' $(( $1 / 3600 ))
  else printf '%dd' $(( $1 / 86400 )); fi
}

# mm_tilde PATH — PATH with a leading $HOME shown as ~, in REPLY. No subshell: status renders
# call it for every row.
mm_tilde() {
  REPLY=$1
  if [[ "$REPLY" == "$HOME" || "$REPLY" == "$HOME"/* ]]; then REPLY="~${REPLY#"$HOME"}"; fi
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

# mm_sysline — "Ubuntu 24.04.5 LTS · 8 cores · 31GB RAM | Free: 37.0GB | Up 3d 4h 12m". In a
# container it says so, and cgroup limits replace the host's cores and RAM when set:
# "Debian GNU/Linux 12 (bookworm) · container · 1.5 of 8 cores · 512.0MB RAM limit | ...".
mm_sysline() {
  local os mem s up="" cores ctr="" lim=""
  os=$(. /etc/os-release && echo "$PRETTY_NAME")
  mem=$(awk '/MemTotal/ { printf "%dGB", $2 / 1048576 + 0.5 }' /proc/meminfo)
  cores="$(nproc) cores"
  if mm_in_container; then
    ctr=" · container"
    mm_cgroup_limits
    [[ -n "$MM_CG_CPU_MILLI" ]] && cores="$(mm_cg_cores "$MM_CG_CPU_MILLI") of $cores"
    [[ -n "$MM_CG_MEM_MAX" ]] && mem="$(mm_human "$MM_CG_MEM_MAX")" lim=" limit"
  fi
  read -r s _ </proc/uptime; s=${s%.*}
  (( s >= 86400 )) && up+="$((s / 86400))d "
  (( s % 86400 >= 3600 )) && up+="$((s % 86400 / 3600))h "
  up+="$((s % 3600 / 60))m"
  printf '%s%s · %s · %s RAM%s | Free: %s | Up %s' "$os" "$ctr" "$cores" "$mem" "$lim" \
    "$(mm_human "$(mm_free_bytes /)")" "$up"
}

# ---------------------------------------------------------------- containers

# mm_in_container — 0 when marmot runs inside a container (Docker, Podman, LXC, systemd-nspawn,
# Kubernetes; so devcontainers, Codespaces, Gitpod and Coder workspaces too). There the kernel,
# swap, disks and usually the Docker daemon belong to the host. MM_CONTAINER=1 or MM_CONTAINER=0
# overrides the detection. Hints: Docker's /.dockerenv, Podman's /run/.containerenv, systemd's
# /run/systemd/container, $container (set by nspawn, Podman and LXC), init's cgroup naming a
# container runtime (cgroup v1, or v2 without a cgroup namespace), and an overlay root filesystem.
mm_in_container() {
  case "${MM_CONTAINER:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if [[ -z "${_MM_IN_CONTAINER:-}" ]]; then
    _MM_IN_CONTAINER=0
    if [[ -e /.dockerenv || -e /run/.containerenv || -s /run/systemd/container || -n "${container:-}" ]] ||
      grep -qE 'docker|kubepods|containerd|libpod|lxc' /proc/1/cgroup 2>/dev/null ||
      awk '$5 == "/" { for (i = 7; i < NF && $i != "-"; i++); fs = $(i + 1) } END { exit fs != "overlay" }' \
        /proc/self/mountinfo 2>/dev/null; then
      _MM_IN_CONTAINER=1
    fi
  fi
  [[ "$_MM_IN_CONTAINER" == 1 ]]
}

# mm_cgroup_limits — the cgroup v2 limits that bind this process: the tightest memory.max and
# cpu.max on its cgroup and every ancestor up to the mount (inside a container's cgroup namespace
# the container's own cgroup is that root). Sets MM_CG_MEM_DIR and MM_CG_MEM_MAX (bytes), and
# MM_CG_CPU_DIR and MM_CG_CPU_MILLI (quota / period, in thousandths of a core); all empty when
# nothing is limited or there is no cgroup v2. The test suite points MM_TEST_CGROUP_FS at a fake
# tree; that is honored only inside bats' per-test directory.
mm_cgroup_limits() {
  local fs=/sys/fs/cgroup rel="" id path d v q p box
  MM_CG_MEM_DIR="" MM_CG_MEM_MAX="" MM_CG_CPU_DIR="" MM_CG_CPU_MILLI=""
  if [[ -n "${MM_TEST_CGROUP_FS:-}" ]]; then
    d=$(realpath -e -- "$MM_TEST_CGROUP_FS" 2>/dev/null) || return 0
    box=$(realpath -e -- "${BATS_TEST_TMPDIR:-/nonexistent}" 2>/dev/null) || return 0
    [[ "$d" == "$box"/?* ]] || return 0
    fs=$d
  fi
  [[ -f "$fs/cgroup.controllers" ]] || return 0
  while IFS=: read -r id _ path; do [[ "$id" == 0 ]] && rel=$path; done 2>/dev/null </proc/self/cgroup
  [[ "$rel" == /* ]] || return 0
  # Without a cgroup namespace the path names a cgroup the mount may not show; missing levels
  # are passed over on the way up.
  d=$fs${rel%/}
  while :; do
    if { read -r v <"$d/memory.max"; } 2>/dev/null && [[ "$v" =~ ^[0-9]+$ ]] &&
      { [[ -z "$MM_CG_MEM_MAX" ]] || (( v < MM_CG_MEM_MAX )); }; then
      MM_CG_MEM_DIR=$d MM_CG_MEM_MAX=$v
    fi
    if { read -r q p <"$d/cpu.max"; } 2>/dev/null && [[ "$q" =~ ^[0-9]+$ && "$p" =~ ^[1-9][0-9]*$ ]]; then
      v=$((q * 1000 / p)); ((v > 0)) || v=1
      if [[ -z "$MM_CG_CPU_MILLI" ]] || (( v < MM_CG_CPU_MILLI )); then MM_CG_CPU_DIR=$d MM_CG_CPU_MILLI=$v; fi
    fi
    [[ "$d" == "$fs"/* ]] || break
    d=${d%/*}
  done
  return 0
}

# mm_cg_cores MILLI — "1.5" / "2" / "0.25" cores from thousandths of a core.
mm_cg_cores() {
  local w=$(($1 / 1000)) f
  printf -v f '%03d' $(($1 % 1000))
  f=${f%0}; f=${f%0}; f=${f%0}
  printf '%d%s' "$w" "${f:+.$f}"
}

# ---------------------------------------------------------------- sudo

# MM_NO_SUDO=1 (unattended runs: mm schedule run) means never run sudo, not even `sudo -n`: only
# root counts as able to, mm_sudo fails, and in-use detection sees only this user's processes.

# mm_can_sudo — 0 if root, or sudo is installed and either works without a password or can prompt
# on a tty.
mm_can_sudo() {
  (( EUID == 0 )) && return 0
  [[ "$MM_NO_SUDO" == 1 ]] && return 1
  command -v sudo >/dev/null && { sudo -n true 2>/dev/null || [[ "$MM_TTY" == 1 ]]; }
}
# mm_sudo CMD... — run as root; prompts only when needed.
mm_sudo() {
  if (( EUID == 0 )); then "$@"
  elif [[ "$MM_NO_SUDO" == 1 ]]; then mm_err "not run without sudo: $*"; return 1
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else sudo "$@"; fi
}

# ---------------------------------------------------------------- in-use detection

MM_INUSE=""        # newline-separated snapshot; kept in memory so a killed run leaves no files
MM_INUSE_REFS=""   # "path<TAB>source" for snapshot paths that only a reference keeps (mm_inuse_why)
MM_INUSE_TAKEN=0
# mm_inuse_refresh — snapshot every path any process has as cwd, root, exe, open fd, mapping, or
# bound unix socket, plus every mount point and bind-mount source (per mount namespace), so a
# target containing a mount is never removed through it; then add references (_mm_inuse_refs):
# files that a process's arguments, a launcher, a tool config, a systemd user unit or the crontab name.
# Sees all processes as root or with passwordless sudo; otherwise only this user's
# (MM_INUSE_PARTIAL=1, warned). An empty process snapshot is fatal: it would mean "nothing is in use".
mm_inuse_refresh() {
  local out live refs script
  script="$(declare -f _mm_inuse_scan); _mm_inuse_scan"
  MM_INUSE_PARTIAL=0
  if (( EUID == 0 )) || { [[ "$MM_NO_SUDO" != 1 ]] && sudo -n true 2>/dev/null; }; then
    out=$(mm_sudo bash -c "$script")
  else
    MM_INUSE_PARTIAL=1
    out=$(bash -c "$script")
  fi
  live=$(grep '^/' <<<"$out")
  MM_INUSE_TAKEN=1 MM_INUSE="" MM_INUSE_REFS=""
  [[ -n "$live" ]] || mm_die "could not list in-use paths; refusing to delete anything"
  refs=$(grep '^A' <<<"$out" | _mm_inuse_refs)
  MM_INUSE_REFS=$(awk -F'\t' 'NR == FNR { live[$0] = 1; next } !($1 in live)' - <(printf '%s\n' "$refs") <<<"$live")
  MM_INUSE=$({ printf '%s\n' "$live"; [[ -n "$MM_INUSE_REFS" ]] && cut -f1 <<<"$MM_INUSE_REFS"; } | sort -u)
  if [[ "$MM_INUSE_PARTIAL" == 1 && -z "${_MM_PARTIAL_WARNED:-}" ]]; then
    _MM_PARTIAL_WARNED=1
    if [[ "$MM_NO_SUDO" == 1 ]]; then mm_warn "Running without sudo: only your own processes are checked for in-use paths"
    else mm_warn "No passwordless sudo: only your own processes are checked for in-use paths"; fi
  fi
  mm_debug "in-use snapshot: $(mm_inuse_paths | wc -l) paths (partial=$MM_INUSE_PARTIAL)"
}

# _mm_inuse_scan — every live path (sorted, one per line), then "A<TAB>process PID (comm)<TAB>word"
# for each argument containing a /. Runs in a child bash (as root when possible), so it uses
# nothing else from this file. Batch reads: one find, one cat, a few awks, whatever the process count.
_mm_inuse_scan() {
  local p w c a=()
  { find /proc/[0-9]*/cwd /proc/[0-9]*/root /proc/[0-9]*/exe /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%l\n'
    # cat, not one awk over the files: mawk stops at the first unreadable one
    cat /proc/[0-9]*/maps | awk '$6 ~ /^\// && !seen[$6]++ { print $6 }'
    { echo /proc/self/mountinfo
      find /proc/[0-9]*/ns/mnt -maxdepth 0 -printf '%l %h\n' | awk '!seen[$1]++ { sub(/\/ns$/, "/mountinfo", $2); print $2 }'
    } | xargs -d '\n' cat | awk '{ print $4; print $5 }'
    awk 'NR > 1 && $8 ~ /^\// { print $8 }' /proc/net/unix
  } 2>/dev/null | sed 's/ (deleted)$//' | grep '^/' | sort -u
  for p in /proc/[0-9]*; do
    [[ "${p#/proc/}" == "$$" || "${p#/proc/}" == "$PPID" ]] && continue   # this scan and its sudo
    { mapfile -d '' -t a <"$p/cmdline" && IFS= read -r c <"$p/comm"; } 2>/dev/null || continue
    for w in "${a[@]}"; do [[ "$w" == */* ]] && printf 'A\tprocess %s (%s)\t%s\n' "${p#/proc/}" "$c" "$w"; done
  done
  return 0
}

# _mm_inuse_refs < ARGV_LINES — "path<TAB>source" for every existing regular file (never a
# directory) named by a running process's arguments (stdin, from _mm_inuse_scan); by a launcher in
# ~/.local/bin, ~/bin or a $PATH dir inside $HOME (symlink target, both as written and resolved, or
# a path inside a text file up to 64KB); by a tool config (agent state files and *.json/jsonc/toml/
# yaml/yml at depth <= 2 in agent state dirs outside their session and logs dirs, up to 16MB: a
# long-used ~/.claude.json holds user-scope MCP servers and grows past 1MB; and files named *mcp*
# with those extensions up to depth 4 in dot-folders, up to 1MB); by a systemd user unit; or by
# the crontab.
# Paths are normalized (~, $HOME, . and .. ) but not resolved through symlinks: a venv's bin/python
# must keep the venv. Tokens are words starting with / or ~/ cut at quotes, spaces and , = : ; ( ) etc.
_mm_inuse_refs() {
  local re='(^|[^A-Za-z0-9_.~/-])(~|\$HOME|\$\{HOME\})?/[^[:space:]"'\''`,=:;(){}<>|&]+'
  local ext=(\( -name '*.json' -o -name '*.jsonc' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \))
  local d s p bins=() states=() dirs=() dots=() prune=() links=() targets=() parts=()
  IFS=: read -r -a parts <<<"$PATH"
  for d in "${parts[@]}" "$HOME/.local/bin" "$HOME/bin"; do
    [[ "$d" == "$HOME"/* && -d "$d" ]] && bins+=("$d")
  done
  for s in "${MM_AGENT_STATE[@]}"; do
    for p in $s; do
      if [[ -d "$p" ]]; then dirs+=("$p"); elif [[ -f "$p" ]]; then states+=("$p"); fi
    done
  done
  for s in "${MM_AGENT_SESSIONS[@]}" "${MM_AGENT_LOGS[@]}"; do
    for p in $s; do prune+=(-path "$p" -o); done
  done
  for p in "$HOME"/.[!.]*; do
    case "${p##*/}" in .cache | .npm | .rustup | .cargo | .*-server | .*-server-insiders) continue ;; esac
    dots+=("$p")
  done
  for d in "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" "$HOME/.config/systemd/user"; do
    for p in "$d"/*.service; do [[ -f "$p" ]] && states+=("$p"); done
  done
  {
    cat
    if (( ${#bins[@]} )); then
      find "${bins[@]}" -maxdepth 1 -type l -printf 'L\t%p\t%l\n'
      mapfile -d '' -t links < <(find "${bins[@]}" -maxdepth 1 -type l -print0)
      (( ${#links[@]} )) && mapfile -d '' -t targets < <(realpath -mz -- "${links[@]}" 2>/dev/null)
      if (( ${#targets[@]} != ${#links[@]} )); then   # a symlink loop prints nothing: pair one by one
        targets=(); for p in "${links[@]}"; do targets+=("$(realpath -m -- "$p" 2>/dev/null)"); done
      fi
      for p in "${!links[@]}"; do printf 'R\t%s\t%s\n' "${links[$p]}" "${targets[$p]}"; done
    fi
    command -v crontab >/dev/null && crontab -l 2>/dev/null | awk '{ print "S\tcrontab\t" $0 }'
    {
      (( ${#bins[@]} )) && find "${bins[@]}" -maxdepth 1 -type f -size -65k -print0
      (( ${#states[@]} )) && find "${states[@]}" -maxdepth 0 -size -16385k -print0
      (( ${#dirs[@]} )) && find -H "${dirs[@]}" -maxdepth 2 \( "${prune[@]}" -false \) -prune -o \
        -type f "${ext[@]}" -size -16385k -print0
      (( ${#dots[@]} )) && find -H "${dots[@]}" -maxdepth 3 \( -name node_modules -o -name .git -o -name extensions \
        -o -path "$HOME/.local/share/Trash" \) -prune -o -type f -iname '*mcp*' "${ext[@]}" -size -1025k -print0
    } 2>/dev/null | xargs -0r grep -IsoHZE -- "$re" | tr '\0' '\t'
  } | awk -F'\t' -v home="$HOME" '
    function norm(t,   n, a, s, i, k, o) {
      if (substr(t, 1, 2) == "~/") t = home substr(t, 2)
      else if (substr(t, 1, 6) == "$HOME/") t = home substr(t, 6)
      else if (substr(t, 1, 8) == "${HOME}/") t = home substr(t, 8)
      n = split(t, a, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "" || a[i] == ".") continue
        if (a[i] == "..") { if (k) k--; continue }
        s[++k] = a[i]
      }
      o = ""; for (i = 1; i <= k; i++) o = o "/" s[i]
      return o
    }
    function label(f) {
      if (f ~ /\/systemd\/user\/[^\/]+$/) { sub(/.*\//, "", f); return "systemd unit " f }
      if (index(f, home "/") == 1) return "~" substr(f, length(home) + 1)
      return f
    }
    function add(t, src,   p) { p = norm(t); if (p != "" && !(p in seen)) { seen[p] = 1; print p "\t" src } }
    function scan(t, src) {
      while (match(t, /(~|\$HOME|\$\{HOME\})?\/[^ \t"\047`,=:;(){}<>|&]+/)) {
        if (RSTART == 1 || substr(t, RSTART - 1, 1) !~ /[A-Za-z0-9_.~\/-]/) add(substr(t, RSTART, RLENGTH), src)
        t = substr(t, RSTART + RLENGTH)
      }
    }
    { text = substr($0, length($1) + length($2) + 3) }
    $1 == "A" { if (substr(text, 1, 1) == "/") add(text, $2); scan(text, $2); next }
    $1 == "S" { scan(text, $2); next }
    $1 == "L" { d = $2; sub(/\/[^\/]*$/, "", d); add(substr(text, 1, 1) == "/" ? text : d "/" text, label($2)); next }
    $1 == "R" { add(text, label($2)); next }
    { text = substr($0, length($1) + 2); sub(/^[^~$\/]/, "", text); add(text, label($1)) }   # grep: file<TAB>match
  ' | while IFS=$'\t' read -r p s; do [[ -f "$p" ]] && printf '%s\t%s\n' "$p" "$s"; done
  return 0
}

# mm_inuse_paths — print the current snapshot, one path per line (taking one if needed).
mm_inuse_paths() {
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh
  [[ -n "$MM_INUSE" ]] && printf '%s\n' "$MM_INUSE"
  return 0
}

# mm_in_use PATH — 0 if PATH or anything under it is in use or referenced per the last snapshot.
mm_in_use() {
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh
  [[ -n "$MM_INUSE" ]] || return 0   # no snapshot (e.g. refresh died in a subshell): fail closed
  MM_P="${1%/}" awk 'BEGIN { p = ENVIRON["MM_P"] }
    $0 == p || index($0, p "/") == 1 { found = 1; exit } END { exit !found }' <<<"$MM_INUSE"
}

# mm_inuse_why PATH — print why PATH is kept and return 0: "in use" when a process uses it or
# something below it (or there is no snapshot), else "used by <source>" for the first reference at
# or below it (~/.claude.json, ~/.local/bin/tool, process 1234 (node), systemd unit x.service,
# crontab). Returns 1, printing nothing, when nothing at or below PATH is in use. Take the snapshot
# in the calling shell first when calling it in $(...): a refresh that dies there cannot stop marmot.
mm_inuse_why() {
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh
  [[ -n "$MM_INUSE" ]] || { echo "in use"; return 0; }
  MM_P="${1%/}" awk -F'\t' 'BEGIN { p = ENVIRON["MM_P"] }
    NR == FNR { if ($1 != "" && !($1 in why)) why[$1] = $2; next }
    $0 == p || index($0, p "/") == 1 { if (!($0 in why)) { live = 1; exit } if (ref == "") ref = why[$0] }
    END { if (live) print "in use"; else if (ref != "") print "used by " ref; else exit 1 }' \
    <(printf '%s\n' "$MM_INUSE_REFS") - <<<"$MM_INUSE"
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

# Carve-outs: folders inside a built-in protected tree that hold only logs or caches, so mm_rm may
# act on entries strictly inside them (never on the folder itself). Only the built-in patterns
# above are skipped for such entries; protected trees, agent state, the whitelist file and in-use
# checks still apply, and anything that looks like credentials is refused anyway
# (mm_credential_like, checking every name from the carve-out down).
# A carve-out that is not a canonical path (symlinks, trailing slash, dot segments) gets no
# waiver, so a link cannot point it at other data.
# gcloud and Azure CLI log folders (CLOUDSDK_CONFIG and AZURE_CONFIG_DIR move their config folder),
# and kubectl's discovery and HTTP response caches (its --cache-dir default). Only those two:
# other folders in ~/.kube/cache belong to auth plugins (kubelogin, oidc-login) and hold tokens.
MM_CLEAN_CARVEOUTS=("${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/logs" "${AZURE_CONFIG_DIR:-$HOME/.azure}/logs"
  "$HOME/.kube/cache/discovery" "$HOME/.kube/cache/http")

# mm_carveout PATH — 0 if PATH lies strictly inside a carve-out and may skip the built-in patterns,
# 1 if it lies in none, 2 if it does but looks like or holds credentials (keep it).
mm_carveout() {
  local path="${1%/}" c
  for c in "${MM_CLEAN_CARVEOUTS[@]}"; do
    [[ "$c" == /?* && "$path" == "$c"/?* ]] || continue
    # Resolved paths only: a symlinked carve-out (or entry parent) gets no waiver.
    [[ -d "$c" && "$(realpath -e -- "$c" 2>/dev/null)" == "$c" ]] || return 1
    [[ "$(realpath -e -- "$(dirname -- "$path")" 2>/dev/null)" == "$(dirname -- "$path")" ]] || return 1
    mm_credential_like "$path" "$c" && return 2
    return 0
  done
  return 1
}

# mm_keep_patterns [--carveout] — every protection pattern: built-ins, agent state, then the
# whitelist file. --carveout leaves the built-ins out (for entries mm_carveout waives).
# MM_KEEP_AGENT_STATE=0 leaves agent state out; only for removing git worktrees that git reports
# clean (agents such as Cursor keep their worktrees inside their state dir). _MM_WAIVED (set by
# mm_rm for MM_AGENT_WAIVER) leaves out only the agent state entries that contain that directory.
mm_keep_patterns() {
  [[ "${1:-}" == --carveout ]] || printf '%s\n' "${MM_BUILTIN_KEEP[@]}"
  if [[ "${MM_KEEP_AGENT_STATE:-1}" != 0 ]]; then
    local p
    while IFS= read -r p; do
      [[ -n "${_MM_WAIVED:-}" && ( "$_MM_WAIVED" == "$HOME${p:1}" || "$_MM_WAIVED" == "$HOME${p:1}"/* ) ]] && continue
      printf '%s\n' "$p"
    done < <(mm_agent_state_paths)
  fi
  cat -- "$MM_WHITELIST_FILE"
}

# mm_whitelisted PATH — 0 if removing PATH would touch a protected entry (built-in, agent state,
# or whitelist file): PATH or an ancestor matches it, or it lies under PATH. Globs follow [[ == ]]
# rules (* crosses /). Inside a carve-out the built-ins are skipped (see mm_carveout).
mm_whitelisted() {
  mm_whitelist_init 2>/dev/null
  # Fail closed: an unreadable whitelist must not mean "nothing is protected".
  [[ -r "$MM_WHITELIST_FILE" ]] || { mm_err "cannot read whitelist $MM_WHITELIST_FILE: refusing"; return 0; }
  local path="${1%/}" pat probe lit carve="" rc=0
  mm_carveout "$path" || rc=$?
  case $rc in 0) carve=--carveout ;; 2) return 0 ;; esac
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
  done < <(mm_keep_patterns ${carve:+"$carve"})
  return 1
}

mm_whitelist_edit() {
  mm_whitelist_init
  "${VISUAL:-${EDITOR:-nano}}" "$MM_WHITELIST_FILE"
}

# ---------------------------------------------------------------- config

# mm_config KEY — print KEY's value from $MM_CONFIG_FILE (~/.config/marmot/config): `key=value`
# lines, `#` starts a comment, spaces around key and value are ignored, the last line for a key
# wins. Fails when the file or the key is missing.
mm_config() {
  [[ -r "$MM_CONFIG_FILE" ]] || return 1
  awk -v k="$1" '
    { sub(/#.*/, "") }
    (i = index($0, "=")) {
      key = substr($0, 1, i - 1); val = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t\r]+$/, "", key); gsub(/^[ \t]+|[ \t\r]+$/, "", val)
      if (key == k) { found = 1; out = val }
    }
    END { if (found) print out; exit !found }' "$MM_CONFIG_FILE"
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

# mm_credential_like PATH [BASE] — 0 if PATH's name, any name under it, or (when PATH lies inside
# BASE) any folder name between BASE and PATH looks like a key, token, credentials file or
# credential config; case-insensitive. A subfolder find cannot read counts as a match (fail
# closed). Agent state mixes these with sessions and logs (~/.claude/.credentials.json,
# ~/.codex/auth.json), and cloud CLIs keep them next to their logs (gcloud credentials.db,
# access_tokens.db, legacy_credentials/, configurations/), so the agent waiver and the carve-outs
# refuse them whatever their age.
_MM_CREDENTIAL_NAMES=('*credential*' '*secret*' '*token*' '*oauth*' '*apikey*' '*api_key*' '*api-key*'
  'auth*.json' '*.pem' '*.key' '*.p12' '*.pfx' '*.kdbx' 'id_rsa*' 'id_dsa*' 'id_ecdsa*'
  'id_ed25519*' '.netrc' '.git-credentials' 'configurations')
mm_credential_like() {
  local rel="${1##*/}" name pat hit
  [[ -n "${2:-}" && "$1" == "${2%/}"/?* ]] && rel=${1#"${2%/}"/}
  while IFS= read -r -d / name; do
    for pat in "${_MM_CREDENTIAL_NAMES[@]}"; do
      # shellcheck disable=SC2053
      [[ "${name,,}" == $pat ]] && return 0
    done
  done <<<"$rel/"
  [[ -d "$1" && ! -L "$1" ]] || return 1
  local -a expr=()
  for pat in "${_MM_CREDENTIAL_NAMES[@]}"; do expr+=(-o -iname "$pat"); done
  hit=$(find "$1" -xdev -mindepth 1 \( "${expr[@]:1}" \) -print -quit 2>/dev/null) || return 0
  [[ -n "$hit" ]]
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
# other than "missing" and failures are written to the operations log; failures also to MM_ERRORS.
# MM_AGENT_WAIVER=DIR mm_rm ... (for that one call) acts inside one agent's own session, state or
# logs directory, which agent state protection otherwise covers: DIR must be exactly one directory
# listed in lib/agents.sh and must be ALLOWED_ROOT. Only the agent state entries containing DIR are
# lifted; other built-ins, protected trees, the whitelist file and in-use checks still apply, and
# anything that looks like credentials is refused.
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
  local waived=""
  if [[ -n "${MM_AGENT_WAIVER:-}" ]]; then
    waived=$(realpath -e -- "$MM_AGENT_WAIVER" 2>/dev/null)
    if [[ "$waived" != "$root" ]] || ! mm_agent_dir "$waived"; then
      _mm_refuse "agent waiver is not this agent directory"; return 1
    fi
    mm_credential_like "$real" && { _mm_refuse "looks like credentials"; return 1; }
  fi
  p=$(mm_protected "$real") && { _mm_refuse "$p"; return 1; }
  _MM_WAIVED=$waived mm_whitelisted "$real" && { _mm_refuse "whitelisted"; return 1; }
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh   # here, not inside $(...): a failed snapshot must stop marmot
  p=$(mm_inuse_why "$real") && { _mm_refuse "$p"; return 1; }

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
        MM_SKIP_REASON="rm failed"; MM_ERRORS+=("$real: rm failed"); mm_log failed "$real" "$bytes" "rm failed"; return 2
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
    MM_SKIP_REASON="move to Trash failed"; MM_ERRORS+=("$real: move to Trash failed")
    mm_log failed "$real" "$bytes" "move to Trash failed"; return 2
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
  out=$(mm_sudo bash -c 'if find /proc/[0-9]*/fd -maxdepth 1 -type l -printf "%l\n" 2>/dev/null |
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
  # Adaptive height (~60%) came with fzf 0.34; older ones (Ubuntu 22.04 ships 0.29) exit with
  # "not a valid number" on it, which would select nothing.
  local height='~60%'
  [[ "$(fzf --version 2>/dev/null)" =~ ^0\.([0-9]+) ]] && (( 10#${BASH_REMATCH[1]} < 34 )) && height=60%
  fzf --multi --ansi --reverse --height="$height" --header="$1" --header-first \
      --bind 'ctrl-a:select-all,ctrl-d:deselect-all' --prompt='filter> '
}
