#!/usr/bin/env bash
# Install marmot for the current user (no root needed).
#
#   ./install.sh               install or update from this checkout
#   ./install.sh --uninstall   remove the launchers and the installed copy; keeps your config,
#                              history, and anything marmot moved to the Trash
#
# Installs to ${MARMOT_PREFIX:-~/.local/share/marmot} and links `mm` and `marmot` into
# ${MARMOT_BIN:-~/.local/bin}. Running it from the install directory itself only (re)creates links.
set -euo pipefail

src=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
prefix=${MARMOT_PREFIX:-$HOME/.local/share/marmot}
bindir=${MARMOT_BIN:-$HOME/.local/bin}

say()  { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# _is_marmot_tree DIR — DIR looks like a marmot install (guards every removal below).
_is_marmot_tree() { [[ -f "$1/marmot" && -f "$1/lib/core.sh" && -d "$1/cmd" ]]; }

uninstall() {
  local l
  for l in "$bindir/mm" "$bindir/marmot"; do
    if [[ -L "$l" && "$(readlink -f "$l")" == "$prefix/marmot" ]]; then
      rm -f -- "$l" && say "removed $l"   # SAFE: our own launcher symlink, target verified
    fi
  done
  if _is_marmot_tree "$prefix"; then
    if [[ -e "$prefix/.git" ]]; then
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
  for c in find awk sed grep stat realpath du df git; do command -v "$c" >/dev/null || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing required tools: ${missing[*]}"
  command -v apt-get >/dev/null || warn "no apt-get: system-package steps will be skipped (marmot targets Ubuntu/Debian)."
  local opt=()
  command -v fzf >/dev/null      || opt+=("fzf (pickers)")
  command -v ncdu >/dev/null     || opt+=("ncdu (mm analyze PATH)")
  command -v jq >/dev/null       || opt+=("jq (--json output)")
  command -v trash-restore >/dev/null || opt+=("trash-cli (trash-restore)")
  (( ${#opt[@]} == 0 )) || say "Optional, recommended: sudo apt-get install fzf ncdu jq trash-cli   # ${opt[*]}"
}

install() {
  check
  if [[ "$(readlink -f "$prefix" 2>/dev/null)" != "$src" ]]; then
    if [[ -e "$prefix" ]]; then
      _is_marmot_tree "$prefix" || die "$prefix exists and is not a marmot install; set MARMOT_PREFIX."
      rm -rf -- "$prefix"   # SAFE: verified marmot tree, replaced by this checkout
    fi
    mkdir -p "$prefix"
    # Only what runs: the launcher, libraries, commands, completion, and this installer (for
    # --uninstall). Tests and git metadata stay in the checkout.
    cp -R -- "$src/marmot" "$src/install.sh" "$src/lib" "$src/cmd" "$src/completion" "$prefix/"
    say "installed to $prefix"
  fi
  mkdir -p "$bindir"
  ln -sfn "$prefix/marmot" "$bindir/mm"
  ln -sfn "$prefix/marmot" "$bindir/marmot"
  say "linked $bindir/mm and $bindir/marmot"
  case ":$PATH:" in *":$bindir:"*) ;; *) warn "$bindir is not on your PATH; add it to your shell profile." ;; esac
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
  -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown option: $1 (see --help)" ;;
esac
