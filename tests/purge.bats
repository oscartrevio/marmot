#!/usr/bin/env bats
# mm purge: only stale, untracked, not-in-use build artifacts are removed; venvs go to the Trash.

setup() { load helpers/common; mm_test_setup; }
teardown() { mm_test_teardown; }

# node_project DIR [ARTIFACT...] — package.json project with a 4KB file in each artifact dir.
node_project() {
  local d="$1" a; shift
  mkdir -p "$d"; echo '{}' >"$d/package.json"
  for a in "${@:-node_modules}"; do mkdir -p "$d/$a"; head -c 4096 /dev/zero >"$d/$a/blob"; done
}

git_repo() {
  git -C "$1" init -q
  git -C "$1" add -A "${@:2}" .
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm init
}

trash_files() { ls -A "$XDG_DATA_HOME/Trash/files" 2>/dev/null; }

@test "newline in a directory name never deletes its sibling (src\\nx/target case)" {
  local p="$SB/proj"
  mkdir -p "$p/src" "$p/src"$'\n'"x/target/debug" "$p/a"$'\n'"node_modules/inner"
  echo 'int main(){}' >"$p/src/main.c"; echo '{}' >"$p/package.json"
  touch "$p/src"$'\n'"x/Cargo.toml" "$p/src"$'\n'"x/target/debug/bin"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$p/src/main.c" ]
  [ -d "$p/src"$'\n'"x/target/debug" ]
  [ -d "$p/a"$'\n'"node_modules/inner" ]
  [ -z "$(mm_log_rows remove)" ]
}

@test "control characters (tab) in a project path: artifact left alone" {
  node_project "$SB/t"$'\t'"ab"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -d "$SB/t"$'\t'"ab/node_modules" ]
}

@test "backslash in names works" {
  node_project "$SB/a\\b"
  mkdir -p "$SB/a\\b/src"; touch "$SB/a\\b/src/keep"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/a\\b/node_modules" ]
  [ -f "$SB/a\\b/src/keep" ]
}

@test "tracked dist/ is kept" {
  node_project "$SB/r" dist
  git_repo "$SB/r"
  printf 'dist/\n' >"$SB/r/.gitignore"   # ignored now, but files are already tracked
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$SB/r/dist/blob" ]
}

@test "force-added dist/ (ignored but tracked) is kept; ignored untracked dist/ is removed" {
  node_project "$SB/forced" dist; printf 'dist/\n' >"$SB/forced/.gitignore"
  git -C "$SB/forced" init -q; git -C "$SB/forced" add -f dist; git_repo "$SB/forced"
  node_project "$SB/plain" dist; printf 'dist/\n' >"$SB/plain/.gitignore"; git_repo "$SB/plain"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$SB/forced/dist/blob" ]
  [ ! -e "$SB/plain/dist" ]
}

@test "untracked dist/ that is not git-ignored is kept" {
  node_project "$SB/r"; printf 'node_modules/\n' >"$SB/r/.gitignore"; git_repo "$SB/r"
  mkdir -p "$SB/r/dist"; touch "$SB/r/dist/out.js"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$SB/r/dist/out.js" ]
  [ ! -e "$SB/r/node_modules" ]
}

@test "committed node_modules is kept" {
  node_project "$SB/r"; git_repo "$SB/r"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$SB/r/node_modules/blob" ]
}

@test "git probe failure (corrupt index) keeps the artifact and says so" {
  node_project "$SB/r"; printf 'node_modules/\n' >"$SB/r/.gitignore"; git_repo "$SB/r"
  echo garbage >"$SB/r/.git/index"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$SB/r/node_modules/blob" ]
  [[ "$output" == *"kept (could not verify git state)"* ]]
}

@test "git probe failure on dist/ check-ignore keeps it" {
  node_project "$SB/r" dist; printf 'dist/\n' >"$SB/r/.gitignore"; git_repo "$SB/r"
  echo garbage >"$SB/r/.git/index"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -f "$SB/r/dist/blob" ]
}

@test "nested .git inside an artifact keeps it" {
  node_project "$SB/a"; mkdir -p "$SB/a/node_modules/dep/.git"
  node_project "$SB/b"; mkdir -p "$SB/b/node_modules/.git"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -d "$SB/a/node_modules/dep/.git" ]
  [ -d "$SB/b/node_modules/.git" ]
}

@test "symlinked artifact is skipped and its target untouched" {
  mkdir -p "$SB/elsewhere/real"; touch "$SB/elsewhere/real/precious"
  node_project "$SB/p"; rm -r "$SB/p/node_modules"
  ln -s "$SB/elsewhere/real" "$SB/p/node_modules"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -L "$SB/p/node_modules" ]
  [ -f "$SB/elsewhere/real/precious" ]
}

