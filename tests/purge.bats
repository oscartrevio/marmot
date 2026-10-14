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

# ---------------------------------------------------------------- what a delete really frees

# fake_pnpm STORE — pnpm double: `store path` prints STORE; `store prune` deletes the store files
# nothing else links to (link count 1), as the real one does. Calls go to $BATS_TEST_TMPDIR/pnpm.calls.
fake_pnpm() {
  mkdir -p "$1"
  mm_test_fake pnpm "echo \"\$*\" >>'$BATS_TEST_TMPDIR/pnpm.calls'
case \"\$*\" in
  'store path') echo '$1' ;;
  'store prune') find '$1' -type f -links 1 -delete ;;
esac"
}
pnpm_calls() { cat "$BATS_TEST_TMPDIR/pnpm.calls" 2>/dev/null; }

# pnpm_modules DIR STORE — DIR/node_modules laid out by pnpm: .modules.yaml, a file of its own,
# and a 64KB package file hard-linked from STORE. Prints the package file's bytes on disk.
pnpm_modules() {
  mkdir -p "$1/node_modules/.pnpm/pkg@1.0.0" "$2"
  printf 'storeDir: %s\n' "$2" >"$1/node_modules/.modules.yaml"
  head -c 4096 /dev/urandom >"$1/node_modules/.pnpm/own"
  head -c 65536 /dev/urandom >"$2/pkg-file"
  ln "$2/pkg-file" "$1/node_modules/.pnpm/pkg@1.0.0/index.js"
  echo $(( $(stat -c %b "$2/pkg-file") * 512 ))
}

log_bytes() { awk -F'\t' -v a="$1" '$3 == a { print $5 }' "$XDG_STATE_HOME/marmot/operations.log"; }

@test "node_modules hard-linked to the pnpm store: reports and frees only its own files, then prunes the store" {
  fake_pnpm "$SB/store"
  node_project "$SB/p"; rm -r "$SB/p/node_modules"
  local pkg own before after
  mm_core
  pkg=$(pnpm_modules "$SB/p" "$SB/store")
  own=$(( $(du -sB1 "$SB/p/node_modules" | cut -f1) - pkg ))
  mm_age "$SB/p" 30
  run mm purge --dry-run --yes "$SB/p"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would free: $(mm_human "$own") "* ]]
  [[ "$output" == *"~$(mm_human "$pkg") more"* ]]
  [ -f "$SB/p/node_modules/.pnpm/own" ]
  [[ "$(pnpm_calls)" != *prune* ]]
  before=$(du -sxB1 "$SB" | cut -f1)
  . "$MM_SRC/cmd/purge.sh"
  mm_proc_running() { return 1; }   # no pnpm running elsewhere on the machine
  run mm_cmd_main --yes "$SB/p"
  [ "$status" -eq 0 ]
  after=$(du -sxB1 "$SB" | cut -f1)
  [ ! -e "$SB/p/node_modules" ]
  [ "$(log_bytes remove)" -eq "$own" ]
  [ "$(pnpm_calls | grep -c '^store prune$')" -eq 1 ]
  [ ! -e "$SB/store/pkg-file" ]
  [ $(( before - after )) -eq $(( own + pkg )) ]
}

@test "artifacts hard-linked only to each other: the dry run's total is what the real run frees" {
  node_project "$SB/a"; head -c 65536 /dev/urandom >"$SB/a/node_modules/pkg"
  mkdir -p "$SB/b"; echo '{}' >"$SB/b/package.json"; cp -al "$SB/a/node_modules" "$SB/b/node_modules"
  mm_age "$SB" 30
  mm_core
  local dry before after
  run mm purge --dry-run --yes "$SB"
  dry=$output
  before=$(du -sxB1 "$SB" | cut -f1)
  run mm purge --yes "$SB"
  after=$(du -sxB1 "$SB" | cut -f1)
  [ ! -e "$SB/a/node_modules" ]
  [ ! -e "$SB/b/node_modules" ]
  [[ "$dry" == *"Would free: $(mm_human $(( before - after ))) "* ]]
  [[ "$output" == *"Space freed: $(mm_human $(( before - after ))) "* ]]
}

