#!/usr/bin/env bash
# End-to-end "agent VM" scenario: build the home of a machine where AI coding agents work, run
# marmot on it for real, and prove that it frees what it says it frees while everything it must
# keep survives.
#
# It deletes from $HOME for real, so it runs only inside a throwaway container prepared by
# tests/e2e/setup.sh, as the user under test (root or not). tests/e2e/run.sh does both steps
# with docker, with HOME on its own tmpfs so that df measures nothing but this scenario.
#
# The home: real npm and pnpm installs from the registry (pnpm projects hard-linked into one
# shared store), a repository whose linked worktrees live in coding agents' worktree folders
# (merged, squash-merged, uncommitted, in progress), npm, pip and TypeScript caches, Trash items
# deleted 40, 12 and 3 days ago, agent sessions with a 30-day retention configured, agent and
# gcloud logs, automation-browser leftovers in /tmp, a whitelisted project and credentials.
#
# Ages: marmot judges projects, worktrees, sessions and logs by modification times, git commit
# dates and .trashinfo dates, which the scenario sets directly. Browser leftovers it judges by
# their newest mtime or ctime, and ctime cannot be backdated, so marmot runs with its clock
# MM_E2E_CLOCK_SHIFT (3 hours) ahead, the way the bats suite moves it (mm_test_clock in
# tests/helpers/common.bash): an exported `date` function that adds the shift to `date +%s`.
#
# Steps: dry runs (nothing may change), then `mm schedule run` (unattended), then `mm clean` and
# `mm purge` on a pseudo-terminal (tests/e2e/pty-drive.py waits for each prompt and accepts
# everything offered, so what survives is protected by marmot's checks, not by the answers).
# Each real run is compared with a dry run taken on the same state just before it and with the
# bytes that really left the disk.
set -euo pipefail

[[ "${MM_E2E:-}" == 1 ]] || { echo "agent-vm.sh: deletes from \$HOME for real; set MM_E2E=1 in a throwaway container" >&2; exit 2; }
[[ -e /.dockerenv || -e /run/.containerenv || -n "${container:-}" ]] ||
  { echo "agent-vm.sh: not in a container; refusing" >&2; exit 2; }
[[ "$HOME" == /root || "$HOME" == /home/?* ]] || { echo "agent-vm.sh: HOME must be /root or /home/<user>" >&2; exit 2; }

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
LOGS=${MM_E2E_LOGS:-$(mktemp -d /tmp/marmot-e2e.XXXXXX)}
mkdir -p "$LOGS"
cd /
export LC_ALL=C.UTF-8 NO_COLOR=1
# npm and pnpm quiet; no npm debug logs (npm rotates them, which would look like a dry run deleting).
export npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false \
  npm_config_loglevel=error npm_config_logs_max=0
export MM_E2E_CLOCK_SHIFT=$((3 * 3600))

