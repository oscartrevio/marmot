# shellcheck shell=bash
# mm uninstall [NAME...] — remove apt/snap/npm/bun/pipx/uv packages or loose ~/.local/bin
# binaries, plus the cache tied to them by exact name (~/.cache/NAME). App data of the same name
# (~/.NAME, ~/.local/share/NAME) is kept unless --app-data is given, and then only after a
# separate confirmation per folder. Base-system packages are never offered. Caches, app data and
# ~/.local/bin items go to the Trash; package managers remove their own packages (apt without
# purge, snap after `snap save`).

# One entry per removable item (parallel arrays, index = item id).
_UN_SRC=() _UN_NAME=() _UN_BYTES=() _UN_TIME=() _UN_PATH=() _UN_NOTE=() _UN_HIDDEN=()
declare -A _UN_BASE=()   # manual apt packages refused as base system: name → reason
_UN_APP_DATA=0           # 1 with --app-data: offer ~/.NAME and ~/.local/share/NAME, one confirmation each

_uninstall_usage() {
  cat <<EOF
Usage: mm uninstall [options] [NAME...]

Remove packages installed via apt, snap, npm -g, bun -g, pipx, uv tool, or loose binaries in
~/.local/bin, together with the cache matched by exact name (~/.cache/NAME). The cache and
~/.local/bin binaries are moved to the Trash (restore with trash-restore). apt packages are
removed, not purged: config files and data (databases, container volumes) stay. A snap is saved
first, so its data comes back with sudo snap restore <id>. apt removals are simulated first; any
package apt would remove beyond your selection needs a separate confirmation, and one whose
removal has wide impact (docker.io, containerd, ...) its own.

App data named after the package (~/.NAME, ~/.local/share/NAME) is kept. With --app-data each
such folder is listed with its file count, size and newest change and moved to the Trash only
after you confirm that one folder. A folder changed in the last 30 days, holding anything that
looks like a key or token, holding a git repository, carrying a generic name, holding a coding
agent's state, or holding something that stays installed is kept either way, and ~/.config/NAME
always is.

Without NAMEs, pick from a list (fzf: TAB marks, ctrl-a selects all; without fzf it only
lists). NAMEs match exact package names across every source. Never offered: the base system
(kernel, boot, init, apt/dpkg, sudo, networking, storage) and cloud/hypervisor guest agents
(Google, AWS, Azure, Oracle, DigitalOcean, QEMU, VMware, Hyper-V, ...). Remote-access/VPN
software (openssh-server, tailscale, zerotier-one, wireguard, cloudflared, openvpn, ...) is
left off the list: name it explicitly, and confirm separately that losing the connection is OK.

Removing needs a terminal for the confirmations; without one, mm uninstall only lists or
previews.

Options:
  -l, --list      List removable packages (largest first) and exit
  -a, --all       Also list manually installed shared libraries (Section: libs)
      --app-data  Offer ~/.NAME and ~/.local/share/NAME too, one confirmation per folder
  -n, --dry-run   Show what would be removed (apt simulation + leftovers); change nothing
  -h, --help      This help
EOF
}

# ---------------------------------------------------------------- small helpers

_uninstall_add() { # SRC NAME BYTES EPOCH PATH NOTE HIDDEN (BYTES empty: size unknown)
  _UN_SRC+=("$1") _UN_NAME+=("$2") _UN_BYTES+=("$3") _UN_TIME+=("${4:-0}")
  _UN_PATH+=("$5") _UN_NOTE+=("$6") _UN_HIDDEN+=("${7:-0}")
}

# _uninstall_human BYTES — mm_human, or "size unknown" for an empty BYTES.
_uninstall_human() { if [[ -n "$1" ]]; then mm_human "$1"; else printf 'size unknown'; fi; }

# _uninstall_generic NAME — 0 for names too generic to tie a ~/.config/NAME-style folder to one
# package: parts of Debian package names (foo-common, foo-utils, foo-daemon), folders the
# freedesktop.org specs, the desktop and the home layout share (~/.config/autostart,
# ~/.local/share/fonts, ~/.config/systemd, ~/bin), credentials, marmot itself, and the words
# people name their own folders after (~/.notes, ~/.backup, ~/.sync): a package called notes does
# not own ~/.notes.
_uninstall_generic() {
  case "${1,,}" in
    common|core|base|data|doc|docs|dev|devel|utils|util|tools|tool|bin|lib|libs|runtime|extra|\
    extras|plugins|addons|modules|cli|client|server|daemon|app|apps|gui|desktop|\
    applications|autostart|fonts|fontconfig|icons|themes|mime|menus|sounds|keyrings|pki|systemd|\
    environment.d|dconf|pulse|pipewire|wireplumber|gtk-2.0|gtk-3.0|gtk-4.0|xdg-desktop-portal|\
    trash|flatpak|snap|cache|config|local|share|state|tmp|temp|etc|src|ssh|gnupg|mm|marmot|\
    agent|agents|backup|backups|cloud|files|music|notes|sync|store|helper|launcher|service|\
    update|updater|manager|monitor|worker|runner|driver|plugin|extension|widget|system) return 0 ;;
  esac
  return 1
}

# _uninstall_re TEXT — TEXT escaped for an extended regex (process-name patterns).
_uninstall_re() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

# _uninstall_ago EPOCH — "today", "3d ago", "2w ago", "4mo ago", "1y ago".
_uninstall_ago() {
  local days
  (( ${1:-0} > 0 )) || { printf -- '-'; return; }
  days=$(( ($(date +%s) - $1) / 86400 ))
  if (( days < 1 )); then printf 'today'
  elif (( days < 14 )); then printf '%dd ago' "$days"
  elif (( days < 60 )); then printf '%dw ago' $(( days / 7 ))
  elif (( days < 365 )); then printf '%dmo ago' $(( days / 30 ))
  else printf '%dy ago' $(( days / 365 )); fi
}

_uninstall_row() { # IDX — one list/picker row: NAME SOURCE SIZE INSTALLED/LAST-USED [warning]
  local i=$1 size='?'
  [[ -n "${_UN_BYTES[i]}" ]] && size=$(mm_human "${_UN_BYTES[i]}")
  printf '%-34s %-6s %9s  %-8s %s\n' "${_UN_NAME[i]}" "${_UN_SRC[i]}" "$size" \
    "$(_uninstall_ago "${_UN_TIME[i]}")" "${_UN_NOTE[i]:+! ${_UN_NOTE[i]}}"
}

# ---------------------------------------------------------------- sources

