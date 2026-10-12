#!/usr/bin/env bats
# cmd/clean.sh: temp files to Trash, Trash retention sweep, tool cleans, Docker, dry-run.

# Busy-tool tests start processes named after real tools (uv, pnpm, npx); clean's busy check sees
# the whole machine, so tests in this file must not run concurrently with each other.
setup_file() { export BATS_NO_PARALLELIZE_WITHIN_FILE=true; }

setup() {
  load helpers/common
  mm_test_setup
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  mkdir -p "$SB/tmp"
}
teardown() { mm_test_teardown; }

# Assertion helpers. Bash's errexit ignores a failing command inside `a && b` (unless it is the
# last) and any `! cmd`, so mid-test checks must be single commands that fail on their own.
# exist PATH... / gone PATH... — every PATH exists / none does.
exist() { local p; for p; do [ -e "$p" ] || { echo "missing: $p"; return 1; }; done; }
gone() { local p; for p; do [ ! -e "$p" ] || { echo "still there: $p"; return 1; }; done; }
# none CMD... — CMD must fail (e.g. a grep that must find nothing).
none() { if "$@"; then return 1; fi; }

# src — source core and the command into the test shell (to call its functions directly).
src() { mm_core; . "$MM_SRC/cmd/clean.sh"; }

# tmp_scan DAYS — the temp scan over $SB/tmp (or $DIRS), with a fresh in-use snapshot.
tmp_scan() {
  mm_inuse_refresh >/dev/null 2>&1
  _CLEAN_TMP_DIRS="${DIRS:-$SB/tmp}" _clean_tmp "$1"
}

# fake_rec NAME [BODY] — double that appends "<cwd> NAME <args>" to $CALLS, then runs BODY.
fake_rec() {
  mm_test_fake "$1" "echo \"\$(pwd) $1 \$*\" >>\"\$CALLS\"
${2:-}"
}

# at_clock_days_ago PATH DAYS — set PATH's mtime/atime DAYS before the shifted clock (mm_test_clock).
at_clock_days_ago() {
  touch -h -d "@$(( $(command date +%s) + ${MM_TEST_CLOCK_SHIFT:-0} - $2 * 86400 ))" "$1"
}

# trash_item NAME DAYS_AGO [INFO] — a Trash entry with a spec .trashinfo (INFO=none: no .trashinfo).
trash_item() {
  local t="$XDG_DATA_HOME/Trash"
  mkdir -p "$t/files" "$t/info"
  echo data >"$t/files/$1"
  [[ "${3:-}" == none ]] && return 0
  printf '[Trash Info]\nPath=/somewhere/%s\nDeletionDate=%s\n' "$1" \
    "${3:-$(command date -d "$2 days ago" +%Y-%m-%dT%H:%M:%S)}" >"$t/info/$1.trashinfo"
}

fake_docker() {
  fake_rec docker '
iso() { command date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000000000Z; }
case "$1 ${2:-}" in
  "ps "*) printf "%s\n" c-old c-recent c-never-old c-never-new ;;
  "container inspect")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      c-old /old-api exited "$(iso "10 days ago")" "$(iso "90 days ago")" app:1 1000 \
      c-recent /long-lived-db exited "$(iso "1 hour ago")" "$(iso "100 days ago")" postgres:16 2000 \
      c-never-old /never-ran created 0001-01-01T00:00:00Z "$(iso "20 days ago")" alpine 0 \
      c-never-new /fresh created 0001-01-01T00:00:00Z "$(iso "1 day ago")" alpine 0 ;;
  "images "*) echo 12MB ;;
  "builder du") echo "Reclaimable: 1.5GB" ;;
  "volume ls") echo vol-db ;;
  "system df") printf "vol-db\t1.8GB\n" ;;
esac'
}

# blob PATH — a 1.1MB file (tool cleans skip caches under 1MB).
blob() { mkdir -p "$(dirname "$1")"; head -c 1100000 /dev/urandom >"$1"; }

