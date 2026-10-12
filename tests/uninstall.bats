#!/usr/bin/env bats
# mm uninstall: leftover safety rules, Trash, and "no terminal = preview only".

setup() {
  load helpers/common
  mm_test_setup
  CALLS="$BATS_TEST_TMPDIR/pm.calls"   # every state-changing package-manager call a double saw
  : >"$CALLS"
  export CALLS FAKE_APT="" FAKE_SNAP="" FAKE_APT_SIM_EXTRA=""
}
teardown() { mm_test_teardown; }

# Doubles that answer the read-only probes mm uninstall makes and record anything else to $CALLS.
# FAKE_APT lists manual apt packages; dpkg-query answers for them (and only them). FAKE_SNAP lists
# installed snaps. FAKE_APT_SIM_EXTRA: packages `apt-get -s` says it would remove on top.
_fake_package_managers() {
  mm_test_fake apt-mark '[[ "$1" == showmanual ]] && { printf "%s\n" $FAKE_APT; exit 0; }
echo "apt-mark $*" >>"$CALLS"'
  mm_test_fake apt-get 'for a in "$@"; do [[ "$a" == -s ]] || continue
  for p in "$@"; do [[ " $FAKE_APT " == *" $p "* ]] && echo "Purg $p [1.0]"; done
  for p in $FAKE_APT_SIM_EXTRA; do echo "Purg $p [1.0]"; done; exit 0; done
echo "apt-get $*" >>"$CALLS"'
  mm_test_fake dpkg 'exit 0'
  mm_test_fake snap '[[ "$1" == list ]] && { echo "Name Version Rev Tracking Publisher Notes"
  for s in $FAKE_SNAP; do echo "$s 1.0 1 latest/stable vendor -"; done; exit 0; }
echo "snap $*" >>"$CALLS"'
  mm_test_fake npm '[[ "$1 $2" == "root -g" ]] && { echo "$HOME/npm-global/lib/node_modules"; exit 0; }
[[ "$1 $2" == "ls -g" ]] && { echo "$HOME/npm-global/lib"; exit 0; }
echo "npm $*" >>"$CALLS"'
  mm_test_fake pipx '[[ "$1" == list || "$1" == environment ]] && exit 0
echo "pipx $*" >>"$CALLS"'
  mm_test_fake dpkg-query 'fmt=""; pk=()
