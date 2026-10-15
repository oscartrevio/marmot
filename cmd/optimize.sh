# shellcheck shell=bash
# mm optimize — performance diagnosis plus bounded maintenance: apt/snap updates, swap reset,
# processes stranded in deleted worktrees, orphaned headless browsers, SSD trim, DNS flush, failed
# units, pending reboot.

_OPTIMIZE_APPLIED=0 _OPTIMIZE_UNCHANGED=0 _OPTIMIZE_SKIPPED=0 _OPTIMIZE_ATTENTION=0
_OPTIMIZE_GIB=1073741824

# ---------------------------------------------------------------- result lines (counted)

# _optimize_applied DONE_TEXT WOULD_TEXT — a task that changed (or in dry-run would change) state.
_optimize_applied() {
  _OPTIMIZE_APPLIED=$((_OPTIMIZE_APPLIED + 1))
  if [[ "$MM_DRY_RUN" == 1 ]]; then mm_act "$2"; else mm_act "$1"; fi
}
_optimize_unchanged() { _OPTIMIZE_UNCHANGED=$((_OPTIMIZE_UNCHANGED + 1)); mm_ok "$@"; }
_optimize_skipped() { _OPTIMIZE_SKIPPED=$((_OPTIMIZE_SKIPPED + 1)); mm_skip "$1" "$2"; }
_optimize_attention() { _OPTIMIZE_ATTENTION=$((_OPTIMIZE_ATTENTION + 1)); mm_warn "$1"; }
_optimize_hint() { printf '    %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

# _optimize_ago SECONDS — "16h ago" / "3d ago".
_optimize_ago() {
  local s=$1
  if (( s < 3600 )); then echo "$((s / 60))m ago"
  elif (( s < 172800 )); then echo "$((s / 3600))h ago"
  else echo "$((s / 86400))d ago"; fi
}

# _optimize_meminfo KEY — value in bytes from /proc/meminfo.
_optimize_meminfo() { awk -v k="$1:" '$1 == k { printf "%.0f\n", $2 * 1024; exit }' /proc/meminfo; }

# _optimize_cg_memory — "AVAILABLE LIMIT" in bytes under the cgroup memory.max limit: what is left
# of it after memory.current less reclaimable inactive_file. Fails without such a limit.
_optimize_cg_memory() {
  local cur inact
  mm_cgroup_limits
  [[ -n "$MM_CG_MEM_MAX" ]] || return 1
  { read -r cur <"$MM_CG_MEM_DIR/memory.current"; } 2>/dev/null && [[ "$cur" =~ ^[0-9]+$ ]] || return 1
  inact=$(awk '$1 == "inactive_file" { printf "%.0f\n", $2; exit }' "$MM_CG_MEM_DIR/memory.stat" 2>/dev/null)
  cur=$(( cur - ${inact:-0} ))
  (( cur < 0 )) && cur=0
  echo "$(( MM_CG_MEM_MAX > cur ? MM_CG_MEM_MAX - cur : 0 )) $MM_CG_MEM_MAX"
}

# ---------------------------------------------------------------- diagnosis (read-only)

# _optimize_cpu_ticks — "pid:starttime<TAB>utime+stime<TAB>comm" for every process.
_optimize_cpu_ticks() {
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{
    if (!match($0, /\(.*\)/)) next
    comm = substr($0, RSTART + 1, RLENGTH - 2)
    n = split(substr($0, RSTART + RLENGTH + 1), f, " ")
    if (n < 20) next
    printf "%s:%s\t%.0f\t%s\n", $1, f[20], f[12] + f[13], comm
  }'
}

_optimize_diagnose() {
  printf '\n%sPERFORMANCE DIAGNOSIS%s\n' "$C_BOLD" "$C_RESET"
  # In a container load, pressure and swap are the whole host's: reported as such, never flagged.
  local cores l1 l5 l15 _ host="" ctr=0
  mm_in_container && ctr=1 host=" (host)"
  cores=$(nproc)
  read -r l1 l5 l15 _ </proc/loadavg
  if (( !ctr )) && awk -v l="$l1" -v c="$cores" 'BEGIN { exit !(l > c) }'; then
    mm_warn "Load $l1 / $l5 / $l15 exceeds $cores cores"
  else
    mm_ok "Load$host $l1 / $l5 / $l15" "$cores cores"
  fi

  # Pressure stall information: share of the last minute some task waited on the resource.
  local r v psi="" hot=""
  for r in cpu memory io; do
    [[ -r /proc/pressure/$r ]] || continue
    v=$(awk '$1 == "some" { sub(/avg60=/, "", $3); print $3 }' "/proc/pressure/$r")
    psi+="${psi:+ · }$r ${v}%"
    awk -v v="$v" 'BEGIN { exit !(v > 10) }' && hot+="${hot:+ · }$r ${v}%"
  done
  if [[ -n "$hot" ]] && (( !ctr )); then
    mm_warn "Pressure (avg60) high: $hot · tasks stalled waiting on these resources"
  elif [[ -n "$psi" ]]; then
    mm_ok "Pressure (avg60${host:+, host})" "$psi"
  fi

  local swap_total swap_used avail total limit="" cga cgt
  swap_total=$(_optimize_meminfo SwapTotal)
  swap_used=$(( swap_total - $(_optimize_meminfo SwapFree) ))
  avail=$(_optimize_meminfo MemAvailable) total=$(_optimize_meminfo MemTotal)
  # Under a cgroup memory limit: what is left of it (never more than the host has available).
  if (( ctr )) && read -r cga cgt < <(_optimize_cg_memory); then
    (( cga < avail )) && avail=$cga
    total=$cgt limit=" (container limit)"
  fi
  mm_ok "Memory" "$(mm_human "$avail") available of $(mm_human "$total")$limit"
  if (( swap_total == 0 )); then
    mm_ok "Swap$host" "none configured"
  elif (( !ctr && swap_used > _OPTIMIZE_GIB )); then
    mm_warn "Swap · $(mm_human "$swap_used") of $(mm_human "$swap_total") used"
  else
    mm_ok "Swap$host" "$(mm_human "$swap_used") of $(mm_human "$swap_total") used"
  fi

  # Top CPU consumer sampled over ~1s (percent of one core).
  local before after t0 t1 top
  before=$(_optimize_cpu_ticks); t0=$(date +%s%N)
  sleep 1
  after=$(_optimize_cpu_ticks); t1=$(date +%s%N)
  top=$(awk -F'\t' -v hz="$(getconf CLK_TCK)" -v ns=$((t1 - t0)) -v self=$$ '
    NR == FNR { prev[$1] = $2; next }
    ($1 in prev) {
      split($1, id, ":"); if (id[1] == self) next
      pct = ($2 - prev[$1]) / hz / (ns / 1e9) * 100
      if (pct > best) { best = pct; who = $3 " (" id[1] ")" }
    }
    END { if (who != "") printf "%.0f\t%s\n", best, who }' <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  if [[ -n "$top" && ${top%%$'\t'*} -gt 80 ]]; then
    mm_warn "High CPU: ${top#*$'\t'} using ${top%%$'\t'*}% of a core"
  elif [[ -n "$top" ]]; then
    mm_ok "No sustained high-CPU bottleneck detected" "busiest: ${top#*$'\t'} ${top%%$'\t'*}%"
  else
    mm_ok "No sustained high-CPU bottleneck detected"
  fi

  # Memory hogs: top 3 processes by RSS + swap.
  local hogs
  hogs=$(cat /proc/[0-9]*/status 2>/dev/null | awk '
    function emit() { if (name != "" && kb > 0) printf "%.0f\t%s (%s)\n", kb * 1024, name, pid }
    /^Name:/ { emit(); name = substr($0, 7); pid = ""; kb = 0; next }
    /^Pid:/ { pid = $2 }
    /^(VmRSS|VmSwap):/ { kb += $2 }
    END { emit() }' | sort -rn | head -3 |
    while IFS=$'\t' read -r b who; do printf '%s %s · ' "$who" "$(mm_human "$b")"; done)
  [[ -n "$hogs" ]] && mm_ok "Memory hogs" "${hogs% · }"
}

# ---------------------------------------------------------------- updates

# _optimize_apt_plan — "u|p|k<TAB>package" from a simulated upgrade (upgrade/phased/kept back).
_optimize_apt_plan() {
  LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | awk '
    /^Inst / { print "u\t" $2; next }
    /deferred due to phasing:/ { m = "p"; next }
    /kept back:/ { m = "k"; next }
    /^  / { if (m != "") for (i = 1; i <= NF; i++) print m "\t" $i; next }
    { m = "" }'
}

# _optimize_list NAMES... — "a b c +N more" (max 6 names).
_optimize_list() {
  local out="${*:1:6}"
  (( $# > 6 )) && out+=" +$(($# - 6)) more"
  printf '%s' "$out"
}

# _optimize_disruptive PKG — prints the impact and returns 0 if upgrading PKG restarts something
# the machine is used through: a container runtime (running containers may stop), a VPN/tunnel
# (remote sessions over it drop), or the SSH server. Such upgrades get their own confirmation.
_optimize_disruptive() {
  case "$1" in
    docker-ce*|docker.io|docker-*-plugin|containerd*|podman|runc|crun)
      echo "restarts the container runtime: running containers may stop" ;;
    tailscale*|zerotier-one|wireguard*|netbird|cloudflared|openvpn*)
      echo "restarts a VPN/tunnel: connections through it drop, possibly including this session" ;;
    openssh-server)
      echo "restarts sshd: existing SSH sessions survive, new logins are briefly refused" ;;
    *) return 1 ;;
  esac
}