# _uninstall_base NAME — 0 if NAME (apt package or snap) is part of the base system marmot never
# removes: kernel/boot/init, package managers, core networking and storage, and the guest/cloud
# agents every major provider and hypervisor installs (removing one can lock you out of the VM).
# Agents only, by exact name: vendor CLIs and apps (google-cloud-cli, awscli, azure-cli,
# google-chrome-*) stay removable.
_uninstall_base() {
  case "${1,,}" in
    linux-*|ubuntu-*|debian-*|base-*|grub*|shim*|efibootmgr|mokutil|initramfs-tools*|dracut*|init|\
    init-system-helpers|systemd*|udev|dbus|dbus-*|kmod|sudo|snapd|apt|apt-*|dpkg|dpkg-*|libc6*|libc-*|\
    netplan*|ifupdown*|network-manager|networkd-dispatcher|isc-dhcp-*|resolvconf|\
    openssh-client|openssh-sftp-server|lvm2|cryptsetup*|mdadm|zfsutils-linux|btrfs-progs|xfsprogs|\
    cloud-init|cloud-guest-utils|cloud-initramfs-*|cloud-utils|\
    google-guest-agent|google-osconfig-agent|google-compute-engine|google-compute-engine-oslogin|\
    google-guest-oslogin|google-cloud-ops-agent|stackdriver-agent|google-fluentd|gce-*|\
    amazon-ssm-agent|amazon-ec2-*|amazon-cloudwatch-agent|ec2-instance-connect|ec2-hibinit-agent|\
    aws-cfn-bootstrap|walinuxagent|waagent|azure-vm-utils|azuremonitoragent|omsagent|\
    oracle-cloud-agent|oci-utils|droplet-agent|do-agent|aliyun-assist|\
    qemu-guest-agent|open-vm-tools*|hyperv-daemons|hv-kvp-daemon*|xe-guest-utilities|\
    virtualbox-guest-*|spice-vdagent) return 0 ;;
  esac
  return 1
}

# _uninstall_remote NAME — 0 for remote-access / VPN software: removing it can cut the connection
# you are using right now. Hidden from the list (name it explicitly) and needs its own confirmation.
_uninstall_remote() {
  case "${1,,}" in
    openssh-server|tailscale|tailscale-*|zerotier-one|wireguard|wireguard-*|netbird*|cloudflared|\
    openvpn|openvpn-*|network-manager-openvpn*|xrdp|x2goserver*|teamviewer*|anydesk|rustdesk|\
    ngrok|nebula|twingate*|headscale) return 0 ;;
  esac
  return 1
}

_uninstall_note() { # NAME — warning shown next to items whose removal has wide impact
  if _uninstall_remote "$1"; then printf 'remote access/VPN: removing it may cut your connection'; return; fi
  case "$1" in
    docker-ce|docker.io|containerd.io|containerd|podman) printf 'stops every container on this machine' ;;
  esac
}

