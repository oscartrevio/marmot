# shellcheck shell=bash
# mm update [--check] — update marmot from the git checkout it was installed from.
# install.sh records that checkout in $MM_HOME/.install-source (key=value lines; read, never
# sourced). An update fetches the branch's upstream, shows what is new, fast-forwards the
# checkout to exactly the commit it showed, and re-runs the checkout's install.sh. Dirty or
# diverged checkouts, and ignored files the new commits would overwrite, are refused. --check,
# --dry-run and runs without a terminal only report.

_UPDATE_AVAILABLE=10   # report-mode exit status: an update is available
_UPDATE_SHOW=20        # new commits listed by subject

_update_usage() {
  cat <<EOF
Usage: mm update [--check | --dry-run]

Updates marmot from the git checkout it was installed from (install.sh records it): fetches
the branch's upstream, lists the new commits, and after you confirm on a terminal
fast-forwards the checkout and re-runs its install.sh. A checkout with uncommitted changes,
with local commits that diverge from upstream, or with ignored files the new commits would
overwrite is refused, with the reason.

  --check   Only report (fetches, changes nothing else). Exit 0: up to date,
            $_UPDATE_AVAILABLE: update available, other: error or refused.
  -n, --dry-run
            Same as --check.

Without a terminal, mm update behaves like --check. It needs git.
EOF
}

