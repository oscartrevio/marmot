# shellcheck shell=bash
# mm purge [DIR...] [--days N] [--all] [--yes] [--paths] — remove abandoned git worktrees and
# rebuildable build artifacts (node_modules, .next, target, venvs...) from idle projects.
#
# Where it looks: DIR arguments; else the roots listed in purge_paths; else discovery: $HOME
# (dot-dirs, ~/snap, the Go module cache, conda installs and site-packages skipped), your folders
# in /workspaces and /workspace (devcontainers, Codespaces, Gitpod, Coder), plus every git
# worktree registered to a repository found there, wherever it lives (agents keep them in
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

# Names a build tool owns: pruned at the match, never descended into. A name proves nothing by
# itself (~/Documents/insurance/coverage, a Go SDK's src/internal/coverage), so each still needs
# the proof its rule in _purge_rule asks for before anything is removed.
_PURGE_TARGETS=(node_modules .next .nuxt .output .turbo .parcel-cache .svelte-kit .astro .angular
  .expo .vite coverage __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .nox .gradle
  .terragrunt-cache .dart_tool .zig-cache zig-out .cxx .docusaurus)
# Only rebuildable next to the right manifest; validated after the scan. Also .nx/cache (nx.json),
# and any directory that tags itself a cache with CACHEDIR.TAG.
_PURGE_CONDITIONAL=(target build dist venv .venv vendor .build obj bin bower_components .pnpm-store)
# A tagged cache dir counts only directly inside a project: one of these next to it.
_PURGE_PROJECT_FILES=(.git package.json Cargo.toml go.mod pyproject.toml setup.py requirements.txt
  pom.xml build.gradle build.gradle.kts Gemfile composer.json pubspec.yaml Package.swift Makefile
  CMakeLists.txt build.zig mix.exs deno.json)
