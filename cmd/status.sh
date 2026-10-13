# shellcheck shell=bash
# mm status: read-only health dashboard. CPU, memory, disk (bytes and inodes), network (default
# route plus VPN/overlay links), processes, and system upkeep (updates, reboot, kernel, failed
# units, AI agent sessions, lingering dev servers, old listening ports) with a 0-100 health score.
# Fast probes read /proc every tick; slow probes (apt, systemd, dpkg, docker) run in the
# background at start and then every ST_SLOW_EVERY seconds. Nothing here changes the system.

ST_SLOW_EVERY=300
ST_HIST=16
ST_SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
# Dev servers/toolchains and listening ports older than this many seconds are "lingering"
# (left running by a finished agent or a forgotten terminal). Env: MM_STATUS_LINGER_AGE.
ST_LINGER_AGE=86400
# VPN/overlay interface globs shown under Network when up. Env: MM_STATUS_VPN_IFACES ("" = none).
ST_VPN_GLOBS='tailscale* wg* tun* zt* nebula* netbird* wt*'
# Dev servers and toolchains (process name, ERE) reported once they outlive ST_LINGER_AGE.
ST_DEV_RE='^(node|nodejs|bun|deno|python[0-9.]*|tsc|vite|next-server.*|nuxt|esbuild|webpack|rollup|parcel|turbo|nx|nodemon|tsx|ts-node|jest|vitest|playwright|uvicorn|gunicorn|hypercorn|flask|celery|rails|puma|ruby|php|java|gradle|mvn|go|air|cargo|cargo-watch|hugo|jekyll)$'
# Interpreters whose argv may name an agent CLI (`node ~/.npm-global/bin/gemini`); argv decides.
ST_INTERP_RE='^(node|nodejs|bun|deno|python[0-9.]*|.*MainThread.*)$'
# Long-lived helpers that belong to an editor, not a forgotten server (matched on the full argv).
ST_LINGER_SKIP_RE='(--stdio|--lsp|/\.(vscode|vscode-insiders|cursor|windsurf|vscodium)-server/|/\.vscode-remote/)'

_status_usage() {
  cat <<EOF
${C_BOLD}mm status${C_RESET}: live system health dashboard (read-only)

Usage: mm status [--once | --json] [--interval N]

Options:
  --once          Print one snapshot and exit (default when stdout is not a terminal)
  --json          Print one snapshot as JSON and exit (needs jq)
  --interval N    Live refresh interval in seconds (default 2)
  -h, --help      Show this help

Keys (live): q quit
Slow probes (apt, systemd, kernel packages, docker) refresh every 5 minutes.

Agents: running AI coding agent CLIs (lib/agents.sh catalog; matched by process name or by the
  script an interpreter runs), with longest age, memory, and orphans (working dir deleted).
Lingering: dev servers/toolchains (node, bun, deno, python, vite, next-server, esbuild, uvicorn,
  gunicorn, ...) of yours running longer than the linger age and not part of a live agent session.
Ports: TCP ports your processes have listened on longer than the linger age.

Environment:
  MM_STATUS_LINGER_AGE   seconds before a dev process or listener counts as lingering (86400)
  MM_STATUS_VPN_IFACES   VPN interface globs ("$ST_VPN_GLOBS")

Health starts at 100 and drops for sustained CPU >85%, load above core count, low available
memory, swap >50%, root disk >=80%, root inodes >=90%, pending reboot, failed units, and
orphaned agent or dev processes.
EOF
}

# ---------------------------------------------------------------- formatting

# Helpers that write into a caller variable (printf -v VAR) use "__"-prefixed locals so they
# never shadow the caller's target name.

# _status_dec VAR X10 — "45.2" from 452.
_status_dec() { printf -v "$1" '%d.%d' $(($2 / 10)) $(($2 % 10)); }

# _status_gib VAR BYTES — "18.7" (GiB, one decimal).
_status_gib() { local __x=$((($2 * 10 + 536870912) / 1073741824)); printf -v "$1" '%d.%d' $((__x / 10)) $((__x % 10)); }

# _status_rate VAR BYTES_PER_SEC — "0.54 MB/s" / "18.3 MB/s".
_status_rate() {
  local __v=$(($2 * 100 / 1048576))
  if ((__v < 1000)); then printf -v "$1" '%d.%02d MB/s' $((__v / 100)) $((__v % 100))
  else printf -v "$1" '%d.%d MB/s' $((__v / 100)) $((__v % 100 / 10)); fi
}

# _status_dur VAR SECONDS — "3d 12h 45m".
_status_dur() {
  local __s=$2 __d __h __m
  __d=$((__s / 86400)) __h=$((__s % 86400 / 3600)) __m=$((__s % 3600 / 60))
  if ((__d)); then printf -v "$1" '%dd %dh %dm' "$__d" "$__h" "$__m"
  elif ((__h)); then printf -v "$1" '%dh %dm' "$__h" "$__m"
  else printf -v "$1" '%dm' "$__m"; fi
}