while (( $# )); do case "$1" in -W) ;; -f) fmt=$2; shift ;; -f=*) fmt=${1#-f=} ;; *) pk+=("$1") ;; esac; shift; done
for p in "${pk[@]}"; do
  [[ " $FAKE_APT " == *" $p "* ]] || continue
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
  _load
  run _uninstall_remove_leftovers deep apt
  [ -d "$HOME/.local/share/deep/a/b/c/d/e/.git" ]
  [ -d "$HOME/.cache/deep/wt/x/y/z/worktrees" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/deep" ]
}

@test "leftover with recent sessions/ data is kept; stale sessions are trashed" {
  mkdir -p "$HOME/.fakeide/a/sessions" "$HOME/.cache/fakeide/sessions"
  echo s >"$HOME/.fakeide/a/sessions/live.jsonl"
  echo o >"$HOME/.cache/fakeide/sessions/old.jsonl"
  mm_age "$HOME/.cache/fakeide" 60
  _load
  run _uninstall_remove_leftovers fakeide apt
  [ -f "$HOME/.fakeide/a/sessions/live.jsonl" ]
  [ ! -e "$HOME/.cache/fakeide" ]
  _trashed fakeide
}

@test "leftover that a remaining ~/.local/bin symlink points into is kept" {
  mkdir -p "$HOME/.cache/fakeide/appimage/launcher" "$HOME/.local/bin"
  echo x >"$HOME/.cache/fakeide/appimage/launcher/fakeide-gui"
  ln -s "$HOME/.cache/fakeide/appimage/launcher/fakeide-gui" "$HOME/.local/bin/fakeide-gui"
  _load
  run _uninstall_remove_leftovers fakeide bin
  [[ "$output" == *"used by ~/.local/bin/fakeide-gui"* ]]
  [ -f "$HOME/.cache/fakeide/appimage/launcher/fakeide-gui" ]
}

@test "leftovers match the exact name only (fakepkg-extra, myfakepkg, fakepkg2 untouched)" {
  mkdir -p "$HOME/.cache/fakepkg" "$HOME/.local/share/fakepkg" "$HOME/.fakepkg" "$HOME/snap/fakepkg" \
    "$HOME/.cache/fakepkg-extra" "$HOME/.local/share/myfakepkg" "$HOME/.cache/fakepkg2" "$HOME/.fakepkgrc.d"
  _load
  run _uninstall_remove_leftovers fakepkg snap
  local p
  for p in .cache/fakepkg .local/share/fakepkg .fakepkg snap/fakepkg; do [ ! -e "$HOME/$p" ]; done
  for p in .cache/fakepkg-extra .local/share/myfakepkg .cache/fakepkg2 .fakepkgrc.d; do [ -d "$HOME/$p" ]; done
  run _uninstall_leftovers ../etc apt
  [ -z "$output" ]
}

@test "a generic name keeps every name-only leftover" {
  local n
  for n in agent cli server tools; do
    mkdir -p "$HOME/.cache/$n" "$HOME/.local/share/$n" "$HOME/.$n"
  done
  _load
  for n in agent cli server tools; do
    run _uninstall_remove_leftovers "$n" apt
    [[ "$output" == *"generic name"* ]]
    [ -d "$HOME/.cache/$n" ]; [ -d "$HOME/.local/share/$n" ]; [ -d "$HOME/.$n" ]
  done
  [ ! -e "$XDG_DATA_HOME/Trash/files" ] || [ -z "$(ls -A "$XDG_DATA_HOME/Trash/files")" ]
}

@test "whitelisted ~/.config/<name> is kept (default whitelist)" {
  mkdir -p "$HOME/.config/fakepkg" "$HOME/.cache/fakepkg"
  _load
  run _uninstall_remove_leftovers fakepkg apt
  [ -d "$HOME/.config/fakepkg" ]
  [ ! -e "$HOME/.cache/fakepkg" ]
}

@test "leftovers go to the Trash with a .trashinfo, never rm" {
  mkdir -p "$HOME/.cache/fakepkg" "$HOME/.local/share/fakepkg"
  echo data >"$HOME/.cache/fakepkg/blob"
  _load
  run _uninstall_remove_leftovers fakepkg apt
  [ ! -e "$HOME/.cache/fakepkg" ]
  [ -f "$XDG_DATA_HOME/Trash/files/fakepkg/blob" ]
  grep -q "^Path=$HOME/.cache/fakepkg$" "$XDG_DATA_HOME/Trash/info/fakepkg.trashinfo"
  [ -f "$XDG_DATA_HOME/Trash/info/fakepkg.2.trashinfo" ]
  [ "$(mm_log_rows trash | wc -l)" -eq 2 ]
  [ -z "$(mm_log_rows remove)" ]
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
  _uninstall_apt_busy() { return 1; }
  MM_TTY=1
  mm_confirm() { return 0; }
  _uninstall_collect
  _uninstall_by_name google-cloud-cli awscli google-guest-agent amazon-ssm-agent
  run _uninstall_apply "${_UN_SEL[@]}"
  grep -q 'snap remove --purge google-cloud-cli$' "$CALLS"
  grep -q 'purge awscli$' "$CALLS"
  run grep -E 'google-guest-agent|amazon-ssm-agent' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "an apt purge that would drag in a guest agent is refused, even when confirmed" {
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
  # Terminal: decline only the question about tailscale; zerotier-one alone is purged.
  # (The host's own apt/unattended-upgrades activity must not decide this test.)
  _uninstall_apt_busy() { return 1; }
  MM_TTY=1
  mm_confirm() { [[ "$1" != *tailscale* ]]; }
  run _uninstall_apply "${_UN_SEL[@]}"
  grep -q 'purge zerotier-one$' "$CALLS"
  run grep -q tailscale "$CALLS"
  [ "$status" -ne 0 ]
}

@test "uninstalling a coding agent's binary keeps its state and says why" {
  mkdir -p "$HOME/.local/bin" "$HOME/.claude/projects/p" "$HOME/.cache/claude"
  echo t >"$HOME/.claude/projects/p/s.jsonl"
  echo '{}' >"$HOME/.claude.json"
  echo bin >"$HOME/.local/bin/claude"
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
