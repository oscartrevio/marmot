# shellcheck shell=bash
# mm purge [DIR...] [--days N] [--all] [--yes] [--paths] — remove abandoned git worktrees and
# rebuildable build artifacts (node_modules, .next, target, venvs...) from idle projects.
#
# Where it looks: DIR arguments; else the roots listed in purge_paths; else discovery: $HOME
# (dot-dirs, ~/snap, the Go module cache, conda installs and site-packages skipped) plus every
# git worktree registered to a repository found there, wherever it lives (agents keep them in
# ~/.cursor/worktrees, ~/.codex/worktrees, <repo>/.claude/worktrees, ...), plus the worktrees in
# the agents' worktree dirs (lib/agents.sh) and the other worktrees of their repositories.

MM_PURGE_PATHS_FILE="${MM_PURGE_PATHS_FILE:-$MM_CONFIG_DIR/purge_paths}"

_PURGE_PATHS_TEMPLATE='# marmot purge: project roots to scan, one per line; ~ expands; # starts a comment.
# While this file lists at least one directory, `mm purge` scans ONLY those roots: automatic
# discovery (your home directory plus every git worktree registered to a repository found
# there) is switched off. Remove every entry, or delete this file, to go back to discovery.
# `mm purge DIR...` overrides both for a single run. Examples:
#   ~/projects
#   /srv/work
'

# Always rebuildable: pruned at the match, never descended into.
_PURGE_TARGETS=(node_modules .next .nuxt .output .turbo .parcel-cache .svelte-kit .astro .angular
  .expo .vite coverage __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .nox .gradle
  .terragrunt-cache .dart_tool .zig-cache zig-out .cxx)
# Only rebuildable next to the right manifest; validated after the scan.
_PURGE_CONDITIONAL=(target build dist venv .venv vendor)
# Never descended into: installed packages, not projects.
_PURGE_SKIP_NAMES=(site-packages dist-packages)
# Below $HOME (besides dot-dirs): snap app data, the Go module cache, conda installs.
_PURGE_SKIP_HOME=(snap go/pkg anaconda3 miniconda3 miniforge3 mambaforge micromamba)
_PURGE_MAXDEPTH=8
_PURGE_SCAN_TIMEOUT=60
_PURGE_GIT_TIMEOUT=20
# Worktrees: a finished one (its work landed) is offered once idle this many seconds; an unmerged
# one only after this many days. Branches are kept either way.
_PURGE_WT_FINISHED_IDLE=3600
_PURGE_WT_UNMERGED_DAYS=30
# gh (pull request state): per-call time limit; _PURGE_GH caches "logged in" for one run.
_PURGE_GH_TIMEOUT=10
_PURGE_GH=""