fake_tools() {
  fake_rec npm
  fake_rec bun
  fake_rec pnpm '[[ "$*" == "store path" ]] && echo "$SB/store"; exit 0'
  fake_rec yarn 'case "$*" in --version) echo 1.22.22 ;; "cache dir") echo "$SB/yarncache" ;; esac'
  blob "$HOME/.npm/_cacache/blob"; blob "$HOME/.bun/install/cache/blob"
  blob "$SB/store/blob"; blob "$SB/yarncache/blob"
}

# ---------------------------------------------------------------- temp files

@test "an idle /tmp entry goes to the Trash with a .trashinfo, never to rm" {
  mkdir -p "$SB/tmp/old-dir/sub"; echo x >"$SB/tmp/old-dir/sub/f"; mm_age "$SB/tmp/old-dir" 30
  mm_test_clock 40
  src; run tmp_scan 7
  [ ! -e "$SB/tmp/old-dir" ]
  [ -f "$XDG_DATA_HOME/Trash/files/old-dir/sub/f" ]
  grep -qxF "Path=$SB/tmp/old-dir" "$XDG_DATA_HOME/Trash/info/old-dir.trashinfo"
  [[ "$(mm_log_rows trash)" == "$SB/tmp/old-dir"* ]]
  [ -z "$(mm_log_rows remove)" ]
}