@test "artifacts under \$HOME/.<dot>/ are skipped when scanning \$HOME (bun globals)" {
  mkdir -p "$HOME/.bun/install/global" "$HOME/.npm/_npx/abc"
  node_project "$HOME/.bun/install/global"
  node_project "$HOME/.npm/_npx/abc"
  node_project "$HOME/proj"
  mm_age "$HOME" 30
  run mm purge --yes "$HOME"
  [ -d "$HOME/.bun/install/global/node_modules" ]
  [ -d "$HOME/.npm/_npx/abc/node_modules" ]
  [ ! -e "$HOME/proj/node_modules" ]
}

@test "a root inside a dot-dir (~/.someagent/worktrees) still works" {
  node_project "$HOME/.someagent/worktrees/w1"
  mm_age "$HOME/.someagent" 30
  run mm purge --yes "$HOME/.someagent/worktrees"
  [ ! -e "$HOME/.someagent/worktrees/w1/node_modules" ]
}

@test "project with a process cwd inside it is skipped" {
  node_project "$SB/busy"; mkdir -p "$SB/busy/src"
  node_project "$SB/idle"
  mm_age "$SB" 30
  mm_test_bg "$SB/busy/src" sleep 60
  run mm purge --yes "$SB"
  [ -d "$SB/busy/node_modules" ]
  [ ! -e "$SB/idle/node_modules" ]
  [[ "$output" == *"skipped (in use)"* ]]
}

@test "--yes removes stale artifacts only and leaves recent ones" {
  node_project "$SB/old" node_modules .next
  mm_age "$SB/old" 30
  node_project "$SB/new" node_modules .next
  run mm purge --yes "$SB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/old/node_modules" ]
  [ ! -e "$SB/old/.next" ]
  [ -d "$SB/new/node_modules" ]
  [ -d "$SB/new/.next" ]
}

@test "--days moves the stale threshold" {
  node_project "$SB/p"
  mm_age "$SB/p" 5
  run mm purge --yes "$SB"
  [ -d "$SB/p/node_modules" ]
  run mm purge --yes --days 3 "$SB"
  [ ! -e "$SB/p/node_modules" ]
}

@test "--yes --all is rejected and deletes nothing" {
  node_project "$SB/old"; mm_age "$SB" 30
  run mm purge --yes --all "$SB"
  [ "$status" -ne 0 ]
  [ -d "$SB/old/node_modules" ]
}

@test "no terminal and no --yes deletes nothing" {
  node_project "$SB/old"; mm_age "$SB" 30
  run mm purge "$SB"
  [ "$status" -eq 0 ]
  [ -d "$SB/old/node_modules" ]
  run mm purge --all "$SB"
  [ -d "$SB/old/node_modules" ]
  [ -z "$(mm_log_rows remove)" ]
}

@test "--dry-run deletes nothing" {
  node_project "$SB/old"; mm_age "$SB" 30
  run mm purge --dry-run --yes "$SB"
  [ "$status" -eq 0 ]
  [ -d "$SB/old/node_modules" ]
}

@test "venv goes to the Trash with a .trashinfo; node_modules is deleted permanently" {
  node_project "$SB/py" node_modules .venv
  touch "$SB/py/pyproject.toml" "$SB/py/.venv/pyvenv.cfg"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ ! -e "$SB/py/.venv" ]
  [ ! -e "$SB/py/node_modules" ]
  [ -f "$XDG_DATA_HOME/Trash/files/.venv/pyvenv.cfg" ]
  grep -q "^Path=$SB/py/.venv\$" "$XDG_DATA_HOME/Trash/info/.venv.trashinfo"
  [ "$(trash_files)" = ".venv" ]
  [ -n "$(mm_log_rows trash)" ]
  mm_log_rows remove | grep -q "$SB/py/node_modules"
}

@test "venv without pyvenv.cfg is not an artifact" {
  node_project "$SB/py" venv
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ -d "$SB/py/venv" ]
}

@test "target/ only with Cargo.toml or pom.xml" {
  mkdir -p "$SB/rust/target" "$SB/java/target" "$SB/other/target"
  touch "$SB/rust/Cargo.toml" "$SB/java/pom.xml" "$SB/other/README"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ ! -e "$SB/rust/target" ]
  [ ! -e "$SB/java/target" ]
  [ -d "$SB/other/target" ]
}

@test "vendor/ only with composer.json" {
  mkdir -p "$SB/php/vendor" "$SB/go/vendor"
  touch "$SB/php/composer.json" "$SB/go/go.mod"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ ! -e "$SB/php/vendor" ]
  [ -d "$SB/go/vendor" ]
}