_purge_usage() {
  cat <<EOF
Usage: mm purge [DIR...] [options]

1. Finished and abandoned git worktrees: linked worktrees that git reports clean (no untracked
   files either), that are not locked or in use, and whose commits are on a branch or tag.
   Finished ones are offered once idle 1+ hour: the branch is merged into the default branch
   (also squash- or rebase-merged), its upstream branch was deleted, or its pull request is
   merged or closed (asked through gh when it is installed and logged in). Unmerged ones after
   ${_PURGE_WT_UNMERGED_DAYS}+ idle days. Removed with \`git worktree remove\` (never --force; the branch is kept),
   only after you confirm on a terminal.
2. Build artifacts (node_modules, .next, target, dist, venvs, caches). Projects idle longer
   than --days are selected by default. Never touched: projects with a running process inside
   them, anything git tracks, and anything whose git state can't be read. Virtualenvs (venv,
   .venv) go to the Trash; everything else is deleted permanently.

Sizes: FREES is what a delete really releases. Files hard-linked from elsewhere (pnpm's store)
stay on disk, so after removing pnpm-installed node_modules or worktrees marmot runs
\`pnpm store prune\` (unless pnpm is running) and reports what that freed.

Where it looks: the DIRs given; else the roots in $MM_PURGE_PATHS_FILE;
else your home directory plus every git worktree registered to a repository found there or
found in a coding agent's worktree folder (~/.cursor/worktrees, ~/.t3/worktrees, ...).

Options:
  --days N       Artifact idle threshold in days (default 14)
  --all          Also select recently active projects by default (terminal only)
  -y, --yes      Unattended: purge the stale artifacts only (never removes worktrees)
  --paths        Edit the scan roots in \$EDITOR (creates the file)
  -n, --dry-run  Show what would be removed
  -h, --help     This help
EOF
}

# _purge_listed_roots — the roots listed in purge_paths (~ expanded), one per line; nothing when
# the file does not exist.
_purge_listed_roots() {
  [[ -f "$MM_PURGE_PATHS_FILE" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"; line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    [[ "$line" == "~"* ]] && line="$HOME${line:1}"
    printf '%s\n' "$line"
  done <"$MM_PURGE_PATHS_FILE"
}

# _purge_in_dotdir PATH — 0 if PATH is a $HOME/.<name> dir or inside one.
_purge_in_dotdir() { [[ "$1" == "$HOME"/.* ]]; }

# _purge_covered PATH ROOT... — 0 if scanning ROOTs reaches PATH ($HOME dot-dirs are only reached
# from a root inside them).
_purge_covered() {
  local p="$1" r; shift
  for r in "$@"; do
    [[ "$p" == "$r" || "$p" == "$r"/* ]] || continue
    if _purge_in_dotdir "$p" && ! _purge_in_dotdir "$r"; then continue; fi
    return 0
  done
  return 1
}

# _purge_scan ROOT... — NUL-separated records, artifacts shallowest first:
#   A<TAB>depth<TAB>path  candidate artifact dir (unvalidated)
#   G<TAB>0<TAB>path      a .git entry (repository or worktree)
#   T<TAB>0<TAB>root      the scan of root hit the time limit (results partial)
_purge_scan() {
  local -a always=() cond=() skip=()
  local n root p
  for n in "${_PURGE_TARGETS[@]}"; do always+=(-o -name "$n"); done
  for n in "${_PURGE_CONDITIONAL[@]}"; do cond+=(-o -name "$n"); done
  for root in "$@"; do
    skip=()
    for n in "${_PURGE_SKIP_NAMES[@]}"; do skip+=(-o -name "$n"); done
    for n in "${_PURGE_SKIP_HOME[@]}"; do p="$HOME/$n"; [[ "$p" == "$root"/* ]] && skip+=(-o -path "$p"); done
    _purge_in_dotdir "$root" || skip+=(-o -path "$HOME/.*")
    timeout "$_PURGE_SCAN_TIMEOUT" find "$root" -xdev -maxdepth "$_PURGE_MAXDEPTH" \
      \( "${skip[@]:1}" \) -prune \
      -o -name .git -printf 'G\t0\t%p\0' -prune \
      -o -type d \( "${always[@]:1}" \) -printf 'A\t%d\t%p\0' -prune \
      -o -type d \( "${cond[@]:1}" \) -printf 'A\t%d\t%p\0' 2>/dev/null
    (( $? == 124 )) && printf 'T\t0\t%s\0' "$root"
  done | sort -z -s -n -t$'\t' -k2,2
}

# _purge_known NAME — 0 if NAME is one of the artifact names purge targets.
_purge_known() {
  local n
  for n in "${_PURGE_TARGETS[@]}" "${_PURGE_CONDITIONAL[@]}"; do [[ "$1" == "$n" ]] && return 0; done
  return 1
}

# _purge_gitcmd ARGS... — bounded, read-only-friendly git: inherited routing/pathspec variables
# are dropped so the repository's own index answers, optional locks are off (status never
# rewrites the index, so idle times stay true), and fsmonitor hooks never run. Returns git's
# status (124 on timeout).
_purge_gitcmd() {
  timeout "$_PURGE_GIT_TIMEOUT" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_LITERAL_PATHSPECS -u GIT_GLOB_PATHSPECS -u GIT_NOGLOB_PATHSPECS -u GIT_ICASE_PATHSPECS \
    GIT_OPTIONAL_LOCKS=0 git --no-optional-locks -c core.fsmonitor=false "$@" 2>/dev/null
}
# _purge_git DIR ARGS... — _purge_gitcmd run in DIR.
_purge_git() { local d="$1"; shift; _purge_gitcmd -C "$d" "$@"; }

# _purge_repo_of DIR — nearest ancestor-or-self holding a .git entry (up to /); 1 if none.
_purge_repo_of() {
  local d="$1"
  while [[ "$d" == /?* ]]; do
    [[ -e "$d/.git" || -L "$d/.git" ]] && { printf '%s' "$d"; return 0; }
    d="${d%/*}"
  done
  [[ -e /.git ]] && { printf '/'; return 0; }
  return 1
}

# _purge_tracked PATH — tri-state git probe (Mole's mole_path_has_git_tracked_files):
# 0 git tracks files under PATH, 1 no repository owns PATH or it tracks nothing there,
# 2 the probe failed or timed out (state unknown: callers must keep PATH).
_purge_tracked() {
  local path="$1" repo rel out rc=0
  repo=$(_purge_repo_of "$path") || return 1
  rel="${path#"$repo"/}"; [[ "$repo" == / ]] && rel="${path#/}"
  out=$(_purge_git "$repo" ls-files -- ":(top,literal)$rel") || rc=$?
  (( rc == 0 )) || return 2
  [[ -n "$out" ]] && return 0
  return 1
}

# _purge_ignored DIR NAME — 0 git ignores DIR/NAME, 1 not ignored or no repository, 2 unknown.
_purge_ignored() {
  local rc=0
  _purge_repo_of "$1" >/dev/null || return 1
  _purge_git "$1" check-ignore -q -- "$2" || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# _purge_valid ARTIFACT ROOT... — 0 purgeable, 1 not an artifact (ignored silently), 2 keep and
# say so (git state unknown). Rules: absolute, no control characters, a known artifact name, a
# real directory (not a symlink), not a repository itself, not inside a $HOME dot-dir no ROOT
# points into, the name-specific manifest rule, and nothing under it tracked by git.
_purge_valid() {
  local art="$1" proj="${1%/*}" name="${1##*/}" rc; shift
  _PURGE_WHY=""
  [[ "$art" == /?*/?* && "$art" != *[[:cntrl:]]* ]] || return 1
  _purge_known "$name" || return 1
  [[ -d "$art" && ! -L "$art" ]] || return 1
  [[ -e "$art/.git" || -L "$art/.git" ]] && return 1 # a repository: never an artifact
  _purge_covered "$art" "$@" || return 1
  case "$name" in
    target) [[ -f "$proj/Cargo.toml" || -f "$proj/pom.xml" ]] || return 1 ;;
    build|dist)
      [[ -f "$proj/package.json" || -f "$proj/pyproject.toml" || -f "$proj/build.gradle" ||
         -f "$proj/build.gradle.kts" ]] || return 1
      rc=0; _purge_ignored "$proj" "$name" || rc=$?
      case "$rc" in 0) ;; 1) return 1 ;; *) _PURGE_WHY="could not verify git state"; return 2 ;; esac ;;
    venv|.venv) [[ -f "$art/pyvenv.cfg" ]] || return 1 ;;
    vendor) [[ -f "$proj/composer.json" ]] || return 1 ;;
  esac
  rc=0; _purge_tracked "$art" || rc=$?
  case "$rc" in
    0) mm_debug "tracked by git, kept: $art"; return 1 ;;
    1) return 0 ;;
    *) _PURGE_WHY="could not verify git state"; return 2 ;;
  esac
}

# _purge_gitroot DIR — nearest ancestor-or-self holding .git, below $HOME (a dotfiles repo at
# $HOME must not group every project together); empty if none.
_purge_gitroot() {
  local d="$1"
  while [[ "$d" == /?* && "$d" != "$HOME" ]]; do
    [[ -e "$d/.git" ]] && { printf '%s' "$d"; return; }
    d="${d%/*}"
  done
}

# _purge_gitdir_of WORKTREE — the per-worktree git dir (WORKTREE/.git, or where its .git file
# points); 1 if it can't be resolved.
_purge_gitdir_of() {
  local e="$1/.git" gd
  if [[ -d "$e" && ! -L "$e" ]]; then printf '%s' "$e"; return 0; fi
  [[ -f "$e" && ! -L "$e" ]] || return 1
  gd=$(sed -n '1s/^gitdir: //p' -- "$e" 2>/dev/null)
  [[ -n "$gd" ]] || return 1
  [[ "$gd" == /* ]] || gd="$1/$gd"
  [[ -d "$gd" ]] || return 1
  printf '%s' "$gd"
}

# _purge_common_dir GITENTRY — absolute common git dir of the repository a .git entry belongs to
# (a worktree's .git file leads to <repo>/.git/worktrees/<name>, whose commondir leads home).
_purge_common_dir() {
  local gd c
  gd=$(_purge_gitdir_of "${1%/.git}") || return 1
  c="$gd"
  if [[ -f "$gd/commondir" ]]; then
    c=$(<"$gd/commondir")
    [[ "$c" == /* ]] || c="$gd/$c"
  fi
  realpath -e -- "$c" 2>/dev/null
}

# _purge_agent_worktrees — NUL-separated .git files of linked worktrees found in the agents'
# worktree dirs (lib/agents.sh). The dirs only say where to look: a worktree is a directory whose
# .git file points into a repository's worktrees dir (<repo>/.git/worktrees/<name>, or
# <bare-repo>/worktrees/<name>) holding a commondir file.
_purge_agent_worktrees() {
  local d f gd
  while IFS= read -r d; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    while IFS= read -r -d '' f; do
      gd=$(_purge_gitdir_of "${f%/.git}") || continue
      [[ "$gd" == */worktrees/?* && -f "$gd/commondir" ]] && printf '%s\0' "$f"
    done < <(timeout "$_PURGE_SCAN_TIMEOUT" find "$d" -xdev -mindepth 2 -maxdepth 6 \
      \( -name node_modules -o -name .git -type d \) -prune -o -name .git -type f -print0 2>/dev/null)
  done < <(mm_agent_worktree_dirs)
}

# _purge_in_agent_wtdir PATH — 0 if PATH lies inside one of the agents' worktree dirs.
_purge_in_agent_wtdir() {
  local d
  while IFS= read -r d; do [[ "$1" == "$d"/* ]] && return 0; done < <(mm_agent_worktree_dirs)
  return 1
}

# _purge_activity DIR [GITROOT] — epoch of the newest mtime among DIR, its top-level files, and
# the git index/HEAD of DIR's repository (worktree .git files are followed to their gitdir).
# Prints nothing when the repository's git dir can't be resolved (activity unknown).
_purge_activity() {
  local dir="$1" git="${2:-}" gd newest
  local -a probes=()
  if [[ -n "$git" ]]; then
    gd=$(_purge_gitdir_of "$git") || return 0
    [[ -f "$git/.git" ]] && probes+=("$git/.git")
    probes+=("$gd/index" "$gd/HEAD")
  fi
  newest=$({
    find "$dir" -maxdepth 1 \( -type f -o -path "$dir" \) -printf '%T@\n' 2>/dev/null
    (( ${#probes[@]} )) && stat -c %Y -- "${probes[@]}" 2>/dev/null
  } | sort -n | tail -n1)
  printf '%s' "${newest%.*}"
}

# _purge_busy PATH... — the given paths that are in use (or have something in use below them),
# per one pass over the in-use snapshot.
_purge_busy() {
  (( $# )) || return 0
  printf '%s\n' "$@" | awk 'NR == FNR { q[$0] = 1; next }
    { p = $0; while (p != "") { if (p in q) print p; if (!sub(/\/[^\/]*$/, "", p)) break } }' \
    - <(mm_inuse_paths) | sort -u
}

# _purge_measure PATH... — NUL-separated "size<TAB>frees<TAB>has_git<TAB>path" per artifact (see
# mm_size_frees), 4 in parallel. has_git=1 when a .git entry exists anywhere inside (a nested
# repository: never purged).
_purge_measure() {
  (
    export -f mm_size_frees
    printf '%s\0' "$@" | xargs -0 -P4 -n1 bash -c '
      g=$(find "$1" -xdev -mindepth 1 -name .git -print -quit 2>/dev/null)
      read -r s f < <(mm_size_frees "$1")
      printf "%s\t%s\t%s\t%s\0" "${s:-0}" "${f:-0}" "${g:+1}" "$1"' _
  )
}

_purge_age() {
  local d=$1
  if (( d < 1 )); then echo "<1d"
  elif (( d < 60 )); then echo "${d}d"
  elif (( d < 730 )); then echo "$(( d / 30 ))mo"
  else echo "$(( d / 365 ))y"; fi
}

# _purge_idle_label SECONDS — "5h" under a day, else like _purge_age.
_purge_idle_label() {
  if (( $1 < 86400 )); then echo "$(( $1 / 3600 ))h"; else _purge_age $(( $1 / 86400 )); fi
}

_purge_tilde() { printf '%s' "${1/#"$HOME"/"~"}"; }

# _purge_clock — a monotonic-enough stamp in microseconds, for the scan timer.
_purge_clock() { printf '%s' "${EPOCHREALTIME//[!0-9]/}"; }

# _purge_ask OPTIONS — ask on the terminal which artifacts to purge; prints the reply.
_purge_ask() {
  local reply
  printf '\n%s?%s Purge which artifacts? %s ' "$C_YELLOW" "$C_RESET" "$1" >/dev/tty
  read -r reply </dev/tty || return 1
  printf '%s' "$reply"
}

# _purge_kept LABEL REASON — "◎ label · kept (reason)": items deliberately left alone.
_purge_kept() { printf '  %s◎%s %s · %skept (%s)%s\n' "$C_DIM" "$C_RESET" "$1" "$C_DIM" "$2" "$C_RESET"; }

# _purge_to_trash ARTIFACT — 0 if ARTIFACT goes to the Trash instead of a permanent delete
# (virtualenvs can hold hand-installed state).
_purge_to_trash() { [[ "${1##*/}" == venv || "${1##*/}" == .venv ]]; }

# ---------------------------------------------------------------- pnpm store
# pnpm hard-links every package file from its content-addressed store into node_modules, so
# deleting a node_modules (or a worktree holding one) frees little by itself: the bytes go when
# `pnpm store prune` drops the store files nothing links to any more.

_PURGE_PNPM_PATHS=()   # pnpm-managed artifacts/worktrees removed (or that would be, in a dry run)

# _purge_pnpm_managed DIR — 0 if DIR is a node_modules pnpm installed, or a project/worktree with
# one at its top or up to two levels down (workspace packages).
_purge_pnpm_managed() {
  local d
  [[ "${1##*/}" == node_modules ]] && { [[ -f "$1/.modules.yaml" ]]; return; }
  for d in "$1" "$1"/*/ "$1"/*/*/; do [[ -f "${d%/}/node_modules/.modules.yaml" ]] && return 0; done
  return 1
}

# _purge_pnpm_store — the pnpm store directory; 1 without pnpm or a store. pnpm runs from $HOME
# (it writes a probe file into its working directory; HOME is the user's global config scope).
_purge_pnpm_store() {
  command -v pnpm >/dev/null || return 1
  local s
  s=$(env -C "$HOME" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 timeout 30 pnpm store path </dev/null 2>/dev/null) || return 1
  [[ "$s" == /* && -d "$s" ]] || return 1
  printf '%s' "$s"
}

# _purge_store_frees PATH... — bytes `pnpm store prune` would release once PATHs are gone: store
# files whose only other links lie inside PATHs. Prints nothing without pnpm, a store, or when the
# store is whitelisted.
_purge_store_frees() {
  local store
  store=$(_purge_pnpm_store) || return 0
  mm_whitelisted "$store" && return 0
  {
    find "$@" -xdev -type f -links +1 -printf 'S %D:%i\n'
    find "$store" -xdev -type f -links +1 -printf 'T %D:%i %n %b\n'
  } 2>/dev/null | awk '$1 == "S" { s[$2]++; next } ($2 in s) && s[$2] + 1 == $3 { f += $4 }
    END { printf "%.0f\n", f * 512 }'
}

# _purge_pnpm_prune — real runs, after pnpm-managed removals: `pnpm store prune` unless pnpm is
# missing or running or the store is whitelisted. Prints the banner line (bytes from the store
# filesystem's df delta).
_purge_pnpm_prune() {
  local store before after
  store=$(_purge_pnpm_store) || return 0
  if mm_whitelisted "$store"; then printf 'pnpm store prune: skipped (store whitelisted)'; return 0; fi
  if mm_proc_running pnpm; then printf 'pnpm store prune: skipped (pnpm busy)'; return 0; fi
  before=$(mm_free_bytes "$store")
  mm_run "prune the pnpm store" env -C "$HOME" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 timeout 300 pnpm store prune </dev/null ||
    { printf 'pnpm store prune: failed'; return 0; }
  after=$(mm_free_bytes "$store")
  printf 'pnpm store prune: freed %s' "$(mm_human $(( after > before ? after - before : 0 )))"
}

# _purge_size_label SIZE FREES PNPM — "1.4GB" or "1.4GB (frees 70.0MB; rest shared with the pnpm
# store)" when hard links elsewhere keep part of it on disk.
_purge_size_label() {
  local out; out=$(mm_human "$1")
  (( $2 < $1 )) || { printf '%s' "$out"; return; }
  out+=" (frees $(mm_human "$2"); rest "
  if (( $3 )); then out+="shared with the pnpm store)"; else out+="hard-linked from elsewhere)"; fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------- git worktrees

# Every worktree of every repository found, index-aligned. MAIN is the repository's main
# worktree (or bare dir); IS_MAIN marks that entry itself.
_WT_PATH=() _WT_COMMON=() _WT_MAIN=() _WT_IS_MAIN=() _WT_HEAD=() _WT_BRANCH=() _WT_LOCKED=()

# _purge_wt_load COMMON — append the worktrees `git worktree list` reports for one repository.
# Uses -z output when git supports it (2.36+); every entry is verified against the repository
# afterwards, so a path that confuses the line-based fallback can never be acted on.
_purge_wt_load() {
  local c="$1" f path="" head="" branch="" locked=0 first=1 main=""
  local -a recs=()
  mapfile -d '' -t recs < <(_purge_gitcmd --git-dir="$c" worktree list --porcelain -z || printf '\1\0')
  if [[ "${recs[-1]:-}" == $'\1' ]]; then
    mapfile -t recs < <(_purge_gitcmd --git-dir="$c" worktree list --porcelain || printf '\1\n')
    [[ "${recs[-1]:-}" == $'\1' ]] && { mm_debug "git worktree list failed for $c"; return 1; }
  fi
  recs+=("")
  for f in "${recs[@]}"; do
    case "$f" in
      "worktree "*) path="${f#worktree }" ;;
      "HEAD "*) head="${f#HEAD }" ;;
      "branch refs/heads/"*) branch="${f#branch refs/heads/}" ;;
      locked|"locked "*) locked=1 ;;
      "")
        if [[ -n "$path" ]]; then
          (( first )) && main="$path"
          _WT_PATH+=("$path") _WT_COMMON+=("$c") _WT_MAIN+=("$main") _WT_IS_MAIN+=("$first")
          _WT_HEAD+=("$head") _WT_BRANCH+=("$branch") _WT_LOCKED+=("$locked")
          first=0
        fi
        path="" head="" branch="" locked=0 ;;
    esac
  done
}

# _purge_default_ref COMMON — the repository's default branch ref: origin/HEAD's target, else
# main, else master; empty if none.
_purge_default_ref() {
  local c="$1" r b
  r=$(_purge_gitcmd --git-dir="$c" symbolic-ref -q refs/remotes/origin/HEAD) && [[ -n "$r" ]] &&
    { printf '%s' "$r"; return 0; }
  for b in main master; do
    _purge_gitcmd --git-dir="$c" show-ref --verify -q "refs/heads/$b" && { printf 'refs/heads/%s' "$b"; return 0; }
  done
}

# _purge_wt_idle WORKTREE — seconds since the worktree's newest activity: its own and its
# top-level files' mtimes (artifacts are not descended into), its git dir's index/HEAD, and the
# HEAD commit time.
_purge_wt_idle() {
  local w="$1" gd newest ct
  newest=$({
    find "$w" -maxdepth 1 \( -type f -o -path "$w" \) -printf '%T@\n' 2>/dev/null
    gd=$(_purge_gitdir_of "$w") && stat -c %Y -- "$gd/index" "$gd/HEAD" 2>/dev/null
    ct=$(_purge_git "$w" log -1 --format=%ct HEAD) && printf '%s\n' "$ct"
  } | sort -n | tail -n1)
  newest="${newest%.*}"
  [[ "$newest" =~ ^[0-9]+$ ]] || { echo 0; return; }
  echo $(( $(date +%s) - newest ))
}

# _purge_wt_clean WORKTREE — 0 clean (ignored files allowed), 1 has changes, 2 unknown.
_purge_wt_clean() {
  local out rc=0
  out=$(_purge_git "$1" status --porcelain --untracked-files=all --ignore-submodules=none) || rc=$?
  (( rc == 0 )) || return 2
  [[ -z "$out" ]]
}

# _purge_wt_landed COMMON HEAD BRANCH — how a worktree's work reached the default branch, by git
# alone (read-only, no fetch): "merged" (HEAD is an ancestor), "rebase-merged" (git cherry: every
# commit has an equivalent patch there), "squash-merged" (the branch's whole diff from the merge
# base has the patch id of one commit there: what git cherry reports for a commit-tree of the
# branch tree on the merge base, without writing that commit), "upstream gone" (its upstream
# branch was deleted); else "unmerged".
_purge_wt_landed() {
  local c="$1" head="$2" br="$3" def out mb want track
  def=$(_purge_default_ref "$c")
  if [[ -n "$def" ]]; then
    _purge_gitcmd --git-dir="$c" merge-base --is-ancestor "$head" "$def" && { echo merged; return; }
    out=$(_purge_gitcmd --git-dir="$c" cherry "$def" "$head")
    if [[ -n "$out" && "$out" != "+"* && "$out" != *$'\n+'* ]]; then echo rebase-merged; return; fi
    if mb=$(_purge_gitcmd --git-dir="$c" merge-base "$def" "$head") && [[ -n "$mb" ]]; then
      want=$(_purge_gitcmd --git-dir="$c" diff --no-color --no-ext-diff --no-textconv "$mb" "$head" |
        _purge_gitcmd patch-id --stable | cut -d' ' -f1)
      if [[ -n "$want" ]] && _purge_gitcmd --git-dir="$c" log --no-color --no-ext-diff --no-textconv \
           --no-merges -p --format='commit %H' "$mb..$def" | _purge_gitcmd patch-id --stable |
           cut -d' ' -f1 | grep -qxF -- "$want"; then
        echo squash-merged; return
      fi
    fi
  fi
  if [[ -n "$br" ]]; then
    track=$(_purge_gitcmd --git-dir="$c" for-each-ref --format='%(upstream:track)' "refs/heads/$br")
    [[ "$track" == "[gone]" ]] && { echo "upstream gone"; return; }
  fi
  echo unmerged
}

# _purge_gh_ready — 0 if gh is installed and holds a login (checked offline, once per run).
_purge_gh_ready() {
  if [[ -z "$_PURGE_GH" ]]; then
    _PURGE_GH=0
    command -v gh >/dev/null &&
      GH_PROMPT_DISABLED=1 timeout "$_PURGE_GH_TIMEOUT" gh auth token </dev/null >/dev/null 2>&1 && _PURGE_GH=1
  fi
  (( _PURGE_GH ))
}

# _purge_pr_state WORKTREE BRANCH — state of the pull request for BRANCH (its upstream branch
# name when it has one) per gh: OPEN, MERGED or CLOSED. Nothing when gh is missing or logged out,
# finds no PR, fails or times out; gh never gets a terminal to prompt on.
_purge_pr_state() {
  _purge_gh_ready || return 0
  local name
  name=$(_purge_git "$1" for-each-ref --format='%(upstream:lstrip=3)' "refs/heads/$2")
  env -C "$1" -u GIT_DIR -u GIT_WORK_TREE GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=cat \
    timeout "$_PURGE_GH_TIMEOUT" gh pr view "${name:-$2}" --json state --jq .state </dev/null 2>/dev/null
}

# _purge_wt_eval I — decide worktree I. Sets _WT_STATE, _WT_WHY (keep reason), _WT_IDLE (seconds)
# and _WT_MERGE (a _purge_wt_landed label, "PR merged", "PR closed" or "unmerged"):
#   offer   clean, unlocked, not in use, commits reachable, idle >= 1h, and finished (its work
#           landed) or unmerged and idle >= 30 days
#   keep    would be offered but one of those checks fails (_WT_WHY says which)
#   active  idle < 1h, or unmerged and idle < 30 days (not shown)
#   skip    the main worktree, or not a worktree of this repository
_purge_wt_eval() {
  local i="$1" w="${_WT_PATH[$1]}" c="${_WT_COMMON[$1]}" head="${_WT_HEAD[$1]}" br="${_WT_BRANCH[$1]}"
  local rc why="" holders
  _WT_STATE=skip _WT_WHY="" _WT_IDLE=0 _WT_MERGE=""
  [[ "${_WT_IS_MAIN[$i]}" == 0 ]] || return 0
  [[ "$w" == /?* && "$w" != *[[:cntrl:]]* && -d "$w" && ! -L "$w" ]] || return 0
  # the directory must really be a worktree of this repository
  [[ "$(_purge_common_dir "$w/.git")" == "$c" ]] || { mm_debug "not a worktree of $c: $w"; return 0; }
  _WT_IDLE=$(_purge_wt_idle "$w")
  (( _WT_IDLE >= _PURGE_WT_FINISHED_IDLE )) || { _WT_STATE=active; return 0; }
  # Agent state (e.g. ~/.cursor/worktrees) is waived here only: git itself vouches for the content.
  if mm_protected "$w" >/dev/null; then why="protected"
  elif [[ "${_WT_LOCKED[$i]}" == 1 ]]; then why="locked"
  elif mm_in_use "$w"; then why="in use"
  elif MM_KEEP_AGENT_STATE=0 mm_whitelisted "$w"; then why="whitelisted"
  else
    rc=0; _purge_wt_clean "$w" || rc=$?
    case "$rc" in
      0) ;;
      1) why="uncommitted or untracked changes" ;;
      *) why="could not verify git state" ;;
    esac
  fi
  [[ -n "$why" || "$head" =~ ^[0-9a-f]{7,64}$ ]] || why="could not verify git state"
  if [[ -z "$why" && -z "$br" ]]; then
    # detached: removing it must not orphan commits no branch or tag holds
    if ! holders=$(_purge_gitcmd --git-dir="$c" for-each-ref --contains "$head" --count=1 --format=x refs/heads refs/tags); then
      why="could not verify git state"
    elif [[ -z "$holders" ]]; then
      why="detached HEAD with commits on no branch or tag"
    fi
  fi
  _WT_MERGE=unmerged
  [[ "$head" =~ ^[0-9a-f]{7,64}$ ]] && _WT_MERGE=$(_purge_wt_landed "$c" "$head" "$br")
  # gh is a network call: only for worktrees that could be offered
  if [[ -z "$why" && "$_WT_MERGE" == unmerged && -n "$br" ]]; then
    case "$(_purge_pr_state "$w" "$br")" in
      MERGED) _WT_MERGE="PR merged" ;;
      CLOSED) _WT_MERGE="PR closed" ;;
    esac
  fi
  if [[ "$_WT_MERGE" == unmerged ]] && (( _WT_IDLE < _PURGE_WT_UNMERGED_DAYS * 86400 )); then
    _WT_STATE=active; return 0
  fi
  if [[ -n "$why" ]]; then _WT_STATE=keep _WT_WHY="$why"; return 0; fi
  _WT_STATE=offer
}

# _purge_worktrees YES ROOT... — the worktrees section for every linked worktree reachable from
# ROOTs: finished ones (work landed) and abandoned ones (unmerged, idle 30+ days). Removes only
# after a terminal confirmation; never with --yes or in a dry run. Sets _PURGE_WT_DONE /
# _PURGE_WT_BYTES (removed) and _PURGE_WT_OFFERED / _PURGE_WT_OFFER_BYTES, all counted in frees
# (mm_size_frees), _PURGE_WT_FINISHED (offered finished ones) and _PURGE_WT_PNPM (offered
# pnpm-managed worktrees).
_purge_worktrees() {
  local yes="$1"; shift
  local i n=0 active=0 sz fr pn line idx desc
  local -a offer=() lines=() sel=()
  local -A size=() label=() pnpm=()
  _PURGE_WT_DONE=0 _PURGE_WT_BYTES=0 _PURGE_WT_OFFERED=0 _PURGE_WT_OFFER_BYTES=0 _PURGE_WT_PNPM=()
  _PURGE_WT_FINISHED=0
  for i in "${!_WT_PATH[@]}"; do
    [[ "${_WT_IS_MAIN[$i]}" == 0 ]] && _purge_covered "${_WT_PATH[$i]}" "$@" && n=$((n + 1))
  done
  (( n )) || return 0
  (( MM_INUSE_TAKEN )) || mm_inuse_refresh
  mm_section "Finished and abandoned worktrees"
  for i in "${!_WT_PATH[@]}"; do
    { [[ "${_WT_IS_MAIN[$i]}" == 0 ]] && _purge_covered "${_WT_PATH[$i]}" "$@"; } || continue
    _purge_wt_eval "$i"
    desc="${_WT_BRANCH[$i]:+branch ${_WT_BRANCH[$i]}}"; desc="${desc:-detached}"
    if [[ "$_WT_MERGE" == unmerged ]]; then desc+=" · unmerged (branch kept)"; else desc+=" · $_WT_MERGE"; fi
    case "$_WT_STATE" in
      active) active=$((active + 1)) ;;
      keep) _purge_kept "$(_purge_tilde "${_WT_PATH[$i]}") · $desc" "$_WT_WHY" ;;
      offer)
        read -r sz fr < <(mm_size_frees "${_WT_PATH[$i]}")
        size[$i]=${fr:-0} pn=0
        _purge_pnpm_managed "${_WT_PATH[$i]}" && { pn=1 pnpm[$i]=1; _PURGE_WT_PNPM+=("${_WT_PATH[$i]}"); }
        label[$i]="$(_purge_tilde "${_WT_PATH[$i]}") · $desc · idle $(_purge_idle_label "$_WT_IDLE") · $(_purge_size_label "${sz:-0}" "${size[$i]}" "$pn")"
        printf '  %s●%s %s\n' "$C_YELLOW" "$C_RESET" "${label[$i]}"
        offer+=("$i")
        _PURGE_WT_OFFERED=$((_PURGE_WT_OFFERED + 1)) _PURGE_WT_OFFER_BYTES=$((_PURGE_WT_OFFER_BYTES + size[$i]))
        [[ "$_WT_MERGE" == unmerged ]] || _PURGE_WT_FINISHED=$((_PURGE_WT_FINISHED + 1))
        ;;
    esac
  done
  (( active )) && mm_info "${C_DIM}$active worktree$( (( active > 1 )) && echo s) in progress not shown (idle < 1h, or unmerged and idle < ${_PURGE_WT_UNMERGED_DAYS}d)${C_RESET}"
  (( ${#offer[@]} )) || { mm_ok "No finished or abandoned worktrees"; return 0; }

  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_info "${C_DIM}A real run asks before removing them (git worktree remove; branches are kept).${C_RESET}"
    return 0
  fi
  if (( yes )); then mm_info "--yes never removes worktrees: run on a terminal without --yes to choose."; return 0; fi
  if [[ "$MM_TTY" != 1 ]]; then mm_info "No terminal: worktrees are listed only."; return 0; fi

  _PURGE_PROMPTED=1
  if (( ${#offer[@]} == 1 )); then
    mm_confirm "Remove worktree $(_purge_tilde "${_WT_PATH[${offer[0]}]}")? (git worktree remove; branch kept)" && sel=("${offer[0]}")
  else
    for i in "${offer[@]}"; do lines+=("$i  ${label[$i]}"); done
    while IFS= read -r line; do
      idx="${line%%[[:space:]]*}"
      [[ "$idx" =~ ^[0-9]+$ && -n "${label[$idx]:-}" ]] && sel+=("$idx")
    done < <(printf '%s\n' "${lines[@]}" | mm_pick "TAB marks worktrees to remove (git worktree remove; branches kept), Enter confirms")
  fi
  (( ${#sel[@]} )) || { mm_info "No worktrees removed."; return 0; }

  # Re-check right before acting: the prompt may have taken a while.
  mm_inuse_refresh
  local w m c rc
  local -A pruned=()
  for i in "${sel[@]}"; do
    w="${_WT_PATH[$i]}" m="${_WT_MAIN[$i]}" c="${_WT_COMMON[$i]}"
    if mm_in_use "$w"; then mm_skip "$(_purge_tilde "$w")" "in use"; continue; fi
    rc=0; _purge_wt_clean "$w" || rc=$?
    (( rc == 0 )) || { _purge_kept "$(_purge_tilde "$w")" "changed since the scan"; continue; }
    if [[ -d "$m" ]]; then
      mm_run "remove worktree $w" timeout 120 git -c core.fsmonitor=false -C "$m" worktree remove -- "$w"; rc=$?
    else
      mm_run "remove worktree $w" timeout 120 git -c core.fsmonitor=false --git-dir="$c" worktree remove -- "$w"; rc=$?
    fi
    (( rc == 0 )) || continue
    mm_log worktree "$w" "${size[$i]}" "${_WT_BRANCH[$i]:-detached}"
    mm_ok "$(_purge_tilde "$w")" "removed, freed $(mm_human "${size[$i]}")${_WT_BRANCH[$i]:+, branch ${_WT_BRANCH[$i]} kept}"
    _PURGE_WT_DONE=$((_PURGE_WT_DONE + 1)) _PURGE_WT_BYTES=$((_PURGE_WT_BYTES + size[$i]))
    [[ -n "${pnpm[$i]:-}" ]] && _PURGE_PNPM_PATHS+=("$w")
    pruned[$c]=1
  done
  # Records of worktrees whose directories are already gone, in the repositories just touched.
  for c in "${!pruned[@]}"; do
    mm_run "prune worktree records in $c" timeout 60 git -c core.fsmonitor=false --git-dir="$c" worktree prune
  done
}

# ---------------------------------------------------------------- main

mm_cmd_main() {
  local days=14 all=0 edit=0 yes=0
  local -a dirs=()
  while (( $# )); do
    case "$1" in
      --days) [[ $# -ge 2 ]] || mm_die "--days needs a number"; days="$2"; shift ;;
      --days=*) days="${1#*=}" ;;
      --all) all=1 ;;
      -y|--yes) yes=1 ;;
      --paths) edit=1 ;;
      -h|--help) _purge_usage; return 0 ;;
      -*) mm_die "unknown option: $1 (see mm purge --help)" ;;
      *) dirs+=("$1") ;;
    esac
    shift
  done
  [[ "$days" =~ ^[0-9]+$ ]] || mm_die "--days expects a whole number of days, got: $days"
  (( yes && all )) && mm_die "--all needs a terminal: --yes purges stale artifacts only"

  if (( edit )); then
    mkdir -p "$MM_CONFIG_DIR"
    [[ -f "$MM_PURGE_PATHS_FILE" ]] || printf '%s' "$_PURGE_PATHS_TEMPLATE" >"$MM_PURGE_PATHS_FILE"
    "${VISUAL:-${EDITOR:-nano}}" "$MM_PURGE_PATHS_FILE"
    return
  fi

  # ---- where to look
  local -a roots=() listed=() missing=()
  local r where
  if (( ${#dirs[@]} )); then
    for r in "${dirs[@]}"; do
      [[ -d "$r" ]] || mm_die "not a directory: $r"
      roots+=("$(realpath -e -- "$r")")
    done
    where=args
  else
    mapfile -t listed < <(_purge_listed_roots)
    if (( ${#listed[@]} )); then
      for r in "${listed[@]}"; do
        if [[ -d "$r" ]]; then roots+=("$(realpath -e -- "$r")"); else missing+=("$r"); fi
      done
      (( ${#roots[@]} )) || mm_die "none of the roots in $MM_PURGE_PATHS_FILE exist (mm purge --paths)"
      where="file"
    else
      roots=("$HOME") where=discover
    fi
  fi

  local free_before; free_before=$(mm_free_bytes /)
  mm_header "Purge Project Artifacts"
  for r in "${missing[@]}"; do mm_skip "$(_purge_tilde "$r")" "not found"; done

  # ---- scan: artifacts, repositories, worktrees
  local t0; t0=$(_purge_clock)
  local -a raw=() cand_raw=() gitents=() timed=() extra=()
  local rec kind
  _purge_ingest() {
    for rec in "${raw[@]}"; do
      kind="${rec%%$'\t'*}" rec="${rec#*$'\t'}" rec="${rec#*$'\t'}"
      case "$kind" in A) cand_raw+=("$rec") ;; G) gitents+=("$rec") ;; T) timed+=("$rec") ;; esac
    done
  }
  mapfile -d '' -t raw < <(_purge_scan "${roots[@]}"); _purge_ingest
  local -A commons=()
  local c i
  for rec in "${gitents[@]}"; do c=$(_purge_common_dir "$rec") && commons[$c]=1; done
  # worktrees in the agents' worktree dirs, whose repositories may live outside the scan
  if [[ "$where" == discover ]]; then
    while IFS= read -r -d '' rec; do c=$(_purge_common_dir "$rec") && commons[$c]=1; done < <(_purge_agent_worktrees)
  fi
  _WT_PATH=() _WT_COMMON=() _WT_MAIN=() _WT_IS_MAIN=() _WT_HEAD=() _WT_BRANCH=() _WT_LOCKED=()
  for c in "${!commons[@]}"; do _purge_wt_load "$c"; done
  # linked worktrees inside an agent's worktree dir: their artifacts are work, not agent state
  local -A agent_wt=()
  for i in "${!_WT_PATH[@]}"; do
    [[ "${_WT_IS_MAIN[$i]}" == 0 ]] && _purge_in_agent_wtdir "${_WT_PATH[$i]}" && agent_wt[${_WT_PATH[$i]}]=1
  done
  if [[ "$where" == discover ]]; then
    # every worktree of every repository found, wherever it lives
    for i in "${!_WT_PATH[@]}"; do
      r="${_WT_PATH[$i]}"
      [[ "$r" == /?* && "$r" != *[[:cntrl:]]* && -d "$r" && ! -L "$r" ]] || continue
      _purge_covered "$r" "${roots[@]}" "${extra[@]}" || extra+=("$r")
    done
    if (( ${#extra[@]} )); then
      mapfile -d '' -t raw < <(_purge_scan "${extra[@]}"); _purge_ingest
      roots+=("${extra[@]}")
    fi
  fi
  local dt=$(( ( $(_purge_clock) - t0 ) / 100000 ))
  local shown=() ; for r in "${roots[@]:0:${#roots[@]}-${#extra[@]}}"; do shown+=("$(_purge_tilde "$r")"); done
  mm_info "${C_DIM}Scanned ${shown[*]}${extra[*]:+ + ${#extra[@]} worktree dirs elsewhere} in $((dt / 10)).$((dt % 10))s · artifacts idle > ${days}d are stale${C_RESET}"
  for r in "${timed[@]}"; do mm_warn "Scan of $(_purge_tilde "$r") stopped after ${_PURGE_SCAN_TIMEOUT}s: results are partial"; done

  # ---- finished and abandoned worktrees (before artifacts: removing one takes its artifacts with it)
  _PURGE_PROMPTED=0 _PURGE_PNPM_PATHS=() _PURGE_GH=""
  _purge_worktrees "$yes" "${roots[@]}"

  # ---- validate artifacts
  local -a kept_out=()
  local -A seen=() gitroot_of=() activity=()
  local -a arts=() projs=() gits=()
  local art proj anc ok g rc
  for art in "${cand_raw[@]}"; do
    [[ -n "$art" && -z "${seen[$art]:-}" ]] || continue
    # an artifact nested inside an already-matched one is part of it
    anc="${art%/*}" ok=1
    while [[ "$anc" == /*/* ]]; do
      [[ -n "${seen[$anc]:-}" ]] && { ok=0; break; }
      anc="${anc%/*}"
    done
    (( ok )) || continue
    rc=0; _purge_valid "$art" "${roots[@]}" || rc=$?
    if (( rc == 2 )); then
      seen[$art]=1; kept_out+=("$art"$'\t'"$_PURGE_WHY"); continue
    fi
    (( rc == 0 )) || continue
    seen[$art]=1
    proj="${art%/*}"
    if [[ -z "${gitroot_of[$proj]+x}" ]]; then
      gitroot_of[$proj]=$(_purge_gitroot "$proj")
      activity[$proj]=$(_purge_activity "$proj" "${gitroot_of[$proj]}")
    fi
    arts+=("$art"); projs+=("$proj"); gits+=("${gitroot_of[$proj]}")
  done

  # ---- in-use: artifact, its project, or the project's repository/worktree
  local -a cand=()
  local -A busy=() skip_n=() skip_names=()
  local key nm p
  if (( ${#arts[@]} )); then
    (( MM_INUSE_TAKEN && ! _PURGE_PROMPTED )) || mm_inuse_refresh
    while IFS= read -r p; do [[ -n "$p" ]] && busy[$p]=1; done < <(_purge_busy "${arts[@]}" "${projs[@]}" "${gits[@]}")
  fi
  for i in "${!arts[@]}"; do
    if [[ -n "${busy[${arts[$i]}]:-}" || -n "${busy[${projs[$i]}]:-}" || ( -n "${gits[$i]}" && -n "${busy[${gits[$i]}]:-}" ) ]]; then
      key="${gits[$i]:-${projs[$i]}}" nm="${arts[$i]##*/}"
      skip_n[$key]=$(( ${skip_n[$key]:-0} + 1 ))
      [[ ", ${skip_names[$key]:-}, " == *", $nm, "* ]] || skip_names[$key]+="${skip_names[$key]:+, }$nm"
    else
      cand+=("$i")
    fi
  done
  if (( ${#skip_n[@]} )); then
    mm_section "In use"
    while IFS= read -r key; do
      mm_skip "$(_purge_tilde "$key") · ${skip_n[$key]} artifact$( (( skip_n[$key] > 1 )) && echo s) (${skip_names[$key]})" "in use"
    done < <(printf '%s\n' "${!skip_n[@]}" | sort)
  fi

  # ---- sizes, frees and nested-repository check (parallel)
  local -A size=() frees=() nested=()
  local b fb hasgit n=0 total=${#cand[@]}
  local -a cand_paths=() keep_cand=() freed_paths=()
  for i in "${cand[@]}"; do cand_paths+=("${arts[$i]}"); done
  if (( total )); then
    while IFS= read -r -d '' rec; do
      b="${rec%%$'\t'*}" rec="${rec#*$'\t'}" fb="${rec%%$'\t'*}" rec="${rec#*$'\t'}"
      hasgit="${rec%%$'\t'*}" p="${rec#*$'\t'}"
      size[$p]=$b frees[$p]=$fb; [[ "$hasgit" == 1 ]] && nested[$p]=1; n=$((n + 1))
      [[ -t 2 ]] && printf '\r  %sMeasuring %d/%d artifacts…%s' "$C_DIM" "$n" "$total" "$C_RESET" >&2
    done < <(_purge_measure "${cand_paths[@]}")
    [[ -t 2 ]] && printf '\r\e[K' >&2
  fi
  for i in "${cand[@]}"; do
    if [[ -n "${nested[${arts[$i]}]:-}" ]]; then
      kept_out+=("${arts[$i]}"$'\t'"contains a git repository")
    else
      keep_cand+=("$i")
    fi
  done
  cand=("${keep_cand[@]}")

  if (( ${#kept_out[@]} )); then
    mm_section "Kept"
    for rec in "${kept_out[@]}"; do _purge_kept "$(_purge_tilde "${rec%%$'\t'*}")" "${rec#*$'\t'}"; done
  fi
  if (( ${#cand[@]} == 0 )); then
    printf '\n'
    if (( ${#arts[@]} )); then mm_ok "No artifacts to purge" "every artifact found is in use or kept"
    else mm_ok "No build artifacts found"; fi
    _purge_banner "$free_before" 0
    return 0
  fi

  # ---- classify and sort by what deleting frees
  local now; now=$(date +%s)
  local -a order=() idle=() stale=() pnpm_art=()
  local stale_bytes=0 recent_bytes=0 stale_n=0 recent_n=0 act shared=0
  for i in "${cand[@]}"; do
    act="${activity[${projs[$i]}]:-}"
    # unknown activity counts as recent: never selected by default
    if [[ -n "$act" ]]; then idle[i]=$(( (now - act) / 86400 )); else idle[i]=0; fi
    if (( idle[i] > days )); then
      stale[i]=1; stale_n=$((stale_n + 1)); stale_bytes=$((stale_bytes + ${frees[${arts[$i]}]:-0}))
    else
      stale[i]=0; recent_n=$((recent_n + 1)); recent_bytes=$((recent_bytes + ${frees[${arts[$i]}]:-0}))
    fi
    pnpm_art[i]=0; _purge_pnpm_managed "${arts[$i]}" && pnpm_art[i]=1
  done
  mapfile -t order < <(for i in "${cand[@]}"; do
      printf '%s\t%s\t%s\n' "${frees[${arts[$i]}]:-0}" "${size[${arts[$i]}]:-0}" "$i"
    done | sort -t$'\t' -k1,1nr -k2,2nr | cut -f3)

  mm_section "Artifacts (${#order[@]})"
  printf '  %s  %9s  %9s  %5s  %s\n' " " "SIZE" "FREES" "IDLE" "PROJECT/ARTIFACT"
  local mark row hidden_n=0 hidden_bytes=0 sz fr
  local -A row_of=()
  for i in "${order[@]}"; do
    sz=${size[${arts[$i]}]:-0} fr=${frees[${arts[$i]}]:-0}
    row=$(printf '%9s  %9s  %5s  %s' "$(mm_human "$sz")" "$(mm_human "$fr")" "$(_purge_age "${idle[i]}")" "$(_purge_tilde "${arts[$i]}")")
    _purge_to_trash "${arts[$i]}" && row+=" (to Trash)"
    if (( fr < sz )); then
      shared=1; (( pnpm_art[i] )) && row+=" (rest in the pnpm store)"
    fi
    row_of[$i]="$row"
    # keep the table readable: recent artifacts freeing under 1MB are summarized, not listed
    if (( ! stale[i] && fr < 1048576 )); then
      hidden_n=$((hidden_n + 1)) hidden_bytes=$((hidden_bytes + fr)); continue
    fi
    if (( stale[i] )); then mark="${C_YELLOW}●${C_RESET}"; else mark="${C_DIM}○${C_RESET}"; fi
    printf '  %s  %s\n' "$mark" "$row"
  done
  (( hidden_n )) && printf '  %s○  %9s  %9s         … %d more recent artifacts freeing under 1MB%s\n' \
    "$C_DIM" "" "$(mm_human "$hidden_bytes")" "$hidden_n" "$C_RESET"
  printf '\n'
  (( shared )) && mm_info "${C_DIM}FREES is what deleting releases: files also hard-linked elsewhere (the pnpm store, other copies) stay on disk.${C_RESET}"
  mm_info "${C_YELLOW}●${C_RESET} stale (idle > ${days}d): $stale_n artifacts, frees $(mm_human "$stale_bytes")"
  mm_info "${C_DIM}○${C_RESET} recent:               $recent_n artifacts, frees $(mm_human "$recent_bytes")"

  # ---- selection: dry-run previews the default; --yes is stale only; otherwise ask on the terminal
  local mode=stale; (( all )) && mode=all
  if [[ "$MM_DRY_RUN" != 1 ]] && (( ! yes )); then
    if [[ "$MM_TTY" != 1 ]]; then
      mm_info ""
      mm_info "No terminal: nothing removed. Re-run with --yes to purge the stale artifacts."
      _purge_banner "$free_before" 0
      return 0
    fi
    local reply def="S" opts="[S]tale only / [a]ll / [p]ick / [n]one"
    (( all )) && { def="A"; opts="[s]tale only / [A]ll / [p]ick / [n]one"; }
    _PURGE_PROMPTED=1
    reply=$(_purge_ask "$opts") || reply=n
    case "${reply:-$def}" in
      [Ss]*) mode=stale ;;
      [Aa]*) mode=all ;;
      [Pp]*) mode=pick ;;
      *) mm_info "No artifacts removed."; _purge_banner "$free_before" 0; return 0 ;;
    esac
  fi

  local -a sel=()
  case "$mode" in
    stale) for i in "${order[@]}"; do (( stale[i] )) && sel+=("$i"); done ;;
    all) sel=("${order[@]}") ;;
    pick)
      local line idx
      while IFS= read -r line; do
        idx="${line%%[[:space:]]*}"
        [[ "$idx" =~ ^[0-9]+$ && -n "${row_of[$idx]:-}" ]] && sel+=("$idx")
      done < <(for i in "${order[@]}"; do
          printf '%-4s %s  %s\n' "$i" "$( (( stale[i] )) && echo stale || echo recent)" "${row_of[$i]}"
        done | mm_pick "TAB marks, ctrl-a all, Enter purges")
      ;;
  esac
  if (( ${#sel[@]} == 0 )); then
    mm_info ""
    mm_info "Nothing selected$( [[ "$mode" == stale ]] && echo " (no project idle > ${days}d; use --all or --days N)")."
    _purge_banner "$free_before" 0
    return 0
  fi

  # ---- delete (re-check in-use for real runs: a prompt may have taken a while)
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_section "Would remove"
  else
    mm_section "Purging"
    mm_inuse_refresh
    busy=()
    local -a recheck=()
    for i in "${sel[@]}"; do recheck+=("${projs[$i]}"); [[ -n "${gits[$i]}" ]] && recheck+=("${gits[$i]}"); done
    while IFS= read -r p; do [[ -n "$p" ]] && busy[$p]=1; done < <(_purge_busy "${recheck[@]}")
  fi
  local -a how=()
  local keep_state
  local -A done_proj=()
  for i in "${sel[@]}"; do
    art="${arts[$i]}" proj="${projs[$i]}" g="${gits[$i]}"
    if [[ -n "${busy[$proj]:-}" || ( -n "$g" && -n "${busy[$g]:-}" ) ]]; then
      mm_skip "$(_purge_tilde "$art")" "in use"
      MM_SKIPPED=$((MM_SKIPPED + 1))
      continue
    fi
    how=(); _purge_to_trash "$art" && how=(--trash)
    keep_state=1; [[ -n "$g" && -n "${agent_wt[$g]:-}" ]] && keep_state=0
    rc=0; MM_KEEP_AGENT_STATE=$keep_state mm_rm "${how[@]}" "$art" "$proj" || rc=$?
    case "$rc" in
      0) mm_ok "$(_purge_tilde "$art")" "$(mm_human "$MM_LAST_BYTES")${how:+ → Trash}"; done_proj[${g:-$proj}]=1
         (( pnpm_art[i] )) && _PURGE_PNPM_PATHS+=("$art")
         (( ${#how[@]} )) || freed_paths+=("$art") ;;
      1) mm_skip "$(_purge_tilde "$art")" "$MM_SKIP_REASON" ;;
      *) mm_err "$(_purge_tilde "$art") · $MM_SKIP_REASON" ;;
    esac
  done
  # Items hard-linked only among themselves (a project's .pnpm-store and its node_modules, cp -al
  # copies) free those files once all of them are gone, as the real run's later deletes count:
  # a dry run sizes what it would delete as one selection.
  [[ "$MM_DRY_RUN" == 1 ]] && (( ${#freed_paths[@]} > 1 )) && MM_FREED=$(mm_frees "${freed_paths[@]}")
  _purge_banner "$free_before" "${#done_proj[@]}"
}

# _purge_banner FREE_BEFORE PROJECTS — closing summary (artifacts plus worktrees). After a real
# run that removed pnpm-managed items it prunes the pnpm store first; a dry run estimates that.
_purge_banner() {
  local free_after trash="" wt="" pn="" est
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    (( MM_TRASHED )) && trash=" | Would move to Trash: $(mm_human "$MM_TRASHED")"
    if (( _PURGE_WT_OFFERED )); then
      est=0; (( ${#_PURGE_WT_PNPM[@]} )) && est=$(_purge_store_frees "${_PURGE_WT_PNPM[@]}")
      wt="Worktrees to remove: $_PURGE_WT_OFFERED, $_PURGE_WT_FINISHED finished (frees $(mm_human "$_PURGE_WT_OFFER_BYTES")"
      (( ${est:-0} > 0 )) && wt+=" + ~$(mm_human "$est") from the pnpm store"
      wt+=", removed only after you confirm)"
    fi
    est=0; (( ${#_PURGE_PNPM_PATHS[@]} )) && est=$(_purge_store_frees "${_PURGE_PNPM_PATHS[@]}")
    (( ${est:-0} > 0 )) && pn="Then pnpm store prune: ~$(mm_human "$est") more (store files only these used)"
    free_after=$(mm_free_bytes /)
    mm_banner "Dry run complete" \
      "Would free: $(mm_human "$MM_FREED")$trash | Artifacts: $MM_COUNT | Projects: $2" \
      ${pn:+"$pn"} \
      ${wt:+"$wt"} \
      "Free space: $(mm_human "$free_after")" \
      "Run without --dry-run to apply."
  else
    (( MM_TRASHED )) && trash=" | Moved to Trash: $(mm_human "$MM_TRASHED") (restore: trash-restore)"
    (( _PURGE_WT_DONE )) && wt="Worktrees removed: $_PURGE_WT_DONE ($(mm_human "$_PURGE_WT_BYTES"); branches kept)"
    (( ${#_PURGE_PNPM_PATHS[@]} )) && pn=$(_purge_pnpm_prune)
    free_after=$(mm_free_bytes /)
    local gained=$(( free_after - $1 )); (( gained < 0 )) && gained=0
    mm_banner "Purge complete" \
      "Space freed: $(mm_human "$MM_FREED")$trash | Artifacts: $MM_COUNT | Projects: $2" \
      ${pn:+"$pn"} \
      ${wt:+"$wt"} \
      "Free space: $(mm_human "$free_after") (+$(mm_human "$gained"))"
  fi
}