_uninstall_collect_apt() {
  command -v dpkg-query >/dev/null && command -v apt-mark >/dev/null || return 0
  local -a manual=() lists=()
  local name bin prio ess isize section status note hidden t f
  declare -A mtime=()
  mapfile -t manual < <(apt-mark showmanual 2>/dev/null)
  (( ${#manual[@]} )) || return 0
  # \x1f separator: tab is IFS whitespace, so empty fields (e.g. no Section) would collapse.
  local rows us=$'\x1f'
  rows=$(dpkg-query -W -f="\${Package}$us\${binary:Package}$us\${Priority}$us\${Essential}$us\${Installed-Size}$us\${Section}$us\${db:Status-Abbrev}\n" \
    "${manual[@]}" 2>/dev/null)
  while IFS=$us read -r name bin _ _ _ _ status; do
    [[ "$status" == ii* ]] || continue
    if [[ -e "/var/lib/dpkg/info/$bin.list" ]]; then lists+=("/var/lib/dpkg/info/$bin.list")
    else lists+=("/var/lib/dpkg/info/$name.list"); fi
  done <<<"$rows"
  while read -r t f; do f=${f##*/}; f=${f%.list}; mtime[${f%%:*}]=$t; done < <(stat -c '%Y %n' -- "${lists[@]}" 2>/dev/null)

  while IFS=$us read -r name bin prio ess isize section status; do
    [[ "$status" == ii* ]] || continue
    if [[ "$prio" == required || "$prio" == important || "$prio" == standard ]]; then
      _UN_BASE[$name]="priority $prio"; continue
    fi
    [[ "$ess" == yes ]] && { _UN_BASE[$name]="essential"; continue; }
    _uninstall_base "$name" && { _UN_BASE[$name]="base system"; continue; }
    note=$(_uninstall_note "$name")
    hidden=0
    [[ "$section" == libs || "$section" == oldlibs || "$section" == */libs || "$section" == */oldlibs ]] && hidden=1
    _uninstall_remote "$name" && hidden=2   # offered only when named explicitly
    _uninstall_add apt "$name" $(( ${isize:-0} * 1024 )) "${mtime[$name]:-0}" "" "$note" "$hidden"
  done <<<"$rows"
}

_uninstall_collect_snap() {
  command -v snap >/dev/null || return 0
  local name rev notes bytes t f hidden
  local -a files
  while read -r name rev notes; do
    case "$name" in core|core[0-9]*|snapd|bare|gnome-*|gtk-*|kde-frameworks-*|mesa-*) continue ;; esac
    [[ "$notes" == *base* || "$notes" == *snapd* ]] && continue
    _uninstall_base "$name" && { _UN_BASE[$name]="base system"; continue; }
    files=(/var/lib/snapd/snaps/"${name}"_*.snap)
    if [[ -e "${files[0]}" ]]; then
      bytes=$(stat -c %s -- "${files[@]}" | awk '{ s += $1 } END { printf "%.0f\n", s }')
    else
      bytes=$(timeout 20 du -sLB1 "/snap/$name/current/" 2>/dev/null | awk '{ printf "%.0f\n", $1 }')
    fi
    f="/var/lib/snapd/snaps/${name}_${rev}.snap"
    t=$(stat -c %Y -- "$f" 2>/dev/null || stat -c %Y -- "/snap/$name/current" 2>/dev/null || echo 0)
    hidden=0; _uninstall_remote "$name" && hidden=2
    _uninstall_add snap "$name" "${bytes:-0}" "$t" "/snap/$name" "$(_uninstall_note "$name")" "$hidden"
  done < <(timeout 15 snap list 2>/dev/null | awk 'NR > 1 { print $1, $3, $NF }')
}

# _uninstall_json_keys FILE FIELD — keys of the top-level object FIELD in a JSON file (jq, else
# python3; nothing if neither is installed).
_uninstall_json_keys() {
  if command -v jq >/dev/null; then
    jq -r --arg f "$2" '.[$f] // {} | keys[]' "$1" 2>/dev/null
  elif command -v python3 >/dev/null; then
    python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get(sys.argv[2]) or {}))' "$1" "$2" 2>/dev/null
  fi
}

_uninstall_collect_npm() {
  command -v npm >/dev/null || return 0
  local root name dir
  root=$(timeout 15 npm root -g 2>/dev/null) || return 0
  [[ -d "$root" ]] || return 0
  while IFS= read -r dir; do
    [[ "$dir" == "$root"/* ]] || continue
    name=${dir#"$root"/}
    [[ "$name" == npm || "$name" == corepack ]] && continue
    _uninstall_add npm "$name" "$(mm_size "$dir")" "$(stat -c %Y -- "$dir" 2>/dev/null || echo 0)" "$dir" \
      "$(_uninstall_note "$name")" "$(_uninstall_remote "$name" && echo 2 || echo 0)"
  done < <(timeout 30 npm ls -g --depth=0 --parseable 2>/dev/null)
}

_uninstall_collect_bun() {
  command -v bun >/dev/null || return 0
  local global="${BUN_INSTALL:-$HOME/.bun}/install/global" name dir
  [[ -f "$global/package.json" ]] || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    dir="$global/node_modules/$name"
    _uninstall_add bun "$name" "$(mm_size "$dir")" "$(stat -c %Y -- "$dir" 2>/dev/null || echo 0)" "$dir" "" 0
  done < <(_uninstall_json_keys "$global/package.json" dependencies)
}

_uninstall_collect_pipx() {
  command -v pipx >/dev/null || return 0
  local venvs name dir
  venvs=$(timeout 15 pipx environment --value PIPX_LOCAL_VENVS 2>/dev/null) || venvs="$HOME/.local/share/pipx/venvs"
  while read -r name _; do
    [[ -n "$name" ]] || continue
    dir="$venvs/$name"
    _uninstall_add pipx "$name" "$(mm_size "$dir")" "$(stat -c %Y -- "$dir" 2>/dev/null || echo 0)" "$dir" "" 0
  done < <(timeout 30 pipx list --short 2>/dev/null)
}

# _uninstall_uv_dir — where uv keeps its tools (`uv tool dir`): UV_TOOL_DIR, else
# $XDG_DATA_HOME/uv/tools.
_uninstall_uv_dir() { printf '%s' "${UV_TOOL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"; }

# Tools installed with `uv tool install` live in their own environment under the uv tool dir,
# marked by uv-receipt.toml, with a symlink in ~/.local/bin. They are uv's to remove (uv tool
# uninstall); the symlink alone is never a loose binary.
_uninstall_collect_uv() {
  command -v uv >/dev/null || return 0
  local root dir name
  root=$(_uninstall_uv_dir)
  for dir in "$root"/*/; do
    dir=${dir%/}
    [[ -f "$dir/uv-receipt.toml" && ! -L "$dir" ]] || continue
    name=${dir##*/}
    _uninstall_add uv "$name" "$(mm_size "$dir")" "$(stat -c %Y -- "$dir" 2>/dev/null || echo 0)" "$dir" \
      "$(_uninstall_note "$name")" "$(_uninstall_remote "$name" && echo 2 || echo 0)"
  done
}

# _uninstall_managed_target PATH — 0 if a ~/.local/bin symlink target belongs to a package
# manager (apt/snap/nix/pipx/uv/node managers) or to marmot itself; those are never offered.
_uninstall_managed_target() {
  case "$1" in
    /usr/*|/bin/*|/sbin/*|/lib/*|/snap/*|/var/lib/snapd/*|/nix/*|/opt/homebrew/*|/home/linuxbrew/*) return 0 ;;
    "$MM_HOME"|"$MM_HOME"/*|"$HOME/.local/share/marmot"|"$HOME/.local/share/marmot"/*) return 0 ;;
    "$HOME"/.local/share/pipx/*|"$HOME"/.local/pipx/*|"$HOME"/.local/share/fnm/*|"$HOME"/.fnm/*) return 0 ;;
    "$HOME"/.nvm/*|"$HOME"/.volta/*|"${BUN_INSTALL:-$HOME/.bun}"/*|"$HOME"/.npm-global/*|"$HOME"/.cargo/*) return 0 ;;
    "$HOME"/.local/share/uv/*|"$(_uninstall_uv_dir)"/*) return 0 ;;
  esac
  return 1
}

_uninstall_collect_localbin() {
  local dir="$HOME/.local/bin" f name target note t
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ -d "$f" && ! -L "$f" ]] && continue
    name=${f##*/}
    [[ "$name" == mm || "$name" == marmot ]] && continue
    note=$(_uninstall_note "$name")
    if [[ -L "$f" ]]; then
      target=$(readlink -f -- "$f" 2>/dev/null) || target=$(readlink -- "$f")
      _uninstall_managed_target "$target" && continue
      [[ -e "$f" ]] || note="broken symlink"
    fi
    t=$(stat -c '%X %Y' -- "$f" 2>/dev/null | awk '{ print ($1 > $2 ? $1 : $2) }')
    _uninstall_add bin "$name" "$(mm_size "$f")" "${t:-0}" "$f" "$note" "$(_uninstall_remote "$name" && echo 2 || echo 0)"
  done
}

_uninstall_collect() {
  _uninstall_collect_apt
  _uninstall_collect_snap
  _uninstall_collect_npm
  _uninstall_collect_bun
  _uninstall_collect_pipx
  _uninstall_collect_uv
  _uninstall_collect_localbin
}

# ---------------------------------------------------------------- leftovers
#
# A leftover is a folder named exactly after the package. Only ~/.cache/NAME is regenerable, so
# only it is preselected; ~/.NAME and ~/.local/share/NAME are the app's own data (mail stores,
# wallets, vaults, shell history) and need --app-data plus their own confirmation. ~/.config/NAME
# is listed so the plan shows it, and always kept (the built-in whitelist). ~/snap/NAME is not a
# leftover at all: snapd owns it and `snap save` copies it before the snap goes.

# _uninstall_leftovers NAME — existing leftover paths tied to NAME by exact name only.
_uninstall_leftovers() {
  local name="$1" p
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 0
  # Name-only matches for generic names are listed (and reported kept), never removed.
  local -a cand=("$HOME/.config/$name" "$HOME/.cache/$name" "$HOME/.local/share/$name")
  [[ -d "$HOME/.$name" && ! -L "$HOME/.$name" ]] && cand+=("$HOME/.$name")
  for p in "${cand[@]}"; do [[ -e "$p" || -L "$p" ]] && printf '%s\n' "$p"; done
  return 0
}

# _uninstall_app_data PATH — 0 if PATH is app data rather than a cache or config: ~/.NAME or
# ~/.local/share/NAME (~/.config/NAME is config, kept by the whitelist; ~/.cache/NAME is a cache).
_uninstall_app_data() { [[ "${1%/}" != "$HOME/.cache/"* && "${1%/}" != "$HOME/.config/"* ]]; }

# _uninstall_describe PATH — "N files, 24KB, newest 3d ago" for a prompt: what the user loses.
# An unreadable count or size says so rather than claiming zero.
_uninstall_describe() {
  local files size newest
  files=$(find "$1" -xdev -type f -printf . 2>/dev/null | wc -c)
  if [[ "$files" =~ ^[0-9]+$ ]]; then files="$files file$( (( files == 1 )) || printf s)"; else files="file count unknown"; fi
  size=$(mm_size "$1") || size=""
  newest=$(find "$1" -xdev -printf '%T@\n' 2>/dev/null | awk 'BEGIN { m = 0 } $1 > m { m = $1 } END { printf "%.0f\n", m }')
  printf '%s, %s, newest %s' "$files" "$(_uninstall_human "$size")" "$(_uninstall_ago "${newest:-0}")"
}

declare -A _UN_GOING=()   # item index → 1 for every item this run removes (set by _uninstall_apply)

# _uninstall_used_by PATH — prints the first item NOT being removed that lives under PATH:
# another collected item's install path, or any ~/.local/bin entry resolved with readlink -f.
_uninstall_used_by() {
  local p="${1%/}" j f target
  for ((j = 0; j < ${#_UN_NAME[@]}; j++)); do
    [[ -n "${_UN_GOING[$j]:-}" || -z "${_UN_PATH[j]}" ]] && continue
    target=${_UN_PATH[j]}
    [[ -L "$target" ]] && { target=$(readlink -f -- "$target" 2>/dev/null) || target=${_UN_PATH[j]}; }
    if [[ "${_UN_PATH[j]}" == "$p" || "${_UN_PATH[j]}" == "$p"/* || "$target" == "$p" || "$target" == "$p"/* ]]; then
      printf '%s' "${_UN_NAME[j]}"; return 0
    fi
  done
  for f in "$HOME"/.local/bin/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    for ((j = 0; j < ${#_UN_NAME[@]}; j++)); do
      [[ -n "${_UN_GOING[$j]:-}" && "${_UN_PATH[j]}" == "$f" ]] && continue 2
    done
    target=$f
    [[ -L "$f" ]] && { target=$(readlink -f -- "$f" 2>/dev/null) || continue; }
    [[ "$target" == "$p" || "$target" == "$p"/* ]] && { mm_tilde "$f"; printf '%s' "$REPLY"; return 0; }
  done
  return 1
}

# _uninstall_keep_reason PATH — why a leftover must stay even though its name matches: a generic
# name, a git repository/worktrees, anything changed in the last 30 days, a key or token inside,
# app data without --app-data, or something still installed inside it. Empty = removable, which
# for app data still means "ask first" (_uninstall_remove_leftovers).
_uninstall_keep_reason() {
  local p="$1" user base=${1##*/}
  _uninstall_generic "${base#.}" && { printf 'generic name'; return; }
  _uninstall_agent_state "$p" && { printf '%s' "$MM_UN_AGENT_KEPT"; return; }
  [[ "$p" == "$MM_TRASH_DIR" || "$MM_TRASH_DIR" == "$p"/* ]] && { printf 'holds the Trash'; return; }
  mm_credential_like "$p" && { printf 'holds a key or token'; return; }
  if [[ -d "$p" && ! -L "$p" ]]; then
    if [[ -n "$(find "$p" -xdev \( -name .git -o -name worktrees \) -print -quit 2>/dev/null)" ]]; then
      printf 'contains a git repository'; return
    fi
    # A folder in use in the last month is nobody's leftover, whatever its name says. An
    # unreadable folder prints nothing and counts as recent: never "nothing there".
    if [[ -z "$(find "$p" -xdev -mtime +30 -print -quit 2>/dev/null)" ||
          -n "$(find "$p" -xdev -mtime -30 -print -quit 2>/dev/null)" ]]; then
      printf 'changed in the last 30 days'; return
    fi
  fi
  if _uninstall_app_data "$p" && (( ! _UN_APP_DATA )); then
    printf 'app data (%s) — mm uninstall --app-data offers it' "$(_uninstall_describe "$p")"; return
  fi
  user=$(_uninstall_used_by "$p") && printf 'used by %s' "$user"
}

# _uninstall_rm_reason PATH [ROOT] — why mm_rm --trash would refuse PATH under ROOT (default
# $HOME); empty if it would trash it.
_uninstall_rm_reason() { ( MM_DRY_RUN=1 MM_DEBUG=0 mm_rm --trash "$1" "${2:-$HOME}" >/dev/null 2>&1; printf '%s' "$MM_SKIP_REASON" ); }

# _uninstall_leftover_reason PATH — every reason a leftover stays (keep rules, then mm_rm rules).
_uninstall_leftover_reason() {
  local r
  r=$(_uninstall_keep_reason "$1")
  [[ -n "$r" ]] || r=$(_uninstall_rm_reason "$1")
  printf '%s' "$r"
}

_uninstall_kept() { mm_tilde "$1"; printf '    %s◎%s %s %s· kept (%s)%s\n' "$C_DIM" "$C_RESET" "$REPLY" "$C_DIM" "$2" "$C_RESET"; }

# _uninstall_remove_leftovers NAME — move every leftover no keep rule protects to the Trash
# (mm_rm --trash, ALLOWED_ROOT=$HOME), printing one ✓/◎ line each. App data (~/.NAME,
# ~/.local/share/NAME) is asked for one folder at a time, naming what it holds; the keep rules run
# again here, right before the move. Whitelist, in-use and mount rules apply via mm_rm.
_uninstall_remove_leftovers() {
  local p rc reason
  while IFS= read -r p; do
    reason=$(_uninstall_keep_reason "$p")
    [[ -n "$reason" ]] && { _uninstall_kept "$p" "$reason"; continue; }
    if _uninstall_app_data "$p"; then
      mm_tilde "$p"
      mm_confirm "Move $REPLY to the Trash? ($(_uninstall_describe "$p"); app data, not a cache)" ||
        { _uninstall_kept "$p" "app data, not confirmed"; continue; }
    fi
    mm_rm --trash "$p" "$HOME"; rc=$?
    case $rc in
      0) mm_tilde "$p"; printf '  '; mm_ok "$REPLY" "$(mm_human "$MM_LAST_BYTES") to Trash" ;;
      1) _uninstall_kept "$p" "$MM_SKIP_REASON" ;;
      *) mm_tilde "$p"; mm_err "$REPLY: ${MM_SKIP_REASON:-move to Trash failed}" ;;
    esac
  done < <(_uninstall_leftovers "$1")
}

# _uninstall_shared IDX SELECTED_IDX... — prints the source of another installed copy of the
# same name that is NOT being removed (its leftovers must then be kept).
_uninstall_shared() {
  local i=$1 j s; shift
  for ((j = 0; j < ${#_UN_NAME[@]}; j++)); do
    (( j == i )) && continue
    [[ "${_UN_NAME[j]}" == "${_UN_NAME[i]}" ]] || continue
    for s in "$@"; do (( s == j )) && continue 2; done
    printf '%s' "${_UN_SRC[j]}"; return 0
  done
  return 1
}

# ---------------------------------------------------------------- what an item provides

# _uninstall_pkg_bins PACKAGE_JSON — command names a node package installs (its "bin" field).
_uninstall_pkg_bins() {
  if command -v jq >/dev/null; then
    jq -r 'if (.bin | type) == "string" then (.name | split("/") | last)
      elif (.bin | type) == "object" then (.bin | keys[]) else empty end' "$1" 2>/dev/null
  elif command -v python3 >/dev/null; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); b=d.get("bin")
print(d.get("name","").split("/")[-1] if isinstance(b,str) else "\n".join(b or {}))' "$1" 2>/dev/null
  fi
}

# _uninstall_commands IDX — command names the item provides, one per line: its own name, the
# binaries an apt package ships, a node package's bin names, and a pipx venv's bin entries.
_uninstall_commands() {
  local i=$1 name=${_UN_NAME[$1]} path=${_UN_PATH[$1]}
  { printf '%s\n' "$name"
    case "${_UN_SRC[i]}" in
      apt) dpkg -L "$name" 2>/dev/null | awk -F/ '/\/s?bin\/[^\/]+$/ { print $NF }' ;;
      npm|bun) [[ -f "$path/package.json" ]] && _uninstall_pkg_bins "$path/package.json" ;;
      pipx|uv) [[ -d "$path/bin" ]] && find "$path/bin" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null |
              grep -vE '^(python|pip|activate|deactivate|wheel|easy_install|Activate)' ;;
    esac
  } | awk 'NF && !seen[$0]++'
}

# _uninstall_agent IDX — index into lib/agents.sh of the coding agent this item installs (one of
# its commands is a known agent process name); fails if it is not an agent.
_uninstall_agent() {
  local c a p
  while IFS= read -r c; do
    for ((a = 0; a < ${#MM_AGENT_NAME[@]}; a++)); do
      for p in ${MM_AGENT_PROCS[a]}; do [[ "$c" == "$p" ]] && { printf '%s' "$a"; return 0; }; done
    done
  done < <(_uninstall_commands "$1")
  return 1
}

MM_UN_AGENT_KEPT='agent state — sessions/credentials; remove manually if you want'

# _uninstall_agent_state PATH — 0 if PATH is, contains, or lies inside any known agent's state.
_uninstall_agent_state() {
  local p="${1%/}" s w
  for s in "${MM_AGENT_STATE[@]}"; do
    for w in $s; do
      [[ "$p" == "$w" || "$p" == "$w"/* || "$w" == "$p"/* ]] && return 0
    done
  done
  return 1
}

# _uninstall_agent_extra IDX — existing state paths of the item's agent that are not already
# among its name-matched leftovers (those report the same reason themselves).
_uninstall_agent_extra() {
  local a w lo
  a=$(_uninstall_agent "$1") || return 0
  lo=$(_uninstall_leftovers "${_UN_NAME[$1]}")
  for w in ${MM_AGENT_STATE[a]}; do
    [[ -e "$w" || -L "$w" ]] || continue
    grep -qxF -- "$w" <<<"$lo" || printf '%s\n' "$w"
  done
}

# ---------------------------------------------------------------- running-process check

# _uninstall_running IDX — prints what is running and returns 0 if the item is in use.
_uninstall_running() {
  local i=$1 c
  local name=${_UN_NAME[i]} src=${_UN_SRC[i]} path=${_UN_PATH[i]}
  local -a comms=()
  mapfile -t comms < <(_uninstall_commands "$i")
  for c in "${comms[@]}"; do
    [[ -n "$c" && "$c" != */* ]] || continue
    mm_proc_match "$(_uninstall_re "${c:0:15}")" && { printf '%s' "$c"; return 0; }
    # Node CLIs run as `node <bin>`: match the package's bin names as an argv path component.
    if [[ ("$src" == npm || "$src" == bun) && "$c" != "$name" ]]; then
      mm_proc_match "" "(^|/)$(_uninstall_re "$c")( |$)" && { printf '%s' "$c"; return 0; }
    fi
  done
  if [[ -n "$path" && "$src" != apt ]]; then
    mm_proc_match "" "$(_uninstall_re "$path")(/| |$)" && { printf '%s' "${path##*/}"; return 0; }
  fi
  return 1
}

# ---------------------------------------------------------------- apt simulation

# _uninstall_apt_sim [--autoremove] PKG... — package names apt-get would remove (simulated).
# `remove`, never `purge`: a purge runs the package's postrm, which drops PostgreSQL clusters and
# wipes /var/lib/docker. Config files and data stay behind, as the plan says.
_uninstall_apt_sim() {
  local out rc
  out=$(LC_ALL=C timeout 120 apt-get -s remove "$@" 2>&1); rc=$?
  if (( rc != 0 )); then
    mm_err "apt-get -s remove $* failed (exit $rc)"
    printf '%s\n' "$out" | grep -E '^(E|W):' | tail -5 | sed 's/^/    /' >&2
    return 1
  fi
  printf '%s\n' "$out" | awk '/^(Purg|Remv) / { sub(/:.*/, "", $2); print $2 }'
}

_uninstall_apt_bytes() { # PKG... — summed Installed-Size in bytes
  (( $# )) || { echo 0; return; }
  dpkg-query -W -f='${Installed-Size}\n' "$@" 2>/dev/null | awk '{ s += $1 } END { printf "%.0f\n", s * 1024 }'
}

# ---------------------------------------------------------------- selection

_uninstall_sorted() { # IDX... → indices sorted by size desc
  local i; for i in "$@"; do printf '%s\t%s\n' "${_UN_BYTES[i]}" "$i"; done | sort -t$'\t' -k1,1nr | cut -f2
}

_uninstall_table() { # IDX...
  printf '\n%s%-34s %-6s %9s  %-8s%s\n' "$C_DIM" "NAME" "SOURCE" "SIZE" "INSTALLED/LAST-USED" "$C_RESET"
  local i row
  for i in "$@"; do
    row=$(_uninstall_row "$i")
    [[ -n "${_UN_NOTE[i]}" ]] && row="${row%%!*}$C_YELLOW!${row#*!}$C_RESET"
    printf '%s\n' "$row"
  done
}

# _uninstall_by_name NAME... — sets _UN_SEL to every item whose name matches exactly.
_uninstall_by_name() {
  local n i found status
  _UN_SEL=()
  for n in "$@"; do
    found=0
    for ((i = 0; i < ${#_UN_NAME[@]}; i++)); do
      [[ "${_UN_NAME[i]}" == "$n" ]] || continue
      [[ " ${_UN_SEL[*]} " == *" $i "* ]] || _UN_SEL+=("$i")
      found=1
    done
    (( found )) && continue
    if [[ -n "${_UN_BASE[$n]:-}" ]]; then
      mm_skip "$n" "${_UN_BASE[$n]} package; marmot never removes it"; continue
    fi
    status=$(dpkg-query -W -f='${db:Status-Abbrev}|${Priority}|${Essential}' "$n" 2>/dev/null)
    if [[ "$status" == ii* ]]; then
      if [[ "$status" == *"|yes" || "$status" == *"|required|"* || "$status" == *"|important|"* ]] || _uninstall_base "$n"; then
        mm_skip "$n" "base system package; marmot never removes it"
      else
        mm_skip "$n" "installed as a dependency, not manually; apt autoremove handles it"
      fi
    elif [[ "$n" == mm || "$n" == marmot ]]; then
      mm_skip "$n" "that's me"
    else
      mm_warn "$n: not installed (looked in apt, snap, npm -g, bun -g, pipx, uv tool, ~/.local/bin)"
    fi
  done
}

# ---------------------------------------------------------------- main

mm_cmd_main() {
  local list=0 all=0 i
  local -a names=() visible=()
  while (( $# )); do
    case "$1" in
      -h|--help) _uninstall_usage; return 0 ;;
      -l|--list) list=1 ;;
      -a|--all) all=1 ;;
      --app-data) _UN_APP_DATA=1 ;;
      --) shift; names+=("$@"); break ;;
      -*) mm_die "unknown option: $1 (see mm uninstall --help)" ;;
      *) names+=("$1") ;;
    esac
    shift
  done

  mm_header "Uninstall"
  _uninstall_collect
  for ((i = 0; i < ${#_UN_NAME[@]}; i++)); do
    (( _UN_HIDDEN[i] == 0 || (all && _UN_HIDDEN[i] == 1) )) && visible+=("$i")
  done
  mapfile -t visible < <(_uninstall_sorted "${visible[@]}")

  if (( list )) || { (( ${#names[@]} == 0 )) && { [[ "$MM_DRY_RUN" == 1 || "$MM_TTY" != 1 ]] || ! command -v fzf >/dev/null; }; }; then
    local hidden=$(( ${#_UN_NAME[@]} - ${#visible[@]} )) total=0 unknown=0 sz
    for i in "${visible[@]}"; do
      if [[ -n "${_UN_BYTES[i]}" ]]; then total=$(( total + _UN_BYTES[i] )); else unknown=$((unknown + 1)); fi
    done
    sz=$(mm_human "$total"); (( unknown )) && sz+=" + $unknown of unknown size"
    mm_section "Removable packages (${#visible[@]}, $sz)"
    _uninstall_table "${visible[@]}"
    printf '\n'
    (( hidden )) && mm_info "${C_DIM}$hidden more hidden (shared libraries: --all; remote access/VPN: name them); NAMEs always match${C_RESET}"
    mm_info "${C_DIM}Preview a removal: mm uninstall --dry-run NAME...   Remove: mm uninstall [NAME...]${C_RESET}"
    return 0
  fi

  _UN_SEL=()
  if (( ${#names[@]} )); then
    mm_section "Selected"
    _uninstall_by_name "${names[@]}"
  else
    local picked line key
    picked=$(for i in "${visible[@]}"; do _uninstall_row "$i"; done |
      mm_pick "Select packages to remove  (TAB mark · ctrl-a all · Enter confirm)")
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key=$(awk '{ print $1 "\t" $2 }' <<<"$line")
      for i in "${visible[@]}"; do
        [[ "${_UN_NAME[i]}"$'\t'"${_UN_SRC[i]}" == "$key" ]] && _UN_SEL+=("$i")
      done
    done <<<"$picked"
    (( ${#_UN_SEL[@]} )) || { mm_info "Nothing selected."; return 0; }
    mm_section "Selected"
  fi
  (( ${#_UN_SEL[@]} )) || { mm_info "Nothing to uninstall."; return 0; }
  _uninstall_apply "${_UN_SEL[@]}"
}

# _uninstall_apply IDX... — checks, plan ("Files to be removed"), confirmations, removal, banner.
_uninstall_apply() {
  # Removing needs a terminal for its confirmations; without one this is a preview.
  local dry=0 i what
  [[ "$MM_DRY_RUN" == 1 || "$MM_TTY" != 1 ]] && dry=1
  local -a keep=()
  [[ "$MM_DRY_RUN" != 1 && "$MM_TTY" != 1 ]] && mm_warn "No terminal: preview only, nothing will be removed"
  mm_inuse_refresh

  # 1. running processes and high-impact packages
  for i in "$@"; do
    mm_ok "${_UN_NAME[i]}" "${_UN_SRC[i]}, $(_uninstall_human "${_UN_BYTES[i]}")"
    if what=$(_uninstall_running "$i"); then
      if [[ "$dry" == 1 ]]; then
        mm_warn "${_UN_NAME[i]} is running ($what); a real run asks before removing it"
      elif ! mm_confirm "${_UN_NAME[i]} is running ($what). Remove it anyway?"; then
        mm_skip "${_UN_NAME[i]}" "running"; continue
      fi
    fi
    if [[ -n "${_UN_NOTE[i]}" && "${_UN_NOTE[i]}" != "broken symlink" ]]; then
      printf '  %s! %s: %s%s\n' "$C_RED$C_BOLD" "${_UN_NAME[i]}" "${_UN_NOTE[i]}" "$C_RESET"
      if [[ "$dry" == 1 ]]; then
        mm_warn "a real run asks for a separate confirmation for ${_UN_NAME[i]}"
      elif ! mm_confirm "Really remove ${_UN_NAME[i]}? (${_UN_NOTE[i]})"; then
        mm_skip "${_UN_NAME[i]}" "declined"; continue
      fi
    fi
    keep+=("$i")
  done
  (( ${#keep[@]} )) || { mm_info "Nothing left to uninstall."; return 0; }

  # 2. apt simulation (remove + autoremove) — every extra package is shown and confirmed
  # separately below, and every package apt would remove, selected or not, carries its own note.
  local -a apt_sel=() apt_all=() apt_extra=() apt_mode=() apt_block=()
  local apt_extra_bytes=0 apt_plan="" p prio
  for i in "${keep[@]}"; do [[ "${_UN_SRC[i]}" == apt ]] && apt_sel+=("${_UN_NAME[i]}"); done
  if (( ${#apt_sel[@]} )); then
    apt_mode=(remove autoremove)
    if apt_plan=$(_uninstall_apt_sim --autoremove "${apt_sel[@]}") && [[ -n "$apt_plan" ]]; then
      mapfile -t apt_all <<<"$apt_plan"
      for p in "${apt_all[@]}"; do [[ " ${apt_sel[*]} " == *" $p "* ]] || apt_extra+=("$p"); done
      # A removal that drags in a base-system or remote-access package is never run, confirmed or not.
      for p in "${apt_extra[@]}"; do
        prio=$(dpkg-query -W -f='${Priority}|${Essential}' "$p" 2>/dev/null)
        if _uninstall_base "$p" || _uninstall_remote "$p" || [[ "$prio" == required\|* || "$prio" == important\|* || "$prio" == *\|yes ]]; then
          apt_block+=("$p")
        fi
      done
      (( ${#apt_block[@]} )) && apt_mode=()
    else
      apt_mode=()
    fi
  fi

  # 3. plan: what goes, with sizes and leftovers, and what is kept and why
  printf '\n%sFiles to be removed:%s\n' "$C_BOLD" "$C_RESET"
  local -a lo=()
  local shared reason lbytes item_bytes item_unknown free_bytes=0 trash_bytes=0 unknown=0
  local -A drop=()
  _UN_GOING=()
  for i in "${keep[@]}"; do
    [[ "${_UN_SRC[i]}" == apt && ${#apt_mode[@]} -eq 0 ]] && continue
    if [[ "${_UN_SRC[i]}" == bin ]]; then
      reason=$(_uninstall_rm_reason "${_UN_PATH[i]}" "$HOME/.local/bin")
      [[ -n "$reason" ]] && { drop[$i]=$reason; continue; }
    fi
    _UN_GOING[$i]=1
  done
  for i in "${keep[@]}"; do
    if [[ "${_UN_SRC[i]}" == apt && ${#apt_mode[@]} -eq 0 ]]; then continue; fi
    if [[ -n "${drop[$i]:-}" ]]; then printf '\n'; mm_skip "${_UN_NAME[i]}" "${drop[$i]}"; continue; fi
    mapfile -t lo < <(_uninstall_leftovers "${_UN_NAME[i]}")
    shared=$(_uninstall_shared "$i" "${keep[@]}") || shared=""
    item_bytes=${_UN_BYTES[i]:-0} item_unknown=0
    if [[ -z "${_UN_BYTES[i]}" ]]; then item_unknown=1
    elif [[ "${_UN_SRC[i]}" == bin ]]; then trash_bytes=$(( trash_bytes + item_bytes )); else free_bytes=$(( free_bytes + item_bytes )); fi
    local -a lines=()
    case "${_UN_SRC[i]}" in
      apt)  lines+=("$C_GREEN✓$C_RESET apt package ${_UN_NAME[i]} (removed; config files and data stay)") ;;
      snap) lines+=("$C_GREEN✓$C_RESET snap ${_UN_NAME[i]} (all revisions; data saved first: snap restore)") ;;
      npm|bun|pipx) mm_tilde "${_UN_PATH[i]}"; lines+=("$C_GREEN✓$C_RESET $REPLY (${_UN_SRC[i]} global)") ;;
      uv)   mm_tilde "${_UN_PATH[i]}"; lines+=("$C_GREEN✓$C_RESET $REPLY (uv tool)") ;;
      bin)  mm_tilde "${_UN_PATH[i]}"; lines+=("$C_GREEN✓$C_RESET $REPLY $C_DIM(to Trash)$C_RESET") ;;
    esac
    for p in "${lo[@]}"; do
      if [[ -n "$shared" ]]; then reason="${_UN_NAME[i]} stays installed via $shared"
      else reason=$(_uninstall_leftover_reason "$p"); fi
      mm_tilde "$p"
      if [[ -n "$reason" ]]; then
        lines+=("$C_DIM◎$C_RESET $REPLY $C_DIM· kept ($reason)$C_RESET")
      elif _uninstall_app_data "$p"; then
        # Not counted in the totals below: each folder gets its own question at removal time.
        lines+=("$C_YELLOW?$C_RESET $REPLY $C_DIM· app data ($(_uninstall_describe "$p")), asked separately$C_RESET")
      elif lbytes=$(mm_size "$p"); then
        item_bytes=$(( item_bytes + lbytes )); trash_bytes=$(( trash_bytes + lbytes ))
        lines+=("$C_GREEN✓$C_RESET $REPLY $C_DIM$(mm_human "$lbytes") to Trash$C_RESET")
      else
        item_unknown=1
        lines+=("$C_GREEN✓$C_RESET $REPLY $C_DIM(size unknown) to Trash$C_RESET")
      fi
    done
    unknown=$(( unknown + item_unknown ))
    printf '\n%s✓%s %s, %s%s\n' "$C_GREEN" "$C_RESET" "${_UN_NAME[i]}" "$(mm_human "$item_bytes")" \
      "$( (( item_unknown )) && printf ' + size unknown')"
    while IFS= read -r p; do
      [[ -n "$p" ]] && { mm_tilde "$p"; lines+=("$C_DIM◎$C_RESET $REPLY $C_DIM· kept ($MM_UN_AGENT_KEPT)$C_RESET"); }
    done < <(_uninstall_agent_extra "$i")
    for p in "${lines[@]}"; do printf '  %s\n' "$p"; done
  done

  if (( ${#apt_sel[@]} )); then
    mm_section "apt simulation (apt-get -s remove --autoremove)"
    if (( ${#apt_block[@]} )); then
      printf '  %s✗ apt would also remove base-system or remote-access package(s): %s%s\n' "$C_RED" "${apt_block[*]}" "$C_RESET"
      mm_skip "${apt_sel[*]}" "marmot never removes ${apt_block[*]}; remove these by hand if you really mean it"
    elif (( ${#apt_mode[@]} == 0 )); then
      mm_skip "${apt_sel[*]}" "apt simulation failed"
    else
      local note declined=""
      for p in "${apt_all[@]}"; do
        if [[ " ${apt_sel[*]} " == *" $p "* ]]; then mm_ok "$p" "selected"
        else printf '  %s✗ %s · NOT selected, apt removes it too%s\n' "$C_RED" "$p" "$C_RESET"; fi
      done
      if (( ${#apt_extra[@]} )); then
        apt_extra_bytes=$(_uninstall_apt_bytes "${apt_extra[@]}")
        printf '  %s! apt would also remove %d package(s) you did not select (%s): %s%s\n' "$C_RED" \
          "${#apt_extra[@]}" "$(mm_human "$apt_extra_bytes")" "${apt_extra[*]}" "$C_RESET"
        # A dependency with wide impact (docker.io under docker-compose) is asked about by name,
        # the same way as if it had been selected; it never hides inside the list of extras.
        for p in "${apt_extra[@]}"; do
          note=$(_uninstall_note "$p")
          [[ -n "$note" ]] || continue
          printf '  %s! %s: %s%s\n' "$C_RED$C_BOLD" "$p" "$note" "$C_RESET"
          if [[ "$dry" == 1 ]]; then
            mm_warn "a real run asks for a separate confirmation for $p"
          elif [[ -z "$declined" ]] && ! mm_confirm "Really remove $p too? ($note)"; then
            declined=$p
          fi
        done
        if [[ "$dry" == 1 ]]; then
          mm_warn "a real run asks for a separate confirmation for these"
        elif [[ -n "$declined" ]] || ! mm_confirm "Also remove ${apt_extra[*]}?"; then
          # Retry without autoremove: if the removal alone touches nothing extra, keep going.
          local -a plain=() extra2=()
          mapfile -t plain < <(_uninstall_apt_sim "${apt_sel[@]}")
          for p in "${plain[@]}"; do [[ " ${apt_sel[*]} " == *" $p "* ]] || extra2+=("$p"); done
          if (( ${#plain[@]} && ${#extra2[@]} == 0 )); then
            apt_mode=(remove); apt_extra=(); apt_extra_bytes=0
            apt_plan=$(printf '%s\n' "${plain[@]}")
            mm_skip "apt autoremove" "declined; removing only ${apt_sel[*]}"
          else
            apt_mode=(); mm_skip "${apt_sel[*]}" "declined (apt would remove ${extra2[*]:-dependents} too)"
          fi
        fi
      fi
      free_bytes=$(( free_bytes + apt_extra_bytes ))
    fi
  fi

  local -a todo=()
  for i in "${keep[@]}"; do
    [[ "${_UN_SRC[i]}" == apt && ${#apt_mode[@]} -eq 0 ]] && continue
    [[ -n "${drop[$i]:-}" ]] && continue
    todo+=("$i")
  done
  (( ${#todo[@]} )) || { mm_info "Nothing left to uninstall."; return 0; }

  local -a todo_names=()
  for i in "${todo[@]}"; do todo_names+=("${_UN_NAME[i]}"); done
  local sizes
  sizes="free $(mm_human "$free_bytes"), move $(mm_human "$trash_bytes") to Trash"
  (( unknown )) && sizes+=", plus $unknown of unknown size"
  if [[ "$dry" == 1 ]]; then
    mm_banner "Uninstall preview$([[ "$MM_DRY_RUN" == 1 ]] && printf ' (dry run)')" \
      "Would remove ${#todo[@]} package$( (( ${#todo[@]} == 1 )) || printf s), $sizes: ${todo_names[*]}" \
      "$([[ "$MM_DRY_RUN" == 1 ]] && printf 'Run without --dry-run to apply.' || printf 'Run from a terminal to apply.')"
    return 0
  fi
  printf '\n'
  mm_confirm "Remove ${#todo[@]} package(s) and their leftovers ($sizes)?" ||
    { mm_info "Cancelled."; return 0; }

  _uninstall_execute "${#apt_mode[@]}" "$apt_extra_bytes" "$apt_plan" "${todo[@]}"
}

# _uninstall_snap_save NAME — snapshot NAME's data (sudo snap save) and print the snapshot set id;
# fails (keeping the snap) when the save fails. The id comes from snap save's own output; when
# that cannot be parsed the save still counts and nothing is printed.
_uninstall_snap_save() {
  local out rc
  out=$(mm_sudo timeout 600 snap save "$1" 2>&1); rc=$?
  if (( rc != 0 )); then
    mm_err "snap save $1 failed (exit $rc); $1 kept"
    printf '%s\n' "$out" | tail -3 | sed 's/^/    /' >&2
    return 1
  fi
  mm_log run "snap save $1"
  printf '%s\n' "$out" | awk -v s="$1" '$2 == s && $1 ~ /^[0-9]+$/ { printf "%.0f", $1; exit }'
}

# _uninstall_apt_recheck STEPS EXPECTED PKG... — 0 if a fresh simulation (with autoremove when
# STEPS is 2) still removes exactly the EXPECTED set (newline-separated). Prompts take time; apt
# may have changed under them.
_uninstall_apt_recheck() {
  local steps=$1 expected="$2" now; shift 2
  local -a opt=()
  (( steps >= 2 )) && opt=(--autoremove)
  now=$(_uninstall_apt_sim "${opt[@]}" "$@") || return 1
  [[ "$(sort <<<"$now")" == "$(sort <<<"$expected")" ]]
}

# _uninstall_apt_installed PKG — 0 while dpkg still has PKG installed.
_uninstall_apt_installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]; }

# _uninstall_tool IDX DESC CMD... — mm_run a package manager's own removal of package IDX; its
# history row carries the package's size, as the banner counts it (0 when unknown).
_uninstall_tool() {
  local i=$1 desc=$2; shift 2
  mm_run --measured "$desc" "$@" || return
  mm_log run "$desc" "${_UN_BYTES[i]:-0}"
}

# _uninstall_execute APT_STEPS APT_EXTRA_BYTES APT_PLAN IDX... — APT_STEPS: 2 remove+autoremove,
# 1 remove only. APT_PLAN: the simulated removal set the user confirmed, re-checked here.
_uninstall_execute() {
  local apt_steps=$1 apt_extra_bytes=$2 apt_plan=$3 i busy rc pkg_bytes=0 unknown=0 free_before ok found p b
  shift 3
  local -a removed=() removed_idx=() apt_sel=() apt_idx=()
  free_before=$(mm_free_bytes /)
  mm_inuse_refresh   # prompts may have taken a while
  mm_section "Removing"

  for i in "$@"; do [[ "${_UN_SRC[i]}" == apt ]] && { apt_idx+=("$i"); apt_sel+=("${_UN_NAME[i]}"); }; done
  if (( ${#apt_sel[@]} )); then
    if busy=$(mm_apt_busy); then
      for i in "${apt_idx[@]}"; do mm_skip "${_UN_NAME[i]}" "$busy"; done; apt_idx=()
    elif ! mm_can_sudo; then
      for i in "${apt_idx[@]}"; do mm_skip "${_UN_NAME[i]}" "needs sudo"; done; apt_idx=()
    elif ! _uninstall_apt_recheck "$apt_steps" "$apt_plan" "${apt_sel[@]}"; then
      # The plan the user confirmed is no longer what apt would do: keep everything and say so.
      for i in "${apt_idx[@]}"; do mm_skip "${_UN_NAME[i]}" "apt's removal set changed since the plan; run again"; done
      apt_idx=()
    else
      # remove, never purge: purge runs maintainer scripts that delete data (PostgreSQL clusters,
      # /var/lib/docker). The confirmed plan said config and data are kept.
      if mm_run --measured "apt-get remove ${apt_sel[*]}" mm_sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get -y -o DPkg::Lock::Timeout=60 remove "${apt_sel[@]}"; then
        # the row carries what the banner counts: the extra packages, and each selected one gone
        b=$apt_extra_bytes
        for i in "${apt_idx[@]}"; do _uninstall_apt_installed "${_UN_NAME[i]}" || b=$(( b + ${_UN_BYTES[i]:-0} )); done
        mm_log run "apt-get remove ${apt_sel[*]}" "$b"
        pkg_bytes=$(( pkg_bytes + apt_extra_bytes ))
      fi
      (( apt_steps >= 2 )) && mm_run "apt-get autoremove" mm_sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get -y -o DPkg::Lock::Timeout=60 autoremove
    fi
  fi

  local snapshot
  for i in "$@"; do
    ok=1
    case "${_UN_SRC[i]}" in
      apt)
        [[ " ${apt_idx[*]} " == *" $i "* ]] || continue
        _uninstall_apt_installed "${_UN_NAME[i]}" && ok=0 ;;
      snap)
        # snapd deletes ~/snap/NAME for every user on remove. A snapshot of marmot's own comes
        # first (no snap goes without one); --purge then skips snapd's duplicate automatic one.
        if snapshot=$(_uninstall_snap_save "${_UN_NAME[i]}"); then
          mm_info "${_UN_NAME[i]} data saved as snapshot ${snapshot:-(id: snap saved ${_UN_NAME[i]})}; bring it back: sudo snap restore ${snapshot:-<id>}"
          _uninstall_tool "$i" "snap remove --purge ${_UN_NAME[i]}" mm_sudo timeout 600 snap remove --purge "${_UN_NAME[i]}" || ok=0
        else
          ok=0
        fi ;;
      npm)  _uninstall_tool "$i" "npm rm -g ${_UN_NAME[i]}" timeout 300 npm rm -g "${_UN_NAME[i]}" || ok=0 ;; # SAFE: confirmed package-manager removal via mm_run
      bun)  _uninstall_tool "$i" "bun remove -g ${_UN_NAME[i]}" timeout 300 bun remove -g "${_UN_NAME[i]}" || ok=0 ;;
      pipx) _uninstall_tool "$i" "pipx uninstall ${_UN_NAME[i]}" timeout 300 pipx uninstall "${_UN_NAME[i]}" || ok=0 ;;
      uv)   _uninstall_tool "$i" "uv tool uninstall ${_UN_NAME[i]}" timeout 300 uv tool uninstall "${_UN_NAME[i]}" || ok=0 ;;
      bin)
        if ! mm_rm --trash "${_UN_PATH[i]}" "$HOME/.local/bin"; then
          mm_skip "${_UN_NAME[i]}" "${MM_SKIP_REASON:-move to Trash failed}"; continue
        fi ;;
    esac
    if (( ! ok )); then mm_err "${_UN_NAME[i]}: removal failed; leftovers kept"; continue; fi
    mm_ok "${_UN_NAME[i]}" "${_UN_SRC[i]}, $(_uninstall_human "${_UN_BYTES[i]}")$([[ "${_UN_SRC[i]}" == bin ]] && printf ' to Trash')"
    removed+=("${_UN_NAME[i]}"); removed_idx+=("$i")
    if [[ "${_UN_SRC[i]}" != bin ]]; then
      if [[ -n "${_UN_BYTES[i]}" ]]; then pkg_bytes=$(( pkg_bytes + _UN_BYTES[i] )); else unknown=$((unknown + 1)); fi
    fi
  done

  # Leftovers only after every package step: anything that failed or was skipped stays "in use"
  # for the used-by rule, so its files under a leftover are never deleted.
  _UN_GOING=()
  for i in "${removed_idx[@]}"; do _UN_GOING[$i]=1; done
  local shared
  for i in "${removed_idx[@]}"; do
    found=$(_uninstall_leftovers "${_UN_NAME[i]}")$(_uninstall_agent_extra "$i")
    [[ -n "$found" ]] || continue
    mm_act "${_UN_NAME[i]} leftovers"
    if shared=$(_uninstall_shared "$i" "${removed_idx[@]}"); then
      printf '  '; mm_skip "leftovers" "${_UN_NAME[i]} stays installed via $shared"
    else
      _uninstall_remove_leftovers "${_UN_NAME[i]}"
    fi
    while IFS= read -r p; do
      [[ -n "$p" ]] && _uninstall_kept "$p" "$MM_UN_AGENT_KEPT"
    done < <(_uninstall_agent_extra "$i")
  done
  rc=0; (( ${#removed[@]} )) || rc=1

  local freed=$(( pkg_bytes + MM_FREED )) free_after
  free_after=$(mm_free_bytes /)
  mm_banner "Uninstall complete" \
    "Removed ${#removed[@]} package$( (( ${#removed[@]} == 1 )) || printf s)${removed[*]:+: ${removed[*]}}" \
    "Space freed: $(mm_human "$freed")$( (( unknown )) && printf ' + %d of unknown size' "$unknown") | Moved to Trash: $(mm_human "$MM_TRASHED") (restore: trash-restore)" \
    "Free space: $(mm_human "$free_after") (+$(mm_human $(( free_after > free_before ? free_after - free_before : 0 ))))"
  return "$rc"
}