@test "the pnpm store is left alone while pnpm runs, and when nothing pnpm installed was removed" {
  fake_pnpm "$SB/store"
  node_project "$SB/plain"; mm_age "$SB/plain" 30
  run mm purge --yes "$SB/plain"
  [ ! -e "$SB/plain/node_modules" ]
  [ -z "$(pnpm_calls)" ]
  node_project "$SB/p"; rm -r "$SB/p/node_modules"; pnpm_modules "$SB/p" "$SB/store" >/dev/null
  mm_age "$SB/p" 30
  mm_core; . "$MM_SRC/cmd/purge.sh"
  # a running pnpm (an install somewhere else on the machine)
  mm_proc_running() { [[ "$1" == pnpm ]]; }
  run mm_cmd_main --yes "$SB/p"
  [ ! -e "$SB/p/node_modules" ]
  [[ "$(pnpm_calls)" != *prune* ]]
  [ -f "$SB/store/pkg-file" ]
}

@test "worktree with a pnpm node_modules: removal logs what it frees and prunes the store" {
  fake_pnpm "$SB/store"
  wt_repo; wt_add wt -b feat
  local pkg own
  pkg=$(pnpm_modules "$SB/wt" "$SB/store")
  own=$(( $(du -sB1 "$SB/wt" | cut -f1) - pkg ))
  mm_age "$SB" 15
  mm_core; . "$MM_SRC/cmd/purge.sh"
  mm_proc_running() { return 1; }   # no pnpm running elsewhere on the machine
  MM_TTY=1
  mm_confirm() { return 0; }
  _purge_ask() { printf n; }
  run mm_cmd_main "$SB"
  [ ! -e "$SB/wt" ]
  [ "$(log_bytes worktree)" -eq "$own" ]
  [ "$(pnpm_calls | grep -c '^store prune$')" -eq 1 ]
  [ ! -e "$SB/store/pkg-file" ]
}

# ---------------------------------------------------------------- agents' worktree dirs

# agent_wt NAME — linked worktree of $SB/repo (outside home) in T3 Code's worktree dir.
agent_wt() { git -C "$SB/repo" worktree add -q "$HOME/.t3/worktrees/repo/$1" -b "$1"; }

@test "discovery: a worktree in an agent's worktree dir is found though its repository is outside home; agent state stays" {
  wt_repo; agent_wt w1
  mkdir -p "$HOME/.t3/userdata"; echo state >"$HOME/.t3/userdata/state.sqlite"
  mm_age "$SB" 15; mm_age "$HOME/.t3" 15
  wt_interactive
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.t3/worktrees/repo/w1" ]
  [ -f "$HOME/.t3/userdata/state.sqlite" ]
  git -C "$SB/repo" show-ref --verify -q refs/heads/w1
  [ -f "$SB/repo/a" ]
}

@test "discovery: --yes purges artifacts inside an agent's worktree, never the worktree, look-alikes or agent state" {
  wt_repo; agent_wt w1
  node_project "$HOME/.t3/worktrees/repo/w1"
  # look-alikes: .git files that do not lead into a repository's worktrees dir
  git -C "$SB" init -q other
  node_project "$HOME/.t3/worktrees/other/clone"
  printf 'gitdir: %s\n' "$SB/other/.git" >"$HOME/.t3/worktrees/other/clone/.git"
  mkdir -p "$SB/fake/worktrees/x"
  node_project "$HOME/.t3/worktrees/fake/x"
  printf 'gitdir: %s\n' "$SB/fake/worktrees/x" >"$HOME/.t3/worktrees/fake/x/.git"
  mm_age "$SB" 30; mm_age "$HOME/.t3" 30
  run mm purge --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.t3/worktrees/repo/w1/node_modules" ]
  [ -f "$HOME/.t3/worktrees/repo/w1/package.json" ]
  [ -d "$HOME/.t3/worktrees/other/clone/node_modules" ]
  [ -d "$HOME/.t3/worktrees/fake/x/node_modules" ]
  [ -z "$(mm_log_rows worktree)" ]
}

# ---------------------------------------------------------------- finished worktrees

# age_hours PATH HOURS — make PATH (recursively) look HOURS old by mtime and atime.
age_hours() { find "$1" -exec touch -c -h -d "$2 hours ago" {} +; }

on_main() { git -C "$SB/repo" -c user.email=t@t -c user.name=t "$@"; }

# feat_wt — $SB/wt on branch feat with two commits main does not have.
feat_wt() {
  wt_repo; wt_add wt -b feat
  echo 1 >"$SB/wt/f1"; wt_commit "$SB/wt" "feat 1"
  echo 2 >"$SB/wt/f2"; wt_commit "$SB/wt" "feat 2"
}

