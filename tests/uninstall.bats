#!/usr/bin/env bats
# mm uninstall: leftover safety rules (caches vs app data), Trash, apt removal without purge, snap
# snapshots, uv tools, and "no terminal = preview only".

setup() {
  load helpers/common
  mm_test_setup
  CALLS="$BATS_TEST_TMPDIR/pm.calls"   # every state-changing package-manager call a double saw
  : >"$CALLS"
  export CALLS FAKE_APT="" FAKE_SNAP="" FAKE_APT_SIM_EXTRA="" FAKE_APT_SIM_AUTO="" FAKE_SNAP_SET=42
}
teardown() { mm_test_teardown; }

# Doubles that answer the read-only probes mm uninstall makes and record anything else to $CALLS.
# FAKE_APT lists manual apt packages; dpkg-query answers for them (and only them). FAKE_SNAP lists
# installed snaps. FAKE_APT_SIM_EXTRA: packages `apt-get -s` says it would remove on top;
# FAKE_APT_SIM_AUTO: the same, only when the simulation has --autoremove. Simulations are logged to
# $CALLS.sim. FAKE_SNAP_SET: the snapshot set id `snap save` prints (empty: the save fails).
_fake_package_managers() {
  mm_test_fake apt-mark '[[ "$1" == showmanual ]] && { [[ -z "$FAKE_APT" ]] || printf "%s\n" $FAKE_APT; exit 0; }
echo "apt-mark $*" >>"$CALLS"'
  mm_test_fake apt-get 'if [[ " $* " == *" -s "* ]]; then
  echo "apt-get $*" >>"$CALLS.sim"
  verb=Remv; [[ " $* " == *" purge "* || " $* " == *" --purge "* ]] && verb=Purg
  for p in "$@"; do [[ " $FAKE_APT " == *" $p "* ]] && echo "$verb $p [1.0]"; done
  for p in $FAKE_APT_SIM_EXTRA; do echo "$verb $p [1.0]"; done
  [[ " $* " == *" --autoremove "* ]] && for p in $FAKE_APT_SIM_AUTO; do echo "$verb $p [1.0]"; done
  exit 0
fi
echo "apt-get $*" >>"$CALLS"'
  mm_test_fake dpkg 'exit 0'
  mm_test_fake snap '[[ "$1" == list ]] && { echo "Name Version Rev Tracking Publisher Notes"
  for s in $FAKE_SNAP; do echo "$s 1.0 1 latest/stable vendor -"; done; exit 0; }
echo "snap $*" >>"$CALLS"
[[ "$1" == save ]] || exit 0
[[ -n "$FAKE_SNAP_SET" ]] || { echo "error: cannot save snapshot" >&2; exit 1; }
printf "Set  Snap  Age    Version  Rev  Size  Notes\n%s  %s  1.00s  1.0  1  4kB  -\n" "$FAKE_SNAP_SET" "$2"'
  mm_test_fake npm '[[ "$1 $2" == "root -g" ]] && { echo "$HOME/npm-global/lib/node_modules"; exit 0; }
[[ "$1 $2" == "ls -g" ]] && { echo "$HOME/npm-global/lib"; exit 0; }
echo "npm $*" >>"$CALLS"'
  mm_test_fake pipx '[[ "$1" == list || "$1" == environment ]] && exit 0
echo "pipx $*" >>"$CALLS"'
  mm_test_fake dpkg-query 'fmt=""; pk=()