@test "a recently changed entry is kept even when its mtime is old (ctime counts)" {
  echo x >"$SB/tmp/fresh"; mm_age "$SB/tmp/fresh" 30
  src; run tmp_scan 7
  [ -e "$SB/tmp/fresh" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/fresh" ]
}

@test "an old folder holding one recent file is kept" {
  mkdir -p "$SB/tmp/mixed"; echo x >"$SB/tmp/mixed/old"; echo y >"$SB/tmp/mixed/new"
  mm_age "$SB/tmp/mixed" 30
  mm_test_clock 40
  at_clock_days_ago "$SB/tmp/mixed/new" 2
  src; run tmp_scan 7
  exist "$SB/tmp/mixed/new" "$SB/tmp/mixed/old"
}

@test "an entry that is some process's cwd is kept" {
  mkdir -p "$SB/tmp/busy"; echo x >"$SB/tmp/busy/f"; mm_age "$SB/tmp/busy" 30
  mm_test_bg "$SB/tmp/busy" sleep 60
  mm_test_clock 40
  src; run tmp_scan 7
  [ -e "$SB/tmp/busy/f" ]
  [[ "$(mm_log_rows refused)" == *"in use"* ]]
}

@test "a whitelisted entry is kept" {
  mkdir -p "$SB/tmp/keep-me" "$XDG_CONFIG_HOME/marmot"; echo x >"$SB/tmp/keep-me/f"; mm_age "$SB/tmp/keep-me" 30
  echo "$SB/tmp/keep-me" >"$XDG_CONFIG_HOME/marmot/whitelist"
  mm_test_clock 40
  src; run tmp_scan 7
  [ -e "$SB/tmp/keep-me/f" ]
}

@test "sockets are kept" {
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SB/tmp/app.sock"
  mm_age "$SB/tmp/app.sock" 30
  mm_test_clock 40
  src; run tmp_scan 7
  [ -S "$SB/tmp/app.sock" ]
}

@test "tmux-*, systemd-private-* and other reserved names are skipped" {
  local n
  for n in tmux-1001 systemd-private-abc-chrony.service-x snap-private-tmp .X11-unix .ICE-unix ssh-agent.1 \
           fnm_multishells marmot-test-other .mount_app; do
    mkdir -p "$SB/tmp/$n"; echo x >"$SB/tmp/$n/f"
  done
  mm_age "$SB/tmp" 30
  mm_test_clock 40
  src; run tmp_scan 7
  for n in tmux-1001 systemd-private-abc-chrony.service-x snap-private-tmp .X11-unix .ICE-unix ssh-agent.1 \
           fnm_multishells marmot-test-other .mount_app; do
    [ -e "$SB/tmp/$n/f" ] || { echo "removed $n"; false; }
  done
}

@test "/var/tmp needs 30 idle days while /tmp follows --days" {
  local d
  for d in tmp vartmp; do
    mkdir -p "$SB/$d/mid"; echo x >"$SB/$d/mid/f"; mm_age "$SB/$d/mid" 35
  done
  mkdir -p "$SB/vartmp/ancient"; echo x >"$SB/vartmp/ancient/f"; mm_age "$SB/vartmp/ancient" 60
  mm_test_clock 40
  at_clock_days_ago "$SB/tmp/mid/f" 20; at_clock_days_ago "$SB/vartmp/mid/f" 20
  src
  DIRS="$SB/tmp $SB/vartmp" _CLEAN_TMP_PERSIST="$SB/vartmp" run tmp_scan 7
  [ ! -e "$SB/tmp/mid" ]          # idle 20 days >= 7
  [ -e "$SB/vartmp/mid/f" ]       # idle 20 days < 30
  [ ! -e "$SB/vartmp/ancient" ]   # idle 40 days
}

@test "_CLEAN_TMP_DIRS outside /tmp and /var/tmp is rejected before anything runs" {
  mkdir -p "$HOME/docs"; echo x >"$HOME/docs/f"; mm_age "$HOME/docs" 60
  local v
  for v in "$HOME" /tmp /var/tmp "/tmp/../$HOME" /tmp/mo-does-not-exist; do
    _CLEAN_TMP_DIRS="$v" run mm clean
    [ "$status" -ne 0 ] || { echo "accepted $v"; false; }
  done
  _CLEAN_TMP_DIRS="$SB/tmp" _CLEAN_TMP_PERSIST="$HOME" run mm clean
  [ "$status" -ne 0 ]
  [ -f "$HOME/docs/f" ]
  [ ! -s "$CALLS" ]
}

@test "with the Trash on another filesystem, temp entries are kept and reported once" {
  [[ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$SB")" ]] || skip "/dev/shm is on the same filesystem"
  local shm; shm=$(mktemp -d /dev/shm/marmot-test-clean.XXXX)
  export XDG_DATA_HOME="$shm"
  mkdir -p "$SB/tmp/a" "$SB/tmp/b"; echo x >"$SB/tmp/a/f"; echo x >"$SB/tmp/b/f"; mm_age "$SB/tmp" 30
  mm_test_clock 40
  src; run tmp_scan 7
  rm -rf "$shm"
  exist "$SB/tmp/a/f" "$SB/tmp/b/f"
  [ "$(grep -c 'another filesystem' <<<"$output")" -eq 1 ]
  [ -z "$(mm_log_rows refused)" ]
}

# ---------------------------------------------------------------- Trash retention

@test "Trash sweep removes an item trashed 8 days ago with its .trashinfo, keeps a 1-day-old one" {
  trash_item old 8; trash_item new 1; trash_item orphan 0 none; trash_item garbled 0 "last tuesday"
  src; mm_inuse_refresh >/dev/null 2>&1
  mm_confirm() { return 0; }
  run _clean_trash "$MM_TRASH_DIR"
  local t="$XDG_DATA_HOME/Trash"
  gone "$t/files/old" "$t/info/old.trashinfo"
  exist "$t/files/new" "$t/info/new.trashinfo"
  [ -e "$t/files/orphan" ]                                    # no .trashinfo: unrecognized
  exist "$t/files/garbled" "$t/info/garbled.trashinfo"  # invalid DeletionDate
}

@test "Trash sweep does nothing without a terminal" {
  trash_item old 30
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_trash "$MM_TRASH_DIR"
  exist "$XDG_DATA_HOME/Trash/files/old" "$XDG_DATA_HOME/Trash/info/old.trashinfo"
  [ -z "$(mm_log_rows remove)" ]
}

@test "a Trash with only recent or no items is reported, not a crash under set -u" {
  mkdir -p "$XDG_DATA_HOME/Trash/files" "$XDG_DATA_HOME/Trash/info"
  run bash -c 'set -uo pipefail; . "$1/lib/core.sh"; . "$1/cmd/clean.sh"; _clean_trash "$MM_TRASH_DIR"' _ "$MM_SRC"
  [ "$status" -eq 0 ]
  trash_item new 1
  run bash -c 'set -uo pipefail; . "$1/lib/core.sh"; . "$1/cmd/clean.sh"; _clean_trash "$MM_TRASH_DIR"' _ "$MM_SRC"
  [ "$status" -eq 0 ]
  [ -e "$XDG_DATA_HOME/Trash/files/new" ]
}

@test "a temp entry marmot trashed today survives the next day's Trash sweep" {
  mkdir -p "$SB/tmp/report"; echo x >"$SB/tmp/report/f"; mm_age "$SB/tmp/report" 30
  mm_test_clock 40
  src; run tmp_scan 7
  [ -e "$XDG_DATA_HOME/Trash/files/report/f" ]
  mm_test_clock 1   # tomorrow, measured from the real DeletionDate written today
  mm_confirm() { return 0; }
  run _clean_trash "$MM_TRASH_DIR"
  [ -e "$XDG_DATA_HOME/Trash/files/report/f" ]
}

# ---------------------------------------------------------------- developer tools

@test "npm/pnpm/yarn cache cleans are skipped while the tool (or npx) runs" {
  fake_tools
  mkdir -p "$SB/bin"
  local t
  for t in npx pnpm yarn; do printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/bin/$t"; chmod +x "$SB/bin/$t"; done
  mm_test_bg "$SB" "$SB/bin/npx"; mm_test_bg "$SB" "$SB/bin/pnpm"; mm_test_bg "$SB" "$SB/bin/yarn"
  src
  run _clean_dev
  [[ "$output" == *"npm cache · skipped (npx busy)"* ]]
  [[ "$output" == *"pnpm store · skipped (pnpm busy)"* ]]
  [[ "$output" == *"yarn cache · skipped (yarn busy)"* ]]
  none grep -E 'npm cache clean|store prune|yarn cache clean' "$CALLS"
  exist "$HOME/.npm/_cacache/blob" "$SB/store/blob" "$SB/yarncache/blob"
}

@test "tool cleans run from / so a project's yarnrc/npmrc/.yarn/cache never applies" {
  fake_tools
  mkdir -p "$SB/project/.yarn/cache"; echo 'cacheFolder: .yarn/cache' >"$SB/project/.yarnrc.yml"
  src
  mm_proc_running() { return 1; }   # isolate from tools running on the host
  cd "$SB/project"
  run _clean_dev
  grep -qxF '/ npm cache clean --force' "$CALLS"
  grep -qxF '/ pnpm store path' "$CALLS"
  grep -qxF '/ pnpm store prune' "$CALLS"
  grep -qxF '/ yarn cache dir' "$CALLS"
  grep -qxF '/ yarn cache clean' "$CALLS"
  grep -qxF '/ bun pm cache rm' "$CALLS"
  none grep -v '^/ ' "$CALLS"
}

# ---------------------------------------------------------------- docker

@test "docker: only containers stopped 7+ days ago (by FinishedAt) are removed; volumes only reported" {
  fake_docker
  src
  mm_confirm() { return 0; }
  docker_then_review() { _clean_docker; _clean_review_print; }
  run docker_then_review
  grep -qE ' docker rm c-old c-never-old$' "$CALLS"
  [ "$(grep -c ' docker rm ' "$CALLS")" -eq 1 ]
  none grep -E 'docker (volume (rm|prune)|system prune|container prune)' "$CALLS"
  [[ "$output" == *"Kept for you to review"*"Unused Docker volumes"*"vol-db"* ]]
}

@test "docker: nothing is removed without a terminal" {
  fake_docker
  src
  run _clean_docker
  none grep ' docker rm ' "$CALLS"
  [[ "$output" == *"old-api"* ]]   # still listed
}

# ---------------------------------------------------------------- editors

@test "editor servers: the newest build and builds in use are kept" {
  local s="$HOME/.vscode-server/cli/servers"
  mkdir -p "$s/Stable-a" "$s/Stable-b" "$s/Stable-c"
  touch -d '20 days ago' "$s/Stable-a"; touch -d '10 days ago' "$s/Stable-b"
  mm_test_bg "$s/Stable-a" sleep 60
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_editors
  exist "$s/Stable-a" "$s/Stable-c"
  gone "$s/Stable-b"
  [ ! -e "$XDG_DATA_HOME/Trash/files/Stable-b" ]   # regenerable: removed, not trashed
}

# ---------------------------------------------------------------- catalog

# catalog — source core + clean, load the catalog (built-in, user file, agents), take an in-use snapshot.
catalog() { src; mm_catalog_load; mm_inuse_refresh >/dev/null 2>&1; }

# full_run ARGS... — `mm clean` with every machine-changing tool faked and the temp scan in $SB/tmp.
full_run() { fake_tools; fake_docker; _CLEAN_TMP_DIRS="$SB/tmp" run mm clean "$@"; }

# busy_proc NAME — run a process called NAME (a script, so pgrep sees it by name) until teardown.
busy_proc() {
  mkdir -p "$SB/bin"; printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/bin/$1"; chmod +x "$SB/bin/$1"
  mm_test_bg "$SB" "$SB/bin/$1"
}

@test "a catalog cache is emptied permanently but its folder is kept" {
  mkdir -p "$HOME/.cache/uv/wheels-v1/pkg" "$HOME/.cache/uv/archive-v0"
  echo x >"$HOME/.cache/uv/wheels-v1/pkg/w.whl"; echo y >"$HOME/.cache/uv/archive-v0/a"
  catalog
  run _clean_catalog_caches
  [ -d "$HOME/.cache/uv" ]
  [ -z "$(ls -A "$HOME/.cache/uv")" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/wheels-v1" ]          # regenerable: removed, not trashed
  [ "$(mm_log_rows remove | grep -c "^$HOME/.cache/uv/")" -eq 2 ]
}

@test "a catalog cache is skipped while its tool runs" {
  mkdir -p "$HOME/.cache/uv/wheels-v1"; echo x >"$HOME/.cache/uv/wheels-v1/w"
  busy_proc uv
  catalog
  run _clean_catalog_caches
  [ -e "$HOME/.cache/uv/wheels-v1/w" ]
  [[ "$output" == *"uv cache · skipped (uv busy)"* ]]
}

@test "a whitelisted catalog cache is skipped" {
  mkdir -p "$HOME/.cache/pip/http" "$XDG_CONFIG_HOME/marmot"; echo x >"$HOME/.cache/pip/http/f"
  echo '~/.cache/pip/http' >"$XDG_CONFIG_HOME/marmot/whitelist"
  catalog
  run _clean_catalog_caches
  [ -e "$HOME/.cache/pip/http/f" ]
}

@test "a catalog cache folder that is a symlink out of the home folder is not emptied" {
  mkdir -p "$SB/elsewhere" "$HOME/.cache"; echo keep >"$SB/elsewhere/f"
  ln -s "$SB/elsewhere" "$HOME/.cache/zig"
  catalog
  run _clean_catalog_caches
  [ -e "$SB/elsewhere/f" ]
}

@test "agent state is never touched, even when a catalog row names a cache-looking folder in it" {
  mkdir -p "$HOME/.claude/cache" "$HOME/.claude/projects/p" "$XDG_CONFIG_HOME/marmot"
  echo x >"$HOME/.claude/cache/c"; echo '{}' >"$HOME/.claude/projects/p/s.jsonl"
  printf 'cache|Claude cache|~/.claude/cache|\ncache|Claude all|~/.claude|\n' >"$XDG_CONFIG_HOME/marmot/catalog"
  catalog
  run _clean_catalog_caches
  exist "$HOME/.claude/cache/c" "$HOME/.claude/projects/p/s.jsonl"
  [ -z "$(mm_log_rows remove)" ]
}

@test "report entries and agent state are never removed, only listed with their size" {
  mkdir -p "$HOME/.cache/huggingface/hub/m" "$HOME/.ollama/models/blobs" "$HOME/.m2/repository/org/x" \
    "$HOME/.local/share/fnm/node-versions/v20.1.0/installation" "$HOME/.local/share/fnm/node-versions/v22.2.0/installation" \
    "$HOME/.claude/projects/p" "$HOME/.claude/cache"
  echo w >"$HOME/.cache/huggingface/hub/m/model.safetensors"; echo b >"$HOME/.ollama/models/blobs/sha"
  echo j >"$HOME/.m2/repository/org/x/x.jar"; echo n >"$HOME/.local/share/fnm/node-versions/v20.1.0/installation/node"
  echo s >"$HOME/.claude/projects/p/s.jsonl"; echo c >"$HOME/.claude/cache/c"
  mm_age "$HOME" 400
  mm_test_clock 400
  full_run
  [ "$status" -eq 0 ]
  exist "$HOME/.cache/huggingface/hub/m/model.safetensors" "$HOME/.ollama/models/blobs/sha" \
    "$HOME/.m2/repository/org/x/x.jar" "$HOME/.local/share/fnm/node-versions/v20.1.0/installation/node" \
    "$HOME/.claude/projects/p/s.jsonl" "$HOME/.claude/cache/c"
  [[ "$output" == *"Kept for you to review"* ]]
  [[ "$output" == *"Maven repository"* && "$output" == *"Hugging Face models"* && "$output" == *"Ollama models"* ]]
  [[ "$output" == *"fnm Node versions"*"2 installed"* ]]
  [[ "$output" == *"Claude Code state"*"last active"* ]]
  [ -z "$(mm_log_rows remove | grep -E '/(\.m2|\.ollama|huggingface|fnm|\.claude)/')" ]
}

# claude_versions ACTIVE VERSION... — fake Claude Code installs (one file per version) + launcher link.
claude_versions() {
  local active=$1 v d="$HOME/.local/share/claude/versions"; shift
  mkdir -p "$d" "$HOME/.local/bin"
  for v in "$@"; do echo "$v" >"$d/$v"; done
  ln -sfn "$d/$active" "$HOME/.local/bin/claude"
}

@test "agent versions: the active one, newer staged ones and one previous are kept" {
  claude_versions 2.1.10 2.1.7 2.1.8 2.1.9 2.1.10 2.1.11
  catalog
  run _clean_builds
  local d="$HOME/.local/share/claude/versions"
  gone "$d/2.1.7" "$d/2.1.8"
  exist "$d/2.1.9" "$d/2.1.10" "$d/2.1.11"
}

@test "agent versions: everything is kept when the active symlink is broken or missing" {
  claude_versions 9.9.9 1.0.0 1.0.1 1.0.2
  catalog
  run _clean_builds
  local d="$HOME/.local/share/claude/versions"
  exist "$d/1.0.0" "$d/1.0.1" "$d/1.0.2"
  rm "$HOME/.local/bin/claude"
  run _clean_builds
  exist "$d/1.0.0" "$d/1.0.1" "$d/1.0.2"
}

@test "Playwright: newest revision per browser kept, plus ones in use or still referenced by a project" {
  local p="$HOME/.cache/ms-playwright" r
  for r in chromium-1100 chromium-1200 chromium_headless_shell-1100 chromium_headless_shell-1200 \
           firefox-1400 firefox-1500 webkit-1900 webkit-2000 ffmpeg-1009; do
    mkdir -p "$p/$r"; echo bin >"$p/$r/browser"
  done
  mkdir -p "$p/.links" "$SB/proj/node_modules/playwright-core"
  printf '{ "browsers": [\n { "name": "chromium-headless-shell",\n "revision": "1100" }\n] }\n' \
    >"$SB/proj/node_modules/playwright-core/browsers.json"
  echo "$SB/proj/node_modules/playwright-core" >"$p/.links/abc123"
  mm_test_bg "$p/webkit-1900" sleep 60
  catalog
  run _clean_builds
  gone "$p/chromium-1100" "$p/firefox-1400"
  for r in chromium-1200 chromium_headless_shell-1100 chromium_headless_shell-1200 firefox-1500 \
           webkit-1900 webkit-2000 ffmpeg-1009 .links; do
    [ -e "$p/$r" ] || { echo "removed $r"; false; }
  done
}

@test "Puppeteer and Cypress: only the newest build per browser is kept" {
  local p="$HOME/.cache/puppeteer" c="$HOME/.cache/Cypress"
  mkdir -p "$p/chrome/linux-120.0.6099.109" "$p/chrome/linux-121.0.6167.85" "$p/chrome-headless-shell/linux-120.0.6099.109" \
    "$c/13.6.0" "$c/13.10.0"
  catalog
  run _clean_builds
  gone "$p/chrome/linux-120.0.6099.109"
  exist "$p/chrome/linux-121.0.6167.85"
  [ -d "$p/chrome-headless-shell/linux-120.0.6099.109" ]
  gone "$c/13.6.0"
  exist "$c/13.10.0"
}

@test "user catalog rows outside the home folder, of other kinds, or the home folder itself are rejected" {
  mkdir -p "$SB/data" "$HOME/mine/stuff" "$XDG_CONFIG_HOME/marmot"
  echo keep >"$SB/data/f"; echo x >"$HOME/mine/stuff/f"; echo keep >"$HOME/top"
  ln -sfn "$SB/data" "$HOME/out"
  cat >"$XDG_CONFIG_HOME/marmot/catalog" <<EOF
cache|outside|$SB/data|
cache|dotdot|~/../sb/data|
cache|via symlink|~/out|
cache|home|~|
revisions|not allowed|~/mine|||1:^(.*)-([0-9]+)\$|
cache|mine|~/mine|
EOF
  catalog
  run _clean_catalog_caches
  exist "$SB/data/f" "$HOME/top" "$HOME/mine"
  [ "$(grep -c 'catalog row ignored' <<<"$output")" -eq 5 ]
  gone "$HOME/mine/stuff"     # the valid user row works
}

@test "~/.m2/repository is never removed" {
  mkdir -p "$HOME/.m2/repository/org/a/1.0"; echo j >"$HOME/.m2/repository/org/a/1.0/a.jar"
  mm_age "$HOME/.m2" 400
  mm_test_clock 400
  full_run
  [ "$status" -eq 0 ]
  [ -e "$HOME/.m2/repository/org/a/1.0/a.jar" ]
}

# ---------------------------------------------------------------- system

@test "apt is busy during an unattended-upgrade run, not because its shutdown helper waits" {
  mkdir -p "$SB/u"
  printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/u/unattended-upgrade-shutdown"
  printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/u/unattended-upgrade"
  chmod +x "$SB/u/"*
  src
  mm_sudo() { "$@"; }                     # fuser as this user: sees no lock holder
  if pgrep -x 'apt|apt-get|aptitude|dpkg' >/dev/null || pgrep -f '/unattended-upgrade( |$)' >/dev/null; then
    skip "apt is really running on this host"
  fi
  mm_test_bg "$SB" "$SB/u/unattended-upgrade-shutdown" --wait-for-signal
  none _clean_apt_busy
  mm_test_bg "$SB" "$SB/u/unattended-upgrade"
  _clean_apt_busy
}

# ---------------------------------------------------------------- dry run

@test "dry-run calls no state-changing command and changes nothing" {
  fake_tools; fake_docker
  trash_item old 30
  mkdir -p "$SB/tmp/old"; echo x >"$SB/tmp/old/f"; mm_age "$SB/tmp/old" 30
  mkdir -p "$HOME/.cache/go-build/aa" "$HOME/.vscode-server/cli/servers/Stable-a" "$HOME/.vscode-server/cli/servers/Stable-b"
  touch -d '10 days ago' "$HOME/.vscode-server/cli/servers/Stable-a"
  mm_test_clock 40
  _CLEAN_TMP_DIRS="$SB/tmp" run mm clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run complete"* ]]
  none grep -E ' (prune|rm|clean|purge)( |$)' "$CALLS"
  exist "$SB/tmp/old/f" "$XDG_DATA_HOME/Trash/files/old" "$HOME/.cache/go-build/aa"
  [ -d "$HOME/.vscode-server/cli/servers/Stable-a" ]
  exist "$HOME/.npm/_cacache/blob" "$SB/store/blob" "$SB/yarncache/blob"
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}