NOW=$(date +%s)
P=$HOME/projects
CS=$HOME/.claude-squad/worktrees   # Claude Squad's worktree folder
PS=$HOME/.paseo/worktrees          # Paseo's
TRASH=$HOME/.local/share/Trash
LEFTOVERS=(/tmp/playwright_chromiumdev_profile-e2eQ1x /tmp/puppeteer_dev_chrome_profile-e2eW2y /tmp/playwright-artifacts-e2eE3z)
SIZE='([0-9.]+[KMGT]?B)'
SLACK=$((256 << 10))   # sizes in marmot's output are rounded (12.3MB); marmot writes its own logs
FAILED=0
STEPS=()

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILED=1; }
check() { local what=$1; shift; if "$@"; then printf 'ok: %s\n' "$what"; else fail "$what"; fi; }
missing() { local f; for f; do [[ ! -e "$f" ]] || return 1; done; }
present() { local f; for f; do [[ -e "$f" ]] || return 1; done; }
ago() { echo $((NOW - $1 * 86400)); }
# age EPOCH PATH... — modification (and access) time of everything under PATH set to EPOCH.
age() { local when=$1; shift; find "$@" -exec touch -c -h -d "@$when" {} +; }
# blob FILE MIB — FILE filled with MIB MiB of incompressible data.
blob() { mkdir -p "$(dirname "$1")"; head -c "$(($2 << 20))" /dev/urandom >"$1"; }
# du_b PATH... — bytes on disk under the PATHs that exist (hard links counted once; a missing
# PATH counts 0, which makes du exit 1).
du_b() { { du -scxB1 "$@" 2>/dev/null || true; } | awk 'END { printf "%.0f\n", $1 }'; }
in_use() { du_b "$HOME" "${LEFTOVERS[@]}"; }
df_used() { df -B1 --output=used "$HOME" | awk 'NR == 2 { printf "%.0f\n", $1 }'; }
mib() { awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'; }
# commit WHEN DIR ARGS... — git commit in DIR dated WHEN (epoch).
commit() { local when=$1 dir=$2; shift 2; GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" git -C "$dir" "$@"; }
# within A B — A and B (bytes) differ by at most 5% of the larger plus SLACK.
within() { local d=$(($1 - $2)) m=$(($1 > $2 ? $1 : $2)); (( d < 0 )) && d=$((-d)); (( d <= m / 20 + SLACK )); }
# shifted CMD... — CMD with marmot's clock CLOCK_SHIFT ahead (see the header).
shifted() {
  (
    # shellcheck disable=SC2317 # runs in marmot, which inherits it through export -f
    date() { if [[ "${1:-}" == +%s ]]; then echo $(( $(command date +%s) + MM_E2E_CLOCK_SHIFT )); else command date "$@"; fi; }
    export -f date
    exec "$@"
  )
}
mm() { shifted "$SRC/marmot" "$@"; }
# mm_tty LOG ARGS... — marmot on a pseudo-terminal, every prompt answered by pty-drive.py.
mm_tty() { local log=$1; shift; shifted python3 "$HERE/pty-drive.py" --log "$LOGS/$log" --timeout 480 -- "$SRC/marmot" "$@"; }
# size_in LOG REGEX — bytes of the size REGEX's first group captures on LOG's last matching line.
size_in() {
  local line re=$2
  line=$(grep -aE "$re" "$LOGS/$1" | tail -n1) || true
  [[ "$line" =~ $re ]] || { echo 0; return; }
  awk -v s="${BASH_REMATCH[1]}" 'BEGIN {
    n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
    m = 1; if (u == "KB") m = 1024; else if (u == "MB") m = 1048576; else if (u == "GB") m = 1073741824
    printf "%.0f\n", n * m }'
}
# trashinfo NAME DAYS_AGO — a .trashinfo saying NAME went to the Trash DAYS_AGO days ago.
trashinfo() {
  printf '[Trash Info]\nPath=%s/%s\nDeletionDate=%s\n' "$HOME" "$1" "$(date -d "@$(ago "$2")" +%Y-%m-%dT%H:%M:%S)" \
    >"$TRASH/info/$1.trashinfo"
}
# snapshot — every directory, and every other entry with size and mtime, under $HOME and /tmp's leftovers.
snapshot() {
  find "$HOME" "${LEFTOVERS[@]}" -xdev \( -type d -printf 'd %p\n' \) -o -printf 'f %p %s %T@\n' 2>/dev/null | sort
}
# step NAME DRY_BYTES REPORTED_BYTES MEASURED_BYTES — one row of the summary, and its checks.
step() {
  STEPS+=("$(printf '%-24s %14s %14s %14s' "$1" "$(mib "$2")" "$(mib "$3")" "$(mib "$4")")")
  check "$1: the dry run's estimate matches what marmot reported freeing (within 5%)" within "$2" "$3"
  check "$1: marmot's report matches the bytes that left the disk (within 5%)" within "$3" "$4"
}

# ---------------------------------------------------------------- the home

build_home() {
  git config --global user.name e2e
  git config --global user.email e2e@example.invalid
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  git config --global maintenance.auto false
  git config --global gc.auto 0
  local base='"lodash": "4.17.21", "date-fns": "3.6.0"' old recent d
  old=$(ago 40) recent=$(ago 3)

  # npm: a project idle for 40 days, the same whitelisted, and one in use today.
  mkdir -p "$P/webapp"
  printf '{ "name": "webapp", "private": true, "dependencies": { %s } }\n' "$base" >"$P/webapp/package.json"
  printf 'node_modules/\n' >"$P/webapp/.gitignore"
  (cd "$P/webapp" && npm install --no-progress >/dev/null)
  git -C "$P/webapp" init -q && git -C "$P/webapp" add -A && commit "$old" "$P/webapp" commit -qm init
  cp -a "$P/webapp" "$P/keep"
  cp -a "$P/webapp" "$P/active"
  age "$old" "$P/webapp" "$P/keep"

  # pnpm: a project idle for 40 days that alone uses rxjs (and its tslib) from the shared store.
  mkdir -p "$P/dashboard"
  printf '{ "name": "dashboard", "private": true, "dependencies": { %s, "rxjs": "7.8.1" } }\n' "$base" >"$P/dashboard/package.json"
  printf 'node_modules/\n' >"$P/dashboard/.gitignore"
  (cd "$P/dashboard" && pnpm install --reporter=silent)
  git -C "$P/dashboard" init -q && git -C "$P/dashboard" add -A && commit "$old" "$P/dashboard" commit -qm init
  age "$old" "$P/dashboard"

  # A pnpm repository and the worktrees agents made of it, each with node_modules from the store:
  #   api-charts   (Claude Squad) merged into main 3 days ago; alone uses moment       finished
  #   api-typo     (Claude Squad) squash-merged into main 3 days ago                    finished
  #   api-flaky    (Paseo) an unmerged commit and an uncommitted change, idle 40 days   kept
  #   api-search   (Paseo) an unmerged commit from an hour ago                          in progress
  mkdir -p "$P/api/src" "$CS" "$PS"
  printf '{ "name": "api", "private": true, "dependencies": { %s } }\n' "$base" >"$P/api/package.json"
  printf 'node_modules/\n' >"$P/api/.gitignore"
  printf '# api\n' >"$P/api/README.md"
  printf 'export const api = 1;\n' >"$P/api/src/index.js"
  (cd "$P/api" && pnpm install --reporter=silent)
  git -C "$P/api" init -q && git -C "$P/api" add -A && commit "$old" "$P/api" commit -qm init
  git -C "$P/api" worktree add -q -b feat/charts "$CS/api-charts"
  git -C "$P/api" worktree add -q -b fix/typo "$CS/api-typo"
  git -C "$P/api" worktree add -q -b fix/flaky "$PS/api-flaky"
  git -C "$P/api" worktree add -q -b feat/search "$PS/api-search"
  for d in "$CS/api-charts" "$CS/api-typo" "$PS/api-flaky" "$PS/api-search"; do
    (cd "$d" && pnpm install --offline --reporter=silent)
  done
  printf 'export const charts = 1;\n' >"$CS/api-charts/src/charts.js"
  (cd "$CS/api-charts" && pnpm add moment@2.30.1 --reporter=silent)
  git -C "$CS/api-charts" add -A && commit "$(ago 4)" "$CS/api-charts" commit -qm "feat: charts"
  # two commits, so only the squash-merge check (not git cherry per commit) can see it landed
  printf 'export const fromat = (s) => s.trim();\n' >"$CS/api-typo/src/format.js"
  git -C "$CS/api-typo" add -A && commit "$(ago 5)" "$CS/api-typo" commit -qm "feat: format"
  printf 'export const format = (s) => s.trim();\n' >"$CS/api-typo/src/format.js"
  git -C "$CS/api-typo" add -A && commit "$(ago 4)" "$CS/api-typo" commit -qm "fix: typo"
  git -C "$P/api" merge -q --squash fix/typo >/dev/null && commit "$recent" "$P/api" commit -qm "fix: typo (#12)"
  commit "$recent" "$P/api" merge -q --no-ff -m "Merge feat/charts (#11)" feat/charts
  printf 'export const retry = 3;\n' >"$PS/api-flaky/src/flaky.js"
  git -C "$PS/api-flaky" add -A && commit "$old" "$PS/api-flaky" commit -qm "wip: flaky test"
  printf 'unfinished\n' >>"$PS/api-flaky/README.md"
  printf 'export const search = 1;\n' >"$PS/api-search/src/search.js"
  git -C "$PS/api-search" add -A && commit "$((NOW - 3600))" "$PS/api-search" commit -qm "wip: search"
  age "$recent" "$P/api" "$CS"
  age "$old" "$PS/api-flaky" "$P/api/.git/worktrees/api-flaky"

  # Caches: npm's (filled by the installs above), pip's and TypeScript's (same layout, filler data).
  blob "$HOME/.cache/pip/http-v2/a/3/f/0/1/e2e.body" 20
  blob "$HOME/.cache/typescript/5.6/node_modules/types-registry/index.json" 5

  # The Trash: items deleted 40, 12 and 3 days ago.
  mkdir -p "$TRASH/files" "$TRASH/info"
  blob "$TRASH/files/old-build.tar" 15 && trashinfo old-build.tar 40
  blob "$TRASH/files/screenshots.tar" 10 && trashinfo screenshots.tar 12
  blob "$TRASH/files/notes.txt" 1 && trashinfo notes.txt 3

  # Agent sessions (30-day retention configured), agent and gcloud logs, old and recent.
  local cl="$HOME/.claude/projects/${HOME//\//-}-projects-api" om="$HOME/.omp/agent/sessions/-${HOME//\//-}-projects-api-"
  blob "$cl/0f6c7a52-old.jsonl" 3 && age "$(ago 60)" "$cl/0f6c7a52-old.jsonl"
  blob "$cl/9b1d2e44-recent.jsonl" 1 && age "$(ago 2)" "$cl/9b1d2e44-recent.jsonl"
  blob "$HOME/.codex/sessions/2026/08/15/rollout-old.jsonl" 2 && age "$(ago 60)" "$HOME/.codex/sessions/2026/08/15"
  blob "$HOME/.codex/sessions/2026/10/12/rollout-recent.jsonl" 1 && age "$(ago 2)" "$HOME/.codex/sessions/2026/10/12"
  blob "$om/old.jsonl" 2 && age "$(ago 60)" "$om/old.jsonl"
  blob "$om/recent.jsonl" 1 && age "$(ago 2)" "$om/recent.jsonl"
  blob "$HOME/.omp/logs/omp.2026-09-20.4242.log" 3 && age "$(ago 20)" "$HOME/.omp/logs/omp.2026-09-20.4242.log"
  blob "$HOME/.omp/logs/omp.recent.4243.log" 1 && age "$(ago 1)" "$HOME/.omp/logs/omp.recent.4243.log"
  blob "$HOME/.codex/log/codex-tui.log" 2 && age "$(ago 20)" "$HOME/.codex/log/codex-tui.log"
  local gl="$HOME/.config/gcloud/logs"
  blob "$gl/2026.09.20/10.11.12.123456.log" 2 && age "$(ago 20)" "$gl/2026.09.20"
  blob "$gl/recent/09.08.07.654321.log" 1 && age "$(ago 1)" "$gl/recent"

  # Credentials, here and inside agent state.
  mkdir -p "$HOME/.ssh" "$HOME/.config/gh" "$HOME/.config/gcloud/configurations"
  printf 'key\n' >"$HOME/.ssh/id_ed25519"
  printf 'github.com:\n  oauth_token: gho_e2e\n' >"$HOME/.config/gh/hosts.yml"
  printf 'db\n' >"$HOME/.config/gcloud/credentials.db"
  printf 'db\n' >"$HOME/.config/gcloud/access_tokens.db"
  printf '[core]\naccount = e2e@example.invalid\n' >"$HOME/.config/gcloud/configurations/config_default"
  printf '{}\n' >"$HOME/.claude/.credentials.json"
  printf '{}\n' >"$HOME/.codex/auth.json"
  printf 'https://e2e:token@example.invalid\n' >"$HOME/.git-credentials"
  printf '//registry.npmjs.org/:_authToken=npm_e2e\n' >"$HOME/.npmrc"
  age "$(ago 60)" "$HOME/.ssh" "$HOME/.config/gh" "$HOME/.config/gcloud/configurations" \
    "$HOME/.config/gcloud/credentials.db" "$HOME/.config/gcloud/access_tokens.db" \
    "$HOME/.claude/.credentials.json" "$HOME/.codex/auth.json" "$HOME/.git-credentials" "$HOME/.npmrc"

  # Automation-browser leftovers of scripts that died (idle for marmot thanks to the clock shift).
  blob "${LEFTOVERS[0]}/Default/Cache/Cache_Data/data_1" 8
  blob "${LEFTOVERS[1]}/Default/Code Cache/js/index" 4
  blob "${LEFTOVERS[2]}/trace.zip" 2

  mkdir -p "$HOME/.config/marmot"
  # shellcheck disable=SC2088 # the whitelist expands ~ itself
  printf '~/projects/keep\n' >"$HOME/.config/marmot/whitelist"
  printf '# agent sessions untouched for 30 days go to the Trash\nsessions_keep_days = 30\n' >"$HOME/.config/marmot/config"
}

# ---------------------------------------------------------------- run

say "agent-vm e2e as $(id -un) (HOME=$HOME) on $(. /etc/os-release && echo "$PRETTY_NAME"), logs in $LOGS"
printf 'node %s · pnpm %s · %s · fzf %s · %s\n' "$(node --version)" "$(pnpm --version)" "$(git --version)" \
  "$(fzf --version | cut -d' ' -f1)" "$(python3 --version)"
for c in ps pgrep fuser ip sudo; do command -v "$c" >/dev/null || printf 'note: no %s on this machine\n' "$c"; done
SECONDS=0
build_home
printf 'home built in %ss\n' "$SECONDS"

store=$(cd "$HOME" && pnpm store path)
unique=$(du_b "$P/dashboard/node_modules/.pnpm/rxjs@"* "$P/dashboard/node_modules/.pnpm/tslib@"* \
  "$CS/api-charts/node_modules/.pnpm/moment@"*)
# Bytes that must leave $HOME at the very least: what the steps delete outright.
expect=$(du_b "$HOME/.npm/_cacache" "$HOME/.cache/pip" "$HOME/.cache/typescript" \
  "$TRASH/files/old-build.tar" "$TRASH/files/screenshots.tar" "$P/webapp/node_modules" \
  "$HOME/.omp/logs/omp.2026-09-20.4242.log" "$HOME/.codex/log/codex-tui.log" "$HOME/.config/gcloud/logs/2026.09.20")
declare -A before after
before[home]=$(du_b "$HOME") before[df]=$(df_used) before[store]=$(du_b "$store")
before[tmp]=$(du_b "${LEFTOVERS[@]}") before[npm]=$(du_b "$HOME/.npm/_cacache") before[trash]=$(du_b "$TRASH")

say "dry runs: nothing may change"
snapshot >"$LOGS/snapshot-before"
mm schedule run --dry-run </dev/null >"$LOGS/schedule-dry.log" 2>&1 || fail "mm schedule run --dry-run exited $?"
mm clean --dry-run </dev/null >"$LOGS/clean-dry-first.log" 2>&1 || fail "mm clean --dry-run exited $?"
mm purge --dry-run </dev/null >"$LOGS/purge-dry-first.log" 2>&1 || fail "mm purge --dry-run exited $?"
snapshot >"$LOGS/snapshot-after-dry"
comm -23 "$LOGS/snapshot-before" "$LOGS/snapshot-after-dry" >"$LOGS/dry-changed"
check "dry runs removed or changed nothing" [ ! -s "$LOGS/dry-changed" ]
head -n 5 "$LOGS/dry-changed"

say "mm schedule run: unattended"
u0=$(in_use)
mm schedule run </dev/null >"$LOGS/schedule.log" 2>&1 || fail "mm schedule run exited $?"
u1=$(in_use)
step "mm schedule run" "$(size_in schedule-dry.log "Would free: $SIZE")" "$(size_in schedule.log "Space freed: $SIZE")" $((u0 - u1))
check "it wrote its summary for mm status" [ -s "$HOME/.local/state/marmot/last-run.json" ]
check "it swept only Trash items deleted 30+ days ago" eval '[ ! -e "$TRASH/files/old-build.tar" ] && [ -e "$TRASH/files/screenshots.tar" ]'
check "it left the worktrees alone" present "$CS/api-charts" "$CS/api-typo"

say "mm clean: on a terminal"
mm clean --dry-run </dev/null >"$LOGS/clean-dry.log" 2>&1 || fail "mm clean --dry-run exited $?"
u0=$(in_use)
mm_tty clean-tty.log clean || fail "mm clean on a terminal exited $?"
grep -a '^pty-drive:' "$LOGS/clean-tty.log" | cut -c1-160 || true
u1=$(in_use)
step "mm clean (terminal)" "$(size_in clean-dry.log "Would free: $SIZE")" "$(size_in clean-tty.log "Space freed: $SIZE")" $((u0 - u1))
check "it asked before sweeping the Trash" grep -aqE '^pty-drive: confirm: .*Trash items' "$LOGS/clean-tty.log"

say "mm purge: on a terminal"
mm purge --dry-run </dev/null >"$LOGS/purge-dry.log" 2>&1 || fail "mm purge --dry-run exited $?"
u0=$(in_use)
mm_tty purge-tty.log purge || fail "mm purge on a terminal exited $?"
grep -a '^pty-drive:' "$LOGS/purge-tty.log" | cut -c1-160 || true
u1=$(in_use)
dry=$(( $(size_in purge-dry.log "Would free: $SIZE") + $(size_in purge-dry.log "finished \(frees $SIZE") \
  + $(size_in purge-dry.log "~$SIZE from the pnpm store") + $(size_in purge-dry.log "Then pnpm store prune: ~$SIZE") ))
real=$(( $(size_in purge-tty.log "Space freed: $SIZE") + $(size_in purge-tty.log "Worktrees removed: [0-9]+ \($SIZE") \
  + $(size_in purge-tty.log "pnpm store prune: freed $SIZE") ))
step "mm purge (terminal)" "$dry" "$real" $((u0 - u1))
check "it offered both finished worktrees in the picker" grep -aq '^pty-drive: picker:' "$LOGS/purge-tty.log"
check "it saw one merged and one squash-merged" eval 'grep -aq "api-charts · branch feat/charts · merged" "$LOGS/purge-tty.log" &&
  grep -aq "api-typo · branch fix/typo · squash-merged" "$LOGS/purge-tty.log"'
# (asked of the first dry run: removing its stale node_modules later makes the worktree look busy)
check "it reported the idle worktree with uncommitted work as kept" grep -aqE 'api-flaky.*uncommitted' "$LOGS/purge-dry-first.log"

after[home]=$(du_b "$HOME") after[df]=$(df_used) after[store]=$(du_b "$store")
after[tmp]=$(du_b "${LEFTOVERS[@]}") after[npm]=$(du_b "$HOME/.npm/_cacache") after[trash]=$(du_b "$TRASH")

say "kept"
check "whitelisted project keeps its node_modules" present "$P/keep/node_modules/lodash"
check "project in use today keeps its node_modules" present "$P/active/node_modules/lodash"
check "worktree with uncommitted work is kept" grep -qx unfinished "$PS/api-flaky/README.md"
check "its change is still uncommitted" eval '[[ "$(git -C "$PS/api-flaky" status --porcelain)" == *README.md* ]]'
check "worktree in progress is kept with its node_modules" present "$PS/api-search/src/search.js" "$PS/api-search/node_modules/lodash"
check "branches of removed worktrees are kept" git -C "$P/api" show-ref -q --verify refs/heads/feat/charts refs/heads/fix/typo
check "repository is intact" git -C "$P/api" fsck --no-progress
check "recent sessions are kept" present "$HOME/.claude/projects/${HOME//\//-}-projects-api/9b1d2e44-recent.jsonl" \
  "$HOME/.codex/sessions/2026/10/12/rollout-recent.jsonl" "$HOME/.omp/agent/sessions/-${HOME//\//-}-projects-api-/recent.jsonl"
check "old sessions went to the Trash, not away" present "$TRASH/files/0f6c7a52-old.jsonl" "$TRASH/files/rollout-old.jsonl" "$TRASH/files/old.jsonl"
check "recent Trash item is kept" present "$TRASH/files/notes.txt" "$TRASH/info/notes.txt.trashinfo"
check "recent agent and gcloud logs are kept" present "$HOME/.omp/logs/omp.recent.4243.log" "$HOME/.config/gcloud/logs/recent/09.08.07.654321.log"
check "credentials are kept" present "$HOME/.ssh/id_ed25519" "$HOME/.config/gh/hosts.yml" \
  "$HOME/.config/gcloud/credentials.db" "$HOME/.config/gcloud/access_tokens.db" \
  "$HOME/.config/gcloud/configurations/config_default" "$HOME/.claude/.credentials.json" \
  "$HOME/.codex/auth.json" "$HOME/.git-credentials" "$HOME/.npmrc"
check "sources are untouched" present "$P/webapp/package.json" "$P/dashboard/package.json" "$P/api/src/index.js"

say "freed"
check "finished worktrees are removed" missing "$CS/api-charts" "$CS/api-typo"
check "git no longer lists them" eval '! git -C "$P/api" worktree list | grep -q -e api-charts -e api-typo'
check "stale node_modules are gone" missing "$P/webapp/node_modules" "$P/dashboard/node_modules"
check "old Trash items are gone" missing "$TRASH/files/old-build.tar" "$TRASH/files/screenshots.tar"
check "old agent and gcloud logs are gone" missing "$HOME/.omp/logs/omp.2026-09-20.4242.log" "$HOME/.codex/log/codex-tui.log" \
  "$HOME/.config/gcloud/logs/2026.09.20"
check "browser leftovers in /tmp are gone" missing "${LEFTOVERS[@]}"
check "npm, pip and TypeScript caches are emptied" [ "$(du_b "$HOME/.npm/_cacache" "$HOME/.cache/pip" "$HOME/.cache/typescript")" -lt $((1 << 20)) ]
check "pnpm store lost at least the packages only stale and finished work used" \
  [ $((before[store] - after[store])) -ge $((unique * 4 / 5)) ]
reclaimed=$((before[home] - after[home]))
check "\$HOME shrank by at least what the scenario made reclaimable ($(mib "$expect"))" [ "$reclaimed" -ge "$expect" ]
check "df agrees with du (within 5%)" within $((before[df] - after[df])) "$reclaimed"

say "before / after"
printf '%-24s %14s %14s %14s\n' "" before after freed
for k in home df store npm trash tmp; do
  case $k in
    home) l='du -sx $HOME' ;; df) l='df used ($HOME fs)' ;; store) l='pnpm store' ;;
    npm) l='npm cache' ;; trash) l='Trash' ;; tmp) l='/tmp browser leftovers' ;;
  esac
  printf '%-24s %14s %14s %14s\n' "$l" "$(mib "${before[$k]}")" "$(mib "${after[$k]}")" "$(mib $((before[$k] - after[$k])))"
done
printf '\n%-24s %14s %14s %14s\n' step "dry run said" "marmot freed" "disk freed"
printf '%s\n' "${STEPS[@]}"
printf '\nscenario took %ss\n' "$SECONDS"

if (( FAILED )); then
  say "FAILED (logs: $LOGS)"
  for f in "$LOGS"/*.log; do printf '\n---- %s (last 40 lines)\n' "${f##*/}"; tail -n 40 "$f"; done
  exit 1
fi
say "PASSED"