# _update_field KEY — KEY's value in this install's record (empty when absent).
_update_field() {
  [[ -f "$MM_HOME/.install-source" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$MM_HOME/.install-source"
}

# _update_is_checkout DIR — DIR is the top level of a git work tree that has a commit.
_update_is_checkout() {
  [[ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" == "$(realpath -e -- "$1" 2>/dev/null)" ]] &&
    git -C "$1" rev-parse -q --verify HEAD >/dev/null 2>&1
}

# _update_version — "marmot 0.2.0 (1a2b3c4)": the commit this copy was installed from, or HEAD
# when marmot runs straight from a git checkout; "-dirty" when it had uncommitted changes.
_update_version() {
  local commit describe=""
  commit=$(_update_field commit)
  if [[ -n "$commit" ]]; then
    describe=$(_update_field describe)
  elif [[ ! -f "$MM_HOME/.install-source" ]] && _update_is_checkout "$MM_HOME"; then
    commit=$(git -C "$MM_HOME" rev-parse HEAD 2>/dev/null)
    describe=$(git -C "$MM_HOME" describe --always --dirty 2>/dev/null)
  fi
  if [[ -n "$commit" ]]; then
    printf 'marmot %s (%s%s)\n' "$MM_VERSION" "${commit:0:7}" "$([[ "$describe" == *-dirty ]] && echo -dirty)"
  else
    printf 'marmot %s\n' "$MM_VERSION"
  fi
}

# _update_resolve — set _UP_SRC (the checkout), _UP_INSTALLED (commit of this copy), _UP_BIN
# (launcher dir) and _UP_INPLACE (1 when marmot runs from the checkout itself), or die saying why
# this install cannot be updated.
_update_resolve() {
  local rec="$MM_HOME/.install-source" clone="clone marmot with git and run ./install.sh from the clone"
  _UP_SRC="" _UP_INSTALLED="" _UP_BIN="" _UP_INPLACE=0
  if [[ -f "$rec" ]]; then
    _UP_SRC=$(_update_field source) _UP_INSTALLED=$(_update_field commit) _UP_BIN=$(_update_field bin)
    [[ -n "$_UP_SRC" ]] || mm_die "$rec names no source folder: $clone"
    [[ -n "$_UP_INSTALLED" ]] ||
      mm_die "marmot was installed from $_UP_SRC, which is not a git checkout (a release tarball or a copy), so mm update cannot fetch updates: $clone"
    [[ -d "$_UP_SRC" ]] || mm_die "marmot was installed from $_UP_SRC, which no longer exists: $clone"
    _update_is_checkout "$_UP_SRC" || mm_die "$_UP_SRC is no longer a git checkout: $clone"
  elif _update_is_checkout "$MM_HOME"; then
    _UP_SRC=$MM_HOME _UP_INPLACE=1
  else
    mm_die "no record of where marmot was installed from ($rec is missing): $clone"
  fi
}

# _update_have_flock — separate so tests can take the mkdir fallback.
_update_have_flock() { command -v flock >/dev/null; }

# _update_lock — one update at a time: flock on $MM_STATE_DIR/update.lock, or where flock is
# missing an atomic mkdir of update.lock.d, removed on exit.
_update_lock() {
  local lock="$MM_STATE_DIR/update.lock"
  mkdir -p "$MM_STATE_DIR" || mm_die "cannot create $MM_STATE_DIR"
  if _update_have_flock; then
    exec {_UPDATE_LOCK_FD}>>"$lock" || mm_die "cannot open $lock"
    flock -n "$_UPDATE_LOCK_FD" || mm_die "another mm update is running (lock: $lock)"
  else
    mkdir -- "$lock.d" 2>/dev/null ||
      mm_die "another mm update is running (lock: $lock.d; remove that folder if none is)"
    _UPDATE_LOCK_DIR="$lock.d"
    trap _update_unlock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
}
_update_unlock() { rmdir -- "$_UPDATE_LOCK_DIR" 2>/dev/null; }   # SAFE: the empty lock dir this run created

# _update_nolock CMD... — run CMD without the flock descriptor, so a process it leaves behind
# (git's background maintenance) cannot hold the lock after this run ends.
_update_nolock() {
  if [[ -n "${_UPDATE_LOCK_FD:-}" ]]; then "$@" {_UPDATE_LOCK_FD}>&-; else "$@"; fi
}

_update_git() { _update_nolock git -C "$_UP_SRC" "$@"; }

# _update_ignored_clash TARGET — print the ignored files in the checkout that a fast-forward to
# TARGET would overwrite or delete (git merge treats ignored files as expendable): one at a path
# TARGET adds or changes, below such a path, or a file where TARGET needs a folder. 1 when git
# cannot list either side.
_update_ignored_clash() {
  local f d
  local -A changed=() ignored=()
  while IFS= read -r -d '' f; do changed[$f]=1; done < <(git -C "$_UP_SRC" diff --name-only --no-renames -z HEAD "$1")
  wait "$!" || return 1
  while IFS= read -r -d '' f; do ignored[$f]=1; done < <(git -C "$_UP_SRC" ls-files -z -o -i --exclude-standard)
  wait "$!" || return 1
  for f in "${!ignored[@]}"; do
    d=$f
    while [[ -z "${changed[$d]:-}" && "$d" == */* ]]; do d=${d%/*}; done
    if [[ -n "${changed[$d]:-}" ]]; then printf '%s\n' "$f"; fi
  done
  for f in "${!changed[@]}"; do
    d=$f
    while [[ "$d" == */* ]]; do
      d=${d%/*}
      if [[ -n "${ignored[$d]:-}" ]]; then printf '%s\n' "$d"; fi
    done
  done
}

# _update_changelog FROM TO — the CHANGELOG.md bullets that the range FROM..TO adds, indented; the
# first _UPDATE_SHOW, then "… and N more". Prints nothing when the range leaves the file alone.
_update_changelog() {
  git -C "$_UP_SRC" diff --unified=0 "$1" "$2" -- CHANGELOG.md 2>/dev/null |
    awk -v show="$_UPDATE_SHOW" '
      /^\+- / { on = 1; n++; if (n <= show) print "    " substr($0, 2); next }
      /^\+  / { if (on && n <= show) print "    " substr($0, 2); next }
      { on = 0 }
      END { if (n > show) printf "    … and %d more\n", n - show }'
}

mm_cmd_main() {
  local report=""
  while (( $# )); do
    case "$1" in
      --check) report=check ;;
      -h|--help) _update_usage; return 0 ;;
      *) mm_die "unknown option: $1 (see mm update --help)" ;;
    esac
    shift
  done
  command -v git >/dev/null || mm_die "git is not installed, and mm update needs it: sudo apt-get install git"
  [[ -z "$report" && "$MM_DRY_RUN" == 1 ]] && report="dry run"
  [[ -z "$report" && "$MM_TTY" != 1 ]] && report="no terminal"
  # Nobody can answer a credential prompt without a terminal: fail instead of hanging.
  [[ "$MM_TTY" == 1 ]] || export GIT_TERMINAL_PROMPT=0

  _update_resolve
  _update_lock

  local branch upstream
  branch=$(git -C "$_UP_SRC" symbolic-ref -q --short HEAD) ||
    mm_die "$_UP_SRC is on a detached HEAD: check out a branch there, then run mm update"
  upstream=$(git -C "$_UP_SRC" rev-parse -q --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) ||
    mm_die "branch $branch in $_UP_SRC tracks no upstream: git -C '$_UP_SRC' branch --set-upstream-to=<remote>/<branch>"

  mm_header "marmot update"
  mm_info "Checkout: $_UP_SRC ($branch, tracking $upstream)"
  _update_git fetch --quiet || mm_die "git fetch failed in $_UP_SRC; nothing changed"

  local head target ahead="" behind=""
  head=$(git -C "$_UP_SRC" rev-parse HEAD) target=$(git -C "$_UP_SRC" rev-parse '@{upstream}') ||
    mm_die "cannot read $upstream in $_UP_SRC"
  read -r ahead behind < <(git -C "$_UP_SRC" rev-list --left-right --count "HEAD...$target")
  [[ "$ahead" =~ ^[0-9]+$ && "$behind" =~ ^[0-9]+$ ]] || mm_die "cannot compare $branch with $upstream"

  if (( _UP_INPLACE )); then
    mm_info "Installed: runs from this checkout, at ${head:0:7}"
  else
    mm_info "Installed: $MM_HOME, at ${_UP_INSTALLED:0:7} (checkout at ${head:0:7})"
  fi
  if (( ahead > 0 && behind > 0 )); then
    mm_die "$branch has diverged from $upstream ($ahead local commit(s) not upstream, $behind upstream commit(s) not local): reconcile it in $_UP_SRC (git pull --rebase, or reset to $upstream), then run mm update"
  fi
  (( ahead > 0 )) && mm_info "$ahead local commit(s) not on $upstream: kept"
  if (( behind > 0 )); then
    mm_info "$behind new commit(s) on $upstream:"
    git -C "$_UP_SRC" log --no-decorate --format='%h %s' -n "$_UPDATE_SHOW" "HEAD..$target" | sed 's/^/    /'
    (( behind > _UPDATE_SHOW )) && mm_info "  … and $((behind - _UPDATE_SHOW)) more"
    local notes
    notes=$(_update_changelog "$head" "$target")
    if [[ -n "$notes" ]]; then mm_info "CHANGELOG.md in that range:"; printf '%s\n' "$notes"; fi
  fi

  # The install can lag the checkout (pulled by hand, not reinstalled): reinstalling catches up.
  local stale=0
  (( ! _UP_INPLACE )) && [[ "$_UP_INSTALLED" != "$head" ]] && stale=1
  if (( behind == 0 && ! stale )); then
    mm_ok "marmot is up to date" "${head:0:7}"
    return 0
  fi
  (( behind == 0 )) && mm_info "The installed copy is not the checkout's ${head:0:7}: a reinstall brings it there"

  local dirty
  dirty=$(git -C "$_UP_SRC" status --porcelain --untracked-files=no 2>/dev/null)
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" | head -5 | sed 's/^/    /'
    mm_die "$_UP_SRC has uncommitted changes: commit or stash them, then run mm update"
  fi
  if (( behind > 0 )); then
    local clash
    clash=$(_update_ignored_clash "$target") || mm_die "cannot list the files $upstream changes in $_UP_SRC; nothing changed"
    if [[ -n "$clash" ]]; then
      printf '%s\n' "$clash" | head -5 | sed 's/^/    /'
      mm_die "$upstream adds or changes files you keep ignored in $_UP_SRC, and the fast-forward would overwrite them: move them out of the checkout, then run mm update"
    fi
  fi

  local want=$head; (( behind > 0 )) && want=$target
  if [[ -n "$report" ]]; then
    case "$report" in
      "dry run") mm_act "Would fast-forward $_UP_SRC to ${want:0:7} and reinstall" ;;
      "no terminal") mm_warn "Update available; not applied without a terminal (run mm update in one)" ;;
      *) mm_warn "Update available: run mm update" ;;
    esac
    return "$_UPDATE_AVAILABLE"
  fi
  if ! mm_confirm "Update marmot to ${want:0:7}?"; then
    mm_info "Nothing changed."
    return 0
  fi

  if (( behind > 0 )); then
    # The commit shown above, not whatever a second fetch would bring.
    mm_run "fast-forward $_UP_SRC to ${want:0:7}" _update_git merge --ff-only --quiet "$want" ||
      mm_die "fast-forward failed; marmot was not reinstalled"
    mm_ok "Checkout fast-forwarded" "${head:0:7} → ${want:0:7}"
  fi
  if (( _UP_INPLACE )); then
    mm_ok "marmot updated in place" "${want:0:7}"
    return 0
  fi
  local env=(MARMOT_PREFIX="$MM_HOME"); [[ -n "$_UP_BIN" ]] && env+=(MARMOT_BIN="$_UP_BIN")
  mm_run "reinstall marmot from $_UP_SRC" _update_nolock env "${env[@]}" bash "$_UP_SRC/install.sh" ||
    mm_die "reinstall failed: run $_UP_SRC/install.sh yourself"
  local now; now=$(_update_field commit)
  [[ "$now" == "$want" ]] || mm_die "reinstall recorded ${now:-no commit}, expected ${want:0:7}: run $_UP_SRC/install.sh yourself"
  mm_ok "marmot updated" "${_UP_INSTALLED:0:7} → ${want:0:7}"
}
