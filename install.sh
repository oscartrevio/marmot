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
set -euo pipefail

src=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
prefix=${MARMOT_PREFIX:-$HOME/.local/share/marmot}
bindir=${MARMOT_BIN:-$HOME/.local/bin}

say()  { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# _is_marmot_tree DIR — DIR looks like a marmot install (guards every removal below).
_is_marmot_tree() { [[ -f "$1/marmot" && -f "$1/lib/core.sh" && -d "$1/cmd" ]]; }

# _is_checkout DIR — DIR holds git metadata: never removed, whoever asks.
_is_checkout() { [[ -e "$1/.git" ]]; }

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
    warn "kept $l: it is not a marmot launcher (remove or rename it to use $1)"
    return 1
  fi
  ln -sfn "$prefix/marmot" "$l" && say "linked $l"
}

# _path_hint — the line that puts $bindir on PATH, and the startup file it belongs in.
_path_hint() {
  local dir=$bindir rc=~/.profile
  [[ "$dir" == "$HOME"/* ]] && dir="\$HOME/${dir#"$HOME"/}"
  case "${SHELL:-}" in */zsh) rc=~/.zshrc ;; */bash) rc=~/.bashrc ;; esac
  warn "$bindir is not on your PATH. Add this line to $rc, then open a new shell:"
  printf '    export PATH="%s:$PATH"\n' "$dir" >&2
}

# _unschedule — remove the timer or crontab line `mm schedule enable` created, so nothing keeps
# calling a launcher that is about to go away.
_unschedule() {
  [[ -f "$prefix/marmot" ]] || return 0
  say "disabling marmot's schedule (mm schedule disable):"
  bash "$prefix/marmot" schedule disable </dev/null || warn "could not disable the schedule: run mm schedule disable before uninstalling"
}

uninstall() {
  local l
  _unschedule
  for l in "$bindir/mm" "$bindir/marmot"; do
    if [[ -L "$l" && "$(readlink -f "$l")" == "$prefix/marmot" ]]; then
      rm -f -- "$l" && say "removed $l"   # SAFE: our own launcher symlink, target verified
    fi
  done
  if _is_marmot_tree "$prefix"; then
    if _is_checkout "$prefix"; then
      say "kept $prefix (a git checkout; remove it yourself if you want)"
    else
      rm -rf -- "$prefix" && say "removed $prefix"   # SAFE: verified marmot install, not a git checkout
    fi
  fi
  say "Kept: ${XDG_CONFIG_HOME:-~/.config}/marmot, ${XDG_STATE_HOME:-~/.local/state}/marmot and the Trash."
}

check() {
  [[ "$(uname -s)" == Linux ]] || die "marmot runs on Linux (Ubuntu/Debian)."
  (( BASH_VERSINFO[0] >= 5 )) || die "bash 5.0 or newer is required (found $BASH_VERSION)."
  local c missing=()
  for c in find awk sed grep stat realpath du df; do command -v "$c" >/dev/null || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing required tools: ${missing[*]}"
  command -v git >/dev/null || say "git not found: everything works except mm update (install git and clone marmot to use it)."
  command -v apt-get >/dev/null || warn "no apt-get: system-package steps will be skipped (marmot targets Ubuntu/Debian)."
  local opt=()
  command -v fzf >/dev/null      || opt+=("fzf (pickers)")
  command -v ncdu >/dev/null     || opt+=("ncdu (mm analyze PATH)")
  command -v jq >/dev/null       || opt+=("jq (--json output)")
  command -v trash-restore >/dev/null || opt+=("trash-cli (trash-restore)")
  (( ${#opt[@]} == 0 )) || say "Optional, recommended: sudo apt-get install fzf ncdu jq trash-cli   # ${opt[*]}"
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
    warn "not recording the source folder (its path has a newline): mm update will not work"
    return 0
  fi
  printf 'source=%s\ncommit=%s\ndescribe=%s\nbin=%s\n' "$src" "$commit" "$describe" "$bin" >"$prefix/.install-source"
  if [[ -n "$commit" ]]; then say "recorded source $src at ${commit:0:7} (for mm update)"
  else say "recorded source $src (not a git checkout: mm update needs a git clone)"; fi
}

install() {
  check
  _foreign mm && die "$bindir/mm exists and is not a marmot launcher: move it away or set MARMOT_BIN, then run install.sh again"
  local copied=0
  if [[ "$(readlink -f "$prefix" 2>/dev/null)" != "$src" ]]; then
    if [[ -e "$prefix" ]]; then
      _is_marmot_tree "$prefix" || die "$prefix exists and is not a marmot install; set MARMOT_PREFIX."
      _is_checkout "$prefix" && die "$prefix is a git checkout; not replacing it. Set MARMOT_PREFIX to install elsewhere, or remove it yourself."
      rm -rf -- "$prefix"   # SAFE: verified marmot tree and not a git checkout, replaced by this checkout
    fi
    mkdir -p "$prefix"
    # Only what runs: the launcher, libraries, commands, completion, and this installer (for
    # --uninstall). Tests and git metadata stay in the checkout.
    cp -R -- "$src/marmot" "$src/install.sh" "$src/lib" "$src/cmd" "$src/completion" "$prefix/"
    say "installed to $prefix"
    copied=1
  fi
  mkdir -p "$bindir"
  if (( copied )); then record_source; fi
  _link mm
  _link marmot || true
  case ":$PATH:" in *":$bindir:"*) ;; *) _path_hint ;; esac
  say ""
  say "Shell completion:"
  say "  bash: echo 'source $prefix/completion/mm.bash' >> ~/.bashrc"
  say "  zsh:  echo 'fpath=($prefix/completion \$fpath)' >> ~/.zshrc   # before compinit"
  say ""
  say "Start with a preview:  mm clean --dry-run"
}

case "${1:-}" in
  "") install ;;
  --uninstall) uninstall ;;
  -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown option: $1 (see --help)" ;;
esac