# fake_gh STATE — gh double, logged in, whose `pr view` answers STATE. Each call is recorded in
# $BATS_TEST_TMPDIR/gh.calls with whether prompts were disabled and stdin was a terminal.
fake_gh() {
  mm_test_fake gh "echo \"\$* prompt-disabled=\${GH_PROMPT_DISABLED:-} tty=\$([[ -t 0 ]] && echo y || echo n)\" >>'$BATS_TEST_TMPDIR/gh.calls'
case \"\$1 \$2\" in
  'auth token') echo gho_test ;;
  'pr view') ${2:-echo '$1'} ;;
  *) exit 1 ;;
esac"
}

@test "finished worktree: branch merged with a merge commit, idle 2h, is offered and removed" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB/wt" ]
  [ "$(git -C "$SB/repo" log -1 --format=%s feat)" = "feat 2" ]
}

@test "finished worktree: squash-merged branch is offered and removed" {
  feat_wt; on_main merge -q --squash feat; on_main commit -qm "feat (#1)"
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ ! -e "$SB/wt" ]
  git -C "$SB/repo" show-ref --verify -q refs/heads/feat
}

@test "finished worktree: rebased-and-merged branch is offered and removed" {
  feat_wt
  echo m >"$SB/repo/m"; on_main add m; on_main commit -qm "main moves on"
  on_main cherry-pick feat~1 feat >/dev/null
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ ! -e "$SB/wt" ]
}

@test "finished worktree: upstream branch gone is offered and removed" {
  feat_wt
  git -C "$SB/repo" remote add origin "$SB/origin.git"
  git -C "$SB/repo" config branch.feat.remote origin
  git -C "$SB/repo" config branch.feat.merge refs/heads/feat
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ ! -e "$SB/wt" ]
}

@test "finished worktree: PR merged per gh is offered and removed; gh never gets a terminal or a prompt" {
  feat_wt; fake_gh MERGED
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ ! -e "$SB/wt" ]
  grep -q '^pr view feat .*prompt-disabled=1 tty=n$' "$BATS_TEST_TMPDIR/gh.calls"
}

@test "worktree whose PR is still open is kept" {
  feat_wt; fake_gh OPEN
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ -f "$SB/wt/f2" ]
  never_offered "$SB/wt"
  grep -q '^pr view feat ' "$BATS_TEST_TMPDIR/gh.calls"
}

@test "a gh that hangs is cut off and the worktree kept" {
  feat_wt; fake_gh OPEN 'exec sleep 30'
  age_hours "$SB" 2
  mm_core; . "$MM_SRC/cmd/purge.sh"
  _PURGE_GH_TIMEOUT=1
  MM_TTY=1
  mm_confirm() { printf '%s\n' "$1" >>"$BATS_TEST_TMPDIR/offered"; return 0; }
  _purge_ask() { printf n; }
  SECONDS=0
  run mm_cmd_main "$SB"
  (( SECONDS < 15 ))
  [ -f "$SB/wt/f2" ]
  never_offered "$SB/wt"
}

@test "finished worktree with an uncommitted change is kept" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  echo changed >"$SB/wt/f1"
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ "$(cat "$SB/wt/f1")" = changed ]
  never_offered "$SB/wt"
}

@test "finished worktree with an untracked file is kept" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  echo new >"$SB/wt/notes.txt"
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ -f "$SB/wt/notes.txt" ]
  never_offered "$SB/wt"
}

@test "finished worktree that is locked is kept" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  git -C "$SB/repo" worktree lock "$SB/wt"
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "finished worktree in use is kept" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  age_hours "$SB" 2
  mm_test_bg "$SB/wt" sleep 60
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "finished worktree idle under an hour is kept" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  age_hours "$SB" 2
  touch "$SB/wt/f1"
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "unmerged worktree idle 2h is kept (it waits 30 days)" {
  feat_wt
  age_hours "$SB" 2
  wt_interactive "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
}

@test "--yes never removes a finished worktree" {
  feat_wt; on_main merge -q --no-ff feat -m "Merge feat"
  age_hours "$SB" 2
  run mm purge --yes "$SB"
  [ "$status" -eq 0 ]
  [ -d "$SB/wt" ]
  wt_interactive --yes "$SB"
  [ -d "$SB/wt" ]
  never_offered "$SB/wt"
  [ -z "$(mm_log_rows worktree)" ]
}
