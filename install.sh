#!/usr/bin/env bash
# Install marmot for the current user (no root needed).
#
#   ./install.sh               install or update from this checkout
#   ./install.sh --uninstall   remove the launchers and the installed copy; keeps your config,
#                              history, and anything marmot moved to the Trash
#
# Installs to ${MARMOT_PREFIX:-~/.local/share/marmot} and links `mm` and `marmot` into
# ${MARMOT_BIN:-~/.local/bin}. Running it from the install directory itself only (re)creates links.
# The copy notes where it came from in .install-source (this folder, its git commit, the launcher
# folder): `mm update` pulls and reinstalls from there, `mm --version` shows the commit.
# .install-manifest lists the files the copy put there: a reinstall or --uninstall removes those
# and nothing else. A prefix that is a symlink or inside a git work tree is refused.
set -euo pipefail

src=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
prefix=${MARMOT_PREFIX:-$HOME/.local/share/marmot}
while [[ "$prefix" == ?*/ ]]; do prefix=${prefix%/}; done   # "link/" would act on the link's target
bindir=${MARMOT_BIN:-$HOME/.local/bin}
manifest=.install-manifest

# What install copies: the launcher, libraries, commands, completion, and this installer (for
# --uninstall). Tests and git metadata stay in the checkout.
PAYLOAD=(marmot install.sh lib cmd completion)
# Everything an install made before .install-manifest existed can hold (no file has left these
# folders since): such a copy is replaced or removed only when it holds nothing else.
LEGACY_DIRS=(lib cmd completion)
LEGACY_FILES=(marmot install.sh .install-source lib/agents.sh lib/catalog.sh lib/core.sh lib/schedule.sh
  cmd/analyze.sh cmd/clean.sh cmd/history.sh cmd/optimize.sh cmd/purge.sh cmd/schedule.sh cmd/status.sh
  cmd/uninstall.sh cmd/update.sh completion/_mm completion/mm.bash)