while (( $# )); do case "$1" in -W) ;; -f) fmt=$2; shift ;; -f=*) fmt=${1#-f=} ;; *) pk+=("$1") ;; esac; shift; done
for p in "${pk[@]}"; do
  [[ -n "$p" && " $FAKE_APT " == *" $p "* ]] || continue
  o=${fmt//"\${Package}"/$p}; o=${o//"\${binary:Package}"/$p}; o=${o//"\${Priority}"/optional}
  o=${o//"\${Essential}"/no}; o=${o//"\${Installed-Size}"/100}; o=${o//"\${Section}"/utils}
  o=${o//"\${db:Status-Abbrev}"/"ii "}; printf "%b" "$o"
done'
}

# sudo double for interactive apt paths: "passwordless", runs the command as the test user.
_fake_sudo() { mm_test_fake sudo '[[ "$1" == -n ]] && shift; [[ "$*" == true ]] && exit 0; exec "$@"'; }

# Source core + the command into the test shell to call its functions directly.
_load() {
  mm_core
  # shellcheck source=../cmd/uninstall.sh
  . "$MM_SRC/cmd/uninstall.sh"
}

_trashed() { [[ -e "$XDG_DATA_HOME/Trash/files/$1" && -f "$XDG_DATA_HOME/Trash/info/$1.trashinfo" ]]; }

@test "leftover containing a .git at any depth is kept (a/b/c/d/e/.git bypass)" {
  mkdir -p "$HOME/.local/share/deep/a/b/c/d/e/.git" "$HOME/.cache/deep/wt/x/y/z/worktrees"
  mm_age "$HOME/.local/share/deep" 40; mm_age "$HOME/.cache/deep" 40
  _load
  _UN_APP_DATA=1
  mm_confirm() { return 0; }
  run _uninstall_remove_leftovers deep
  [[ "$output" == *"git repository"* ]]
  [ -d "$HOME/.local/share/deep/a/b/c/d/e/.git" ]
  [ -d "$HOME/.cache/deep/wt/x/y/z/worktrees" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/deep" ]
}

@test "leftover that a remaining ~/.local/bin symlink points into is kept" {
  mkdir -p "$HOME/.cache/fakeide/appimage/launcher" "$HOME/.local/bin"
  echo x >"$HOME/.cache/fakeide/appimage/launcher/fakeide-gui"
  mm_age "$HOME/.cache/fakeide" 40
  ln -s "$HOME/.cache/fakeide/appimage/launcher/fakeide-gui" "$HOME/.local/bin/fakeide-gui"
  _load
  run _uninstall_remove_leftovers fakeide
  [[ "$output" == *"used by ~/.local/bin/fakeide-gui"* ]]
  [ -f "$HOME/.cache/fakeide/appimage/launcher/fakeide-gui" ]
}

@test "leftovers match the exact name only (fakepkg-extra, myfakepkg, fakepkg2 untouched)" {
  mkdir -p "$HOME/.cache/fakepkg" "$HOME/.local/share/fakepkg" "$HOME/.fakepkg" "$HOME/snap/fakepkg" \
    "$HOME/.cache/fakepkg-extra" "$HOME/.local/share/myfakepkg" "$HOME/.cache/fakepkg2" "$HOME/.fakepkgrc.d"
  mm_age "$HOME" 40
  _load
  _UN_APP_DATA=1
  mm_confirm() { return 0; }
  run _uninstall_remove_leftovers fakepkg
  local p
  for p in .cache/fakepkg .local/share/fakepkg .fakepkg; do [ ! -e "$HOME/$p" ]; done
  for p in .cache/fakepkg-extra .local/share/myfakepkg .cache/fakepkg2 .fakepkgrc.d; do [ -d "$HOME/$p" ]; done
  [ -d "$HOME/snap/fakepkg" ]   # snapd's own data folder: saved by `snap save`, never a Trash leftover
  run _uninstall_leftovers ../etc
  [ -z "$output" ]
}

@test "a generic name keeps every name-only leftover" {
  local n names="common cli server tools agent backup notes sync files cloud music"
  for n in $names; do
    mkdir -p "$HOME/.cache/$n" "$HOME/.local/share/$n" "$HOME/.$n"
  done
  _load
  _UN_APP_DATA=1
  mm_confirm() { return 0; }   # app data opted in: only the generic-name rule may keep these
  for n in $names; do
    run _uninstall_remove_leftovers "$n"
    [[ "$output" == *"generic name"* ]]
    [ -d "$HOME/.cache/$n" ]; [ -d "$HOME/.local/share/$n" ]; [ -d "$HOME/.$n" ]
  done
  [ ! -e "$XDG_DATA_HOME/Trash/files" ] || [ -z "$(ls -A "$XDG_DATA_HOME/Trash/files")" ]
}

@test "whitelisted ~/.config/<name> is kept (default whitelist)" {
  mkdir -p "$HOME/.config/fakepkg" "$HOME/.cache/fakepkg"
  mm_age "$HOME/.config/fakepkg" 40; mm_age "$HOME/.cache/fakepkg" 40
  _load
  run _uninstall_remove_leftovers fakepkg
  [[ "$output" == *"whitelisted"* ]]
  [ -d "$HOME/.config/fakepkg" ]
  [ ! -e "$HOME/.cache/fakepkg" ]
}

@test "leftovers go to the Trash with a .trashinfo, never rm" {
  mkdir -p "$HOME/.cache/fakepkg" "$HOME/.local/share/fakepkg"
  echo data >"$HOME/.cache/fakepkg/blob"
  mm_age "$HOME/.cache/fakepkg" 40; mm_age "$HOME/.local/share/fakepkg" 40
  _load
  _UN_APP_DATA=1
  mm_confirm() { return 0; }
  run _uninstall_remove_leftovers fakepkg
  [ ! -e "$HOME/.cache/fakepkg" ]
  [ -f "$XDG_DATA_HOME/Trash/files/fakepkg/blob" ]
  grep -q "^Path=$HOME/.cache/fakepkg$" "$XDG_DATA_HOME/Trash/info/fakepkg.trashinfo"
  [ -f "$XDG_DATA_HOME/Trash/info/fakepkg.2.trashinfo" ]
  [ "$(mm_log_rows trash | wc -l)" -eq 2 ]
  [ -z "$(mm_log_rows remove)" ]
}

@test "only ~/.cache/NAME is preselected: ~/.NAME and ~/.local/share/NAME stay without --app-data" {
  mkdir -p "$HOME/.local/bin" "$HOME/.cache/mailer" "$HOME/.mailer/Mail" "$HOME/.local/share/mailer/store"
  echo bin >"$HOME/.local/bin/mailer"
  echo c >"$HOME/.cache/mailer/c"; echo m >"$HOME/.mailer/Mail/Inbox"; echo s >"$HOME/.local/share/mailer/store/db"
  mm_age "$HOME/.cache/mailer" 40; mm_age "$HOME/.mailer" 40; mm_age "$HOME/.local/share/mailer" 40
  _load
  MM_TTY=1
  mm_confirm() { return 0; }   # every question answered yes: the app data must stay anyway
  _uninstall_add bin mailer 4096 0 "$HOME/.local/bin/mailer" "" 0
  run _uninstall_apply 0
  [ "$status" -eq 0 ]
  _trashed mailer                                  # the binary
  [ ! -e "$HOME/.cache/mailer" ]                   # the cache
  [ -f "$HOME/.mailer/Mail/Inbox" ]; [ -f "$HOME/.local/share/mailer/store/db" ]
  [ "$(mm_log_rows trash | wc -l)" -eq 2 ]
}

@test "--app-data asks once per app data folder, naming it; only the folders confirmed go to the Trash" {
  _fake_package_managers
  mkdir -p "$HOME/.local/bin" "$HOME/.mailer/Mail" "$HOME/.local/share/mailer/store"
  echo bin >"$HOME/.local/bin/mailer"
  echo m >"$HOME/.mailer/Mail/Inbox"; echo s >"$HOME/.local/share/mailer/store/db"
  mm_age "$HOME/.mailer" 40; mm_age "$HOME/.local/share/mailer" 40
  run mm uninstall --app-data --dry-run mailer
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/.mailer"* && "$output" == *"~/.local/share/mailer"* ]]
  [ -f "$HOME/.mailer/Mail/Inbox" ]; [ -f "$HOME/.local/share/mailer/store/db" ]
  [ ! -s "$CALLS" ]
  _load
  _UN_APP_DATA=1
  local prompts="$BATS_TEST_TMPDIR/prompts"
  mm_confirm() { printf '%s\n' "$1" >>"$prompts"; [[ "$1" == *"~/.mailer "* ]]; }
  run _uninstall_remove_leftovers mailer
  [ ! -e "$HOME/.mailer" ]; _trashed .mailer
  [ -f "$HOME/.local/share/mailer/store/db" ]
  [ "$(wc -l <"$prompts")" -eq 2 ]
  grep -q '~/\.mailer ' "$prompts"; grep -q '~/\.local/share/mailer ' "$prompts"
}

@test "a leftover with a file changed in the last 30 days or a credential-like name is always kept" {
  mkdir -p "$HOME/.cache/fresh" "$HOME/.fresh" "$HOME/.cache/keyed/registry" "$HOME/.keyed" \
    "$HOME/.cache/stale" "$HOME/.stale"
  echo old >"$HOME/.cache/fresh/old.bin"; echo old >"$HOME/.fresh/old.txt"
  echo t >"$HOME/.cache/keyed/registry/credentials.toml"; echo k >"$HOME/.keyed/id_ed25519"
  echo o >"$HOME/.cache/stale/o"; echo o >"$HOME/.stale/o"
  mm_age "$HOME/.cache" 40; mm_age "$HOME/.fresh" 40; mm_age "$HOME/.keyed" 40; mm_age "$HOME/.stale" 40
  echo new >"$HOME/.cache/fresh/new.bin"
  echo new >"$HOME/.fresh/new.txt"; touch -d '2 days ago' "$HOME/.fresh/new.txt"
  _load
  _UN_APP_DATA=1
  mm_confirm() { return 0; }
  local n
  for n in fresh keyed stale; do run _uninstall_remove_leftovers "$n"; done
  [ -f "$HOME/.cache/fresh/old.bin" ]; [ -f "$HOME/.fresh/old.txt" ]
  [ -f "$HOME/.cache/keyed/registry/credentials.toml" ]; [ -f "$HOME/.keyed/id_ed25519" ]
  [ ! -e "$HOME/.cache/stale" ]; [ ! -e "$HOME/.stale" ]
  [ "$(mm_log_rows trash | wc -l)" -eq 2 ]
}

@test "no terminal: nothing removed and no package-manager removal runs" {
  _fake_package_managers
  export FAKE_APT=fakepkg
  mkdir -p "$HOME/.local/bin" "$HOME/.cache/fakebin" "$HOME/.cache/fakepkg"
  echo bin >"$HOME/.local/bin/fakebin"
  run mm uninstall fakebin fakepkg
  [ "$status" -eq 0 ]
  [ -f "$HOME/.local/bin/fakebin" ]; [ -d "$HOME/.cache/fakebin" ]; [ -d "$HOME/.cache/fakepkg" ]
  [ ! -e "$XDG_DATA_HOME/Trash" ]
  [ ! -s "$CALLS" ]
  [ -z "$(mm_log_rows trash)$(mm_log_rows remove)$(mm_log_rows run)" ]
  run mm uninstall
  [ "$status" -eq 0 ]
  [ -f "$HOME/.local/bin/fakebin" ]
  [ ! -s "$CALLS" ]
  # Preview-only must not hinge on mm_confirm declining: even a confirm that says yes changes nothing.
  _load
  MM_TTY=0
  mm_confirm() { return 0; }
  _uninstall_add bin fakebin 4096 0 "$HOME/.local/bin/fakebin" "" 0
  run _uninstall_apply 0
  [ -f "$HOME/.local/bin/fakebin" ]; [ -d "$HOME/.cache/fakebin" ]
  [ ! -e "$XDG_DATA_HOME/Trash" ]
}

@test "dry-run of a NAME calls only read-only tools and changes nothing" {
  _fake_package_managers
  export FAKE_APT=fakepkg
  mkdir -p "$HOME/.cache/fakepkg"
  run mm uninstall --dry-run fakepkg
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt simulation"* ]]
  [[ "$output" == *"~/.cache/fakepkg"* ]]
  [ -d "$HOME/.cache/fakepkg" ]
  [ ! -s "$CALLS" ]
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}

@test "confirmed interactive removal trashes the binary and its leftovers, runs npm rm -g" {
  _fake_package_managers
  mkdir -p "$HOME/.local/bin" "$HOME/.cache/fakebin" "$HOME/.cache/fakenpm" "$HOME/npm-global/lib/node_modules/fakenpm"
  echo bin >"$HOME/.local/bin/fakebin"
  mm_age "$HOME/.cache/fakebin" 40; mm_age "$HOME/.cache/fakenpm" 40
  _load
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_add bin fakebin 4096 0 "$HOME/.local/bin/fakebin" "" 0
  _uninstall_add npm fakenpm 4096 0 "$HOME/npm-global/lib/node_modules/fakenpm" "" 0
  run _uninstall_apply 0 1
  [ "$status" -eq 0 ]
  _trashed fakebin
  [ -d "$XDG_DATA_HOME/Trash/files/fakebin.2" ]   # ~/.cache/fakebin
  _trashed fakenpm
  [ "$(cat "$CALLS")" = "npm rm -g fakenpm" ]
  [[ "$output" == *"Moved to Trash"*"trash-restore"* ]]
}

@test "declining the running-process confirmation keeps the item" {
  mkdir -p "$HOME/.local/bin"
  cp /bin/sleep "$HOME/.local/bin/fakerun"
  mm_test_bg "$SB" "$HOME/.local/bin/fakerun" 30
  _load
  MM_TTY=1
  mm_confirm() { return 1; }
  _uninstall_add bin fakerun 4096 0 "$HOME/.local/bin/fakerun" "" 0
  run _uninstall_apply 0
  [ -f "$HOME/.local/bin/fakerun" ]
  [[ "$output" == *"fakerun · skipped (running)"* ]]
}

@test "cloud/hypervisor guest agents are never offered or removable (apt and snap)" {
  _fake_package_managers
  export FAKE_APT="amazon-ssm-agent walinuxagent qemu-guest-agent ncdu" FAKE_SNAP="amazon-ssm-agent fakesnap"
  run mm uninstall --dry-run --all
  [ "$status" -eq 0 ]
  [[ "$output" == *ncdu* && "$output" == *fakesnap* ]]
  [[ "$output" != *amazon-ssm-agent* && "$output" != *walinuxagent* && "$output" != *qemu-guest-agent* ]]
  run mm uninstall --dry-run amazon-ssm-agent walinuxagent qemu-guest-agent
  [ "$status" -eq 0 ]
  [ "$(grep -c 'skipped (base system' <<<"$output")" -eq 3 ]
  [[ "$output" != *"Files to be removed"* ]]
  [ ! -s "$CALLS" ]
}

@test "vendor CLIs (google-cloud-cli snap, awscli apt) are removable; their guest agents are not" {
  _fake_package_managers
  _fake_sudo
  export FAKE_APT="awscli google-guest-agent amazon-ssm-agent" FAKE_SNAP="google-cloud-cli amazon-ssm-agent"
  run mm uninstall --dry-run --all
  [[ "$output" == *google-cloud-cli* && "$output" == *awscli* ]]
  [[ "$output" != *google-guest-agent* && "$output" != *amazon-ssm-agent* ]]
  _load
  mm_apt_busy() { return 1; }
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name google-cloud-cli awscli google-guest-agent amazon-ssm-agent
  run _uninstall_apply "${_UN_SEL[@]}"
  grep -q 'snap remove --purge google-cloud-cli$' "$CALLS"
  grep -q ' remove awscli$' "$CALLS"
  run grep -E 'google-guest-agent|amazon-ssm-agent' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "an apt removal that would drag in a guest agent is refused, even when confirmed" {
  _fake_package_managers
  _fake_sudo
  export FAKE_APT=ncdu FAKE_APT_SIM_EXTRA=qemu-guest-agent
  _load
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name ncdu
  run _uninstall_apply "${_UN_SEL[@]}"
  [[ "$output" == *qemu-guest-agent* ]]
  [ ! -s "$CALLS" ]
}

@test "remote-access/VPN packages (tailscale, zerotier-one) are hidden unless named" {
  _fake_package_managers
  export FAKE_APT="ncdu tailscale zerotier-one"
  local args
  for args in "--dry-run" "--dry-run --all" "--list"; do
    # shellcheck disable=SC2086
    run mm uninstall $args
    [[ "$output" == *ncdu* ]]
    [[ "$output" != *tailscale* && "$output" != *zerotier-one* ]]
  done
  run mm uninstall --dry-run tailscale zerotier-one
  [[ "$output" == *"apt package tailscale"* && "$output" == *"apt package zerotier-one"* ]]
  [ ! -s "$CALLS" ]
}

@test "remote-access/VPN packages need their own confirmation on a terminal" {
  _fake_package_managers
  _fake_sudo
  export FAKE_APT="tailscale zerotier-one"
  _load
  _uninstall_collect
  _uninstall_by_name tailscale zerotier-one
  # No terminal: a confirm that would say yes is never consulted.
  MM_TTY=0
  mm_confirm() { return 0; }
  run _uninstall_apply "${_UN_SEL[@]}"
  [ ! -s "$CALLS" ]
  # Terminal: decline only the question about tailscale; zerotier-one alone is removed.
  # (The host's own apt/unattended-upgrades activity must not decide this test.)
  mm_apt_busy() { return 1; }
  MM_TTY=1
  mm_confirm() { [[ "$1" != *tailscale* ]]; }
  run _uninstall_apply "${_UN_SEL[@]}"
  grep -q ' remove zerotier-one$' "$CALLS"
  run grep -q tailscale "$CALLS"
  [ "$status" -ne 0 ]
}

@test "uninstalling a coding agent's binary keeps its state and says why" {
  mkdir -p "$HOME/.local/bin" "$HOME/.claude/projects/p" "$HOME/.cache/claude"
  echo t >"$HOME/.claude/projects/p/s.jsonl"
  echo '{}' >"$HOME/.claude.json"
  echo bin >"$HOME/.local/bin/claude"
  mm_age "$HOME/.cache/claude" 40
  _load
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_add bin claude 4096 0 "$HOME/.local/bin/claude" "" 0
  run _uninstall_apply 0
  [ "$status" -eq 0 ]
  _trashed claude                                  # the binary
  [ ! -e "$HOME/.cache/claude" ]                   # a plain cache leftover still goes
  [ -f "$HOME/.claude/projects/p/s.jsonl" ]; [ -f "$HOME/.claude.json" ]
  [ "$(grep -c '\.claude.* kept (agent state' <<<"$output")" -ge 4 ]   # plan + run, both paths
}

@test "apt packages are removed, never purged; autoremove runs without --purge" {
  _fake_package_managers
  _fake_sudo
  export FAKE_APT=fakepkg FAKE_APT_SIM_AUTO=fakedep
  _load
  mm_apt_busy() { return 1; }
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name fakepkg
  run _uninstall_apply "${_UN_SEL[@]}"
  grep -q ' remove fakepkg$' "$CALLS"
  grep -q ' autoremove$' "$CALLS"
  [ -s "$CALLS.sim" ]
  run grep -h purge "$CALLS" "$CALLS.sim"
  [ "$status" -eq 1 ]
}

@test "a package apt would remove beyond the selection gets its own note and confirmation (docker.io)" {
  _fake_package_managers
  _fake_sudo
  export FAKE_APT=fakecompose FAKE_APT_SIM_AUTO="libfake1 docker.io"
  _load
  mm_apt_busy() { return 1; }
  MM_TTY=1
  # Yes to the list of extra packages, no to the separate question about docker.io.
  mm_confirm() { [[ "$1" == "Also remove"* || "$1" != *docker.io* ]]; }
  _uninstall_collect
  _uninstall_by_name fakecompose
  run _uninstall_apply "${_UN_SEL[@]}"
  grep -q ' remove fakecompose$' "$CALLS"
  run grep -E 'autoremove|docker' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "apt's plan is simulated again right before removal; a plan that changed removes nothing" {
  _fake_package_managers
  _fake_sudo
  export FAKE_APT=fakepkg
  # From the second simulation on (the one at removal time) apt would also remove fakenew.
  mm_test_fake apt-get 'if [[ " $* " == *" -s "* ]]; then
  n=$(( $(cat "$CALLS.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$CALLS.n"
  echo "Remv fakepkg [1.0]"; (( n > 1 )) && echo "Remv fakenew [1.0]"; exit 0
fi
echo "apt-get $*" >>"$CALLS"'
  _load
  mm_apt_busy() { return 1; }
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name fakepkg
  run _uninstall_apply "${_UN_SEL[@]}"
  [ "$(cat "$CALLS.n")" -ge 2 ]
  [ ! -s "$CALLS" ]
}

@test "a snap is removed only after snap save succeeds; ~/snap/NAME is never a Trash leftover" {
  _fake_package_managers
  _fake_sudo
  export FAKE_SNAP="fakesnap othersnap"
  mkdir -p "$HOME/snap/fakesnap/common" "$HOME/snap/othersnap/common"
  echo mail >"$HOME/snap/fakesnap/common/Inbox"; echo mail >"$HOME/snap/othersnap/common/Inbox"
  mm_age "$HOME/snap" 40
  _load
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name fakesnap
  run _uninstall_apply "${_UN_SEL[@]}"
  [ "$(cat "$CALLS")" = $'snap save fakesnap\nsnap remove --purge fakesnap' ]
  [[ "$output" == *"snap restore 42"* ]]
  mm_log_rows run | cut -f1 | grep -q '^snap save fakesnap'
  [ -f "$HOME/snap/fakesnap/common/Inbox" ]   # snapd deletes it after the snapshot; marmot never trashes it
  [ -z "$(mm_log_rows trash)" ]
  # The snapshot fails: the snap stays installed.
  : >"$CALLS"
  export FAKE_SNAP_SET=""
  _uninstall_by_name othersnap
  run _uninstall_apply "${_UN_SEL[@]}"
  [ "$(cat "$CALLS")" = "snap save othersnap" ]
}

@test "a ~/.local/bin link into a uv tool is that tool: removed with uv tool uninstall, never trashed" {
  _fake_package_managers
  mm_test_fake uv 'echo "uv $*" >>"$CALLS"'
  local tool="$HOME/.local/share/uv/tools/fakeuv"
  mkdir -p "$tool/bin" "$HOME/.local/bin"
  : >"$tool/uv-receipt.toml"
  printf '#!/bin/sh\n' >"$tool/bin/fakeuv"; chmod +x "$tool/bin/fakeuv"
  ln -s "$tool/bin/fakeuv" "$HOME/.local/bin/fakeuv"
  _load
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name fakeuv
  [ "${#_UN_SEL[@]}" -eq 1 ]
  [ "${_UN_SRC[_UN_SEL[0]]}" = uv ]
  run _uninstall_apply "${_UN_SEL[@]}"
  [ "$(cat "$CALLS")" = "uv tool uninstall fakeuv" ]
  [ -L "$HOME/.local/bin/fakeuv" ]   # uv removes its own link; marmot does not trash it
  [ -z "$(mm_log_rows trash)" ]
}