# _optimize_apt_install ARGS... — non-interactive apt-get as root, keeping existing config files.
_optimize_apt_install() {
  mm_sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=60 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# _optimize_apt_upgrade PKG... — confirm and install the upgradable set on a terminal. Disruptive
# packages need their own confirmation and are held back otherwise.
_optimize_apt_upgrade() {
  local p why safe=() risky=() chosen=() held=()
  local -A impact=()
  for p in "$@"; do
    if why=$(_optimize_disruptive "$p"); then risky+=("$p"); impact[$why]+=" $p"; else safe+=("$p"); fi
  done
  mm_info "$# upgradable: $(_optimize_list "$@")"
  for why in "${!impact[@]}"; do
    printf '  %s! %s · %s%s\n' "$C_RED" "${impact[$why]# }" "$why" "$C_RESET"
  done

  if [[ "$MM_DRY_RUN" == 1 ]]; then
    local note=""
    (( ${#risky[@]} )) && note=", ${#risky[@]} disruptive need a separate interactive confirmation"
    _optimize_applied "" "Would upgrade $# packages after confirmation (apt-get upgrade$note)"
    return
  fi
  if [[ "$MM_TTY" != 1 ]]; then
    _optimize_skipped "Packages" "needs a terminal to confirm"
    return
  fi
  local excluded=()
  if (( ${#safe[@]} )); then
    if mm_confirm "Install ${#safe[@]} upgrades?"; then chosen+=("${safe[@]}"); else excluded+=("${safe[@]}"); fi
  fi
  if (( ${#risky[@]} )); then
    if mm_confirm "Also upgrade ${risky[*]} (see warning above)?"; then
      chosen+=("${risky[@]}")
    else
      held=("${risky[@]}"); excluded+=("${risky[@]}")
    fi
  fi

  if (( ${#chosen[@]} == 0 )); then
    (( ${#held[@]} )) || _optimize_skipped "Packages" "declined"
  elif (( ${#excluded[@]} == 0 )); then
    if mm_run "apt-get upgrade" _optimize_apt_install upgrade; then
      _optimize_applied "Upgraded $# packages" ""
    else
      _optimize_attention "apt-get upgrade failed · rerun: sudo apt-get upgrade"
    fi
  else
    _optimize_apt_upgrade_subset "${#excluded[@]}" "${excluded[@]}" "${chosen[@]}"
  fi
  (( ${#held[@]} )) && _optimize_skipped "Disruptive upgrades: ${held[*]}" \
    "held back; when convenient: sudo apt-get install --only-upgrade ${held[*]}"
  return 0
}

# _optimize_apt_upgrade_subset N EXCLUDED(N)... CHOSEN... — upgrade only CHOSEN, refusing if apt
# would remove anything or drag in an excluded package. Restores auto-installed marks
# `apt-get install` may clear.
_optimize_apt_upgrade_subset() {
  local n=$1; shift
  local excluded=("${@:1:n}") chosen=("${@:n+1}") pulled=() removed=() autos=() p op
  local -A will=()
  while read -r op p; do
    if [[ "$op" == Remv ]]; then removed+=("$p"); else will[$p]=1; fi
  done < <(LC_ALL=C apt-get -s -o Debug::NoLocking=1 install --only-upgrade "${chosen[@]}" 2>/dev/null |
    awk '/^(Inst|Remv) / { print $1, $2 }')
  if (( ${#removed[@]} )); then
    _optimize_attention "Not upgrading: it would remove $(_optimize_list "${removed[@]}") · review with sudo apt-get upgrade"
    return
  fi
  for p in "${excluded[@]}"; do [[ -n "${will[$p]:-}" ]] && pulled+=("$p"); done
  if (( ${#pulled[@]} )); then
    _optimize_attention "Not upgrading: it would also upgrade the excluded ${pulled[*]} · run sudo apt-get upgrade when convenient"
    return
  fi
  mapfile -t autos < <(apt-mark showauto "${chosen[@]}" 2>/dev/null)
  if mm_run "apt-get install --only-upgrade ${chosen[*]}" _optimize_apt_install install --only-upgrade "${chosen[@]}"; then
    (( ${#autos[@]} )) && mm_run "apt-mark auto ${autos[*]}" mm_sudo apt-mark auto "${autos[@]}"
    _optimize_applied "Upgraded ${#chosen[@]} packages" ""
  else
    _optimize_attention "apt-get upgrade failed · rerun: sudo apt-get install --only-upgrade ${chosen[*]}"
  fi
}

_optimize_updates() {
  mm_section "System Updates"
  local busy
  if ! command -v apt-get >/dev/null; then
    _optimize_skipped "Packages" "apt not available"
  elif busy=$(mm_apt_busy); then
    _optimize_skipped "Packages" "$busy"
  else
    # Without a terminal nothing can be confirmed, so apt-get update would be the only change.
    local refreshed=1
    if [[ "$MM_DRY_RUN" == 1 ]]; then
      mm_info "${C_DIM}Using current package lists (apt-get update not run in dry run)${C_RESET}"
    elif [[ "$MM_TTY" != 1 ]]; then
      mm_info "${C_DIM}Using current package lists (no terminal: nothing will be installed)${C_RESET}"
    elif mm_run "apt-get update" mm_sudo apt-get -q -o DPkg::Lock::Timeout=60 update; then
      mm_act "Package lists refreshed"
    else
      refreshed=0
    fi

    local kind pkg up=() phased=() kept=()
    while IFS=$'\t' read -r kind pkg; do
      case "$kind" in u) up+=("$pkg") ;; p) phased+=("$pkg") ;; k) kept+=("$pkg") ;; esac
    done < <(_optimize_apt_plan)

    if (( ${#up[@]} == 0 )); then
      if (( refreshed )); then _optimize_unchanged "Packages" "up to date"
      else _optimize_skipped "Packages" "apt-get update failed"; fi
    else
      _optimize_apt_upgrade "${up[@]}"
    fi
    (( ${#phased[@]} )) && mm_info "${C_DIM}◎ ${#phased[@]} phased updates held (normal: Ubuntu rolls them out gradually): $(_optimize_list "${phased[@]}")${C_RESET}"
    (( ${#kept[@]} )) && mm_info "${C_DIM}◎ ${#kept[@]} kept back (new dependencies; sudo apt full-upgrade): $(_optimize_list "${kept[@]}")${C_RESET}"
  fi

  command -v snap >/dev/null || return 0
  local snaps
  if ! snaps=$(LC_ALL=C timeout 20 snap refresh --list 2>&1); then
    if [[ "$snaps" == *"up to date"* ]]; then _optimize_unchanged "Snaps" "up to date"
    else _optimize_skipped "Snaps" "snapd not responding"; fi
  elif [[ "$snaps" == *"up to date"* ]]; then
    _optimize_unchanged "Snaps" "up to date"
  else
    local names=()
    mapfile -t names < <(awk 'NR > 1 { print $1 }' <<<"$snaps")
    _optimize_unchanged "Snaps" "${#names[@]} pending ($(_optimize_list "${names[@]}")); snapd auto-refreshes them"
  fi
}

# ---------------------------------------------------------------- swap

_optimize_swap_total() { awk 'NR > 1 { t += $3 } END { printf "%.0f\n", t * 1024 }' /proc/swaps; }

_optimize_swap() {
  mm_section "Memory"
  local total used avail need
  if mm_in_container; then _optimize_skipped "Swap reset" "in a container: swap belongs to the host"; return; fi
  total=$(_optimize_meminfo SwapTotal)
  if (( total == 0 )); then _optimize_skipped "Swap reset" "no swap configured"; return; fi
  used=$(( total - $(_optimize_meminfo SwapFree) ))
  avail=$(_optimize_meminfo MemAvailable)
  need=$(( used * 3 / 2 + 2 * _OPTIMIZE_GIB ))
  if (( used <= _OPTIMIZE_GIB )); then
    _optimize_unchanged "Swap" "$(mm_human "$used") used, no reset needed"
  elif (( avail <= need )); then
    _optimize_skipped "Swap reset · $(mm_human "$used") used" "not enough free RAM"
  elif [[ "$MM_DRY_RUN" == 1 ]]; then
    _optimize_applied "" "Would reset swap · $(mm_human "$used") swapped out, $(mm_human "$avail") RAM available (swapoff -a; swapon -a; re-enable every current device)"
  elif [[ "$MM_TTY" != 1 ]]; then
    _optimize_skipped "Swap reset · $(mm_human "$used") used" "needs a terminal to confirm"
  elif ! mm_can_sudo; then
    _optimize_skipped "Swap reset" "needs sudo"
  elif ! mm_confirm "Move $(mm_human "$used") of swap back into RAM (swapoff -a, then re-enable all swap)?"; then
    _optimize_skipped "Swap reset" "declined"
  else
    _optimize_swap_reset "$used"
  fi
}

# _optimize_swap_reset USED — swapoff -a, swapon -a, then re-enable (with its priority) every device
# that was active before but is not now (zram and other non-fstab swap). Never leaves swap smaller.
_optimize_swap_reset() {
  local before_total dev prio active after_total after_used
  local -a devs=()
  before_total=$(_optimize_swap_total)
  mapfile -t devs < <(swapon --show=NAME,PRIO --noheadings --raw 2>/dev/null)
  mm_run "swapoff -a" mm_sudo swapoff -a
  mm_run "swapon -a" mm_sudo swapon -a
  active=$(swapon --show=NAME --noheadings --raw 2>/dev/null)
  for dev in "${devs[@]}"; do
    read -r dev prio <<<"$dev"
    grep -qxF -- "$dev" <<<"$active" && continue
    if (( prio >= 0 )); then mm_run "swapon $dev" mm_sudo swapon -p "$prio" -- "$dev"
    else mm_run "swapon $dev" mm_sudo swapon -- "$dev"; fi
  done
  after_total=$(_optimize_swap_total)
  after_used=$(( $(_optimize_meminfo SwapTotal) - $(_optimize_meminfo SwapFree) ))
  if (( after_total < before_total )); then
    _optimize_attention "Swap reset left $(mm_human "$after_total") of $(mm_human "$before_total") swap active · check: swapon --show"
    mm_err "swap shrank after reset; re-enable missing devices with sudo swapon <device>"
  else
    _optimize_applied "Swap reset · $(mm_human "$1") → $(mm_human "$after_used") used of $(mm_human "$after_total")" ""
  fi
}

# ---------------------------------------------------------------- orphaned processes

# _optimize_ancestors — pids of this process and every ancestor (never orphan candidates).
_optimize_ancestors() {
  local pid=$$
  echo "$BASHPID"
  while [[ -n "$pid" ]] && (( pid > 1 )); do
    echo "$pid"
    pid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
  done
}

# _optimize_starttime PID — process start time in clock ticks (identity guard against pid reuse).
_optimize_starttime() { _optimize_stat_field "$1" 20; }

# _optimize_cwd_deleted PID — 0 if the process's working directory was deleted and its path
# does not exist any more. A recreated path counts as existing (conservative).
_optimize_cwd_deleted() {
  local cwd
  cwd=$(readlink "/proc/$1/cwd" 2>/dev/null) || return 1
  [[ "$cwd" == *" (deleted)" ]] || return 1
  [[ ! -e "${cwd% (deleted)}" ]]
}

# _optimize_orphans — "pid<TAB>start<TAB>age<TAB>bytes<TAB>comm<TAB>cwd<TAB>args" for this user's
# processes older than MM_OPTIMIZE_ORPHAN_AGE seconds (default 3600) whose cwd was deleted.
_optimize_orphans() {
  local min_age=${MM_OPTIMIZE_ORPHAN_AGE:-3600} p pid age bytes comm cwd args
  local -A mine=()
  for pid in $(_optimize_ancestors); do mine[$pid]=1; done
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [[ -n "${mine[$pid]:-}" ]] && continue
    [[ -O "$p" ]] || continue
    _optimize_cwd_deleted "$pid" || continue
    age=$(mm_proc_age "$pid") || continue
    (( age >= min_age )) || continue
    bytes=$(awk '/^(VmRSS|VmSwap):/ { kb += $2 } END { printf "%.0f\n", kb * 1024 }' "$p/status" 2>/dev/null)
    # The process may exit mid-scan: skip it quietly.
    { comm=$(<"$p/comm"); } 2>/dev/null || continue
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue; cwd=${cwd% (deleted)}
    args=$(tr '\0\t\n' '   ' <"$p/cmdline" 2>/dev/null | cut -c1-70)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$(_optimize_starttime "$pid")" "$age" "${bytes:-0}" \
      "$comm" "$cwd" "${args% }"
  done
}

# _optimize_alive PID START — 0 if the same process (pid + start time) still exists.
_optimize_alive() { [[ -d "/proc/$1" && "$(_optimize_starttime "$1")" == "$2" ]]; }

# _optimize_stat_field PID N — Nth field of /proc/PID/stat counted after "(comm)" (1 = state,
# 4 = session, 5 = tty_nr, 20 = starttime).
_optimize_stat_field() {
  awk -v n="$2" '{ match($0, /\(.*\)/); split(substr($0, RSTART + RLENGTH + 1), f, " "); print f[n] }' \
    "/proc/$1/stat" 2>/dev/null
}

# _optimize_on_terminal PID — 0 if PID has a controlling tty and its session leader is alive: a
# multiplexer/ssh pane, an interactive shell, or a job the user can still see. Leftovers whose
# terminal session ended (nohup'd or backgrounded, then the shell exited) return 1. Unreadable → 0.
_optimize_on_terminal() {
  local sid tty
  sid=$(_optimize_stat_field "$1" 4) && tty=$(_optimize_stat_field "$1" 5) || return 0
  [[ -n "$tty" ]] || return 0
  [[ "$tty" != 0 && -d "/proc/${sid:-0}" ]]
}

# _optimize_protected PID COMM — prints why PID must not be offered for SIGTERM and returns 0:
# a terminal multiplexer or ssh daemon, a process on a live terminal, or a parent of any child
# that is on a terminal, has a cwd that still exists, or cannot be inspected (conservative).
_optimize_protected() {
  case "$2" in
    tmux*|screen*|SCREEN*|zellij*|sshd*|abduco*|dtach*|byobu*) echo "hosts other sessions"; return 0 ;;
  esac
  _optimize_on_terminal "$1" && { echo "attached to a live terminal"; return 0; }
  local child cwd
  for child in $(mm_proc_children "$1"); do
    [[ -d "/proc/$child" ]] || continue
    cwd=$(readlink "/proc/$child/cwd" 2>/dev/null) || { echo "hosts other sessions"; return 0; }
    if [[ "$cwd" != *" (deleted)" ]] || _optimize_on_terminal "$child"; then
      echo "hosts other sessions"; return 0
    fi
  done
  return 1
}

# _optimize_agent_of PID COMM — the coding agent (lib/agents.sh) PID belongs to, if any: matched
# on comm or on the program/script name in argv (agents often run as `node …/claude.js`).
_optimize_agent_of() {
  local names=("$2") a i proc
  local -a argv=()
  mapfile -d '' -n 2 argv <"/proc/$1/cmdline" 2>/dev/null
  for a in "${argv[@]}"; do a=${a##*/}; names+=("${a%.*js}"); done
  for i in "${!MM_AGENT_NAME[@]}"; do
    for proc in ${MM_AGENT_PROCS[i]}; do
      for a in "${names[@]}"; do [[ "$a" == "$proc" ]] && { echo "${MM_AGENT_NAME[i]}"; return 0; }; done
    done
  done
  return 1
}

# _optimize_orphan_line ROW — the one-line display (and picker entry) for an orphan row; pid first.
_optimize_orphan_line() {
  local pid start age bytes comm cwd args agent
  IFS=$'\t' read -r pid start age bytes comm cwd args <<<"$1"
  agent=$(_optimize_agent_of "$pid" "$comm") && comm+=" [$agent]"
  printf '%-7s %-16s %-8s %9s  %s  %s\n' "$pid" "$comm" "$(_optimize_ago "$age" | sed 's/ ago//')" \
    "$(mm_human "$bytes")" "$cwd" "$args"
}

# _optimize_have_fzf — 0 if the multi-select picker is available.
_optimize_have_fzf() { command -v fzf >/dev/null; }

_optimize_orphan_task() {
  mm_section "Orphaned Processes"
  local rows=() cands=() row pid start age bytes comm cwd args
  mapfile -t rows < <(_optimize_orphans)
  if (( ${#rows[@]} == 0 )); then
    _optimize_unchanged "Orphaned processes" "none (no process of yours is stranded in a deleted directory)"
    return
  fi
  local why
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r pid start age bytes comm cwd args <<<"$row"
    if why=$(_optimize_protected "$pid" "$comm"); then
      _optimize_skipped "$comm ($pid) in deleted $cwd" "$why"
      continue
    fi
    cands+=("$row")
    printf '  %s•%s %s\n' "$C_YELLOW" "$C_RESET" "$(_optimize_orphan_line "$row")"
  done
  (( ${#cands[@]} )) || return 0

  local total=0
  for row in "${cands[@]}"; do IFS=$'\t' read -r _ _ _ bytes _ <<<"$row"; total=$((total + bytes)); done
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    _optimize_applied "" "Would offer ${#cands[@]} processes running in deleted directories for SIGTERM ($(mm_human "$total") RAM+swap; you pick which, interactively)"
    return
  fi
  if [[ "$MM_TTY" != 1 ]]; then
    _optimize_skipped "Orphaned processes" "needs interactive confirmation"
    return
  fi

  # The user chooses each process; there is no unattended path.
  local picked=() chosen=()
  if (( ${#cands[@]} == 1 )) || ! _optimize_have_fzf; then
    # One candidate, or no fzf: ask about each process in turn.
    for row in "${cands[@]}"; do
      mm_confirm "Send SIGTERM to $(_optimize_orphan_line "$row")?" && picked+=("${row%%$'\t'*}")
    done
  else
    mapfile -t picked < <(for row in "${cands[@]}"; do _optimize_orphan_line "$row"; done |
      mm_pick "TAB: mark processes to SIGTERM · Enter: confirm · Esc: none" | awk '{ print $1 }')
  fi
  for row in "${cands[@]}"; do
    for pid in "${picked[@]}"; do [[ "${row%%$'\t'*}" == "$pid" ]] && chosen+=("$row"); done
  done
  if (( ${#chosen[@]} == 0 )); then
    _optimize_skipped "Orphaned processes" "none selected"
    return
  fi

  local sent=() starts=() survivors=() freed=0
  for row in "${chosen[@]}"; do
    IFS=$'\t' read -r pid start _ bytes comm _ _ <<<"$row"
    # Re-verify identity, the deleted cwd and the session guard: time has passed since the scan.
    if ! _optimize_alive "$pid" "$start" || ! _optimize_cwd_deleted "$pid" ||
       _optimize_protected "$pid" "$comm" >/dev/null; then
      continue
    fi
    if mm_run "kill -TERM $pid ($comm)" kill -TERM "$pid"; then
      sent+=("$pid"); starts+=("$start"); freed=$((freed + bytes))
    fi
  done
  (( ${#sent[@]} )) || { _optimize_skipped "Orphaned processes" "already gone or changed"; return; }
  sleep 5
  local i
  for i in "${!sent[@]}"; do _optimize_alive "${sent[$i]}" "${starts[$i]}" && survivors+=("${sent[$i]}"); done
  _optimize_applied "Sent SIGTERM to ${#sent[@]} orphaned processes ($(mm_human "$freed") RAM+swap)" ""
  if (( ${#survivors[@]} )); then
    _optimize_attention "${#survivors[@]} still running after 5s · force: kill -9 ${survivors[*]}"
  fi
}

# ---------------------------------------------------------------- orphaned automation browsers
# Playwright, Puppeteer and agent browser tools start headless Chromium and stop it when their
# script ends. A script that crashes or is killed leaves the browser, its renderers and its GPU
# process running with nobody connected to them.

# Chromium-family program names (argv[0] basename, or comm: at most 15 characters).
_OPTIMIZE_CHROMIUM='chrome|chromium|chromium-browser|headless_shell|chrome-headless-shell|chrome-headless|msedge'
# Programs that drive browsers: a browser whose parent is one of them is in use, even when that
# parent is PID 1 (a container running node or python as its init).
_OPTIMIZE_DRIVERS='node|nodejs|bun|deno|python[0-9.]*|java|ruby|php|dotnet|chromedriver|msedgedriver|MainThread'
# Init and subreapers: where the kernel hands a process whose parent exited.
_OPTIMIZE_REAPERS='systemd|init|tini|docker-init|dumb-init|catatonit|s6-svscan|runsvdir'

# _optimize_browser_root PID — prints "NAME<TAB>PROFILE" and returns 0 if PID is the main process
# of an automation browser: a Chromium-family program without --type= (renderer, GPU, zygote and
# utility processes carry one), started --headless or on a throwaway automation profile
# (--user-data-dir=…/playwright_chromiumdev_profile-*, puppeteer_dev_chrome_profile-*,
# *_dev_*profile*). PROFILE is that --user-data-dir, empty when none was given.
_optimize_browser_root() {
  local -a argv=()
  local comm name a headless=0 profile=""
  { mapfile -d '' -t argv <"/proc/$1/cmdline"; IFS= read -r comm <"/proc/$1/comm"; } 2>/dev/null || return 1
  (( ${#argv[@]} )) || return 1
  name=${argv[0]##*/}
  if [[ ! "$name" =~ ^($_OPTIMIZE_CHROMIUM)$ ]]; then
    [[ "$comm" =~ ^($_OPTIMIZE_CHROMIUM)$ ]] || return 1
    name=$comm
  fi
  for a in "${argv[@]:1}"; do
    case $a in
      --type=*) return 1 ;;
      --headless|--headless=*) headless=1 ;;
      --user-data-dir=*) profile=${a#--user-data-dir=} ;;
    esac
  done
  profile=${profile%/}
  case ${profile##*/} in
    playwright_chromiumdev_profile-*|puppeteer_dev_chrome_profile-*|*_dev_*profile*) ;;
    *) (( headless )) || return 1 ;;
  esac
  printf '%s\t%s\n' "$name" "$profile"
}

# _optimize_service_main PID — 0 if PID is the oldest process of a systemd service's cgroup: a
# browser run as a service on purpose, not one left behind (a leftover shares its cgroup with the
# older program that started it).
_optimize_service_main() {
  local cg start q s
  cg=$(awk -F: '$1 == 0 { print $3; exit }' "/proc/$1/cgroup" 2>/dev/null)
  [[ "$cg" == *.service && -r "/sys/fs/cgroup$cg/cgroup.procs" ]] || return 1
  start=$(_optimize_starttime "$1")
  [[ "$start" =~ ^[0-9]+$ ]] || return 1
  while IFS= read -r q; do
    s=$(_optimize_starttime "$q")
    [[ "$s" =~ ^[0-9]+$ ]] && (( s < start )) && return 1
  done <"/sys/fs/cgroup$cg/cgroup.procs"
  return 0
}

# _optimize_browser_orphaned PID — 0 if nothing that could have launched PID is its parent any
# more: the parent is gone, started after PID (so PID was handed to it), or is init (PID 1) or a
# subreaper (systemd --user, tini, docker-init, ...) that is not itself a program that drives
# browsers. A parent outside this PID namespace (ppid 0), an unreadable parent, or a browser that
# is a systemd service's own process is not an orphan.
_optimize_browser_orphaned() {
  local ppid start pstart pcomm="" pname
  local -a pargv=()
  ppid=$(_optimize_stat_field "$1" 2); start=$(_optimize_starttime "$1")
  [[ "$ppid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] && (( ppid > 0 )) || return 1
  _optimize_service_main "$1" && return 1
  [[ -d "/proc/$ppid" ]] || return 0
  pstart=$(_optimize_starttime "$ppid")
  { IFS= read -r pcomm <"/proc/$ppid/comm"; mapfile -d '' -n 1 -t pargv <"/proc/$ppid/cmdline"; } 2>/dev/null
  [[ "$pstart" =~ ^[0-9]+$ && -n "$pcomm" ]] || return 1
  (( pstart > start )) && return 0
  pname=${pargv[0]:-}; pname=${pname##*/}
  [[ "$pcomm" =~ ^($_OPTIMIZE_DRIVERS)$ || "$pname" =~ ^($_OPTIMIZE_DRIVERS)$ ]] && return 1
  (( ppid == 1 )) || [[ "$pcomm" =~ ^($_OPTIMIZE_REAPERS)$ ]]
}

# _optimize_mem_bytes PID... — proportional memory (PSS plus swapped PSS: pages shared with other
# processes are split among them) of the PIDs together; resident + swap where smaps_rollup is
# missing (Linux < 4.14). cat skips processes that exit mid-read.
_optimize_mem_bytes() {
  local pid file=smaps_rollup keys='Pss|SwapPss' files=()
  [[ -r "/proc/$1/smaps_rollup" ]] || file=status keys='VmRSS|VmSwap'
  for pid; do files+=("/proc/$pid/$file"); done
  cat -- "${files[@]}" 2>/dev/null | awk -v k="^($keys):\$" '$1 ~ k { kb += $2 } END { printf "%.0f\n", kb * 1024 }'
}

# _optimize_browsers — "pid<TAB>start<TAB>age<TAB>bytes<TAB>name<TAB>profile<TAB>parent<TAB>tree" for
# this user's orphaned automation browsers older than MM_OPTIMIZE_ORPHAN_AGE seconds (default
# 3600). Only the browser's main process is listed; tree holds "pid:start" of every process under
# it, bytes the memory of all of them. profile is "-" without --user-data-dir (tab-separated
# read collapses empty fields).
_optimize_browsers() {
  local min_age=${MM_OPTIMIZE_ORPHAN_AGE:-3600} p pid st info name profile age tree c parent
  local -a f=() queue=() more=() pids=()
  local -A mine=() kids=() start=()
  for pid in $(_optimize_ancestors); do mine[$pid]=1; done
  for p in /proc/[0-9]*; do
    { IFS= read -r st <"$p/stat"; } 2>/dev/null || continue
    read -r -a f <<<"${st##*) }"
    pid=${p#/proc/}; start[$pid]=${f[19]}; kids[${f[1]}]+=" $pid"
  done
  for pid in "${!start[@]}"; do
    [[ -z "${mine[$pid]:-}" && -O "/proc/$pid" ]] || continue
    info=$(_optimize_browser_root "$pid") || continue
    _optimize_browser_orphaned "$pid" || continue
    age=$(mm_proc_age "$pid") || continue
    (( age >= min_age )) || continue
    IFS=$'\t' read -r name profile <<<"$info"; profile=${profile:--}
    { parent=$(<"/proc/$(_optimize_stat_field "$pid" 2)/comm"); } 2>/dev/null || parent="?"
    tree="" pids=("$pid")
    read -r -a queue <<<"${kids[$pid]:-}"
    while (( ${#queue[@]} )); do
      c=${queue[0]}; queue=("${queue[@]:1}")
      tree+="${tree:+ }$c:${start[$c]}" pids+=("$c")
      read -r -a more <<<"${kids[$c]:-}"; queue+=("${more[@]}")
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "${start[$pid]}" "$age" \
      "$(_optimize_mem_bytes "${pids[@]}")" "$name" "$profile" "$parent" "$tree"
  done
}

# _optimize_running PID START — 0 if the same process (pid + start time) still runs (not a zombie).
_optimize_running() { _optimize_alive "$1" "$2" && [[ "$(_optimize_stat_field "$1" 1)" != Z ]]; }

# _optimize_browser_line ROW — the one-line display (and picker entry) for a browser row; pid first.
_optimize_browser_line() {
  local pid age bytes name profile parent tree n=1
  IFS=$'\t' read -r pid _ age bytes name profile parent tree <<<"$1"
  [[ -n "$tree" ]] && n=$(( $(wc -w <<<"$tree") + 1 ))
  [[ "$profile" == - ]] && profile="(no profile dir)"
  printf '%-7s %-14s %-6s %9s  %s · %s processes · parent %s\n' "$pid" "$name" \
    "$(_optimize_ago "$age" | sed 's/ ago//')" "$(mm_human "$bytes")" "$profile" "$n" "$parent"
}

_optimize_browser_task() {
  mm_section "Orphaned Browsers"
  local rows=() row pid start bytes name tree total=0
  mapfile -t rows < <(_optimize_browsers)
  if (( ${#rows[@]} == 0 )); then
    _optimize_unchanged "Orphaned browsers" "none (no headless browser of yours outlived the script that started it)"
    return
  fi
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r _ _ _ bytes _ <<<"$row"; total=$((total + bytes))
    printf '  %s•%s %s\n' "$C_YELLOW" "$C_RESET" "$(_optimize_browser_line "$row")"
  done
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    _optimize_applied "" "Would offer ${#rows[@]} orphaned headless browsers for SIGTERM ($(mm_human "$total") RAM+swap; you pick which, interactively)"
    return
  fi
  if [[ "$MM_TTY" != 1 ]]; then
    _optimize_skipped "Orphaned browsers" "needs interactive confirmation"
    return
  fi

  local picked=() chosen=()
  if (( ${#rows[@]} == 1 )) || ! _optimize_have_fzf; then
    for row in "${rows[@]}"; do
      mm_confirm "Stop browser $(_optimize_browser_line "$row")?" && picked+=("${row%%$'\t'*}")
    done
  else
    mapfile -t picked < <(for row in "${rows[@]}"; do _optimize_browser_line "$row"; done |
      mm_pick "TAB: mark browsers to stop · Enter: confirm · Esc: none" | awk '{ print $1 }')
  fi
  for row in "${rows[@]}"; do
    for pid in "${picked[@]}"; do [[ "${row%%$'\t'*}" == "$pid" ]] && chosen+=("$row"); done
  done
  if (( ${#chosen[@]} == 0 )); then
    _optimize_skipped "Orphaned browsers" "none selected"
    return
  fi

  # Every signal goes to a pid only while it still has the start time seen in the scan: a pid
  # reused by another process in the meantime is never touched.
  local procs=() names=() freed=0 n=0 forced=0 left p i member
  for row in "${chosen[@]}"; do
    IFS=$'\t' read -r pid start _ bytes name _ _ tree <<<"$row"
    if ! _optimize_running "$pid" "$start" || ! _optimize_browser_root "$pid" >/dev/null ||
       ! _optimize_browser_orphaned "$pid"; then
      continue
    fi
    mm_run "kill -TERM $pid ($name)" kill -TERM "$pid" || continue
    n=$((n + 1)) freed=$((freed + bytes))
    procs+=("$pid:$start") names+=("$name")
    for member in $tree; do procs+=("$member") names+=("$name"); done
  done
  (( n )) || { _optimize_skipped "Orphaned browsers" "already gone or changed"; return; }
  for (( i = 0; i < 25; i++ )); do
    left=0
    for p in "${procs[@]}"; do _optimize_running "${p%%:*}" "${p#*:}" && { left=1; break; }; done
    (( left )) || break
    sleep 0.2
  done
  for i in "${!procs[@]}"; do
    p=${procs[$i]}
    _optimize_running "${p%%:*}" "${p#*:}" || continue
    mm_run "kill -KILL ${p%%:*} (${names[$i]})" kill -KILL "${p%%:*}" && forced=$((forced + 1))
  done
  local note=""
  (( forced )) && note="; $forced processes ignored SIGTERM and got SIGKILL"
  _optimize_applied "Stopped $n orphaned browsers ($(mm_human "$freed") RAM+swap$note)" ""
}

# ---------------------------------------------------------------- disk, network, services

# _optimize_last_trim — epoch of the last fstrim.service run (falls back to the timer's
# persistent last-trigger time, which survives reboots).
_optimize_last_trim() {
  local ts
  ts=$(systemctl show fstrim.service -p ExecMainExitTimestamp --value 2>/dev/null)
  [[ -n "$ts" && "$ts" != "n/a" ]] || ts=$(systemctl show fstrim.timer -p LastTriggerUSec --value 2>/dev/null)
  [[ -n "$ts" && "$ts" != "n/a" ]] || return 1
  date -d "$ts" +%s 2>/dev/null
}

_optimize_disk() {
  mm_section "Disk"
  local last since
  if mm_in_container; then
    _optimize_skipped "SSD TRIM" "in a container: the disk belongs to the host"
  elif ! command -v fstrim >/dev/null; then
    _optimize_skipped "SSD TRIM" "fstrim not installed"
  elif last=$(_optimize_last_trim) && since=$(( $(date +%s) - last )) && (( since < 86400 )); then
    _optimize_unchanged "SSD TRIM" "fstrim.timer ran $(_optimize_ago "$since")"
  elif [[ "$MM_DRY_RUN" != 1 ]] && ! mm_can_sudo; then
    _optimize_skipped "SSD TRIM" "needs sudo"
  elif mm_run "fstrim /" mm_sudo fstrim -v /; then
    _optimize_applied "SSD TRIM issued on /" "Would TRIM free blocks on / (fstrim -v /)"
  else
    _optimize_attention "fstrim / failed (filesystem or disk may not support discard)"
  fi

  local journal
  journal=$(journalctl --disk-usage 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "up") { print $(i + 1); exit } }')
  [[ -n "$journal" ]] && _optimize_unchanged "Journal" "$journal on disk (mm clean vacuums old entries)"
}

_optimize_network() {
  command -v resolvectl >/dev/null || return 0
  mm_section "Network"
  if ! systemctl is-active -q systemd-resolved 2>/dev/null; then
    _optimize_skipped "DNS cache" "systemd-resolved not running"
  elif [[ "$MM_DRY_RUN" != 1 ]] && ! mm_can_sudo; then
    _optimize_skipped "DNS cache" "needs sudo"
  elif mm_run "resolvectl flush-caches" mm_sudo resolvectl flush-caches; then
    _optimize_applied "DNS cache flushed" "Would flush DNS cache (resolvectl flush-caches)"
  else
    _optimize_attention "DNS cache flush failed"
  fi
}

_optimize_services() {
  mm_section "Services"
  local units=() user_units=() u
  if [[ ! -d /run/systemd/system ]]; then _optimize_skipped "Systemd units" "systemd is not running"; return; fi
  mapfile -t units < <(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF { print $1 }')
  mapfile -t user_units < <(systemctl --user --failed --no-legend --plain 2>/dev/null | awk 'NF { print $1 }')
  if (( ${#units[@]} + ${#user_units[@]} == 0 )); then
    _optimize_unchanged "Systemd units" "none failed"
    return
  fi
  for u in "${units[@]}"; do _optimize_attention "Failed unit: $u · systemctl status $u"; done
  for u in "${user_units[@]}"; do _optimize_attention "Failed user unit: $u · systemctl --user status $u"; done
}

_optimize_reboot() {
  mm_section "Reboot"
  local pending=() running newest
  if mm_in_container; then _optimize_skipped "Reboot" "in a container: the kernel belongs to the host"; return; fi
  if [[ -f /var/run/reboot-required ]]; then
    if [[ -s /var/run/reboot-required.pkgs ]]; then mapfile -t pending < <(sort -u /var/run/reboot-required.pkgs)
    else pending=("(reboot-required flag)"); fi
  fi
  running=$(uname -r)
  newest=$(dpkg-query -W -f='${Status}\t${Package}\n' 'linux-image-[0-9]*' 2>/dev/null |
    awk -F'\t' '$1 == "install ok installed" { sub(/^linux-image-/, "", $2); print $2 }' | sort -V | tail -1)
  if [[ -n "$newest" && "$newest" != "$running" &&
        "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | tail -1)" == "$newest" ]]; then
    [[ " ${pending[*]} " == *" linux-image-$newest "* ]] || pending+=("linux-image-$newest")
  fi
  if (( ${#pending[@]} )); then
    _optimize_attention "Reboot pending: $(_optimize_list "${pending[@]}") · running $running · sudo reboot"
  else
    _optimize_unchanged "Reboot" "not needed (running $running)"
  fi
}

# ---------------------------------------------------------------- main

_optimize_usage() {
  cat <<EOF
Usage: mm optimize [--dry-run]

Diagnose performance (load, pressure, swap, CPU and memory hogs), then:
  apt upgrade (snap refresh reported only) · swap reset when RAM allows · SIGTERM processes
  stranded in deleted directories (older than 1h) · stop orphaned headless browsers (Playwright,
  Puppeteer and agent Chromium whose script is gone, older than 1h: SIGTERM, then SIGKILL for
  the same process if it ignores it) · fstrim / (unless trimmed <24h ago) · DNS cache flush ·
  report failed units and pending reboots (never reboots).

Options:
  -n, --dry-run   Show what would be applied; runs nothing (not even apt-get update)

Confirmations (upgrades, swap reset, SIGTERM, browsers) need a terminal; without one they are
skipped. In a container the swap reset, TRIM and reboot check are skipped (swap, disk and kernel
belong to the host), the diagnosis reports load, pressure and swap as the host's without flagging
them, and memory against the cgroup limit when one is set.

Environment:
  MM_OPTIMIZE_ORPHAN_AGE   minimum process age in seconds for orphaned processes and browsers
                           (default 3600)
  MM_CONTAINER             1 or 0: treat this machine as a container or not (default: detected)
EOF
}

mm_cmd_main() {
  while (( $# )); do
    case "$1" in
      -h|--help) _optimize_usage; return 0 ;;
      *) mm_die "unknown option: $1 (see mm optimize --help)" ;;
    esac
  done

  mm_header "Optimize"
  _optimize_diagnose
  _optimize_updates
  _optimize_swap
  _optimize_orphan_task
  _optimize_browser_task
  _optimize_disk
  _optimize_network
  _optimize_services
  _optimize_reboot

  local tail="$_OPTIMIZE_UNCHANGED unchanged | $_OPTIMIZE_SKIPPED skipped"
  (( _OPTIMIZE_ATTENTION )) && tail+=" | $_OPTIMIZE_ATTENTION need attention"
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_banner "Dry Run Complete" "Would apply $_OPTIMIZE_APPLIED optimizations" "$tail" \
      "Run without --dry-run to apply."
  else
    mm_banner "Optimization Complete" "Applied $_OPTIMIZE_APPLIED optimizations" "$tail"
  fi
}