# Lines look like marmot's own (lib/core.sh mm_ok/mm_warn/mm_err), which this does not source: it
# would canonicalize HOME and probe the terminal. Color only when that stream is a terminal.
_mark() {   # _mark FD COLOR SYMBOL MESSAGE
  local c="" r=""
  if [[ -t $1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then c=$'\e['"$2m" r=$'\e[0m'; fi
  printf '  %s%s%s %s\n' "$c" "$3" "$r" "$4" >&"$1"
}
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { _mark 1 32 ✓ "$*"; }
warn() { _mark 2 33 ! "$*"; }
die()  { _mark 2 31 ✗ "$*"; exit 1; }

# _is_marmot_tree DIR — DIR looks like a marmot install.
_is_marmot_tree() { [[ -f "$1/marmot" && -f "$1/lib/core.sh" && -d "$1/cmd" ]]; }

# _work_tree DIR — print the top of the git work tree DIR (or, while it does not exist, its
# nearest existing parent) is in; 1 when none. A .git found walking up counts even without git.
_work_tree() {
  local d=$1 top
  while [[ ! -d "$d" ]]; do d=$(dirname -- "$d"); done
  if command -v git >/dev/null && top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [[ -n "$top" ]]; then
    printf '%s\n' "$top"
    return 0
  fi
  d=$(cd -- "$d" && pwd -P)
  while :; do
    if [[ -e "$d/.git" ]]; then printf '%s\n' "$d"; return 0; fi
    [[ "$d" != / ]] || return 1
    d=$(dirname -- "$d")
  done
}

# _plain_path REL — REL is relative, has no "." or ".." part, and no symlinked folder leads to it
# inside $prefix (real path in $real), so acting on $prefix/REL stays inside $prefix.
_plain_path() {
  local rel=$1 dir want=$real
  [[ -n "$rel" && "/$rel/" != *//* && "/$rel/" != */./* && "/$rel/" != */../* ]] || return 1
  dir=$(dirname -- "$rel")
  [[ "$dir" == . ]] || want+="/$dir"
  [[ ! -e "$prefix/$dir" ]] || [[ "$(realpath -e -- "$prefix/$dir")" == "$want" ]]
}

# _owned — set owned to the files of the marmot copy in $prefix: its manifest's list or, for an
# install made before manifests, LEGACY_FILES when the folder holds nothing else. 1 when $prefix
# is no marmot install. Dies naming the reason when it cannot tell marmot's files from yours.
_owned() {
  local rel f other=() by_hand="remove marmot's own files from $prefix by hand (keeping yours) or set MARMOT_PREFIX"
  local -A known=()
  owned=()
  if [[ -f "$prefix/$manifest" ]]; then
    while IFS= read -r rel; do
      [[ -z "$rel" || "$rel" == '#'* ]] && continue
      _plain_path "$rel" || die "$prefix/$manifest lists '$rel', which is not a file inside $prefix; nothing removed: $by_hand"
      owned+=("$rel")
    done <"$prefix/$manifest"
    return 0
  fi
  _is_marmot_tree "$prefix" || return 1
  for f in "${LEGACY_DIRS[@]}"; do known[$f]="dir"; done
  for f in "${LEGACY_FILES[@]}"; do known[$f]="file"; done
  while IFS= read -r -d '' f; do
    rel=${f#"$prefix"/}
    if [[ -d "$f" && ! -L "$f" ]]; then
      [[ "${known[$rel]:-}" == dir ]] || other+=("$rel")
    elif [[ "${known[$rel]:-}" == file ]]; then
      owned+=("$rel")
    else
      other+=("$rel")
    fi
  done < <(find "$prefix" -mindepth 1 -print0)
  (( ${#other[@]} == 0 )) ||
    die "$prefix holds files marmot did not install (${other[*]:0:5}) and has no $manifest to tell them apart; nothing removed: $by_hand"
}

# _remove_owned — remove the files in owned, then the folders that leaves empty (deepest first),
# then the manifest. Nothing else in $prefix is touched.
_remove_owned() {
  local rel d p dirs=()
  local -A seen=()
  for rel in "${owned[@]}"; do
    p=$prefix/$rel
    if [[ -L "$p" || ( -e "$p" && ! -d "$p" ) ]]; then
      rm -f -- "$p"   # SAFE: a file the manifest (or the pre-manifest layout) says marmot copied, path checked by _plain_path
    fi
    d=$(dirname -- "$rel")
    while [[ "$d" != . && -z "${seen[$d]:-}" ]]; do seen[$d]=1; dirs+=("$d"); d=$(dirname -- "$d"); done
  done
  rm -f -- "${prefix:?}/$manifest"   # SAFE: marmot's own manifest
  (( ${#dirs[@]} )) || return 0
  while IFS= read -r d; do
    rmdir -- "$prefix/$d" 2>/dev/null || true   # SAFE: rmdir removes only an empty folder
  done < <(printf '%s\n' "${dirs[@]}" | LC_ALL=C sort -r)
}

# _foreign NAME — $bindir/NAME exists and is not a symlink to a marmot launcher.
_foreign() {
  local l="$bindir/$1"
  [[ -e "$l" || -L "$l" ]] && ! { [[ -L "$l" ]] && _is_marmot_tree "$(dirname "$(readlink -f "$l")")"; }
}

# _link NAME — point $bindir/NAME at this install unless _foreign; 1 (with a warning naming the
# file) when it was left alone.
_link() {
  local l="$bindir/$1"
  if _foreign "$1"; then
    warn "Kept $l: it is not a marmot launcher (remove or rename it to use $1)"
    return 1
  fi
  ln -sfn "$prefix/marmot" "$l" && ok "Linked $l"
}

# _path_hint — the line that puts $bindir on PATH, and the startup file it belongs in.
_path_hint() {
  local dir=$bindir rc=~/.profile
  [[ "$dir" == "$HOME"/* ]] && dir="\$HOME/${dir#"$HOME"/}"
  case "${SHELL:-}" in */zsh) rc=~/.zshrc ;; */bash) rc=~/.bashrc ;; esac
  warn "$bindir is not on your PATH. Add this line to $rc, then open a new shell:"
  printf '      export PATH="%s:$PATH"\n' "$dir" >&2
}

# _unschedule — remove the timer or crontab line `mm schedule enable` created, so nothing keeps
# calling a launcher that is about to go away.
_unschedule() {
  [[ -f "$prefix/marmot" ]] || return 0
  info "Disabling marmot's schedule (mm schedule disable):"
  bash "$prefix/marmot" schedule disable </dev/null || warn "Could not disable the schedule: run mm schedule disable before uninstalling"
}

uninstall() {
  local l keep="" top
  owned=()
  if [[ -L "$prefix" ]]; then
    keep="a symlink to $(readlink -f -- "$prefix"); remove the copy yourself"
  elif [[ ! -e "$prefix" ]]; then
    keep=none
  elif top=$(_work_tree "$prefix"); then
    keep="in the git checkout $top; remove it yourself if you want"
  else
    real=$(realpath -e -- "$prefix")
    _owned || keep=none   # dies, before anything changed, when marmot's files cannot be told apart
  fi
  _unschedule
  for l in "$bindir/mm" "$bindir/marmot"; do
    if [[ -L "$l" && "$(readlink -f "$l")" == "$prefix/marmot" ]]; then
      rm -f -- "$l" && ok "Removed $l"   # SAFE: our own launcher symlink, target verified
    fi
  done
  case "$keep" in
    "")
      _remove_owned
      if rmdir -- "$prefix" 2>/dev/null; then   # SAFE: rmdir removes only an empty folder
        ok "Removed $prefix"
      else
        ok "Removed marmot's files from $prefix; kept the rest (marmot did not install it)"
      fi ;;
    none) ;;
    *) info "Kept $prefix ($keep)" ;;
  esac
  info "Kept ${XDG_CONFIG_HOME:-~/.config}/marmot, ${XDG_STATE_HOME:-~/.local/state}/marmot and the Trash."
}

check() {
  [[ "$(uname -s)" == Linux ]] || die "marmot runs on Linux (Ubuntu/Debian)."
  (( BASH_VERSINFO[0] >= 5 )) || die "Bash 5.0 or newer is required (found $BASH_VERSION)."
  local c missing=()
  for c in find awk sed grep stat realpath du df; do command -v "$c" >/dev/null || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "Missing required tools: ${missing[*]}"
  command -v git >/dev/null || info "Git not found: everything works except mm update (install git and clone marmot to use it)."
  command -v apt-get >/dev/null || warn "No apt-get: system-package steps will be skipped (marmot targets Ubuntu/Debian)."
  local opt=() pkg=()
  command -v fzf >/dev/null      || { opt+=("fzf (pickers)"); pkg+=(fzf); }
  command -v ncdu >/dev/null     || { opt+=("ncdu (mm analyze PATH)"); pkg+=(ncdu); }
  command -v jq >/dev/null       || { opt+=("jq (--json output)"); pkg+=(jq); }
  command -v trash-restore >/dev/null || { opt+=("trash-cli (trash-restore)"); pkg+=(trash-cli); }
  if (( ${#opt[@]} )); then
    info "Optional tools missing (recommended):"
    printf '    %s\n' "${opt[@]}"
    info "  Install them with: sudo apt-get install ${pkg[*]}"
  fi
}

# record_source — write $prefix/.install-source: plain key=value lines (read, never sourced).
# commit is empty when this folder is not the top of a git checkout (a tarball or a copy).
record_source() {
  local commit="" describe="" bin
  bin=$(cd "$bindir" && pwd)
  if command -v git >/dev/null && [[ "$(git -C "$src" rev-parse --show-toplevel 2>/dev/null)" == "$src" ]]; then
    commit=$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null) || commit=""
    if [[ -n "$commit" ]]; then describe=$(git -C "$src" describe --tags --always --dirty 2>/dev/null) || describe=""; fi
  fi
  if [[ "$src$bin" == *$'\n'* ]]; then
    warn "Not recording the source folder (its path has a newline): mm update will not work"
    return 0
  fi
  printf 'source=%s\ncommit=%s\ndescribe=%s\nbin=%s\n' "$src" "$commit" "$describe" "$bin" >"$prefix/.install-source"
  if [[ -n "$commit" ]]; then ok "Recorded source $src at ${commit:0:7} (for mm update)"
  else warn "Recorded source $src: not a git checkout, so mm update needs a git clone"; fi
}

# write_manifest — list the copied files (files, from install) in $prefix/.install-manifest:
# written last and renamed into place, so a manifest always describes a finished copy.
write_manifest() {
  local tmp
  tmp=$(mktemp "$prefix/$manifest.XXXXXX")
  { echo "# Files install.sh copied here; a reinstall or install.sh --uninstall removes these only."
    printf '%s\n' "${files[@]}"; } >"$tmp"
  mv -f -- "$tmp" "$prefix/$manifest"
}

# _in_the_way — die, before anything changed, naming what in $prefix the copy would overwrite
# that is not marmot's: anything but a file in owned where a copied file (files) goes, anything
# but a plain folder where a copied folder (dirs) goes.
_in_the_way() {
  local f p blocked=()
  local -A mine=()
  for f in "${owned[@]}"; do mine[$f]=1; done
  for f in "${files[@]}"; do
    p=$prefix/$f
    if ! _plain_path "$f" ||
      [[ ( -e "$p" || -L "$p" ) && ( -z "${mine[$f]:-}" || ( -d "$p" && ! -L "$p" ) ) ]]; then
      blocked+=("$f")
    fi
  done
  for f in "${dirs[@]}"; do
    p=$prefix/$f
    if ! _plain_path "$f" || [[ -L "$p" || ( -e "$p" && ! -d "$p" ) ]]; then blocked+=("$f"); fi
  done
  (( ${#blocked[@]} == 0 )) ||
    die "$prefix already has ${blocked[*]:0:5}, which marmot did not install and would overwrite; nothing changed: move them away or set MARMOT_PREFIX"
}

# _finale — the first-run message: the marmot, three next steps, then the completion line for each
# shell whose rc file does not load it yet. Printed only: nothing is run, no rc file is written.
_finale() {
  cat <<'ART'
     _..--.._
  ()'        '()     marmot
   |  ^    ^  |      Keep the machines your coding agents
  .--.  \/  .--.     run on clean, fast and healthy.
--(mm)--UU--(mm)--------------------------------------------
ART
  say ""
  say "marmot is installed. Three next steps:"
  say "  1. mm clean --dry-run    preview: lists what mm clean would remove, deletes nothing"
  say "  2. mm status             see what the machine is doing"
  say "  3. mm schedule enable    clean up on a schedule"
  local bash_hint=1 zsh_hint=1
  grep -qsF -- "$prefix/completion" ~/.bashrc && bash_hint=0
  grep -qsF -- "$prefix/completion" ~/.zshrc && zsh_hint=0
  (( bash_hint || zsh_hint )) || return 0
  say ""
  say "Shell completion:"
  (( bash_hint )) && say "  bash: echo 'source $prefix/completion/mm.bash' >> ~/.bashrc"
  (( zsh_hint )) && say "  zsh:  echo 'fpath=($prefix/completion \$fpath)' >> ~/.zshrc   # before compinit"
  return 0
}

install() {
  check
  _foreign mm && die "$bindir/mm exists and is not a marmot launcher: move it away or set MARMOT_BIN, then run install.sh again"
  local copied=0 fresh=0 top f files=() dirs=()
  owned=()
  if [[ "$(readlink -f "$prefix" 2>/dev/null)" != "$src" ]]; then
    [[ ! -L "$prefix" ]] ||
      die "$prefix is a symlink (to $(readlink -f -- "$prefix")); not installing through it. Set MARMOT_PREFIX to a real folder."
    if top=$(_work_tree "$prefix"); then
      die "$prefix is in the git checkout $top; not installing there (it would replace that checkout's files). Set MARMOT_PREFIX to a folder outside it."
    fi
    while IFS= read -r -d '' f; do
      [[ "$f" != *$'\n'* ]] || die "$src/$f has a newline in its name; not installing"
      if [[ -d "$src/$f" && ! -L "$src/$f" ]]; then dirs+=("$f"); else files+=("$f"); fi
    done < <(cd "$src" && find "${PAYLOAD[@]}" -print0)
    files+=(.install-source)
    [[ -e "$prefix" ]] || fresh=1
    if [[ -e "$prefix" ]]; then
      real=$(realpath -e -- "$prefix")
      _owned || die "$prefix exists and is not a marmot install; set MARMOT_PREFIX."
      _in_the_way
      _remove_owned
    fi
    mkdir -p "$prefix"
    cp -R -- "${PAYLOAD[@]/#/$src/}" "$prefix/"
    ok "Installed to $prefix"
    copied=1
  fi
  mkdir -p "$bindir"
  if (( copied )); then record_source; write_manifest; fi
  _link mm
  _link marmot || true
  case ":$PATH:" in *":$bindir:"*) ;; *) _path_hint ;; esac
  if (( fresh )); then _finale; fi
}

case "${1:-}" in
  "") install ;;
  --uninstall) uninstall ;;
  -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "Unknown option: $1 (see --help)" ;;
esac