@test "nested node_modules inside a matched node_modules is one item" {
  node_project "$SB/p"; mkdir -p "$SB/p/node_modules/a/node_modules/b"
  mm_age "$SB" 30
  run mm purge --yes "$SB"
  [ ! -e "$SB/p/node_modules" ]
  [ "$(mm_log_rows remove | wc -l)" -eq 1 ]
}

@test "interactive pick that selects nothing deletes nothing" {
  node_project "$SB/old"; mm_age "$SB" 30
  mm_core; . "$MM_SRC/cmd/purge.sh"
  MM_TTY=1
  mm_pick() { cat >/dev/null; }
  _purge_ask() { printf p; }
  run mm_cmd_main "$SB"
  [ -d "$SB/old/node_modules" ]
  [[ "$output" == *"Nothing selected"* ]]
}

@test "interactive pick removes only the picked artifact" {
  node_project "$SB/a"; node_project "$SB/b"; mm_age "$SB" 30
  mm_core; . "$MM_SRC/cmd/purge.sh"
  MM_TTY=1
  mm_pick() { grep '/b/node_modules'; }
  _purge_ask() { printf p; }
  run mm_cmd_main "$SB"
  [ -d "$SB/a/node_modules" ]
  [ ! -e "$SB/b/node_modules" ]
}

# ---------------------------------------------------------------- discovery

@test "discovery (no purge_paths, no DIR): finds a project under \$HOME and creates no purge_paths" {
  node_project "$HOME/code/app"
  mm_age "$HOME/code" 30
  run mm purge --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/code/app/node_modules" ]
  [ ! -e "$XDG_CONFIG_HOME/marmot/purge_paths" ]
}

@test "discovery follows a worktree that lives in a dot-dir; --yes purges its artifacts, never the worktree" {
  mkdir -p "$HOME/proj"; echo '{}' >"$HOME/proj/package.json"; printf 'node_modules/\n' >"$HOME/proj/.gitignore"
  git_repo "$HOME/proj"
  git -C "$HOME/proj" worktree add -q "$HOME/.agentx/worktrees/w1" -b w1
  mkdir -p "$HOME/.agentx/worktrees/w1/node_modules"; touch "$HOME/.agentx/worktrees/w1/node_modules/blob"
  mm_age "$HOME/proj" 30; mm_age "$HOME/.agentx" 30
  run mm purge --yes
  [ ! -e "$HOME/.agentx/worktrees/w1/node_modules" ]
  [ -f "$HOME/.agentx/worktrees/w1/package.json" ]
  [ -z "$(mm_log_rows worktree)" ]
}

@test "a purge_paths file with entries replaces discovery" {
  node_project "$HOME/code/app"; node_project "$SB/p"
  mm_age "$HOME/code" 30; mm_age "$SB" 30
  mkdir -p "$XDG_CONFIG_HOME/marmot"; printf '# mine\n%s\n' "$SB" >"$XDG_CONFIG_HOME/marmot/purge_paths"
  run mm purge --yes
  [ ! -e "$SB/p/node_modules" ]
  [ -d "$HOME/code/app/node_modules" ]
}

@test "--paths creates a comment-only template; discovery still runs while it lists nothing" {
  EDITOR=true VISUAL=true run mm purge --paths
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/marmot/purge_paths" ]
  [ -z "$(grep -v '^[[:space:]]*#' "$XDG_CONFIG_HOME/marmot/purge_paths" | tr -d '[:space:]')" ]
  node_project "$HOME/code/app"; mm_age "$HOME/code" 30
  run mm purge --yes
  [ ! -e "$HOME/code/app/node_modules" ]
}

# ---------------------------------------------------------------- abandoned worktrees

ago() { date -d "$1 days ago" -R; }

# wt_commit DIR MSG [DAYS_AGO=40] — commit everything in DIR with author/committer dates in the past.
wt_commit() {
  git -C "$1" add -A
  GIT_AUTHOR_DATE="$(ago "${3:-40}")" GIT_COMMITTER_DATE="$(ago "${3:-40}")" \
    git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"
}

# wt_repo — $SB/repo on branch main, one commit 40 days old, node_modules ignored.
wt_repo() {
  git -C "$SB" init -q -b main repo
  printf 'node_modules/\n' >"$SB/repo/.gitignore"; echo a >"$SB/repo/a"
  wt_commit "$SB/repo" init
}

# never_offered PATH — PATH was not proposed for removal in any prompt.
never_offered() { ! grep -qF "$1" "$BATS_TEST_TMPDIR/offered" 2>/dev/null; }

# wt_add NAME ARGS... — linked worktree $SB/NAME (git worktree add ARGS).
wt_add() { local n="$1"; shift; git -C "$SB/repo" worktree add -q "$SB/$n" "$@"; }