# A node project: npm, pnpm, bun, deno and their frameworks build next to one of these.
_PURGE_NODE_FILES=(package.json deno.json deno.jsonc)
# A python project: pip, pytest, mypy, ruff, tox and nox write next to one of these (or next to a
# requirements*.txt, checked separately).
_PURGE_PY_FILES=(pyproject.toml setup.py setup.cfg Pipfile tox.ini tox.toml noxfile.py)
# https://bford.info/cachedir/ — the first line of a CACHEDIR.TAG file.
_PURGE_CACHEDIR_SIG="Signature: 8a477f597d28d172789f06886806bc55"
# Never descended into: installed packages, not projects.
_PURGE_SKIP_NAMES=(site-packages dist-packages)
# Below $HOME (besides dot-dirs): snap app data, the Go module cache, conda installs.
_PURGE_SKIP_HOME=(snap go/pkg anaconda3 miniconda3 miniforge3 mambaforge micromamba)
_PURGE_MAXDEPTH=8
_PURGE_SCAN_TIMEOUT=60
_PURGE_GIT_TIMEOUT=20
# Reading a project with no repository to the bottom for its newest edit (_purge_deep_mtime).
_PURGE_DEEP_TIMEOUT=20
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
   files either), that are not locked or in use, and whose commits, also those only their HEAD
   reflog holds, are on a branch, tag or remote branch. Their git-ignored files go with them, so
   these may only be build artifacts purge recognizes or byte-for-byte copies of the main
   worktree's files (a copied .env); anything else, or a nested git repository, keeps the
   worktree, and the prompt names what goes. Finished ones are offered once idle 1+ hour: the
   branch is merged into the default branch (also squash- or rebase-merged), its upstream branch
   was deleted, or its pull request is merged or closed (asked through gh when it is installed
   and logged in). Unmerged ones after ${_PURGE_WT_UNMERGED_DAYS}+ idle days. Removed with \`git worktree
   remove\` (never --force; the branch is kept, other worktrees' records are left alone), only
   after you confirm on a terminal.
2. Build artifacts, each only where a project of the matching type vouches for it: node_modules
   and the JS framework caches (.next, .nuxt, .output, .turbo, ...) next to a package.json or a
   deno manifest, target next to Cargo.toml or pom.xml, build/dist/coverage next to a manifest
   and git-ignored by the project's own repository, venvs (a pyvenv.cfg), SwiftPM .build, .NET
   bin/obj, bower_components, .nx/cache, .docusaurus, a project's .pnpm-store, python tool caches
   (.pytest_cache, .mypy_cache, .ruff_cache, .tox, .nox) next to a python project, and the
   toolchain caches .gradle, .terragrunt-cache, .dart_tool, .zig-cache, zig-out and .cxx next to
   their build file. Projects idle longer than --days are selected by default.
   Only in the picker, never by --yes, a scheduled run or the stale/all answers: folders that
   merely tag themselves with CACHEDIR.TAG, and anything inside a folder synced by Syncthing,
   Dropbox, Nextcloud/ownCloud or Resilio (deleting there deletes on every device).
   Never touched: projects with a running process inside them or active since the scan (activity
   counts edits anywhere in the project and writes inside the artifact), anything git tracks,
   anything whose rule, git state, activity or size can't be read, and artifacts holding a nested
   git repository, a deploy keypair (*-keypair.json) or local Terraform state (*.tfstate).
   Every check is run again right before the deletion. Virtualenvs go to the Trash; everything
   else is deleted permanently.

Sizes: FREES is what a delete really releases. Files hard-linked from elsewhere (pnpm's store)
stay on disk, so after removing pnpm-installed node_modules or worktrees marmot runs
\`pnpm store prune\` (unless pnpm is running) and reports what that freed.

Where it looks: the DIRs given; else the roots in $MM_PURGE_PATHS_FILE;
else your home directory and your folders in /workspaces and /workspace (devcontainers,
Codespaces, Gitpod, Coder), plus every git worktree registered to a repository found there or
found in a coding agent's worktree folder (~/.cursor/worktrees, ~/.t3/worktrees, ...).

Options:
  --days N       Artifact idle threshold in days (default 14)
  --all          Also select recently active projects by default and list every row (terminal only)
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

# _purge_workspace_dirs — the workspace folders of dev containers and cloud dev environments,
# NUL-separated: VS Code dev containers and Codespaces mount repositories under /workspaces,
# Gitpod and Coder templates under /workspace. The test suite sets MM_TEST_WORKSPACE_PREFIX to a
# folder standing in for /; that is honored only inside bats' per-test directory, and an unusable
# one yields no folders (never the machine's own).
_purge_workspace_dirs() {
  local pre="" box
  if [[ -n "${MM_TEST_WORKSPACE_PREFIX+x}" ]]; then
    pre=$(realpath -e -- "$MM_TEST_WORKSPACE_PREFIX" 2>/dev/null) || return 0
    box=$(realpath -e -- "${BATS_TEST_TMPDIR:-/nonexistent}" 2>/dev/null) || return 0
    [[ "$pre" == "$box"/?* ]] || return 0
  fi
  printf '%s\0' "$pre/workspaces" "$pre/workspace"
}

# _purge_workspace_roots — discovery roots beyond $HOME, NUL-separated. A workspace folder you own
# that is itself a repository (one repo mounted at /workspace) is a root; otherwise each folder
# you own directly inside it is (Docker creates the mount point as root, the repositories inside
# are yours, and each is usually its own mount, which the scan's -xdev would not enter from
# above). Hidden folders (tool state such as Codespaces' .codespaces or Gitpod's caches) and
# symlinks are left out, as dot-dirs are in $HOME.
_purge_workspace_roots() {
  local w d
  while IFS= read -r -d '' w; do
    [[ -d "$w" && ! -L "$w" ]] || continue
    if [[ -O "$w" && -e "$w/.git" ]]; then
      d=$(realpath -e -- "$w") && printf '%s\0' "$d"
      continue
    fi
    for d in "$w"/*; do
      [[ -d "$d" && ! -L "$d" && -O "$d" ]] && d=$(realpath -e -- "$d") && printf '%s\0' "$d"
    done
  done < <(_purge_workspace_dirs)
  return 0
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

# _purge_scan ROOT... — NUL-separated records, in find order:
#   A<TAB>depth<TAB>path  candidate artifact dir (unvalidated); dirs holding a CACHEDIR.TAG file
#                         carry the depth of that file
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
      -o -type d \( "${always[@]:1}" -o -path '*/.nx/cache' \) -printf 'A\t%d\t%p\0' -prune \
      -o -type d \( "${cond[@]:1}" \) -printf 'A\t%d\t%p\0' \
      -o -type f -name CACHEDIR.TAG -printf 'A\t%d\t%h\0' 2>/dev/null
    (( $? == 124 )) && printf 'T\t0\t%s\0' "$root"
  done
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

# _purge_repo_of DIR — sets _PURGE_REPO to the nearest ancestor-or-self holding a .git entry
# (up to /); 1 if none.
_purge_repo_of() {
  local d="$1"
  while [[ "$d" == /?* ]]; do
    [[ -e "$d/.git" || -L "$d/.git" ]] && { _PURGE_REPO="$d"; return 0; }
    d="${d%/*}"
  done
  [[ -e /.git ]] && { _PURGE_REPO=/; return 0; }
  return 1
}

# Git state of the scanned artifacts, per _purge_tracked_load: 0 git tracks files under it,
# 2 the probe failed or timed out. Absent: no repository owns it or it tracks nothing there.
declare -A _PURGE_TRACKED=()

# _purge_tracked_load ART... — fill _PURGE_TRACKED with one `git ls-files` per repository. A file
# name holding a newline splits into pieces whose first one still starts with the artifact: it can
# only add "tracked", never hide it.
_purge_tracked_load() {
  local art repo rel rc
  local -A rels=()
  _PURGE_TRACKED=()
  for art; do
    [[ "$art" == /?* && "$art" != *[[:cntrl:]]* ]] || continue
    _purge_repo_of "$art" || continue
    [[ "$_PURGE_REPO" != "$art" ]] || continue
    rel="${art#"$_PURGE_REPO"/}"; [[ "$_PURGE_REPO" == / ]] && rel="${art#/}"
    rels[$_PURGE_REPO]+="$rel"$'\n'
  done
  for repo in "${!rels[@]}"; do
    while IFS=$'\t' read -r rc rel; do
      art="${repo%/}/$rel"
      _PURGE_TRACKED[$art]=$rc
    done < <({ _purge_git "$repo" ls-files -z | tr '\0' '\n'; printf '\1%s\n' "${PIPESTATUS[0]}"; } |
      awk 'NR == FNR { q[$0] = 1; next }
        { last = $0; p = $0
          while (p != "") {
            if ((p in q) && !(p in hit)) { hit[p] = 1; print "0\t" p }
            if (!sub(/\/[^\/]*$/, "", p)) break
          } }
        END { if (last != "\0010") for (p in q) print "2\t" p }' <(printf '%s' "${rels[$repo]}") -)
  done
}

# _purge_tracked PATH — tri-state, per _purge_tracked_load: 0 git tracks files under PATH, 1 no
# repository owns PATH or it tracks nothing there, 2 unknown (callers must keep PATH).
_purge_tracked() { return "${_PURGE_TRACKED[$1]:-1}"; }

# _purge_ignored DIR NAME — 0 git ignores DIR/NAME, 1 not ignored or no repository, 2 unknown.
# Only the project's own repository below $HOME answers (_purge_gitroot): a dotfiles repository
# at $HOME whose .gitignore says `*` must not make every folder below it look rebuildable.
_purge_ignored() {
  local rc=0
  _purge_gitroot "$1"
  [[ -n "$_PURGE_GITROOT" ]] || return 1
  _purge_git "$1" check-ignore -q -- "$2" || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# _purge_valid ARTIFACT ROOT... — 0 purgeable, 1 not an artifact (ignored silently), 2 keep and
# say so (git state unknown). Rules: absolute, no control characters, a real directory (not a
# symlink), not a repository itself, not inside a $HOME dot-dir no ROOT points into, a named rule
# (_purge_rule) or a tagged cache (_purge_tagged_cache), and nothing under it tracked by git
# (_purge_tracked_load must have seen ARTIFACT). Sets _PURGE_TAGGED when only the cache tag
# matched: a tag is the owner's hint, so those are offered in the picker and nowhere else.
_purge_valid() {
  local art="$1" proj="${1%/*}" name="${1##*/}" rc; shift
  _PURGE_WHY="" _PURGE_TAGGED=0
  [[ "$art" == */.nx/cache ]] && proj="${art%/.nx/cache}"
  [[ "$art" == /?*/?* && "$art" != *[[:cntrl:]]* ]] || return 1
  [[ -d "$art" && ! -L "$art" ]] || return 1
  [[ -e "$art/.git" || -L "$art/.git" ]] && return 1 # a repository: never an artifact
  _purge_covered "$art" "$@" || return 1
  rc=0; _purge_rule "$art" "$proj" "$name" || rc=$?
  case "$rc" in
    0) ;;
    1) _purge_tagged_cache "$art" "$proj" "$@" || return 1; _PURGE_TAGGED=1 ;;
    *) _PURGE_WHY="could not verify git state"; return 2 ;;
  esac
  rc=0; _purge_tracked "$art" || rc=$?
  case "$rc" in
    0) mm_debug "tracked by git, kept: $art"; return 1 ;;
    1) return 0 ;;
    *) _PURGE_WHY="could not verify git state"; return 2 ;;
  esac
}

# _purge_rule ART PROJ NAME — 0 if ART is what a project of the matching type next to it builds;
# 1 no rule matches; 2 the git state needed is unknown. Every name needs that project: ~/sdk/go*
# ships a src/internal/coverage, a deployed Nuxt app is an .output with no sources left, and a
# node prefix keeps its global packages in <prefix>/lib/node_modules.
_purge_rule() {
  local art="$1" proj="$2" name="$3" rc
  if [[ "$art" == */.nx/cache ]]; then [[ -f "$proj/nx.json" ]]; return; fi
  # a virtualenv is one whatever it is called (virtualenv and uv tag theirs as caches)
  _purge_known "$name" || { [[ -f "$art/pyvenv.cfg" ]] && _purge_py_project "$proj"; return; }
  case "$name" in
    node_modules) _purge_node_project "$proj" || return 1 ;;
    .next|.nuxt|.output|.turbo|.parcel-cache|.svelte-kit|.astro|.angular|.expo|.vite|.docusaurus)
      _purge_node_project "$proj" || return 1 ;;
    coverage)
      # a generic name: the project must own it and its own repository call it output
      _purge_project_dir "$proj" || return 1
      rc=0; _purge_ignored "$proj" "$name" || rc=$?
      case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac ;;
    __pycache__) _purge_pycache "$art" || return 1 ;;
    # pytest, mypy and ruff write a CACHEDIR.TAG of their own into these: either that tag or a
    # python project next to them proves the tool, not a person, made the folder.
    .pytest_cache|.mypy_cache|.ruff_cache) _purge_py_project "$proj" || _purge_cachedir_tag "$art" || return 1 ;;
    .tox|.nox) _purge_py_project "$proj" || return 1 ;;
    .gradle) _purge_has "$proj" build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradlew || return 1 ;;
    .terragrunt-cache) [[ -f "$proj/terragrunt.hcl" ]] || return 1 ;;
    .dart_tool) [[ -f "$proj/pubspec.yaml" ]] || return 1 ;;
    .zig-cache|zig-out) [[ -f "$proj/build.zig" ]] || return 1 ;;
    .cxx) _purge_has "$proj" build.gradle build.gradle.kts CMakeLists.txt || return 1 ;;
    target) [[ -f "$proj/Cargo.toml" || -f "$proj/pom.xml" ]] || return 1 ;;
    build|dist)
      [[ -f "$proj/package.json" || -f "$proj/pyproject.toml" || -f "$proj/build.gradle" ||
         -f "$proj/build.gradle.kts" ]] || return 1
      rc=0; _purge_ignored "$proj" "$name" || rc=$?
      case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac ;;
    venv|.venv) [[ -f "$art/pyvenv.cfg" ]] || return 1 ;;
    vendor) [[ -f "$proj/composer.json" ]] || return 1 ;;
    .build) [[ -f "$proj/Package.swift" ]] || return 1 ;;
    obj) _purge_dotnet_project "$proj" || return 1 ;;
    bin) _purge_dotnet_project "$proj" && [[ -d "$art/Debug" || -d "$art/Release" ]] || return 1 ;;
    bower_components) [[ -f "$proj/bower.json" ]] || return 1 ;;
    .pnpm-store) [[ -f "$proj/package.json" || -f "$proj/pnpm-workspace.yaml" ]] || return 1 ;;
  esac
  return 0
}

# _purge_has DIR FILE... — 0 if DIR holds one of FILEs.
_purge_has() {
  local d="$1" f; shift
  for f; do [[ -f "$d/$f" ]] && return 0; done
  return 1
}

# _purge_node_project DIR — 0 if DIR is a node or deno project root.
_purge_node_project() { _purge_has "$1" "${_PURGE_NODE_FILES[@]}"; }

# _purge_py_project DIR — 0 if DIR is a python project root (a requirements*.txt counts).
_purge_py_project() {
  _purge_has "$1" "${_PURGE_PY_FILES[@]}" && return 0
  local f
  for f in "$1"/requirements*.txt; do [[ -f "$f" ]] && return 0; done
  return 1
}

# _purge_project_dir DIR — 0 if DIR is a project root of any kind (_PURGE_PROJECT_FILES).
_purge_project_dir() {
  local f
  for f in "${_PURGE_PROJECT_FILES[@]}"; do [[ -e "$1/$f" || -L "$1/$f" ]] && return 0; done
  return 1
}

# _purge_pycache ART — 0 if ART holds nothing but compiled modules (regular *.pyc / *.pyo files),
# which python writes itself and rebuilds on the next import; an unreadable one is not one.
_purge_pycache() {
  local other
  other=$(find "$1" -xdev -mindepth 1 \
    ! \( -type f \( -name '*.pyc' -o -name '*.pyo' \) \) -print -quit 2>/dev/null) || return 1
  [[ -z "$other" ]]
}

# _purge_dotnet_project DIR — 0 if DIR holds a .NET project file.
_purge_dotnet_project() {
  local f
  for f in "$1"/*.csproj "$1"/*.fsproj "$1"/*.vbproj; do [[ -f "$f" ]] && return 0; done
  return 1
}

# _purge_cachedir_tag DIR — 0 if DIR holds a real CACHEDIR.TAG (a regular file starting with the
# standard signature, https://bford.info/cachedir/).
_purge_cachedir_tag() {
  local tag="$1/CACHEDIR.TAG" sig
  [[ -f "$tag" && ! -L "$tag" ]] || return 1
  read -r -N "${#_PURGE_CACHEDIR_SIG}" sig <"$tag" 2>/dev/null || return 1
  [[ "$sig" == "$_PURGE_CACHEDIR_SIG" ]]
}

# _purge_tagged_cache ART PROJ ROOT... — 0 if ART tags itself a cache (_purge_cachedir_tag) and
# sits directly in a project (one of _PURGE_PROJECT_FILES next to it), never a scan root itself
# nor directly in $HOME. People also tag folders only to keep them out of backups, so a tag is a
# hint, not proof: callers offer these in the picker only (see _PURGE_TAGGED).
_purge_tagged_cache() {
  local art="$1" proj="$2" r; shift 2
  _purge_cachedir_tag "$art" || return 1
  [[ "$proj" != "$HOME" ]] || return 1
  for r; do [[ "$art" != "$r" ]] || return 1; done
  _purge_project_dir "$proj"
}

# _purge_sync_marker DIR — the file-sync tool whose marker DIR carries, or nothing: Syncthing's
# .stfolder, Dropbox's .dropbox / .dropbox.cache, the Nextcloud and ownCloud clients' .sync_*.db,
# ._sync_*.db and .owncloudsync.log, Resilio Sync's .sync/ID.
_purge_sync_marker() {
  local d="$1" f
  [[ -e "$d/.stfolder" ]] && { printf 'Syncthing'; return 0; }
  [[ -e "$d/.dropbox" || -e "$d/.dropbox.cache" ]] && { printf 'Dropbox'; return 0; }
  [[ -e "$d/.sync/ID" ]] && { printf 'Resilio Sync'; return 0; }
  [[ -e "$d/.owncloudsync.log" ]] && { printf 'Nextcloud or ownCloud'; return 0; }
  for f in "$d"/.sync_*.db "$d"/._sync_*.db; do
    [[ -e "$f" ]] && { printf 'Nextcloud or ownCloud'; return 0; }
  done
  return 1
}

# Which folders a sync tool owns, per _purge_synced; one answer per directory per run.
declare -A _PURGE_SYNCED=()

# _purge_synced ART ROOT... — the file-sync tool that keeps a folder above ART in step with other
# devices, or nothing. Ancestors are read from ART's project up to the ROOT that covers it, or
# $HOME. Deleting below such a folder deletes on every device it syncs to, and the other devices
# cannot rebuild it, so callers offer these in the picker only.
_purge_synced() {
  local d="${1%/*}" r why="" stop
  local -a walked=()
  shift
  while [[ "$d" == /?* ]]; do
    if [[ -n "${_PURGE_SYNCED[$d]+x}" ]]; then why="${_PURGE_SYNCED[$d]}"; break; fi
    walked+=("$d")
    why=$(_purge_sync_marker "$d") && break
    stop=0; [[ "$d" == "$HOME" ]] && stop=1
    for r; do [[ "$d" == "$r" ]] && stop=1; done
    (( stop )) && break
    d="${d%/*}"
  done
  for d in "${walked[@]}"; do _PURGE_SYNCED[$d]="$why"; done
  [[ -n "$why" ]] && printf '%s' "$why"
}

# _purge_gitroot DIR — sets _PURGE_GITROOT to the nearest ancestor-or-self holding .git, below
# $HOME (a dotfiles repo at $HOME must not group every project together); empty if none.
_purge_gitroot() {
  local d="$1"
  _PURGE_GITROOT=""
  while [[ "$d" == /?* && "$d" != "$HOME" ]]; do
    [[ -e "$d/.git" ]] && { _PURGE_GITROOT="$d"; return; }
    d="${d%/*}"
  done
}

# _purge_gitdir_of WORKTREE — sets _PURGE_GITDIR to the per-worktree git dir (WORKTREE/.git, or
# where its .git file points); 1 if it can't be resolved.
_purge_gitdir_of() {
  local e="$1/.git" gd=""
  if [[ -d "$e" && ! -L "$e" ]]; then _PURGE_GITDIR="$e"; return 0; fi
  [[ -f "$e" && ! -L "$e" ]] || return 1
  IFS= read -r gd <"$e" 2>/dev/null
  [[ "$gd" == "gitdir: "?* ]] || return 1
  gd="${gd#gitdir: }"
  [[ "$gd" == /* ]] || gd="$1/$gd"
  [[ -d "$gd" ]] || return 1
  _PURGE_GITDIR="$gd"
}

# _purge_common_dir GITENTRY — absolute common git dir of the repository a .git entry belongs to
# (a worktree's .git file leads to <repo>/.git/worktrees/<name>, whose commondir leads home).
_purge_common_dir() {
  local gd c
  _purge_gitdir_of "${1%/.git}" || return 1
  gd="$_PURGE_GITDIR" c="$_PURGE_GITDIR"
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
      _purge_gitdir_of "${f%/.git}" || continue
      gd="$_PURGE_GITDIR"
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

# _purge_deep_prune — the find -regex pattern of what a deep activity walk must not descend into:
# .git and the artifact names, whose mtimes are a tool's writes, not the user's work.
_purge_deep_prune() {
  local n out=""
  for n in .git "${_PURGE_TARGETS[@]}" "${_PURGE_CONDITIONAL[@]}"; do out+="\\|${n//./\\.}"; done
  printf '.*/\\(%s\\)' "${out:2}"
}

# _purge_deep_mtime DIR... — "EPOCH<TAB>DIR" for each DIR: the newest mtime anywhere below it,
# artifacts and .git pruned; "?<TAB>DIR" when the walk failed or timed out, so the caller keeps
# DIR instead of calling it idle. 4 walks in parallel, each bounded by _PURGE_DEEP_TIMEOUT.
_purge_deep_mtime() {
  printf '%s\0' "$@" | MM_DEEP_RE=$(_purge_deep_prune) MM_DEEP_TIMEOUT=$_PURGE_DEEP_TIMEOUT \
    xargs -0 -P4 -n1 bash -c '
      t=$(timeout "$MM_DEEP_TIMEOUT" find "$1" -xdev -regextype posix-basic -regex "$MM_DEEP_RE" \
            -prune -o -printf "%T@\n" 2>/dev/null |
          awk '\''{ t = int($1); if (t > m) m = t } END { printf "%.0f", m }'\''
          exit "${PIPESTATUS[0]}") || t="?"
      printf "%s\t%s\n" "${t:-?}" "$1"' _
}

# _purge_activity DIR<TAB>GITROOT... — "EPOCH<TAB>DIR" for each DIR: the newest mtime among DIR,
# its top-level files, and the git index/HEAD of GITROOT's repository (worktree .git files are
# followed to their gitdir). A DIR with no repository (empty GITROOT) is read to the bottom
# instead (_purge_deep_mtime): a file edited today deep in ~/Documents is activity too. One find
# and one stat for all DIRs. A DIR whose repository's git dir or whose deep walk can't be read is
# left out (activity unknown).
_purge_activity() {
  local pair dir git
  local -a dirs=() deep=() probes=() map=()
  local -A gd=()
  for pair; do
    dir="${pair%%$'\t'*}" git="${pair#*$'\t'}"
    if [[ -n "$git" && -z "${gd[$git]+x}" ]]; then
      gd[$git]=""
      if _purge_gitdir_of "$git"; then
        gd[$git]="$_PURGE_GITDIR"
        [[ -f "$git/.git" ]] && { probes+=("$git/.git"); map+=("P"$'\t'"$git/.git"$'\t'"$git"); }
        probes+=("$_PURGE_GITDIR/index" "$_PURGE_GITDIR/HEAD")
        map+=("P"$'\t'"$_PURGE_GITDIR/index"$'\t'"$git" "P"$'\t'"$_PURGE_GITDIR/HEAD"$'\t'"$git")
      fi
    fi
    [[ -z "$git" || -n "${gd[$git]}" ]] || continue
    dirs+=("$dir"); map+=("Q"$'\t'"$dir"$'\t'"$git")
    [[ -n "$git" ]] || deep+=("$dir")
  done
  (( ${#dirs[@]} )) || return 0
  {
    find "${dirs[@]}" -maxdepth 0 -printf '%T@\t%p\n' 2>/dev/null
    find "${dirs[@]}" -mindepth 1 -maxdepth 1 -type f -printf '%T@\t%h\n' 2>/dev/null
    (( ${#deep[@]} )) && _purge_deep_mtime "${deep[@]}"
    (( ${#probes[@]} )) && stat -c '%Y'$'\t''%n' -- "${probes[@]}" 2>/dev/null
  } | awk -F '\t' 'NR == FNR { if ($1 == "Q") q[$2] = $3; else pr[$2] = $3; next }
    ($2 in q) { if ($1 == "?") { bad[$2] = 1; next }
      t = int($1); if (t > d[$2]) d[$2] = t; next }
    ($2 in pr) { t = int($1); g = pr[$2]; if (t > r[g]) r[g] = t }
    END {
      for (k in q) {
        if (k in bad) continue
        t = d[k]; g = q[k]
        if (g != "" && r[g] > t) t = r[g]
        if (t > 0) printf "%.0f\t%s\n", t, k
      } }' <(printf '%s\n' "${map[@]}") -
}

# _purge_changed GITROOT PROJ... — "EPOCH<TAB>PROJ" for each PROJ (GITROOT or a directory in it)
# holding files git reports modified or untracked (not ignored), EPOCH the newest of their mtimes:
# edits deep in src/ count as activity before they are staged. One git call for all PROJs;
# "?<TAB>PROJ" for every PROJ when it fails or times out (activity unknown).
_purge_changed() {
  local root="$1" t rel p; shift
  while IFS=$'\t' read -r t rel; do
    printf '%s\t%s\n' "$t" "$root${rel#.}"
  done < <({ _purge_git "$root" ls-files -m -o --exclude-standard -z |
      (cd -- "$root" && xargs -0 -r stat -c '%Y %n' -- 2>/dev/null)
    printf '\1%s\n' "${PIPESTATUS[0]}"; } |
    awk 'NR == FNR { q[$0] = 1; next }
      { last = $0 }
      /^[0-9]+ / {
        t = $1 + 0; p = "./" substr($0, index($0, " ") + 1)
        while (1) {
          if ((p in q) && t > m[p]) m[p] = t
          if (!sub(/\/[^\/]*$/, "", p)) break
        } }
      END {
        for (p in q)
          if (last == "\0010") { if (p in m) printf "%.0f\t%s\n", m[p], p }
          else printf "?\t%s\n", p
      }' <(for p; do if [[ "$p" == "$root" ]]; then echo .; else printf './%s\n' "${p#"$root"/}"; fi; done) -)
}

declare -A _PURGE_ACT=()

# _purge_activity_load PROJ<TAB>GITROOT... — fill _PURGE_ACT with each PROJ's last activity
# epoch: its own and top-level mtimes, its repository's index/HEAD (_purge_activity) and the files
# git reports changed or new (deep edits not staged yet, _purge_changed). One probe per
# repository. A PROJ whose activity is unknown is absent or empty.
_purge_activity_load() {
  local pair t p g cur
  local -A changed=()
  local -a list=()
  _PURGE_ACT=()
  for pair; do
    g="${pair#*$'\t'}"; [[ -n "$g" ]] && changed[$g]+="${pair%%$'\t'*}"$'\n'
  done
  while IFS=$'\t' read -r t p; do _PURGE_ACT[$p]=$t; done < <(_purge_activity "$@")
  for g in "${!changed[@]}"; do
    mapfile -t list <<<"${changed[$g]%$'\n'}"
    while IFS=$'\t' read -r t p; do
      cur="${_PURGE_ACT[$p]:-}"
      if [[ "$t" == "?" ]]; then _PURGE_ACT[$p]=""
      elif [[ -n "$cur" && "$t" =~ ^[0-9]+$ ]] && (( t > cur )); then _PURGE_ACT[$p]=$t; fi
    done < <(_purge_changed "$g" "${list[@]}")
  done
}

# _purge_busy PATH... — the given paths that are in use (or have something in use below them),
# per one pass over the in-use snapshot.
_purge_busy() {
  (( $# )) || return 0
  printf '%s\n' "$@" | awk 'NR == FNR { q[$0] = 1; next }
    { p = $0; while (p != "") { if (p in q) print p; if (!sub(/\/[^\/]*$/, "", p)) break } }' \
    - <(mm_inuse_paths) | sort -u
}

# _purge_probe ART — "HOLDS<TAB>MTIME" for ART from one bounded walk. HOLDS is what makes it
# never purgeable: "git" (a .git entry anywhere inside: a nested repository), "keypair" (a
# *-keypair.json file: Solana and Anchor keep program keypairs in target/deploy/, and losing one
# loses the deploy authority), "tfstate" (*.tfstate or *.tfstate.backup: local Terraform state is
# the only record of what is deployed, and terragrunt runs terraform inside .terragrunt-cache),
# else empty. MTIME is the newest mtime of ART and anything inside it: a tool writing there is
# activity, whatever the project's own files say. Both are "?" when the walk failed or timed out
# (what cannot be read is never purged).
_purge_probe() {
  local out
  out=$(timeout "${MM_SIZE_TIMEOUT:-300}" find "$1" -xdev -printf '%y\t%T@\t%p\n' 2>/dev/null |
    awk -F'\t' -v root="$1" 'BEGIN { h = 0 }
      { t = int($2); if (t > m) m = t }
      NF == 3 && $3 == root { next }
      { n = $NF; sub(/.*\//, "", n)
        if (n == ".git") h = 3
        else if ($1 == "f" && n ~ /-keypair\.json$/) { if (h < 2) h = 2 }
        else if ($1 == "f" && n ~ /\.tfstate(\.backup)?$/) { if (h < 1) h = 1 } }
      END { split("tfstate keypair git", name, " ")
        printf "%s\t%.0f", (h ? name[h] : ""), m }'
    exit "${PIPESTATUS[0]}") || { printf '?\t?'; return 0; }
  printf '%s' "$out"
}

# _purge_measure PATH... — NUL-separated "size<TAB>frees<TAB>holds<TAB>mtime<TAB>path" per
# artifact (see mm_size_frees and _purge_probe), 4 in parallel. size and frees are "?" when
# sizing failed or timed out (size unknown), holds and mtime when the probe could not read it.
_purge_measure() {
  (
    export -f mm_size_frees _purge_probe; export MM_SIZE_TIMEOUT MM_SIZE_SUDO
    printf '%s\0' "$@" | xargs -0 -P4 -n1 bash -c '
      h=$(_purge_probe "$1")
      if r=$(mm_size_frees "$1") && [[ "$r" =~ ^[0-9]+\ [0-9]+$ ]]; then s=${r% *} f=${r#* }; else s="?" f="?"; fi
      printf "%s\t%s\t%s\t%s\0" "$s" "$f" "$h" "$1"' _
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

# _purge_to_trash ARTIFACT — 0 if ARTIFACT goes to the Trash instead of a permanent delete: a
# virtualenv (pyvenv.cfg), whatever it is called, can hold hand-installed or patched packages.
_purge_to_trash() {
  [[ "${1##*/}" == venv || "${1##*/}" == .venv || -f "$1/pyvenv.cfg" ]]
}

# ---------------------------------------------------------------- pnpm store
# pnpm hard-links every package file from its content-addressed store into node_modules, so
# deleting a node_modules (or a worktree holding one) frees little by itself: the bytes go when
# `pnpm store prune` drops the store files nothing links to any more.

_PURGE_PNPM_PATHS=()   # pnpm-managed artifacts/worktrees removed (or that would be, in a dry run)
_PURGE_STORE_BYTES=0   # what the pnpm store prune after them freed (a scheduled dry run: estimate)
_PURGE_MODE=ask        # see _purge_run

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
# missing or running or the store is whitelisted. Sets _PURGE_PRUNE_LINE (the banner line) and
# _PURGE_STORE_BYTES (freed, from the store filesystem's df delta), which its history row carries.
_purge_pnpm_prune() {
  local store before after
  _PURGE_PRUNE_LINE="" _PURGE_STORE_BYTES=0
  store=$(_purge_pnpm_store) || return 0
  if mm_whitelisted "$store"; then _PURGE_PRUNE_LINE='pnpm store prune: skipped (store whitelisted)'; return 0; fi
  if mm_proc_running pnpm; then _PURGE_PRUNE_LINE='pnpm store prune: skipped (pnpm busy)'; return 0; fi
  before=$(mm_free_bytes "$store")
  if ! mm_run --measured "prune the pnpm store" env -C "$HOME" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 timeout 300 pnpm store prune </dev/null; then
    _PURGE_PRUNE_LINE='pnpm store prune: failed'; return 0
  fi
  after=$(mm_free_bytes "$store")
  _PURGE_STORE_BYTES=$(( after > before ? after - before : 0 ))
  mm_log run "prune the pnpm store" "$_PURGE_STORE_BYTES"
  _PURGE_PRUNE_LINE="pnpm store prune: freed $(mm_human "$_PURGE_STORE_BYTES")"
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
  local w="$1" newest ct
  newest=$({
    find "$w" -maxdepth 1 \( -type f -o -path "$w" \) -printf '%T@\n' 2>/dev/null
    _purge_gitdir_of "$w" && stat -c %Y -- "$_PURGE_GITDIR/index" "$_PURGE_GITDIR/HEAD" 2>/dev/null
    ct=$(_purge_git "$w" log -1 --format=%ct HEAD) && printf '%s\n' "$ct"
  } | sort -n | tail -n1)
  newest="${newest%.*}"
  [[ "$newest" =~ ^[0-9]+$ ]] || { echo 0; return; }
  echo $(( $(date +%s) - newest ))
}

# _purge_wt_clean WORKTREE — 0 clean, 1 has changes, 2 unknown. Clean still allows git-ignored
# entries, which `git worktree remove` deletes too: they are left in _PURGE_WT_IGN, relative to
# WORKTREE (a directory matching an ignore pattern is one "dir/" entry), for _purge_wt_ignored.
_purge_wt_clean() {
  local r
  local -a recs=()
  _PURGE_WT_IGN=()
  mapfile -d '' -t recs < <(_purge_git "$1" status --porcelain -z --untracked-files=all \
    --ignored=matching --ignore-submodules=none && printf '\1\0')
  [[ "${recs[-1]:-}" == $'\1' ]] || return 2
  for r in "${recs[@]:0:${#recs[@]}-1}"; do
    [[ "$r" == '!! '?* ]] || return 1
    _PURGE_WT_IGN+=("${r:3}")
  done
}

# _purge_wt_ignored WORKTREE MAIN ENTRY... — 0 if removing WORKTREE loses nothing with its
# git-ignored ENTRYs (from _purge_wt_clean): each is an artifact a purge rule names
# (_purge_wt_artifact) or a regular file MAIN, the main worktree, holds byte for byte at the same
# path (a copied .env), and no repository hides anywhere in WORKTREE (a nested .git) nor a deploy
# keypair in one of those artifacts. Sets _PURGE_WT_GOES to what goes along ("node_modules ×2,
# .env (same as main)"); else 1, and _PURGE_WT_WHY names what would be lost. Vetting stops at three
# entries that would be lost, or after _PURGE_GIT_TIMEOUT seconds (keep).
_purge_wt_ignored() {
  local w="$1" m="$2" wr e p n hit along="" k
  local -a ents=("${@:3}") arts=() names=() copies=() held=() repos=() hits=() lost=()
  local -A count=()
  local -i deadline=$(( SECONDS + _PURGE_GIT_TIMEOUT ))
  _PURGE_WT_GOES="" _PURGE_WT_WHY="could not verify its files"
  wr=$(realpath -e -- "$w") || return 1
  for (( k = 0; k < ${#ents[@]} && ${#held[@]} < 3 && SECONDS <= deadline; k++ )); do
    e="${ents[k]}" p="$w/${ents[k]%/}"
    if [[ "$e" == */ ]] && _purge_wt_artifact "$p"; then
      n="${p##*/}"; [[ "$p" == */.nx/cache ]] && n=.nx/cache
      arts+=("$p"); [[ -n "${count[$n]:-}" ]] || names+=("$n")
      count[$n]=$(( ${count[$n]:-0} + 1 ))
    elif [[ "$e" != */ ]] && _purge_wt_copy "$p" "$m/$e" "$wr"; then copies+=("$e")
    else held+=("$e")
    fi
  done
  # one walk; the worktree's own .git file is the only .git at depth 1
  mapfile -d '' -t hits < <(timeout "$_PURGE_SCAN_TIMEOUT" find "$w" -mindepth 2 \( -name .git -prune -print0 \) \
    -o \( -type f -name '*-keypair.json' -print0 \) 2>/dev/null; printf '\1%s\0' "$?")
  for hit in "${hits[@]:0:${#hits[@]}-1}"; do
    if [[ "${hit##*/}" == .git ]]; then p="${hit%/.git}"; repos+=("${p#"$w"/}"); continue; fi
    for p in "${arts[@]}"; do [[ "$hit" == "$p"/* ]] && { held+=("${hit#"$w"/}"); break; }; done
  done
  (( ${#repos[@]} )) && lost+=("holds a git repository: $(_purge_wt_names 0 "${repos[@]}")")
  (( ${#held[@]} )) && lost+=("ignored files: $(_purge_wt_names $(( ${#ents[@]} - k )) "${held[@]}")")
  (( ${#held[@]} || k == ${#ents[@]} )) || lost+=("could not check every ignored file")
  [[ "${hits[-1]}" == $'\1'0 ]] || lost+=("could not read all its folders")
  if (( ${#lost[@]} )); then
    printf -v _PURGE_WT_WHY '%s; ' "${lost[@]}"; _PURGE_WT_WHY="${_PURGE_WT_WHY%; }"
    return 1
  fi
  for n in "${names[@]}"; do
    along+=", ${n//[[:cntrl:]]/?}"; [[ "${count[$n]}" == 1 ]] || along+=" ×${count[$n]}"
  done
  for e in "${copies[@]}"; do along+=", ${e//[[:cntrl:]]/?} (same as main)"; done
  _PURGE_WT_GOES="${along#, }" _PURGE_WT_WHY=""
}

# _purge_wt_artifact DIR — 0 if DIR, a real directory, is an artifact a purge rule names
# (_purge_rule; the project is the folder holding it, as for _purge_valid). "Can't tell" is no.
_purge_wt_artifact() {
  local proj="${1%/*}"
  [[ "$1" == */.nx/cache ]] && proj="${1%/.nx/cache}"
  [[ -d "$1" && ! -L "$1" ]] && _purge_rule "$1" "$proj" "${1##*/}"
}

# _purge_wt_copy FILE ORIG DIR — 0 if FILE is a regular file and ORIG, resolved, a regular file
# outside DIR with the same bytes (a .env copied from the main checkout): nothing is lost with FILE.
_purge_wt_copy() {
  local o
  [[ -f "$1" && ! -L "$1" ]] || return 1
  o=$(realpath -e -- "$2" 2>/dev/null) && [[ -f "$o" && "$o" != "$3"/* ]] || return 1
  timeout "$_PURGE_GIT_TIMEOUT" cmp -s -- "$1" "$o"
}

# _purge_wt_names EXTRA ITEM... — "a, b, c +4 more": the first three ITEMs (control characters
# shown as ?) and how many more there are (the other ITEMs plus EXTRA).
_purge_wt_names() {
  local -i more=$(( $1 + ($# > 4 ? $# - 4 : 0) ))
  local s="" e
  shift
  for e in "${@:1:3}"; do s+=", ${e//[[:cntrl:]]/?}"; done
  (( more )) && s+=" +$more more"
  printf '%s' "${s#, }"
}

# _purge_wt_reflog WORKTREE — 0 if every commit in WORKTREE's HEAD reflog is on a branch, tag or
# remote-tracking branch. `git worktree remove` deletes that reflog, so a commit only it holds (made
# on a detached HEAD, dropped by a reset) would be orphaned. Else 1, _PURGE_WT_WHY says why.
_purge_wt_reflog() {
  local log n
  _PURGE_WT_WHY="could not verify git state"
  log=$(_purge_git "$1" rev-list -g HEAD) || return 1
  if [[ -n "$log" ]]; then
    n=$(_purge_git "$1" rev-list --count --stdin --not --branches --tags --remotes <<<"$log") || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n == 0 )) || { _PURGE_WT_WHY="$n commit$( (( n > 1 )) && echo s) only in its HEAD reflog"; return 1; }
  fi
  _PURGE_WT_WHY=""
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

# _purge_wt_eval I — decide worktree I. Sets _WT_STATE, _WT_WHY (keep reason), _WT_IDLE (seconds),
# _WT_MERGE (a _purge_wt_landed label, "PR merged", "PR closed" or "unmerged") and _WT_GOES (the
# git-ignored artifacts and copies that would go with it, per _purge_wt_ignored):
#   offer   clean, nothing git-ignored but artifacts and copies of the main worktree's files, no
#           nested repository, unlocked, not in use, no commit that only its HEAD or HEAD reflog
#           holds, idle >= 1h, and finished (its work landed) or unmerged and idle >= 30 days
#   keep    would be offered but one of those checks fails (_WT_WHY says which)
#   active  idle < 1h, or unmerged and idle < 30 days (not shown)
#   skip    the main worktree, or not a worktree of this repository
_purge_wt_eval() {
  local i="$1" w="${_WT_PATH[$1]}" c="${_WT_COMMON[$1]}" head="${_WT_HEAD[$1]}" br="${_WT_BRANCH[$1]}"
  local rc why="" holders
  local -a ign=()
  _WT_STATE=skip _WT_WHY="" _WT_IDLE=0 _WT_MERGE="" _WT_GOES=""
  [[ "${_WT_IS_MAIN[$i]}" == 0 ]] || return 0
  [[ "$w" == /?* && "$w" != *[[:cntrl:]]* && -d "$w" && ! -L "$w" ]] || return 0
  # the directory must really be a worktree of this repository
  [[ "$(_purge_common_dir "$w/.git")" == "$c" ]] || { mm_debug "not a worktree of $c: $w"; return 0; }
  _WT_IDLE=$(_purge_wt_idle "$w")
  (( _WT_IDLE >= _PURGE_WT_FINISHED_IDLE )) || { _WT_STATE=active; return 0; }
  # Agent state (e.g. ~/.cursor/worktrees) is waived here only: git itself vouches for the content.
  if mm_protected "$w" >/dev/null; then why="protected"
  elif [[ "${_WT_LOCKED[$i]}" == 1 ]]; then why="locked"
  elif mm_in_use "$w"; then why=$(mm_inuse_why "$w" || echo "in use")
  elif MM_KEEP_AGENT_STATE=0 mm_whitelisted "$w"; then why="whitelisted"
  else
    rc=0; _purge_wt_clean "$w" || rc=$?
    case "$rc" in
      0) ign=("${_PURGE_WT_IGN[@]}") ;;
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
  [[ -n "$why" ]] || _purge_wt_reflog "$w" || why="$_PURGE_WT_WHY"
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
  # what else `git worktree remove` deletes (ignored files, nested repositories): a walk, so last
  [[ -n "$why" ]] || _purge_wt_ignored "$w" "${_WT_MAIN[$i]}" "${ign[@]}" || why="$_PURGE_WT_WHY"
  if [[ -n "$why" ]]; then _WT_STATE=keep _WT_WHY="$why"; return 0; fi
  _WT_STATE=offer _WT_GOES="$_PURGE_WT_GOES"
}

# _purge_worktrees YES ROOT... — the worktrees section for every linked worktree reachable from
# ROOTs: finished ones (work landed) and abandoned ones (unmerged, idle 30+ days). Removes only
# after a terminal confirmation; never with --yes or in a dry run. Sets _PURGE_WT_DONE /
# _PURGE_WT_BYTES (removed) and _PURGE_WT_OFFERED / _PURGE_WT_OFFER_BYTES, all counted in frees
# (mm_size_frees), _PURGE_WT_FINISHED (offered finished ones) and _PURGE_WT_PNPM (offered
# pnpm-managed worktrees). Never `git worktree prune`: `git worktree remove` drops its own record,
# and a worktree whose folder is only absent (an unplugged drive, a path that exists only inside
# a dev container) must keep its record, which holds its index, HEAD and reflog.
_purge_worktrees() {
  local yes="$1"; shift
  local i n=0 active=0 sz fr pn line idx desc
  local -a offer=() lines=() sel=()
  local -A size=() label=() pnpm=() goes=()
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
      keep) mm_tilde "${_WT_PATH[$i]}"; _purge_kept "$REPLY · $desc" "$_WT_WHY" ;;
      offer)
        if ! { sz=$(mm_size_frees "${_WT_PATH[$i]}") && [[ "$sz" =~ ^[0-9]+\ [0-9]+$ ]]; }; then
          mm_tilde "${_WT_PATH[$i]}"; _purge_kept "$REPLY · $desc" "size unknown"; continue
        fi
        fr=${sz#* } sz=${sz% *}
        size[$i]=$fr pn=0
        _purge_pnpm_managed "${_WT_PATH[$i]}" && { pn=1 pnpm[$i]=1; _PURGE_WT_PNPM+=("${_WT_PATH[$i]}"); }
        mm_tilde "${_WT_PATH[$i]}"
        label[$i]="$REPLY · $desc · idle $(_purge_idle_label "$_WT_IDLE") · $(_purge_size_label "$sz" "${size[$i]}" "$pn")"
        goes[$i]="$_WT_GOES" label[$i]+="${_WT_GOES:+ · ignored: $_WT_GOES}"
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
    i="${offer[0]}"; mm_tilde "${_WT_PATH[$i]}"
    mm_confirm "Remove worktree $REPLY${goes[$i]:+ and its ignored ${goes[$i]}}? (git worktree remove; branch kept)" && sel=("$i")
  else
    for i in "${offer[@]}"; do lines+=("$i  ${label[$i]}"); done
    while IFS= read -r line; do
      idx="${line%%[[:space:]]*}"
      [[ "$idx" =~ ^[0-9]+$ && -n "${label[$idx]:-}" ]] && sel+=("$idx")
    done < <(printf '%s\n' "${lines[@]}" |
      mm_pick "TAB marks worktrees to remove (git worktree remove, with the ignored files listed; branches kept), Enter confirms")
  fi
  (( ${#sel[@]} )) || { mm_info "No worktrees removed."; return 0; }

  # Re-check right before acting: the prompt may have taken a while.
  mm_inuse_refresh
  local w m c rc
  for i in "${sel[@]}"; do
    w="${_WT_PATH[$i]}" m="${_WT_MAIN[$i]}" c="${_WT_COMMON[$i]}"
    if mm_in_use "$w"; then mm_tilde "$w"; mm_skip "$REPLY" "$(mm_inuse_why "$w" || echo "in use")"; continue; fi
    if ! _purge_wt_clean "$w" || ! _purge_wt_ignored "$w" "$m" "${_PURGE_WT_IGN[@]}" ||
      [[ "$_PURGE_WT_GOES" != "${goes[$i]}" ]] || ! _purge_wt_reflog "$w"; then
      mm_tilde "$w"; _purge_kept "$REPLY" "changed since the scan"; continue
    fi
    if [[ -d "$m" ]]; then
      mm_run "remove worktree $w" timeout 120 git -c core.fsmonitor=false -C "$m" worktree remove -- "$w"; rc=$?
    else
      mm_run "remove worktree $w" timeout 120 git -c core.fsmonitor=false --git-dir="$c" worktree remove -- "$w"; rc=$?
    fi
    (( rc == 0 )) || continue
    mm_log worktree "$w" "${size[$i]}" "${_WT_BRANCH[$i]:-detached}"
    mm_tilde "$w"
    mm_ok "$REPLY" "removed, freed $(mm_human "${size[$i]}")${_WT_BRANCH[$i]:+, branch ${_WT_BRANCH[$i]} kept}"
    _PURGE_WT_DONE=$((_PURGE_WT_DONE + 1)) _PURGE_WT_BYTES=$((_PURGE_WT_BYTES + size[$i]))
    [[ -n "${pnpm[$i]:-}" ]] && _PURGE_PNPM_PATHS+=("$w")
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
  local mode=ask
  (( all )) && mode=all
  (( yes )) && mode=yes
  _purge_run "$mode" "$days" "${dirs[@]}"
}

# _purge_run MODE DAYS [DIR...] — scan, list and purge. MODE: ask (a terminal picks; stale
# artifacts by default), all (--all: every artifact by default), yes (--yes: stale artifacts, no
# questions, worktrees only listed) or scheduled (`mm schedule run`: like yes, under a section
# instead of the header and banner, worktrees left out, and roots that are gone are skipped, not
# fatal). The pnpm store prune that follows is counted in _PURGE_STORE_BYTES.
_purge_run() {
  _PURGE_MODE=$1
  local days=$2 all=0 yes=0
  shift 2
  local -a dirs=("$@")
  case "$_PURGE_MODE" in all) all=1 ;; yes|scheduled) yes=1 ;; esac

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
      if (( ${#roots[@]} == 0 )); then
        [[ "$_PURGE_MODE" == scheduled ]] || mm_die "none of the roots in $MM_PURGE_PATHS_FILE exist (mm purge --paths)"
        mm_section "Stale build artifacts"
        mm_tilde "$MM_PURGE_PATHS_FILE"
        mm_skip "Build artifacts" "none of the roots in $REPLY exist"
        return 0
      fi
      where="file"
    else
      roots=("$HOME") where=discover
      mapfile -d '' -t listed < <(_purge_workspace_roots)
      for r in "${listed[@]}"; do _purge_covered "$r" "${roots[@]}" || roots+=("$r"); done
    fi
  fi

  local free_before; free_before=$(mm_free_bytes /)
  if [[ "$_PURGE_MODE" == scheduled ]]; then mm_section "Stale build artifacts"; else mm_header "Purge Project Artifacts"; fi
  for r in "${missing[@]}"; do mm_tilde "$r"; mm_skip "$REPLY" "not found"; done

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
  local shown=() ; for r in "${roots[@]:0:${#roots[@]}-${#extra[@]}}"; do mm_tilde "$r"; shown+=("$REPLY"); done
  mm_info "${C_DIM}Scanned ${shown[*]}${extra[*]:+ + ${#extra[@]} worktree dirs elsewhere} in $((dt / 10)).$((dt % 10))s · artifacts idle > ${days}d are stale${C_RESET}"
  for r in "${timed[@]}"; do mm_tilde "$r"; mm_warn "Scan of $REPLY stopped after ${_PURGE_SCAN_TIMEOUT}s: results are partial"; done

  # ---- finished and abandoned worktrees (before artifacts: removing one takes its artifacts with it)
  _PURGE_PROMPTED=0 _PURGE_PNPM_PATHS=() _PURGE_GH="" _PURGE_SYNCED=()
  [[ "$_PURGE_MODE" == scheduled ]] || _purge_worktrees "$yes" "${roots[@]}"

  # ---- validate artifacts. picks[i] is why an artifact is only ever removed by hand: a terminal
  # picker shows it, --yes, a scheduled run and the stale/all answers never touch it.
  local -a kept_out=()
  local -A seen=() gitroot_of=()
  local -a arts=() projs=() gits=() picks=()
  local art proj anc ok g rc pick
  local pickable=0
  [[ "$MM_TTY" == 1 && ( "$_PURGE_MODE" == ask || "$_PURGE_MODE" == all ) ]] && pickable=1
  # shallowest first, so an artifact inside another one is seen as part of it
  mapfile -d '' -t cand_raw < <(for art in "${cand_raw[@]}"; do
      anc="${art//[!\/]/}"; printf '%s\t%s\0' "${#anc}" "$art"
    done | sort -z -s -n -t$'\t' -k1,1 | cut -z -f2-)
  _purge_tracked_load "${cand_raw[@]}"
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
    proj="${art%/*}"; [[ "$art" == */.nx/cache ]] && proj="${art%/.nx/cache}"
    if [[ -z "${gitroot_of[$proj]+x}" ]]; then _purge_gitroot "$proj"; gitroot_of[$proj]=$_PURGE_GITROOT; fi
    pick=""; (( _PURGE_TAGGED )) && pick="tagged as a cache"
    g=$(_purge_synced "$art" "${roots[@]}") && pick="${pick:+$pick, }synced by $g"
    arts+=("$art"); projs+=("$proj"); gits+=("${gitroot_of[$proj]}"); picks+=("$pick")
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
    elif [[ -n "${picks[$i]}" ]] && (( ! pickable )); then
      kept_out+=("${arts[$i]}"$'\t'"${picks[$i]}; pick it on a terminal")
    else
      cand+=("$i")
    fi
  done
  if (( ${#skip_n[@]} )); then
    mm_section "In use"
    while IFS= read -r key; do
      mm_tilde "$key"
      mm_skip "$REPLY · ${skip_n[$key]} artifact$( (( skip_n[$key] > 1 )) && echo s) (${skip_names[$key]})" "$(mm_inuse_why "$key" || echo "in use")"
    done < <(printf '%s\n' "${!skip_n[@]}" | sort)
  fi

  # ---- sizes, frees, what an artifact holds that must survive and when it was last written
  local -A size=() frees=() holds=() written=()
  local b fb h mt n=0 total=${#cand[@]}
  local -a cand_paths=() keep_cand=() freed_paths=()
  for i in "${cand[@]}"; do cand_paths+=("${arts[$i]}"); done
  if (( total )); then
    while IFS= read -r -d '' rec; do
      b="${rec%%$'\t'*}" rec="${rec#*$'\t'}" fb="${rec%%$'\t'*}" rec="${rec#*$'\t'}"
      h="${rec%%$'\t'*}" rec="${rec#*$'\t'}" mt="${rec%%$'\t'*}" p="${rec#*$'\t'}"
      size[$p]=$b frees[$p]=$fb holds[$p]=$h written[$p]=$mt; n=$((n + 1))
      [[ -t 2 ]] && printf '\r  %sMeasuring %d/%d artifacts…%s' "$CE_DIM" "$n" "$total" "$CE_RESET" >&2
    done < <(_purge_measure "${cand_paths[@]}")
    [[ -t 2 ]] && printf '\r\e[K' >&2
  fi
  for i in "${cand[@]}"; do
    art="${arts[$i]}"
    case "${holds[$art]:-}" in
      git) kept_out+=("$art"$'\t'"contains a git repository"); continue ;;
      keypair) kept_out+=("$art"$'\t'"holds a deploy keypair"); continue ;;
      tfstate) kept_out+=("$art"$'\t'"holds local Terraform state"); continue ;;
      '?') kept_out+=("$art"$'\t'"could not read what it holds"); continue ;;
    esac
    # unknown size (sizing failed or timed out, or no record) is never counted as 0
    if [[ "${size[$art]:-?}" == "?" || "${frees[$art]:-?}" == "?" ]]; then
      kept_out+=("$art"$'\t'"size unknown"); continue
    fi
    keep_cand+=("$i")
  done
  cand=("${keep_cand[@]}")

  if (( ${#kept_out[@]} )); then
    mm_section "Kept"
    for rec in "${kept_out[@]}"; do mm_tilde "${rec%%$'\t'*}"; _purge_kept "$REPLY" "${rec#*$'\t'}"; done
  fi
  if (( ${#cand[@]} == 0 )); then
    printf '\n'
    if (( ${#arts[@]} )); then mm_ok "No artifacts to purge" "every artifact found is in use or kept"
    else mm_ok "No build artifacts found"; fi
    _purge_banner "$free_before" 0
    return 0
  fi

  # ---- classify and sort by what deleting frees
  local -A pair_of=()
  for i in "${cand[@]}"; do pair_of[${projs[$i]}]="${projs[$i]}"$'\t'"${gits[$i]}"; done
  _purge_activity_load "${pair_of[@]}"
  local now; now=$(date +%s)
  local -a order=() idle=() stale=() kind=() pnpm_art=()
  local stale_bytes=0 recent_bytes=0 pick_bytes=0 stale_n=0 recent_n=0 pick_n=0 act mt shared=0
  for i in "${cand[@]}"; do
    act="${_PURGE_ACT[${projs[$i]}]:-}"
    # a write inside the artifact is activity too: a tool is still using it
    mt="${written[${arts[$i]}]:-?}"
    if [[ ! "$mt" =~ ^[0-9]+$ ]]; then act=""
    elif [[ -n "$act" ]] && (( mt > act )); then act=$mt; fi
    # unknown activity counts as recent: never selected by default
    if [[ -n "$act" ]]; then idle[i]=$(( (now - act) / 86400 )); else idle[i]=0; fi
    if [[ -n "${picks[$i]}" ]]; then
      stale[i]=0 kind[i]=pick; pick_n=$((pick_n + 1)); pick_bytes=$((pick_bytes + ${frees[${arts[$i]}]:-0}))
    elif (( idle[i] > days )); then
      stale[i]=1 kind[i]=stale; stale_n=$((stale_n + 1)); stale_bytes=$((stale_bytes + ${frees[${arts[$i]}]:-0}))
    else
      stale[i]=0 kind[i]=recent; recent_n=$((recent_n + 1)); recent_bytes=$((recent_bytes + ${frees[${arts[$i]}]:-0}))
    fi
    pnpm_art[i]=0; _purge_pnpm_managed "${arts[$i]}" && pnpm_art[i]=1
  done
  mapfile -t order < <(for i in "${cand[@]}"; do
      printf '%s\t%s\t%s\n' "${frees[${arts[$i]}]:-0}" "${size[${arts[$i]}]:-0}" "$i"
    done | sort -t$'\t' -k1,1nr -k2,2nr | cut -f3)

  mm_section "Artifacts (${#order[@]})"
  printf '  %s  %9s  %9s  %5s  %s\n' " " "SIZE" "FREES" "IDLE" "PROJECT/ARTIFACT"
  local mark row hidden_n=0 hidden_bytes=0 sz fr
  local -a shown=()
  local -A row_of=()
  for i in "${order[@]}"; do
    sz=${size[${arts[$i]}]:-0} fr=${frees[${arts[$i]}]:-0}
    mm_tilde "${arts[$i]}"
    printf -v row '%9s  %9s  %5s  %s' "$(mm_human "$sz")" "$(mm_human "$fr")" "$(_purge_age "${idle[i]}")" "$REPLY"
    _purge_to_trash "${arts[$i]}" && row+=" (to Trash)"
    [[ -n "${picks[$i]}" ]] && row+=" (${picks[$i]})"
    if (( fr < sz )); then
      shared=1; (( pnpm_art[i] )) && row+=" (rest in the pnpm store)"
    fi
    row_of[$i]="$row"
    # keep the table readable: recent artifacts freeing under 1MB are summarized, not listed, and
    # never removed by an answer that did not name them. --all lists every row it can act on.
    # Pick-only rows stay too: the picker is the only way to remove them, so they must be seen.
    shown[i]=0
    if (( ! stale[i] && fr < 1048576 && ! all )) && [[ "${kind[i]}" != pick ]]; then
      hidden_n=$((hidden_n + 1)) hidden_bytes=$((hidden_bytes + fr)); continue
    fi
    shown[i]=1
    if [[ "${kind[i]}" == pick ]]; then mark="${C_DIM}◎${C_RESET}"
    elif (( stale[i] )); then mark="${C_YELLOW}●${C_RESET}"
    else mark="${C_DIM}○${C_RESET}"; fi
    printf '  %s  %s\n' "$mark" "$row"
  done
  (( hidden_n )) && printf '  %s○  %9s  %9s         … %d more recent artifacts freeing under 1MB%s\n' \
    "$C_DIM" "" "$(mm_human "$hidden_bytes")" "$hidden_n" "$C_RESET"
  printf '\n'
  (( shared )) && mm_info "${C_DIM}FREES is what deleting releases: files also hard-linked elsewhere (the pnpm store, other copies) stay on disk.${C_RESET}"
  mm_info "${C_YELLOW}●${C_RESET} stale (idle > ${days}d): $stale_n artifacts, frees $(mm_human "$stale_bytes")"
  mm_info "${C_DIM}○${C_RESET} recent:               $recent_n artifacts, frees $(mm_human "$recent_bytes")"
  (( pick_n )) && mm_info "${C_DIM}◎${C_RESET} pick only:            $pick_n artifacts, frees $(mm_human "$pick_bytes"); never selected for you"

  # ---- selection: dry-run previews the default; --yes is stale only; otherwise ask on the terminal
  local mode=stale; (( all )) && mode=all
  if [[ "$MM_DRY_RUN" != 1 ]] && (( ! yes )); then
    if [[ "$MM_TTY" != 1 ]]; then
      mm_info ""
      mm_info "No terminal: nothing removed. Re-run with --yes to purge the stale artifacts."
      _purge_banner "$free_before" 0
      return 0
    fi
    local reply def="s" opts="[S]tale only / [a]ll / [p]ick / [n]one"
    (( all )) && { def="a"; opts="[s]tale only / [A]ll / [p]ick / [n]one"; }
    _PURGE_PROMPTED=1
    reply=$(_purge_ask "$opts") || reply=n
    # whole words only: "abort" and "skip" are not answers, and anything unrecognized is none
    case "${reply:-$def}" in
      s|stale|S|Stale|STALE) mode=stale ;;
      a|all|A|All|ALL) mode=all ;;
      p|pick|P|Pick|PICK) mode=pick ;;
      *) mm_info "No artifacts removed."; _purge_banner "$free_before" 0; return 0 ;;
    esac
  fi

  # stale and all take only rows the table named and a rule vouches for: a pick-only row needs
  # the picker, and a row folded into the "… N more" line was never put to the user
  local -a sel=()
  case "$mode" in
    stale) for i in "${order[@]}"; do (( stale[i] )) && sel+=("$i"); done ;;
    all)
      for i in "${order[@]}"; do (( shown[i] )) && [[ "${kind[i]}" != pick ]] && sel+=("$i"); done
      (( hidden_n )) && mm_info "The $hidden_n artifact$( (( hidden_n > 1 )) && echo s) the table folded away are kept: run with --all to list and remove them."
      ;;
    pick)
      local line idx
      while IFS= read -r line; do
        idx="${line%%[[:space:]]*}"
        [[ "$idx" =~ ^[0-9]+$ && -n "${row_of[$idx]:-}" ]] && sel+=("$idx")
      done < <(for i in "${order[@]}"; do
          printf '%-4s %-6s %s\n' "$i" "${kind[i]}" "${row_of[$i]}"
        done | mm_pick "TAB marks, ctrl-a all, Enter purges")
      ;;
  esac
  if (( ${#sel[@]} == 0 )); then
    mm_info ""
    if [[ "$_PURGE_MODE" == scheduled ]]; then mm_info "Nothing to remove: no project idle > ${days}d."
    else mm_info "Nothing selected$( [[ "$mode" == stale ]] && echo " (no project idle > ${days}d; use --all or --days N)")."; fi
    _purge_banner "$free_before" 0
    return 0
  fi

  # ---- delete. A real run asks every question again right before each removal (the listing and
  # the prompt may be minutes old, and an agent may have been working next to us): the rule, what
  # git tracks and ignores, what the artifact holds, who uses it and when it was last written.
  # Anything that changed, or that cannot be answered now, keeps the artifact and says why.
  local why probe
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_section "Would remove"
  else
    mm_section "Purging"
    mm_inuse_refresh
    busy=()
    local -a recheck=() sel_arts=()
    for i in "${sel[@]}"; do recheck+=("${projs[$i]}"); [[ -n "${gits[$i]}" ]] && recheck+=("${gits[$i]}"); done
    while IFS= read -r p; do [[ -n "$p" ]] && busy[$p]=1; done < <(_purge_busy "${recheck[@]}")
    pair_of=()
    for i in "${sel[@]}"; do
      pair_of[${projs[$i]}]="${projs[$i]}"$'\t'"${gits[$i]}"; sel_arts+=("${arts[$i]}")
    done
    _purge_activity_load "${pair_of[@]}"
    _purge_tracked_load "${sel_arts[@]}"
  fi
  local scan_now=$now; now=$(date +%s)
  local -a how=()
  local keep_state freed0=$MM_FREED
  local -A done_proj=()
  for i in "${sel[@]}"; do
    art="${arts[$i]}" proj="${projs[$i]}" g="${gits[$i]}"
    if [[ -n "${busy[$proj]:-}" || ( -n "$g" && -n "${busy[$g]:-}" ) ]]; then
      mm_tilde "$art"; mm_skip "$REPLY" "$(mm_inuse_why "${g:-$proj}" || echo "in use")"
      MM_SKIPPED=$((MM_SKIPPED + 1))
      continue
    fi
    why=""
    if [[ "$MM_DRY_RUN" != 1 ]]; then
      rc=0; _purge_valid "$art" "${roots[@]}" || rc=$?
      if (( rc != 0 )); then why="${_PURGE_WHY:-no longer a rebuildable artifact}"
      elif (( _PURGE_TAGGED )) && [[ "${kind[i]}" != pick ]]; then why="only a tagged cache now"
      fi
      if [[ -z "$why" ]]; then
        probe=$(_purge_probe "$art"); h="${probe%%$'\t'*}" mt="${probe#*$'\t'}"
        case "$h" in
          git) why="contains a git repository" ;;
          keypair) why="holds a deploy keypair" ;;
          tfstate) why="holds local Terraform state" ;;
        esac
        [[ -n "$why" || "$mt" =~ ^[0-9]+$ ]] || why="could not read what it holds"
        [[ -n "$why" ]] || (( mt <= scan_now )) || why="written since the scan"
      fi
      # activity since the scan: touched after it, or a stale project no longer idle past the
      # threshold. Unknown activity keeps the artifact.
      if [[ -z "$why" ]]; then
        act="${_PURGE_ACT[$proj]:-}"
        if [[ ! "$act" =~ ^[0-9]+$ ]]; then why="activity unknown"
        elif (( act > scan_now || (stale[i] && (now - act) / 86400 <= days) )); then why="active since the scan"; fi
      fi
    fi
    if [[ -n "$why" ]]; then
      mm_tilde "$art"; mm_skip "$REPLY" "$why"
      MM_SKIPPED=$((MM_SKIPPED + 1))
      continue
    fi
    how=(); _purge_to_trash "$art" && how=(--trash)
    keep_state=1; [[ -n "$g" && -n "${agent_wt[$g]:-}" ]] && keep_state=0
    rc=0; MM_KEEP_AGENT_STATE=$keep_state mm_rm "${how[@]}" "$art" "$proj" || rc=$?
    mm_tilde "$art"
    case "$rc" in
      0) mm_ok "$REPLY" "$(mm_human "$MM_LAST_BYTES")${how:+ → Trash}"; done_proj[${g:-$proj}]=1
         (( pnpm_art[i] )) && _PURGE_PNPM_PATHS+=("$art")
         (( ${#how[@]} )) || freed_paths+=("$art") ;;
      1) mm_skip "$REPLY" "$MM_SKIP_REASON" ;;
      *) mm_err "$REPLY · $MM_SKIP_REASON" ;;
    esac
  done
  # Items hard-linked only among themselves (a project's .pnpm-store and its node_modules, cp -al
  # copies) free those files once all of them are gone, as the real run's later deletes count:
  # a dry run sizes what it would delete as one selection (per-item sums stay if that sizing fails).
  if [[ "$MM_DRY_RUN" == 1 ]] && (( ${#freed_paths[@]} > 1 )) && fb=$(mm_frees "${freed_paths[@]}") && [[ "$fb" =~ ^[0-9]+$ ]]; then
    MM_FREED=$(( freed0 + fb ))
  fi
  _purge_banner "$free_before" "${#done_proj[@]}"
}

# _purge_banner FREE_BEFORE PROJECTS — closing summary (artifacts plus worktrees). After a real
# run that removed pnpm-managed items it prunes the pnpm store first; a dry run estimates that.
# A scheduled run gets no banner, only that prune (_purge_scheduled_end).
_purge_banner() {
  [[ "$_PURGE_MODE" == scheduled ]] && { _purge_scheduled_end; return 0; }
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
    (( ${#_PURGE_PNPM_PATHS[@]} )) && { _purge_pnpm_prune; pn=$_PURGE_PRUNE_LINE; }
    free_after=$(mm_free_bytes /)
    local gained=$(( free_after - $1 )); (( gained < 0 )) && gained=0
    mm_banner "Purge complete" \
      "Space freed: $(mm_human "$MM_FREED")$trash | Artifacts: $MM_COUNT | Projects: $2" \
      ${pn:+"$pn"} \
      ${wt:+"$wt"} \
      "Free space: $(mm_human "$free_after") (+$(mm_human "$gained"))"
  fi
}

# _purge_scheduled_end — after a scheduled run's pnpm-managed removals: `pnpm store prune`, or in
# a dry run its estimate, as a line of the section; the bytes go to _PURGE_STORE_BYTES.
_purge_scheduled_end() {
  _PURGE_STORE_BYTES=0
  (( ${#_PURGE_PNPM_PATHS[@]} )) || return 0
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    _PURGE_STORE_BYTES=$(_purge_store_frees "${_PURGE_PNPM_PATHS[@]}")
    _PURGE_STORE_BYTES=${_PURGE_STORE_BYTES:-0}
    (( _PURGE_STORE_BYTES )) && mm_ok "pnpm store prune" "~$(mm_human "$_PURGE_STORE_BYTES") (store files only these used)"
    return 0
  fi
  _purge_pnpm_prune
  case "$_PURGE_PRUNE_LINE" in
    "") ;;
    *"skipped ("*) local why=${_PURGE_PRUNE_LINE#*skipped (}; mm_skip "pnpm store prune" "${why%)}" ;;
    *) mm_ok "pnpm store prune" "${_PURGE_PRUNE_LINE#pnpm store prune: }" ;;
  esac
}