# _status_pad VAR TEXT WIDTH — plain TEXT left-aligned in WIDTH characters. printf's %-Ns pads
# bytes, which misaligns columns after "…" or any non-ASCII name.
_status_pad() {
  local __p
  printf -v __p '%*s' $(($3 > ${#2} ? $3 - ${#2} : 0)) ''
  printf -v "$1" '%s%s' "$2" "$__p"
}

# _status_trunc VAR TEXT WIDTH — plain text cut to WIDTH chars with an ellipsis.
_status_trunc() {
  local __t=$2 __w=$3
  ((__w < 1)) && __w=1
  ((${#__t} > __w)) && __t="${__t:0:__w-1}…"
  printf -v "$1" '%s' "$__t"
}

# _status_vlen VAR TEXT — visible length (ANSI SGR sequences stripped).
_status_vlen() {
  local __s=$2 __pre __rest
  while [[ "$__s" == *$'\e['* ]]; do
    __pre=${__s%%$'\e['*} __rest=${__s#*$'\e['}
    __s=$__pre${__rest#*m}
  done
  printf -v "$1" '%d' "${#__s}"
}

# _status_bar VAR PCT10 WIDTH [INVERT] — threshold-colored bar; INVERT=1 when low is bad.
_status_bar() {
  local __p=$2 __w=$3 __inv=${4:-0} __fill __color __full __empty
  ((__p < 0)) && __p=0
  ((__p > 1000)) && __p=1000
  __fill=$(((__p * __w + 500) / 1000))
  if ((__inv)); then
    if ((__p <= 100)); then __color=$C_RED; elif ((__p <= 200)); then __color=$C_YELLOW; else __color=$C_GREEN; fi
  else
    if ((__p >= 900)); then __color=$C_RED; elif ((__p >= 750)); then __color=$C_YELLOW; else __color=$C_GREEN; fi
  fi
  printf -v __full '%*s' "$__fill" ''
  printf -v __empty '%*s' $((__w - __fill)) ''
  printf -v "$1" '%s%s%s%s%s' "$__color" "${__full// /█}" "$C_DIM" "${__empty// /░}" "$C_RESET"
}

# _status_meter VAR LEVEL — five-cell "▮▮▮▯▯" meter (LEVEL 0-5).
_status_meter() {
  local __l=$2 __on __off
  ((__l < 0)) && __l=0
  ((__l > 5)) && __l=5
  printf -v __on '%*s' "$__l" ''
  printf -v __off '%*s' $((5 - __l)) ''
  printf -v "$1" '%s%s%s%s%s' "$C_CYAN" "${__on// /▮}" "$C_DIM" "${__off// /▯}" "$C_RESET"
}

# _status_io_level BYTES_PER_SEC — meter level on a log-ish scale (0.1/1/10/50/200 MB/s) in REPLY.
_status_io_level() {
  local b=$1 l=0 t
  for t in 104857 1048576 10485760 52428800 209715200; do ((b >= t)) && l=$((l + 1)); done
  REPLY=$l
}

# _status_spark VAR FLOOR VALUE... — sparkline of the samples so far (no padding: callers put it
# after fixed-width columns, so a short history never opens a gap), scaled to max(FLOOR, values).
_status_spark() {
  local __out=$1 __max=$2 __v __s=""
  shift 2
  for __v; do ((__v > __max)) && __max=$__v; done
  for __v; do
    ((__v < 0)) && __v=0
    __s+=${ST_SPARK[__max > 0 ? __v * 7 / __max : 0]}
  done
  printf -v "$__out" '%s%s%s' "$C_CYAN" "$__s" "$C_RESET"
}

# _status_push ARRAY VALUE — append and keep the last ST_HIST entries.
_status_push() {
  local -n _arr=$1
  _arr+=("$2")
  ((${#_arr[@]} > ST_HIST)) && _arr=("${_arr[@]:1}")
  return 0
}

# ---------------------------------------------------------------- static facts

_status_init() {
  local k v src i
  local -a procs
  ST_TMP=$(mktemp -d -t marmot-status.XXXXXX) || mm_die "cannot create a temp dir"
  ST_HZ=$(getconf CLK_TCK)
  ST_CORES=$(nproc)
  ST_HOST=${HOSTNAME%%.*}
  ST_MODEL=""
  while IFS=: read -r k v; do
    [[ "$k" == model\ name* ]] && { ST_MODEL=$v; break; }
  done </proc/cpuinfo
  # ARM kernels have no "model name" in /proc/cpuinfo; lscpu names the core (Neoverse-N1, ...).
  [[ -n "${ST_MODEL// /}" ]] || ST_MODEL=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Model name/ { print $2; exit }')
  ST_MODEL=${ST_MODEL//(R)/} ST_MODEL=${ST_MODEL//(TM)/} ST_MODEL=${ST_MODEL%%@*}
  ST_MODEL=${ST_MODEL% CPU*} ST_MODEL=${ST_MODEL% Processor*} ST_MODEL=${ST_MODEL% with *}
  ST_MODEL=${ST_MODEL% [0-9]*-Core*}
  read -r -a v <<<"$ST_MODEL"
  ST_MODEL="${v[*]:-unknown cpu}"
  ST_OS=$(. /etc/os-release 2>/dev/null && echo "${NAME:-Linux} ${VERSION_ID:-}")
  ST_MEMGB=$(awk '/^MemTotal/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
  # Root block device as the kernel names it in /proc/diskstats (sda1, nvme0n1p2, dm-0, md0).
  # btrfs reports subvolumes as /dev/sda2[/@]; zfs/overlay roots have no block device.
  src=$(findmnt -no SOURCE / 2>/dev/null)
  src=${src%%\[*}
  ST_DISK=""
  [[ "$src" == /dev/* ]] && ST_DISK=$(lsblk -ndo KNAME "$src" 2>/dev/null)
  ST_HAS_BOOT=0
  mountpoint -q /boot 2>/dev/null && ST_HAS_BOOT=1
  read -r -a ST_VPN_PATS <<<"$ST_VPN_GLOBS"
  # Agent catalog (lib/agents.sh): process name → agent, and the 15-char comm the kernel shows.
  declare -gA ST_AGENT_OF=() ST_AGENT_COMM=()
  for i in "${!MM_AGENT_NAME[@]}"; do
    read -r -a procs <<<"${MM_AGENT_PROCS[i]}"
    for k in "${procs[@]}"; do ST_AGENT_OF[$k]=${MM_AGENT_NAME[i]} ST_AGENT_COMM[${k:0:15}]=$k; done
  done
  ST_PF=0 ST_T=0 ST_SLOW_PID="" ST_SLOW_AT=0 ST_TOPN=5 ST_NCORE=4 ST_GAP=1 ST_IF=""
  ST_CT=() ST_CI=() ST_CPU=() ST_CPUH=() ST_RXH=() ST_TXH=() ST_FAILED=() ST_ORPHANS=() ST_KPENDING=0
  declare -gA ST_SLOW=() ST_NRX=() ST_NTX=() ST_P_NRX=() ST_P_NTX=() ST_RBPS=() ST_TBPS=()
}

# ---------------------------------------------------------------- fast probes (every tick)

# _status_sample — read /proc counters; the previous sample is kept as ST_P_*.
_status_sample() {
  local name u n s i w q sq st rest idx=0 maj min dev rd rm sr rt wr wm sw ifc data rx tx dst mask k v p g it iu
  ST_P_T=$ST_T ST_P_CT=("${ST_CT[@]}") ST_P_CI=("${ST_CI[@]}")
  ST_P_DR=${ST_DR:-0} ST_P_DW=${ST_DW:-0}
  ST_P_NRX=() ST_P_NTX=()
  for k in "${!ST_NRX[@]}"; do ST_P_NRX[$k]=${ST_NRX[$k]} ST_P_NTX[$k]=${ST_NTX[$k]}; done
  ST_T=${EPOCHREALTIME/[.,]/}

  ST_CT=() ST_CI=()
  while read -r name u n s i w q sq st rest; do
    [[ "$name" == cpu* ]] || break
    ST_CT[idx]=$((u + n + s + i + w + q + sq + st)) ST_CI[idx]=$((i + w))
    idx=$((idx + 1))
  done </proc/stat

  ST_DR=0 ST_DW=0
  if [[ -n "$ST_DISK" ]]; then
    while read -r maj min dev rd rm sr rt wr wm sw rest; do
      [[ "$dev" == "$ST_DISK" ]] && { ST_DR=$sr ST_DW=$sw; break; }
    done </proc/diskstats
  fi

  # Default route: IPv4 first, then ::/0 for IPv6-only hosts.
  ST_IF=""
  while read -r ifc dst _ _ _ _ _ mask _; do
    [[ "$dst" == 00000000 && "$mask" == 00000000 ]] && { ST_IF=$ifc; break; }
  done 2>/dev/null </proc/net/route
  if [[ -z "$ST_IF" && -r /proc/net/ipv6_route ]]; then
    while read -r dst mask _ _ _ _ _ _ _ ifc; do
      [[ "$dst" == 00000000000000000000000000000000 && "$mask" == 00 && "$ifc" != lo ]] && { ST_IF=$ifc; break; }
    done </proc/net/ipv6_route
  fi
  # VPN/overlay links that are up (IFF_UP), other than the default-route interface.
  ST_VPN=()
  if ((${#ST_VPN_PATS[@]})); then
    for p in /sys/class/net/*; do
      ifc=${p##*/}
      [[ "$ifc" == "$ST_IF" ]] && continue
      for g in "${ST_VPN_PATS[@]}"; do
        # shellcheck disable=SC2053 # $g is a glob on purpose
        [[ "$ifc" == $g ]] || continue
        v=0
        read -r v 2>/dev/null <"$p/flags"
        ((v & 1)) && ST_VPN+=("$ifc")
        break
      done
    done
  fi
  ST_NRX=() ST_NTX=()
  local -A want=()
  [[ -n "$ST_IF" ]] && want[$ST_IF]=1
  for v in "${ST_VPN[@]}"; do want[$v]=1; done
  while IFS=: read -r ifc data; do
    ifc=${ifc// /}
    [[ -n "$ifc" && -n "${want[$ifc]:-}" ]] || continue
    read -r rx _ _ _ _ _ _ _ tx _ <<<"$data"
    ST_NRX[$ifc]=$rx ST_NTX[$ifc]=$tx
  done </proc/net/dev

  ST_SWT=0 ST_SWF=0
  while read -r k v _; do
    case "$k" in
      MemTotal:) ST_MT=$v ;;
      MemAvailable:) ST_MA=$v ;;
      SwapTotal:) ST_SWT=$v ;;
      SwapFree:) ST_SWF=$v ;;
    esac
  done </proc/meminfo
  ST_PSI=""
  [[ -r /proc/pressure/memory ]] && { read -r _ v _ </proc/pressure/memory; ST_PSI=${v#avg10=}; }
  read -r ST_L1 ST_L5 ST_L15 _ </proc/loadavg
  read -r v _ </proc/uptime
  ST_UP=${v%.*}

  ST_REBOOT=0 ST_REBOOT_PKGS=""
  if [[ -f /var/run/reboot-required ]]; then
    ST_REBOOT=1
    if [[ -r /var/run/reboot-required.pkgs ]]; then
      local -A seen=()
      while read -r v; do
        [[ -n "$v" && -z "${seen[$v]:-}" ]] || continue
        seen[$v]=1 ST_REBOOT_PKGS+="${ST_REBOOT_PKGS:+ }$v"
      done </var/run/reboot-required.pkgs
    fi
  fi

  # "mount size used avail inodes_total inodes_used"; inode counts are 0 where the filesystem
  # has no fixed inode table (btrfs, zfs report "-" or 0).
  ST_DF=()
  local -a mounts=(/)
  ((ST_HAS_BOOT)) && mounts+=(/boot)
  while read -r k s u v it iu; do
    [[ "$k" == /* ]] || continue
    [[ "$it" =~ ^[0-9]+$ ]] || it=0
    [[ "$iu" =~ ^[0-9]+$ ]] || iu=0
    ST_DF+=("$k $s $u $v $it $iu")
  done < <(df -B1 --output=target,size,used,avail,itotal,iused "${mounts[@]}" 2>/dev/null)

  _status_procs
  _status_ports
}

# _status_procs — one pass over /proc/*/stat and /proc/*/status: per-process CPU deltas (top 5),
# RSS+swap (top 5; marmot's own process tree is left out of both), zombie and process counts.
# Then, among this user's processes:
#   ST_AGENTS  agent sessions "pid agent proc age kb orphan" (helper processes of a session are
#              folded in: their memory counts, they are not extra sessions);
#   ST_LINGER  dev servers/toolchains older than ST_LINGER_AGE that are not inside a live agent
#              session or an editor, "pid name age kb orphan";
#   ST_ORPHANS either kind whose working directory was deleted, "pid name age cwd kind".
_status_procs() {
  local prev=$ST_TMP/procs.$((ST_PF ^ 1)) cur=$ST_TMP/procs.$ST_PF dt=$((ST_T - ST_P_T))
  local kind a b c d e out pid ppid kb comm age proc name cwd orphan p n
  ((ST_P_T > 0)) || dt=0
  ST_PF=$((ST_PF ^ 1))
  : >>"$prev"
  out=$(cat /proc/[0-9]*/stat /proc/[0-9]*/status 2>/dev/null | awk -v hz="$ST_HZ" -v dt="$dt" \
    -v up="$ST_UP" -v uid="$EUID" -v pf="$prev" -v cur="$cur" -v agents="${!ST_AGENT_COMM[*]}" \
    -v devre="$ST_DEV_RE" -v interp="$ST_INTERP_RE" -v minage="$ST_LINGER_AGE" -v me="$$" '
    function ins(set, v, p, n,   i, j) {
      for (i = 1; i <= 5; i++) if (!((set, i) in tv) || v > tv[set, i]) break
      if (i > 5) return
      for (j = 5; j > i; j--) if ((set, j - 1) in tv) {
        tv[set, j] = tv[set, j - 1]; tp[set, j] = tp[set, j - 1]; tn[set, j] = tn[set, j - 1]
      }
      tv[set, i] = v; tp[set, i] = p; tn[set, i] = n
    }
    # mine PID — 1 if PID is marmot itself or runs under it (the sampling pipeline, slow probes).
    function mine(p,   q, n) {
      if (p in self) return self[p]
      for (q = p + 0; q > 1 && n++ < 64; q = ppid[q] + 0) if (q == me) return self[p] = 1
      return self[p] = 0
    }
    function flush() {
      if (spid != "" && mem > 0) { smem[spid] = mem; sn[spid] = sname }
      if (spid != "" && suid == uid && (spid in ppid)) {
        print "P", spid, ppid[spid]
        if (spid in kind) print kind[spid], spid, ppid[spid], mem, cname[spid], age[spid]
      }
      spid = ""; mem = 0; suid = ""
    }
    BEGIN { OFS = "\t"; n = split(agents, al, " "); for (i = 1; i <= n; i++) isagent[al[i]] = 1 }
    FILENAME == pf { prev[$1] = $2; next }
    /^[0-9]+ \(/ {
      l = index($0, "("); r = 0
      for (i = l + 17; i > l; i--) if (substr($0, i, 1) == ")") { r = i; break }
      if (!r) next
      pid = substr($0, 1, l - 2); comm = substr($0, l + 1, r - l - 1)
      split(substr($0, r + 2), f, " ")
      ticks = f[12] + f[13]; a = int(up - f[20] / hz)
      print pid, ticks > cur
      total++; ppid[pid] = f[2]
      if (f[1] == "Z") zombies++
      if (dt > 0 && (pid in prev)) { pct = int((ticks - prev[pid]) * 1e9 / (hz * dt) + 0.5); if (pct > 0) { cpu[pid] = pct; cn[pid] = comm } }
      if (comm in isagent) kind[pid] = "A"
      else if (comm ~ interp) kind[pid] = "I"
      else if (comm ~ devre && a >= minage) kind[pid] = "D"
      if (pid in kind) { cname[pid] = comm; age[pid] = a }
      next
    }
    /^Name:/ { flush(); sname = substr($0, 7) }
    /^Pid:/ { spid = $2 }
    /^Uid:/ { suid = $2 }
    /^VmRSS:|^VmSwap:/ { mem += $2 }
    END {
      flush(); close(cur)
      print "Z", zombies + 0, total + 0
      for (p in cpu) if (!mine(p)) ins("C", cpu[p], p, cn[p])
      for (p in smem) if (!mine(p)) ins("M", smem[p], p, sn[p])
      for (i = 1; i <= 5; i++) if (("C", i) in tv) print "C", tp["C", i], tv["C", i], tn["C", i]
      for (i = 1; i <= 5; i++) if (("M", i) in tv) print "M", tp["M", i], tv["M", i], tn["M", i]
    }' "$prev" -)

  ST_TOPCPU=() ST_TOPMEM=()
  local -A pp=() agent_of=()
  local -a cands=() agents=() devs=()
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      Z) ST_ZOMBIES=$a ST_NPROC=$b ;;
      C) _status_pname "$a" "$c"; ST_TOPCPU+=("$a"$'\t'"$b"$'\t'"$REPLY") ;;
      M) _status_pname "$a" "$c"; ST_TOPMEM+=("$a"$'\t'"$b"$'\t'"$REPLY") ;;
      P) pp[$a]=$b ;;
      A | I | D) cands+=("$kind"$'\t'"$a"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\t'"$e") ;;
    esac
  done <<<"$out"
  _status_top_ctx

  # Agents: by process name, or by the script an interpreter runs (node .../bin/gemini).
  for e in "${cands[@]}"; do
    IFS=$'\t' read -r kind pid ppid kb comm age <<<"$e"
    proc=""
    if [[ "$kind" == A ]]; then
      proc=${ST_AGENT_COMM[$comm]}
    elif [[ "$kind" == I ]]; then
      _status_argv "$pid"
      [[ -n "$ST_ARGV_SCRIPT" && -n "${ST_AGENT_OF[$ST_ARGV_SCRIPT]:-}" ]] && proc=$ST_ARGV_SCRIPT
      [[ -z "$proc" && -n "$ST_ARGV_BASE" && -n "${ST_AGENT_OF[$ST_ARGV_BASE]:-}" ]] && proc=$ST_ARGV_BASE
    fi
    if [[ -n "$proc" ]]; then
      agent_of[$pid]=$proc
      agents+=("$e"$'\t'"$proc")
    elif ((age >= ST_LINGER_AGE)); then
      devs+=("$e")
    fi
  done

  ST_AGENTS=() ST_AGENT_KB=0 ST_AGENT_MAXAGE=0 ST_ORPHANS=() ST_LINGER=() ST_LINGER_KB=0
  for e in "${agents[@]}"; do
    IFS=$'\t' read -r kind pid ppid kb comm age proc <<<"$e"
    ST_AGENT_KB=$((ST_AGENT_KB + kb))
    [[ -n "${agent_of[$ppid]:-}" ]] && continue
    ((age > ST_AGENT_MAXAGE)) && ST_AGENT_MAXAGE=$age
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) orphan=0
    if [[ "$cwd" == *" (deleted)" ]]; then
      orphan=1
      ST_ORPHANS+=("$pid"$'\t'"$proc"$'\t'"$age"$'\t'"${cwd% (deleted)}"$'\t'agent)
    fi
    ST_AGENTS+=("$pid"$'\t'"${ST_AGENT_OF[$proc]}"$'\t'"$proc"$'\t'"$age"$'\t'"$kb"$'\t'"$orphan")
  done

  for e in "${devs[@]}"; do
    IFS=$'\t' read -r kind pid ppid kb comm age <<<"$e"
    # Started by a live agent (any ancestor): part of that session, not lingering.
    p=$ppid
    for ((n = 0; n < 64; n++)); do
      [[ -n "${agent_of[$p]:-}" ]] && continue 2
      [[ -n "${pp[$p]:-}" ]] || break
      p=${pp[$p]}
    done
    _status_argv "$pid"
    [[ "$ST_ARGV_LINE" =~ $ST_LINGER_SKIP_RE ]] && continue
    name=$comm
    if [[ "$comm" =~ $ST_INTERP_RE ]] && [[ -n "$ST_ARGV_BASE$ST_ARGV_TITLE" ]]; then _status_argv_name; name=$REPLY; fi
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) orphan=0
    if [[ "$cwd" == *" (deleted)" ]]; then
      orphan=1
      ST_ORPHANS+=("$pid"$'\t'"$name"$'\t'"$age"$'\t'"${cwd% (deleted)}"$'\t'lingering)
    fi
    ST_LINGER+=("$pid"$'\t'"$name"$'\t'"$age"$'\t'"$kb"$'\t'"$orphan")
    ST_LINGER_KB=$((ST_LINGER_KB + kb))
  done
  ((${#ST_AGENTS[@]} > 1)) && mapfile -t ST_AGENTS < <(printf '%s\n' "${ST_AGENTS[@]}" | sort -t$'\t' -k4,4nr)
  ((${#ST_LINGER[@]} > 1)) && mapfile -t ST_LINGER < <(printf '%s\n' "${ST_LINGER[@]}" | sort -t$'\t' -k3,3nr)
  return 0
}

# _status_argv PID — parse /proc/PID/cmdline into ST_ARGV_BASE (argv[0] basename), ST_ARGV_PATH
# (first non-option argument: the script an interpreter runs), ST_ARGV_SCRIPT (its basename
# without .js/.mjs/.cjs/.py/.ts), ST_ARGV_TITLE (a rewritten process title such as
# "node (vitest 1)", which arrives as one spaced string) and ST_ARGV_LINE (argv joined by spaces).
_status_argv() {
  ST_ARGV_BASE="" ST_ARGV_PATH="" ST_ARGV_SCRIPT="" ST_ARGV_TITLE="" ST_ARGV_LINE=""
  local -a argv=()
  local a skip=0
  mapfile -d '' -n 16 argv 2>/dev/null <"/proc/$1/cmdline" || return 0
  ((${#argv[@]})) || return 0
  ST_ARGV_LINE="${argv[*]}"
  if [[ "${argv[0]}" == *" "* ]]; then a=${argv[0]}; ST_ARGV_TITLE=${a%"${a##*[! ]}"}; return 0; fi
  ST_ARGV_BASE=${argv[0]##*/}
  for a in "${argv[@]:1}"; do
    if ((skip)); then skip=0; continue; fi
    case "$a" in
      -r | --require | --import | --loader | --experimental-loader | --env-file | --conditions | -C | --title | -W | -X | -c | -e | --eval | -p | --print)
        skip=1; continue ;;
      -* | "") continue ;;
    esac
    [[ "${a##*/}" == "$ST_ARGV_BASE" ]] && continue
    ST_ARGV_PATH=$a
    a=${a##*/} a=${a%.*js} a=${a%.py} a=${a%.ts}
    ST_ARGV_SCRIPT=$a
    break
  done
}

# _status_argv_name — display name from the last _status_argv, in REPLY: the rewritten title,
# "node vite" (generic entry points like cli.js/index.js use their package dir), or argv[0].
_status_argv_name() {
  local a=$ST_ARGV_SCRIPT
  if [[ -n "$ST_ARGV_TITLE" ]]; then
    REPLY=$ST_ARGV_TITLE
  elif [[ -n "$a" ]]; then
    if [[ "$a" == @(cli|index|main|run|__main__) && "$ST_ARGV_PATH" == */*/* ]]; then a=${ST_ARGV_PATH%/*} a=${a##*/}; fi
    REPLY="$ST_ARGV_BASE $a"
  else
    REPLY=$ST_ARGV_BASE
  fi
}

# _status_pname PID COMM — display name in REPLY. Interpreters and generic thread names
# (node, python3, bun, MainThread...) become "node vite" from argv; others keep COMM.
_status_pname() {
  REPLY=$2
  [[ "$2" =~ $ST_INTERP_RE || "$2" =~ ^(ruby|perl|java|npm.*)$ ]] || return 0
  _status_argv "$1"
  [[ -n "$ST_ARGV_BASE$ST_ARGV_TITLE" ]] || { REPLY=$2; return 0; }
  _status_argv_name
}

# _status_top_ctx — append where each ST_TOPCPU/ST_TOPMEM process works as a fourth field: the
# last two components of its cwd when that lies under $HOME ("handle/esi"), else empty. Two tsc
# or node processes are told apart by project this way. One find(1) call for all of them.
_status_top_ctx() {
  local e dir cwd a
  local -A ctx=()
  local -a paths=()
  for e in "${ST_TOPCPU[@]}" "${ST_TOPMEM[@]}"; do paths+=("/proc/${e%%$'\t'*}/cwd"); done
  ((${#paths[@]})) || return 0
  while IFS=$'\t' read -r dir cwd; do
    [[ "$cwd" == "$HOME"/* && "$cwd" != *" (deleted)" ]] || continue
    cwd=${cwd#"$HOME"/}
    [[ "$cwd" == */*/* ]] && cwd=${cwd#"${cwd%/*/*}"/}
    ctx[${dir#/proc/}]=$cwd
  done < <(find "${paths[@]}" -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null)
  for a in ST_TOPCPU ST_TOPMEM; do
    local -n top=$a
    for e in "${!top[@]}"; do top[e]+=$'\t'"${ctx[${top[e]%%$'\t'*}]:-}"; done
    unset -n top
  done
}

# _status_page PID — process age in seconds (from /proc/PID/stat, relative to ST_UP) in REPLY.
_status_page() {
  local line
  local -a f
  read -r line 2>/dev/null <"/proc/$1/stat" || return 1
  read -r -a f <<<"${line##*) }"
  [[ "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
  REPLY=$((ST_UP - f[19] / ST_HZ))
}

# _status_hexaddr HEX — /proc/net/tcp{,6} address as text in REPLY: "*" (any), dotted IPv4
# (also for IPv4-mapped IPv6), "::1", or "v6".
_status_hexaddr() {
  local h=$1
  case "$h" in
    00000000 | 00000000000000000000000000000000) REPLY="*" ;;
    00000000000000000000000001000000) REPLY="::1" ;;
    ????????) REPLY="$((16#${h:6:2})).$((16#${h:4:2})).$((16#${h:2:2})).$((16#${h:0:2}))" ;;
    0000000000000000FFFF0000????????) _status_hexaddr "${h:24:8}" ;;
    *) REPLY="v6" ;;
  esac
}

# _status_ports — TCP sockets this user listens on (/proc/net/tcp{,6}), mapped to their process
# through /proc/*/fd. ST_NLISTEN counts them; ST_PORTS holds those older than ST_LINGER_AGE as
# "port addr pid name age", oldest first. A listener on both stacks counts once.
_status_ports() {
  local f loc st uid ino dir link pid age port key addr comm
  local -A sock=() owner=() pidage=() entry=()
  ST_PORTS=() ST_NLISTEN=0
  for f in /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$f" ]] || continue
    while read -r _ loc _ st _ _ _ uid _ ino _; do
      [[ "$st" == 0A && "$uid" == "$EUID" && "$ino" != 0 ]] && sock[$ino]=$loc
    done <"$f"
  done
  ((${#sock[@]})) || return 0
  while read -r dir link; do
    ino=${link#socket:\[} ino=${ino%\]}
    [[ -n "${sock[$ino]:-}" ]] || continue
    pid=${dir#/proc/} pid=${pid%/fd}
    if [[ -z "${pidage[$pid]:-}" ]]; then _status_page "$pid" || continue; pidage[$pid]=$REPLY; fi
    age=${pidage[$pid]}
    # Forked workers share the socket; it belongs to the oldest of them (the server's parent).
    if [[ -z "${owner[$ino]:-}" ]] || ((age > ${owner[$ino]#* })); then owner[$ino]="$pid $age"; fi
  done < <(find /proc/[0-9]*/fd -maxdepth 1 -lname 'socket:*' -printf '%h %l\n' 2>/dev/null)
  for ino in "${!owner[@]}"; do
    read -r pid age <<<"${owner[$ino]}"
    port=$((16#${sock[$ino]##*:}))
    _status_hexaddr "${sock[$ino]%:*}"
    addr=$REPLY key="$pid:$port"
    if [[ -n "${entry[$key]:-}" && "$addr" != "*" ]]; then continue; fi
    entry[$key]="$port"$'\t'"$addr"$'\t'"$pid"$'\t'"$age"
  done
  ST_NLISTEN=${#entry[@]}
  for key in "${!entry[@]}"; do
    IFS=$'\t' read -r port addr pid age <<<"${entry[$key]}"
    ((age >= ST_LINGER_AGE)) || continue
    comm=""
    read -r comm 2>/dev/null <"/proc/$pid/comm"
    _status_pname "$pid" "${comm:-?}"
    ST_PORTS+=("$port"$'\t'"$addr"$'\t'"$pid"$'\t'"$REPLY"$'\t'"$age")
  done
  ((${#ST_PORTS[@]} > 1)) && mapfile -t ST_PORTS < <(printf '%s\n' "${ST_PORTS[@]}" | sort -t$'\t' -k5,5nr -k1,1n)
  return 0
}

# _status_derive — rates and percentages from the last two samples; feeds the histories.
_status_derive() {
  local dt=$((ST_T - ST_P_T)) i t d v k m sz us av it iu
  ((dt > 0)) || dt=1
  ST_CPU=()
  for i in "${!ST_CT[@]}"; do
    t=$((ST_CT[i] - ${ST_P_CT[i]:-0})) d=$((ST_CI[i] - ${ST_P_CI[i]:-0}))
    ST_CPU[i]=$((t > 0 ? (t - d) * 1000 / t : 0))
  done
  _status_push ST_CPUH "${ST_CPU[0]:-0}"
  v=$(((ST_DR - ST_P_DR) * 512 * 1000000 / dt)); ST_RD_BPS=$((v > 0 ? v : 0))
  v=$(((ST_DW - ST_P_DW) * 512 * 1000000 / dt)); ST_WR_BPS=$((v > 0 ? v : 0))
  ST_RBPS=() ST_TBPS=()
  for k in "${!ST_NRX[@]}"; do
    ST_RBPS[$k]=0 ST_TBPS[$k]=0
    [[ -n "${ST_P_NRX[$k]:-}" ]] || continue
    v=$(((${ST_NRX[$k]} - ${ST_P_NRX[$k]}) * 1000000 / dt)); ST_RBPS[$k]=$((v > 0 ? v : 0))
    v=$(((${ST_NTX[$k]} - ${ST_P_NTX[$k]}) * 1000000 / dt)); ST_TBPS[$k]=$((v > 0 ? v : 0))
  done
  ST_RX_BPS=0 ST_TX_BPS=0
  [[ -n "$ST_IF" ]] && ST_RX_BPS=${ST_RBPS[$ST_IF]:-0} ST_TX_BPS=${ST_TBPS[$ST_IF]:-0}
  _status_push ST_RXH "$ST_RX_BPS"
  _status_push ST_TXH "$ST_TX_BPS"

  ST_MEM_USED_PCT=$(((ST_MT - ST_MA) * 1000 / ST_MT)) ST_MEM_AVAIL_PCT=$((ST_MA * 1000 / ST_MT))
  ST_SWAP_PCT=0
  ((ST_SWT > 0)) && ST_SWAP_PCT=$(((ST_SWT - ST_SWF) * 1000 / ST_SWT))
  ST_ROOT_PCT=0 ST_ROOT_IPCT=-1
  for v in "${ST_DF[@]}"; do
    read -r m sz us av it iu <<<"$v"
    [[ "$m" == / ]] || continue
    ((sz > 0)) && ST_ROOT_PCT=$((us * 1000 / sz))
    ((it > 0)) && ST_ROOT_IPCT=$((iu * 1000 / it))
  done
  _status_health
}

# ---------------------------------------------------------------- slow probes (background)

# _status_slow_probe FILE — apt/systemd/dpkg/docker/addresses as "key<TAB>value" lines, atomically.
# Every tool is optional; each probe is capped at 2s so a snapshot stays under 3s.
_status_slow_probe() {
  local out=$1 d=$ST_TMP/slow.d
  mkdir -p "$d"
  {
    if command -v apt >/dev/null; then
      timeout 2 apt list --upgradable 2>/dev/null |
        awk -F/ 'NR > 1 && NF { n++; if (n <= 30) names = names (names ? " " : "") $1 }
          END { printf "upgradable\t%d\nupgradable_names\t%s\n", n, names }'
    fi
  } >"$d/apt" &
  {
    local f
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
      if f=$(timeout 2 systemctl --failed --no-legend --plain 2>/dev/null); then
        printf 'failed_ok\t1\nfailed\t%s\n' "$(awk '{ print $1 }' <<<"$f" | paste -sd' ')"
      fi
      if command -v unattended-upgrade >/dev/null; then
        printf 'unattended\t%s\n' "$(timeout 2 systemctl is-active unattended-upgrades 2>/dev/null)"
      else
        printf 'unattended\tabsent\n'
      fi
    else
      printf 'systemd\tabsent\n'
    fi
  } >"$d/systemd" &
  {
    # Debian/Ubuntu kernel packages carry the ABI (6.8.0-45, 6.1.0-18); a reboot is pending when
    # an installed one is newer than the running kernel.
    local re='[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' running abi newest="" pending=0
    running=$(uname -r) abi=$(grep -oE "$re" <<<"$running")
    if command -v dpkg-query >/dev/null; then
      newest=$(timeout 2 dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null |
        awk '$1 == "ii" { print $2 }' | grep -oE "$re" | sort -V | tail -1)
    fi
    if [[ -n "$newest" && -n "$abi" && "$newest" != "$abi" &&
      "$(printf '%s\n%s\n' "$abi" "$newest" | sort -V | tail -1)" == "$newest" ]]; then pending=1; fi
    printf 'kernel_running\t%s\nkernel_running_abi\t%s\nkernel_newest_abi\t%s\nkernel_pending\t%s\n' \
      "$running" "$abi" "$newest" "$pending"
  } >"$d/kernel" &
  {
    if command -v docker >/dev/null; then
      local states
      if states=$(timeout 2 docker ps -a --format '{{.State}}' 2>/dev/null); then
        printf 'docker\t%s\n' "$(awk '$1 == "running" { r++; next } NF { o++ } END { printf "%d %d", r, o }' <<<"$states")"
      else
        printf 'docker\tdown\n'
      fi
    fi
  } >"$d/docker" &
  {
    if command -v ip >/dev/null; then
      ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); printf "addr_%s\t%s\n", $2, $4 }'
    fi
  } >"$d/addr" &
  wait
  { cat "$d"/apt "$d"/systemd "$d"/kernel "$d"/docker "$d"/addr; printf 'at\t%s\n' "$(date +%s)"; } >"$out.tmp"
  mv -f "$out.tmp" "$out"
}

_status_slow_start() {
  [[ -n "$ST_SLOW_PID" ]] && kill -0 "$ST_SLOW_PID" 2>/dev/null && return 0
  _status_slow_probe "$ST_TMP/slow" &
  ST_SLOW_PID=$! ST_SLOW_AT=${EPOCHSECONDS}
}

# _status_slow_load — read the latest slow-probe results into ST_SLOW (keeps old ones until then).
_status_slow_load() {
  [[ -f "$ST_TMP/slow" ]] || return 0
  local k v
  ST_SLOW=()
  while IFS=$'\t' read -r k v; do [[ -n "$k" ]] && ST_SLOW[$k]=$v; done <"$ST_TMP/slow"
  ST_KPENDING=${ST_SLOW[kernel_pending]:-0}
  ST_FAILED=()
  read -r -a ST_FAILED <<<"${ST_SLOW[failed]:-}"
}

# ---------------------------------------------------------------- health

_status_pen() { ST_PEN+=("$1"); ST_WHY+=("$2"); ST_SCORE=$((ST_SCORE - $1)); }

_status_health() {
  local n=0 sum=0 v i j pct
  ST_SCORE=100 ST_PEN=() ST_WHY=() ST_REASONS=()
  for ((i = ${#ST_CPUH[@]} - 1; i >= 0 && n < 15; i--)); do sum=$((sum + ST_CPUH[i])) n=$((n + 1)); done
  # A snapshot (--once/--json) has one 0.5s sample; only call CPU "sustained" over >= 3 samples.
  if ((n >= 3 && sum / n > 850)); then _status_dec pct $((sum / n)); _status_pen 15 "CPU ${pct}% sustained"; fi
  v=${ST_L1/./}
  ((10#$v > ST_CORES * 100)) && _status_pen 10 "load $ST_L1 > $ST_CORES cores"
  if ((ST_MEM_AVAIL_PCT < 100)); then _status_pen 20 "memory $((ST_MEM_AVAIL_PCT / 10))% available"
  elif ((ST_MEM_AVAIL_PCT < 200)); then _status_pen 10 "memory $((ST_MEM_AVAIL_PCT / 10))% available"; fi
  ((ST_SWAP_PCT > 500)) && _status_pen 10 "swap $((ST_SWAP_PCT / 10))% used"
  if ((ST_ROOT_PCT >= 900)); then _status_pen 25 "disk $((ST_ROOT_PCT / 10))% full"
  elif ((ST_ROOT_PCT >= 800)); then _status_pen 10 "disk $((ST_ROOT_PCT / 10))% full"; fi
  ((ST_REBOOT || ${ST_KPENDING:-0})) && _status_pen 10 "reboot required"
  if ((ST_ROOT_IPCT >= 900)); then _status_pen 20 "inodes $((ST_ROOT_IPCT / 10))% used"; fi
  ((${#ST_FAILED[@]})) && _status_pen 10 "${#ST_FAILED[@]} failed unit$( ((${#ST_FAILED[@]} > 1)) && echo s)"
  ((${#ST_ORPHANS[@]})) && _status_pen 5 "${#ST_ORPHANS[@]} orphaned process$( ((${#ST_ORPHANS[@]} > 1)) && echo es)"
  ((ST_SCORE < 0)) && ST_SCORE=0
  # Reasons, heaviest penalty first (stable).
  local -a idx=("${!ST_PEN[@]}")
  for ((i = 1; i < ${#idx[@]}; i++)); do
    for ((j = i; j > 0 && ST_PEN[idx[j]] > ST_PEN[idx[j - 1]]; j--)); do
      v=${idx[j]} idx[j]=${idx[j - 1]} idx[j - 1]=$v
    done
  done
  for i in "${idx[@]}"; do ST_REASONS+=("${ST_WHY[i]}"); done
}

# ---------------------------------------------------------------- panels

# _status_row LABEL CONTENT — append a "Label    content" row to ST_PANEL (labels over 8 chars
# push only their own row's content).
_status_row() { local l; printf -v l '%-8s %s' "$1" "$2"; ST_PANEL+=("$l"); }
# _status_count VAR N — "11.6M" / "58.5K" / "600".
_status_count() {
  if (($2 >= 1000000)); then printf -v "$1" '%d.%dM' $(($2 / 1000000)) $(($2 % 1000000 / 100000))
  elif (($2 >= 1000)); then printf -v "$1" '%d.%dK' $(($2 / 1000)) $(($2 % 1000 / 100))
  else printf -v "$1" '%d' "$2"; fi
}
_status_title() { ST_PANEL=("$C_BOLD$1$C_RESET"); }
_status_ok() { REPLY="$C_GREEN✓$C_RESET $1"; }
_status_bad() { REPLY="$C_RED✗$C_RESET $1"; }
_status_warn() { REPLY="$C_YELLOW!$C_RESET $1"; }

_status_panel_cpu() {
  local bar pct i j best v l1 trend
  _status_title "⚙ CPU"
  _status_bar bar "${ST_CPU[0]:-0}" 20
  _status_dec pct "${ST_CPU[0]:-0}"
  _status_row Total "$bar $(printf '%6s' "$pct%")"
  l1="$ST_L1 / $ST_L5 / $ST_L15"
  v=${ST_L1/./}
  ((10#$v > ST_CORES * 100)) && l1="$C_YELLOW$l1$C_RESET"
  _status_row Load "$l1 ($ST_CORES cores)"
  # Busiest ST_NCORE cores (selection on a copy).
  local -a cores=("${ST_CPU[@]:1}") used=()
  for ((j = 0; j < ST_NCORE && j < ${#cores[@]}; j++)); do
    best=-1
    for i in "${!cores[@]}"; do
      [[ -n "${used[i]:-}" ]] && continue
      ((best < 0 || cores[i] > cores[best])) && best=$i
    done
    used[best]=1
    _status_bar bar "${cores[best]}" 20
    _status_dec pct "${cores[best]}"
    _status_row "Core $best" "$bar $(printf '%6s' "$pct%")"
  done
  if ((${#ST_CPUH[@]} >= 2)); then
    _status_spark trend 1000 "${ST_CPUH[@]}"
    _status_row Trend "$trend"
  fi
}

_status_panel_mem() {
  local bar pct used total avail sw swu
  _status_title "▦ Memory"
  _status_gib used $(((ST_MT - ST_MA) * 1024))
  _status_gib total $((ST_MT * 1024))
  _status_gib avail $((ST_MA * 1024))
  _status_bar bar "$ST_MEM_USED_PCT" 20
  _status_dec pct "$ST_MEM_USED_PCT"
  _status_row Used "$bar $(printf '%6s' "$pct%")  $used/$total GB"
  _status_bar bar "$ST_MEM_AVAIL_PCT" 20 1
  _status_dec pct "$ST_MEM_AVAIL_PCT"
  _status_row Avail "$bar $(printf '%6s' "$pct%")  $avail GB"
  if ((ST_SWT > 0)); then
    _status_gib swu $(((ST_SWT - ST_SWF) * 1024))
    _status_gib sw $((ST_SWT * 1024))
    _status_bar bar "$ST_SWAP_PCT" 20
    _status_dec pct "$ST_SWAP_PCT"
    _status_row Swap "$bar $(printf '%6s' "$pct%")  $swu/$sw GB"
  else
    _status_row Swap "${C_DIM}none$C_RESET"
  fi
  if [[ -n "$ST_PSI" ]]; then
    local p=${ST_PSI%.*} c=""
    if ((p >= 20)); then c=$C_RED; elif ((p >= 5)); then c=$C_YELLOW; fi
    _status_row Pressure "${c}some $ST_PSI%$C_RESET (avg10)"
  fi
}

_status_panel_disk() {
  local v m sz us av it iu bar pct free label meter rate p c
  _status_title "▤ Disk"
  for v in "${ST_DF[@]}"; do
    read -r m sz us av it iu <<<"$v"
    ((sz > 0)) || continue
    label=Root
    [[ "$m" == /boot ]] && label=Boot
    _status_bar bar $((us * 1000 / sz)) 20
    _status_dec pct $((us * 1000 / sz))
    free=$(mm_human "$av")
    _status_row "$label" "$bar $(printf '%6s' "$pct%")  $free free"
    # Inodes: node_modules-heavy trees can exhaust them long before bytes run out.
    if [[ "$m" == / ]] && ((it > 0)); then
      p=$((iu * 1000 / it)) c=""
      if ((p >= 900)); then c=$C_RED; elif ((p >= 800)); then c=$C_YELLOW; fi
      _status_bar bar "$p" 20
      _status_dec pct "$p"
      _status_count free $((it - iu))
      _status_row Inodes "$bar $c$(printf '%6s' "$pct%")$C_RESET  $free free"
    fi
  done
  if [[ -n "$ST_DISK" ]]; then
    _status_io_level "$ST_RD_BPS"; _status_meter meter "$REPLY"; _status_rate rate "$ST_RD_BPS"
    _status_row Read "$meter $(printf '%10s' "$rate") · $ST_DISK"
    _status_io_level "$ST_WR_BPS"; _status_meter meter "$REPLY"; _status_rate rate "$ST_WR_BPS"
    _status_row Write "$meter $(printf '%10s' "$rate")"
  fi
}

# _status_netgraph VAR BPS HISTORY... — sparkline once there is history, else a level meter.
_status_netgraph() {
  local __o=$1 __b=$2
  shift 2
  if (($# >= 2)); then _status_spark "$__o" 65536 "$@"; else _status_io_level "$__b"; _status_meter "$__o" "$REPLY"; fi
}

_status_panel_net() {
  local sp rate rx tx addr ifc t
  _status_title "⇅ Network"
  if [[ -z "$ST_IF" ]]; then
    _status_row Route "${C_DIM}no default route$C_RESET"
  else
    _status_netgraph sp "$ST_RX_BPS" "${ST_RXH[@]}"; _status_rate rate "$ST_RX_BPS"
    _status_row Down "$(printf '%10s' "$rate") $sp"
    _status_netgraph sp "$ST_TX_BPS" "${ST_TXH[@]}"; _status_rate rate "$ST_TX_BPS"
    _status_row Up "$(printf '%10s' "$rate") $sp"
    addr=${ST_SLOW[addr_$ST_IF]:-}
    _status_row Iface "$ST_IF${addr:+ · $addr}"
  fi
  for ifc in "${ST_VPN[@]}"; do
    _status_rate rx "${ST_RBPS[$ifc]:-0}"; _status_rate tx "${ST_TBPS[$ifc]:-0}"
    addr=${ST_SLOW[addr_$ifc]:-}
    t="$ifc ↓ ${rx% MB/s} ↑ $tx"
    ((${#t} + ${#addr} + 3 <= ST_W - 9)) && t+="${addr:+ · $addr}"
    _status_trunc t "$t" $((ST_W - 9))
    _status_row VPN "$t"
  done
}

_status_panel_proc() {
  local e pid v name ctx meter pct nw pw=3 label size z row
  # PID column as wide as the widest PID shown, not pid_max's seven digits.
  for e in "${ST_TOPCPU[@]:0:ST_TOPN}" "${ST_TOPMEM[@]:0:ST_TOPN}"; do
    pid=${e%%$'\t'*}
    ((${#pid} > pw)) && pw=${#pid}
  done
  nw=$((ST_W - 24 - pw))
  ((nw > 36)) && nw=36
  ((nw < 6)) && nw=6
  _status_title "▶ Processes"
  z=${ST_ZOMBIES:-0}
  ((z > 0)) && z="$C_YELLOW$z$C_RESET"
  _status_row Procs "${ST_NPROC:-0} · zombies $z"
  label="Top CPU"
  for e in "${ST_TOPCPU[@]:0:ST_TOPN}"; do
    IFS=$'\t' read -r pid v name ctx <<<"$e"
    _status_trunc name "$name${ctx:+ ($ctx)}" "$nw"
    _status_pad name "$name" "$nw"
    _status_meter meter $(((v + 199) / 200))
    _status_dec pct "$v"
    printf -v row "%s %${pw}s %s %6s" "$name" "$pid" "$meter" "$pct%"
    _status_row "$label" "$row"
    label=""
  done
  [[ "$label" ]] && _status_row "$label" "${C_DIM}idle$C_RESET"
  label="Top mem"
  for e in "${ST_TOPMEM[@]:0:ST_TOPN}"; do
    IFS=$'\t' read -r pid v name ctx <<<"$e"
    _status_trunc name "$name${ctx:+ ($ctx)}" "$nw"
    _status_pad name "$name" "$nw"
    _status_gib size $((v * 1024))
    printf -v row "%s %${pw}s %7s" "$name" "$pid" "$size GB"
    _status_row "$label" "$row"
    label=""
  done
}

# _status_age VAR SECONDS — two-unit age: "3d 12h", "2h 5m", "1d", "16m".
_status_age() {
  local __s=$2 __d __h __m
  __d=$((__s / 86400)) __h=$((__s % 86400 / 3600)) __m=$((__s % 3600 / 60))
  if ((__d)); then
    if ((__h)); then printf -v "$1" '%dd %dh' "$__d" "$__h"; else printf -v "$1" '%dd' "$__d"; fi
  elif ((__h)); then
    if ((__m)); then printf -v "$1" '%dh %dm' "$__h" "$__m"; else printf -v "$1" '%dh' "$__h"; fi
  else
    printf -v "$1" '%dm' "$__m"
  fi
}

_status_panel_sys() {
  local up t pkgs w=$((ST_W - 9)) n e pid name age cwd kind d agent proc kb orphan port addr
  local nd=$((ST_TOPN >= 4 ? 3 : ST_TOPN - 1)) older
  _status_age older "$ST_LINGER_AGE"
  older=">$older"
  _status_title "◆ System"
  _status_dur up "$ST_UP"
  _status_row Uptime "$up"
  if ((ST_REBOOT)); then
    _status_trunc pkgs "${ST_REBOOT_PKGS:-unknown}" $((w - 12))
    _status_bad "required: $pkgs"
  else
    _status_ok "not required"
  fi
  _status_row Reboot "$REPLY"
  if [[ -z "${ST_SLOW[at]:-}" ]]; then
    _status_row Kernel "${C_DIM}checking…$C_RESET"
    _status_row Units "${C_DIM}checking…$C_RESET"
    _status_row Updates "${C_DIM}checking…$C_RESET"
  else
    if ((ST_KPENDING)); then
      _status_trunc t "${ST_SLOW[kernel_newest_abi]} installed, running ${ST_SLOW[kernel_running_abi]}" $((w - 2))
      _status_bad "$t"
    else
      _status_trunc t "${ST_SLOW[kernel_running]}" $((w - 2))
      _status_ok "$t"
    fi
    _status_row Kernel "$REPLY"
    if [[ "${ST_SLOW[systemd]:-}" == absent ]]; then
      REPLY="${C_DIM}no systemd$C_RESET"
    elif [[ -z "${ST_SLOW[failed_ok]:-}" ]]; then
      _status_warn "systemctl did not answer"
    elif ((${#ST_FAILED[@]})); then
      _status_trunc t "${ST_FAILED[*]}" $((w - 14))
      _status_bad "${#ST_FAILED[@]} failed: $t"
    else
      _status_ok "none failed"
    fi
    _status_row Units "$REPLY"
    n=${ST_SLOW[upgradable]:-}
    if [[ -z "$n" ]]; then t="${C_DIM}apt not available$C_RESET"
    elif ((n > 0)); then t="$C_YELLOW$n$C_RESET upgradable"
    else t="$C_GREEN✓$C_RESET current"; fi
    case "${ST_SLOW[unattended]:-}" in
      "") ;;
      active) t+=" · unattended $C_GREEN✓$C_RESET" ;;
      absent) t+=" · ${C_DIM}no unattended-upgrades$C_RESET" ;;
      *) t+=" · unattended $C_YELLOW${ST_SLOW[unattended]}$C_RESET" ;;
    esac
    _status_row Updates "$t"
    if [[ -n "${ST_SLOW[docker]:-}" ]]; then
      if [[ "${ST_SLOW[docker]}" == down ]]; then
        _status_row Docker "${C_DIM}daemon not reachable$C_RESET"
      else
        read -r n t <<<"${ST_SLOW[docker]}"
        _status_row Docker "$n running · $t stopped"
      fi
    fi
  fi

  # Agents: sessions, oldest, memory, orphans; then a per-CLI breakdown ("omp ×5 · claude ×1").
  if ((${#ST_AGENTS[@]})); then
    local -A per=()
    n=0
    for e in "${ST_AGENTS[@]}"; do
      IFS=$'\t' read -r pid agent proc age kb orphan <<<"$e"
      per[$proc]=$((${per[$proc]:-0} + 1)) n=$((n + orphan))
    done
    _status_age d "$ST_AGENT_MAXAGE"
    t="${#ST_AGENTS[@]} running · oldest $d · $(mm_human $((ST_AGENT_KB * 1024)))"
    ((n && ${#t} + 13 <= w)) && t+=" · $C_YELLOW$n orphaned$C_RESET"
    _status_row Agents "$t"
    t=$(for proc in "${!per[@]}"; do printf '%s\t%s\n' "${per[$proc]}" "$proc"; done |
      sort -t$'\t' -k1,1nr -k2,2 | awk -F'\t' '{ printf "%s%s ×%s", (NR > 1 ? " · " : ""), $2, $1 }')
    _status_trunc t "$t" "$w"
    _status_row "" "$C_DIM$t$C_RESET"
  else
    _status_row Agents "${C_DIM}none running$C_RESET"
  fi
  for e in "${ST_ORPHANS[@]:0:nd}"; do
    IFS=$'\t' read -r pid name age cwd kind <<<"$e"
    _status_age d "$age"
    _status_trunc t "$name $pid · $d · cwd deleted: ${cwd/#"$HOME"/\~}" $((w - 2))
    _status_row "" "$C_YELLOW!$C_RESET $t"
  done

  if ((${#ST_LINGER[@]})); then
    _status_row Lingering "${#ST_LINGER[@]} $older · $(mm_human $((ST_LINGER_KB * 1024)))"
    for e in "${ST_LINGER[@]:0:nd}"; do
      IFS=$'\t' read -r pid name age kb orphan <<<"$e"
      _status_age d "$age"
      _status_trunc t "$name $pid · $d · $(mm_human $((kb * 1024)))" $((w - 2))
      _status_row "" "$C_DIM·$C_RESET $t"
    done
  else
    _status_row Lingering "$C_GREEN✓$C_RESET none $older"
  fi

  if ((${#ST_PORTS[@]})); then
    IFS=$'\t' read -r _ _ _ _ age <<<"${ST_PORTS[0]}"
    _status_age d "$age"
    _status_row Ports "${#ST_PORTS[@]} listening $older · oldest $d"
    for e in "${ST_PORTS[@]:0:nd}"; do
      IFS=$'\t' read -r port addr pid name age <<<"$e"
      [[ "$addr" == "*" ]] && addr=""
      _status_age d "$age"
      _status_trunc t "$addr:$port → $name ($d)" $((w - 2))
      _status_row "" "$C_DIM·$C_RESET $t"
    done
  else
    _status_row Ports "$C_GREEN✓$C_RESET none $older · ${ST_NLISTEN:-0} listening"
  fi
}

# ---------------------------------------------------------------- frame

# _status_frame COLS — render the dashboard into ST_FRAME (array of lines).
_status_frame() {
  local cols=$1 two=0 col head info len ilen r i rows left pad
  ((cols >= 100)) && two=1
  if ((two)); then ST_W=$(((cols - 2) / 2)); ((ST_W > 56)) && ST_W=56
  else ST_W=$((cols > 80 ? 80 : cols)); ((ST_W < 40)) && ST_W=40; fi

  if ((ST_SCORE >= 80)); then col=$C_GREEN; elif ((ST_SCORE >= 60)); then col=$C_YELLOW; else col=$C_RED; fi
  printf -v head '%smm status%s  Health %s● %d%s' "$C_BOLD" "$C_RESET" "$col" "$ST_SCORE" "$C_RESET"
  if ((${#ST_REASONS[@]})); then
    r=${ST_REASONS[0]}${ST_REASONS[1]:+ · ${ST_REASONS[1]}}
    head+="  $col$r$C_RESET"
  fi
  info="$ST_HOST · $ST_MODEL · ${ST_MEMGB}GB · $ST_OS"
  _status_vlen len "$head"
  ilen=${#info}
  ST_FRAME=()
  if ((len + 2 + ilen <= (two ? cols : ST_W))); then
    ST_FRAME+=("$head  $C_DIM$info$C_RESET")
  else
    ST_FRAME+=("$head" "$C_DIM$info$C_RESET")
  fi
  ST_FRAME+=("")

  local -a P_CPU P_MEM P_DISK P_NET P_PROC P_SYS
  _status_panel_cpu; P_CPU=("${ST_PANEL[@]}")
  _status_panel_mem; P_MEM=("${ST_PANEL[@]}")
  _status_panel_disk; P_DISK=("${ST_PANEL[@]}")
  _status_panel_net; P_NET=("${ST_PANEL[@]}")
  _status_panel_proc; P_PROC=("${ST_PANEL[@]}")
  _status_panel_sys; P_SYS=("${ST_PANEL[@]}")

  local pair a b
  local -a sep=("")
  ((ST_GAP)) || sep=()
  if ((two)); then
    for pair in "P_CPU P_MEM" "P_DISK P_NET" "P_PROC P_SYS"; do
      read -r a b <<<"$pair"
      local -n pa=$a pb=$b
      rows=$((${#pa[@]} > ${#pb[@]} ? ${#pa[@]} : ${#pb[@]}))
      for ((i = 0; i < rows; i++)); do
        left=${pa[i]:-}
        if [[ -n "${pb[i]:-}" ]]; then
          _status_vlen len "$left"
          printf -v pad '%*s' $((ST_W - len + 2)) ''
          left+="$pad${pb[i]}"
        fi
        ST_FRAME+=("$left")
      done
      ST_FRAME+=("${sep[@]}")
      unset -n pa pb
    done
  else
    # One column: upkeep (System) before the long process lists so short terminals keep it.
    for a in P_CPU P_MEM P_DISK P_NET P_SYS P_PROC; do
      local -n pa=$a
      ST_FRAME+=("${pa[@]}" "${sep[@]}")
      unset -n pa
    done
  fi
  [[ -z "${ST_FRAME[-1]}" ]] && unset 'ST_FRAME[-1]'
  return 0
}

_status_cols() {
  local c=""
  if [[ -t 1 ]]; then c=$(tput cols 2>/dev/null); fi
  [[ "$c" =~ ^[0-9]+$ ]] || c=${COLUMNS:-80}
  [[ "$c" =~ ^[0-9]+$ ]] || c=80
  REPLY=$c
}

# ---------------------------------------------------------------- JSON

_status_json() {
  local tc tm ag li or po df nets e ifc i core_list=""
  tc=$(printf '%s\n' "${ST_TOPCPU[@]}")
  tm=$(printf '%s\n' "${ST_TOPMEM[@]}")
  ag=$(printf '%s\n' "${ST_AGENTS[@]}")
  li=$(printf '%s\n' "${ST_LINGER[@]}")
  or=$(printf '%s\n' "${ST_ORPHANS[@]}")
  po=$(printf '%s\n' "${ST_PORTS[@]}")
  df=$(printf '%s\n' "${ST_DF[@]}")
  nets=""
  [[ -n "$ST_IF" ]] && nets+="$ST_IF"$'\tdefault\t'"$ST_RX_BPS"$'\t'"$ST_TX_BPS"$'\n'
  for ifc in "${ST_VPN[@]}"; do nets+="$ifc"$'\tvpn\t'"${ST_RBPS[$ifc]:-0}"$'\t'"${ST_TBPS[$ifc]:-0}"$'\n'; done
  for ((i = 1; i < ${#ST_CPU[@]}; i++)); do core_list+="${core_list:+ }${ST_CPU[i]}"; done
  jq -n \
    --arg host "$ST_HOST" --arg model "$ST_MODEL" --arg os "$ST_OS" --arg score "$ST_SCORE" \
    --arg reasons "$(printf '%s\n' "${ST_REASONS[@]}")" \
    --arg cpu "${ST_CPU[0]:-0}" --arg cores "$core_list" --arg ncores "$ST_CORES" \
    --arg l1 "$ST_L1" --arg l5 "$ST_L5" --arg l15 "$ST_L15" \
    --arg mt "$ST_MT" --arg ma "$ST_MA" --arg swt "$ST_SWT" --arg swf "$ST_SWF" --arg psi "$ST_PSI" \
    --arg df "$df" --arg disk "$ST_DISK" --arg rd "$ST_RD_BPS" --arg wr "$ST_WR_BPS" --arg nets "$nets" \
    --arg tc "$tc" --arg tm "$tm" --arg zombies "${ST_ZOMBIES:-0}" --arg nproc "${ST_NPROC:-0}" \
    --arg up "$ST_UP" --arg reboot "$ST_REBOOT" --arg rpkgs "$ST_REBOOT_PKGS" \
    --arg ag "$ag" --arg akb "$ST_AGENT_KB" --arg amax "$ST_AGENT_MAXAGE" \
    --arg li "$li" --arg lkb "$ST_LINGER_KB" --arg linger "$ST_LINGER_AGE" \
    --arg or "$or" --arg po "$po" --arg nlisten "$ST_NLISTEN" \
    --argjson slow "$(for e in "${!ST_SLOW[@]}"; do printf '%s\t%s\n' "$e" "${ST_SLOW[$e]}"; done |
      jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')" \
    --arg kpending "${ST_KPENDING:-0}" '
    def num: if . == null or . == "" then null else tonumber end;
    def lines: split("\n") | map(select(length > 0) | split("\t"));
    def words: split(" ") | map(select(length > 0));
    def pct10: (tonumber / 10);
    def pct(a; b): if b > 0 then (a * 1000 / b | floor) / 10 else null end;
    {
      host: $host, cpu_model: $model, os: $os,
      health_score: ($score | tonumber),
      health_reasons: ($reasons | split("\n") | map(select(length > 0))),
      collected_at: (now | todate),
      cpu: {
        usage: ($cpu | pct10), logical_cpu: ($ncores | tonumber),
        per_core: ($cores | words | map(pct10)),
        load: [($l1, $l5, $l15) | tonumber]
      },
      memory: {
        total: (($mt | tonumber) * 1024), available: (($ma | tonumber) * 1024),
        used: ((($mt | tonumber) - ($ma | tonumber)) * 1024),
        used_percent: pct(($mt | tonumber) - ($ma | tonumber); $mt | tonumber),
        swap_total: (($swt | tonumber) * 1024), swap_used: ((($swt | tonumber) - ($swf | tonumber)) * 1024),
        psi_some_avg10: ($psi | num)
      },
      disks: ($df | lines | map(.[0] | split(" ") | map(tonumber? // .)) | map({
        mount: .[0], total: .[1], used: .[2], free: .[3], used_percent: (pct(.[2]; .[1]) // 0),
        inodes_total: (if .[4] > 0 then .[4] else null end),
        inodes_used: (if .[4] > 0 then .[5] else null end),
        inodes_used_percent: pct(.[5]; .[4])
      })),
      disk_io: (if $disk == "" then null else
        { device: $disk, read_bytes_per_sec: ($rd | tonumber), write_bytes_per_sec: ($wr | tonumber) } end),
      network: ($nets | lines | map({
        interface: .[0], kind: .[1], default_route: (.[1] == "default"),
        rx_bytes_per_sec: (.[2] | tonumber), tx_bytes_per_sec: (.[3] | tonumber),
        ipv4: $slow["addr_" + .[0]]
      })),
      processes: {
        total: ($nproc | tonumber), zombie_count: ($zombies | tonumber),
        top_cpu: ($tc | lines | map({ pid: (.[0] | tonumber), name: .[2], cpu_percent: (.[1] | pct10) })),
        top_memory: ($tm | lines | map({ pid: (.[0] | tonumber), name: .[2], rss_swap_bytes: ((.[1] | tonumber) * 1024) }))
      },
      system: {
        uptime_seconds: ($up | tonumber),
        reboot_required: ($reboot == "1" or $kpending == "1"),
        reboot_required_pkgs: ($rpkgs | words),
        kernel_running: $slow.kernel_running,
        kernel_newest_installed: ($slow.kernel_newest_abi | if . == "" then null else . end),
        kernel_update_pending: ($kpending == "1"),
        failed_units: (if $slow.failed_ok then ($slow.failed // "" | words) else null end),
        upgradable_packages: ($slow.upgradable | num),
        upgradable_names: ($slow.upgradable_names // "" | words),
        unattended_upgrades: (if ($slow.unattended // "absent") == "absent" then null else $slow.unattended == "active" end),
        docker: (if ($slow.docker // "") == "" then null
          elif $slow.docker == "down" then { reachable: false }
          else ($slow.docker | words | { reachable: true, running: (.[0] | tonumber), stopped: (.[1] | tonumber) }) end),
        agents: {
          count: ($ag | lines | length), longest_age_seconds: ($amax | tonumber),
          rss_swap_bytes: (($akb | tonumber) * 1024),
          orphan_count: ($ag | lines | map(select(.[5] == "1")) | length),
          sessions: ($ag | lines | map({ pid: (.[0] | tonumber), agent: .[1], process: .[2],
            age_seconds: (.[3] | tonumber), rss_swap_bytes: ((.[4] | tonumber) * 1024), orphan: (.[5] == "1") }))
        },
        lingering: {
          min_age_seconds: ($linger | tonumber), count: ($li | lines | length),
          rss_swap_bytes: (($lkb | tonumber) * 1024),
          processes: ($li | lines | map({ pid: (.[0] | tonumber), name: .[1], age_seconds: (.[2] | tonumber),
            rss_swap_bytes: ((.[3] | tonumber) * 1024), orphan: (.[4] == "1") }))
        },
        orphans: ($or | lines | map({ pid: (.[0] | tonumber), name: .[1], kind: .[4],
          age_seconds: (.[2] | tonumber), deleted_cwd: .[3] })),
        listening_ports: {
          min_age_seconds: ($linger | tonumber), total_listening: ($nlisten | tonumber),
          count: ($po | lines | length),
          oldest_age_seconds: ($po | lines | map(.[4] | tonumber) | max),
          ports: ($po | lines | map({ port: (.[0] | tonumber), address: .[1], pid: (.[2] | tonumber),
            name: .[3], age_seconds: (.[4] | tonumber) }))
        }
      }
    }'
}

# ---------------------------------------------------------------- modes

_status_cleanup() {
  [[ -n "${ST_TMP:-}" ]] || return 0
  [[ -n "${ST_SLOW_PID:-}" ]] && kill "$ST_SLOW_PID" 2>/dev/null
  if [[ "${ST_LIVE:-0}" == 1 ]]; then
    printf '\e[?7h'
    tput cnorm 2>/dev/null || printf '\e[?25h'
    tput rmcup 2>/dev/null || printf '\e[?1049l'
    [[ -n "${ST_STTY:-}" ]] && stty "$ST_STTY" </dev/tty 2>/dev/null
    ST_LIVE=0
  fi
  [[ "$ST_TMP" == "${TMPDIR:-/tmp}"/marmot-status.* ]] && rm -rf -- "$ST_TMP" # SAFE: status's own mktemp -d dir
  ST_TMP=""
}

# _status_first — collect a first delta (and the first slow probe, waiting until DEADLINE_US).
_status_first() {
  local deadline=$1
  _status_slow_start
  _status_sample
  sleep 0.5
  _status_sample
  if ((deadline > 0)); then
    while kill -0 "$ST_SLOW_PID" 2>/dev/null && ((${EPOCHREALTIME/[.,]/} < deadline)); do sleep 0.1; done
  else
    wait "$ST_SLOW_PID" 2>/dev/null
  fi
  _status_slow_load
  _status_derive
}

_status_draw() {
  local rows cols size buf line i n
  size=$(stty size </dev/tty 2>/dev/null)
  read -r rows cols <<<"$size"
  [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows=${LINES:-50}
  [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols=${COLUMNS:-80}
  # Frame + blank + footer use at most rows-1 rows: every row, the footer included, ends with
  # erase-to-end-of-line and a newline, so a capture (script, tmux pipe-pane) never glues the
  # footer to the next frame, and the footer's newline never scrolls the screen.
  # Shrink until it fits: top lists, cores, panel gaps, then 1 each.
  ST_TOPN=5 ST_NCORE=4 ST_GAP=1
  while :; do
    _status_frame "$cols"
    ((${#ST_FRAME[@]} + ST_GAP + 2 <= rows)) && break
    if ((ST_TOPN > 2)); then ST_TOPN=$((ST_TOPN - 1))
    elif ((ST_NCORE > 2)); then ST_NCORE=$((ST_NCORE - 1))
    elif ((ST_GAP)); then ST_GAP=0
    elif ((ST_TOPN > 1)); then ST_TOPN=1 ST_NCORE=1
    else break; fi
  done
  ((ST_GAP)) && ST_FRAME+=("")
  n=${#ST_FRAME[@]}
  ((n > rows - 2)) && n=$((rows > 2 ? rows - 2 : 0))
  buf=$'\e[H'
  for ((i = 0; i < n; i++)); do buf+="${ST_FRAME[i]}"$'\e[K\n'; done
  buf+="$C_DIM  q quit · refresh ${ST_INTERVAL}s · slow probes every $((ST_SLOW_EVERY / 60))m$C_RESET"$'\e[K\n\e[J'
  printf '%s' "$buf"
}

_status_live() {
  local interval_us=$((ST_INTERVAL * 1000000)) next now rem t key
  ST_STTY=$(stty -g </dev/tty 2>/dev/null)
  ST_LIVE=1
  trap '_status_cleanup' EXIT
  trap '_status_cleanup; exit 130' INT TERM HUP
  trap 'ST_RESIZED=1' WINCH
  # Under `timeout mm status` we are in a background process group: ignore TTOU/TTIN so stty
  # works and tty reads fail fast (EIO) instead of stopping the process.
  trap '' TTOU TTIN
  tput smcup 2>/dev/null || printf '\e[?1049h'
  tput civis 2>/dev/null || printf '\e[?25l'
  printf '\e[?7l\e[H\e[2J'
  stty -echo </dev/tty 2>/dev/null
  _status_first $((${EPOCHREALTIME/[.,]/} + 1500000))
  _status_draw
  next=$((${EPOCHREALTIME/[.,]/} + interval_us))
  while :; do
    now=${EPOCHREALTIME/[.,]/}
    if ((now >= next)); then
      ((EPOCHSECONDS - ST_SLOW_AT >= ST_SLOW_EVERY)) && _status_slow_start
      _status_sample
      _status_slow_load
      _status_derive
      _status_draw
      next=$((next + interval_us))
      ((next <= now)) && next=$((now + interval_us))
      continue
    fi
    if [[ "${ST_RESIZED:-0}" == 1 ]]; then ST_RESIZED=0; _status_draw; continue; fi
    rem=$((next - now))
    printf -v t '%d.%06d' $((rem / 1000000)) $((rem % 1000000))
    key=""
    read -rsn1 -t "$t" key 2>/dev/null </dev/tty
    case $? in
      0) [[ "$key" == [qQ] ]] && break ;;
      1) sleep "$t" ;; # tty unreadable (background process group): just pace the refresh
    esac
  done
  _status_cleanup
  trap - EXIT INT TERM HUP WINCH TTOU TTIN
}

mm_cmd_main() {
  local mode=live
  ST_INTERVAL=2
  while (($#)); do
    case "$1" in
      --once) mode=once ;;
      --json) mode=json ;;
      --interval | --interval=*)
        local v
        if [[ "$1" == *=* ]]; then v=${1#*=}; else v=${2:-}; shift; fi
        v=${v%s}
        if [[ ! "$v" =~ ^[0-9]+$ ]] || ((v < 1)); then mm_die "--interval needs whole seconds >= 1 (got '$v')"; fi
        ST_INTERVAL=$v
        ;;
      -h | --help) _status_usage; return 0 ;;
      *) mm_die "unknown option: $1 (see mm status --help)" ;;
    esac
    shift
  done
  if [[ -n "${MM_STATUS_LINGER_AGE:-}" ]]; then
    [[ "$MM_STATUS_LINGER_AGE" =~ ^[0-9]+$ ]] || mm_die "MM_STATUS_LINGER_AGE must be whole seconds (got '$MM_STATUS_LINGER_AGE')"
    ST_LINGER_AGE=$((10#$MM_STATUS_LINGER_AGE))
  fi
  ST_VPN_GLOBS=${MM_STATUS_VPN_IFACES-$ST_VPN_GLOBS}
  export LC_ALL=C.UTF-8
  # Live mode needs a terminal on both ends (MM_TTY: stdin is a tty and /dev/tty opens).
  if [[ "$mode" == live ]] && { [[ "$MM_TTY" != 1 || ! -t 1 ]]; }; then mode=once; fi
  command -v jq >/dev/null || [[ "$mode" != json ]] || mm_die "jq is required for --json"

  _status_init
  case "$mode" in
    live) _status_live ;;
    once | json)
      trap '_status_cleanup' EXIT
      _status_first 0
      if [[ "$mode" == json ]]; then
        _status_json
      else
        _status_cols
        _status_frame "$REPLY"
        printf '\n'
        printf '%s\n' "${ST_FRAME[@]}"
        printf '\n'
      fi
      _status_cleanup
      trap - EXIT
      ;;
  esac
}