# wt_interactive ARGS... — run mm_cmd_main as if on a terminal that accepts every prompt
# (worktree confirm / pick-all) and declines the artifact prompt. Everything offered is recorded
# in $BATS_TEST_TMPDIR/offered.
wt_interactive() {
  mm_core; . "$MM_SRC/cmd/purge.sh"
  MM_TTY=1
  mm_confirm() { printf '%s\n' "$1" >>"$BATS_TEST_TMPDIR/offered"; return 0; }
  mm_pick() { tee -a "$BATS_TEST_TMPDIR/offered"; }
  _purge_ask() { printf n; }
  run mm_cmd_main "$@"
}

@test "worktree: merged, clean, idle 15d is offered and removed (branch kept, logged)" {
  wt_repo; wt_add wt -b feat
  mkdir -p "$SB/wt/node_modules"; touch "$SB/wt/node_modules/x"   # ignored files are fine
  mm_age "$SB" 15
  wt_interactive "$SB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/wt" ]
  git -C "$SB/repo" show-ref --verify -q refs/heads/feat
  [ -z "$(git -C "$SB/repo" worktree list --porcelain | grep "^worktree $SB/wt\$")" ]
  mm_log_rows worktree | grep -q "^$SB/wt"$'\t'
  [ -f "$SB/repo/a" ]
}

@test "worktree: several offered, only the picked one is removed" {
  wt_repo; wt_add w1 -b b1; wt_add w2 -b b2
  mm_age "$SB" 15
  wt_interactive "$SB"
  [ ! -e "$SB/w1" ]   # pick-all removes both
  [ ! -e "$SB/w2" ]
  wt_add w3 -b b3; wt_add w4 -b b4
  mm_age "$SB" 15
  mm_pick() { grep "$SB/w4 "; }
  run mm_cmd_main "$SB"
  [ -d "$SB/w3" ]
  [ ! -e "$SB/w4" ]
}

@test "worktree with an untracked file is kept" {
  wt_repo; wt_add wt -b feat; echo new >"$SB/wt/notes.txt"
  mm_age "$SB" 15
  wt_interactive "$SB"
  [ -f "$SB/wt/notes.txt" ]
  never_offered "$SB/wt"
}

@test "worktree with a modified tracked file is kept" {
  wt_repo; wt_add wt -b feat; echo changed >"$SB/wt/a"
  mm_age "$SB" 15
  wt_interactive "$SB"
  [ "$(cat "$SB/wt/a")" = changed ]
  never_offered "$SB/wt"
}

@test "locked worktree is kept" {
  wt_repo; wt_add wt -b feat; git -C "$SB/repo" worktree lock "$SB/wt"
  mm_age "$SB" 15
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "detached HEAD at a commit no branch or tag holds is kept" {
  wt_repo; wt_add wt --detach
  echo lone >"$SB/wt/lone"; wt_commit "$SB/wt" lone
  mm_age "$SB" 31
  wt_interactive "$SB"
  [ -f "$SB/wt/lone" ]
  never_offered "$SB/wt"
}

@test "detached HEAD at a commit main holds is removable" {
  wt_repo; wt_add wt --detach
  mm_age "$SB" 15
  wt_interactive "$SB"
  [ ! -e "$SB/wt" ]
}

@test "unmerged clean worktree: idle 20d kept, idle 31d removed with its branch kept" {
  wt_repo; wt_add wt -b feat
  echo f >"$SB/wt/f"; wt_commit "$SB/wt" feat
  mm_age "$SB" 20
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
  mm_age "$SB" 31
  run mm_cmd_main "$SB"
  [ ! -e "$SB/wt" ]
  git -C "$SB/repo" show-ref --verify -q refs/heads/feat
  [ "$(git -C "$SB/repo" log -1 --format=%s feat)" = feat ]
}

@test "worktree in use (process cwd inside) is kept" {
  wt_repo; wt_add wt -b feat; mkdir -p "$SB/wt/sub"
  mm_age "$SB" 15
  mm_test_bg "$SB/wt/sub" sleep 60
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "--yes never removes worktrees, even on a terminal" {
  wt_repo; wt_add wt -b feat
  mm_age "$SB" 31
  run mm purge --yes "$SB"
  [ "$status" -eq 0 ]
  [ -d "$SB/wt" ]
  wt_interactive --yes "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
  [ -z "$(mm_log_rows worktree)" ]
}

@test "--dry-run removes no worktree" {
  wt_repo; wt_add wt -b feat
  mm_age "$SB" 31
  run mm purge --dry-run "$SB"
  [ -d "$SB/wt" ]
  MM_DRY_RUN=1 wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "the main worktree is never offered" {
  wt_repo; wt_add recent -b r
  mm_age "$SB/repo" 100
  wt_interactive "$SB"
  never_offered "$SB/repo"
  [ -d "$SB/repo/.git" ]
  [ -f "$SB/repo/a" ]
  [ -d "$SB/recent" ]
}
