#!/usr/bin/env bats
# cmd/clean.sh: shared temp report, Trash retention sweep, tool cleans, Docker, dry-run.

# Busy-tool tests start processes named after real tools (pip, pnpm, npx, uv); clean's busy
# check sees the whole machine, so tests in this file must not run concurrently with each other.
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

# fake_rec NAME [BODY] — double that appends "<cwd> NAME <args>" to $CALLS, then runs BODY.
fake_rec() {
  mm_test_fake "$1" "echo \"\$(pwd) $1 \$*\" >>\"\$CALLS\"
${2:-}"
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

# fake_docker — containers: c-old/c-never-old (stopped/created long ago), c-recent (postgres:16,
# stopped an hour ago), c-never-new, and c-running (web:1, listed only without --filter). Images
# no container uses: old/tool:1 (90 days), multi:a+multi:b (200 days, tag time unknown), base:12
# (built 90 days ago, pulled 2 days ago), fresh:1 (3 days), and an untagged one. Removing the
# two old ones drops the `system df` Images total by 2.1GB (estimate from unique sizes: 2.0GB).
# FAKE_DOCKER_PS_FAIL=1 makes `docker ps` fail.
fake_docker() {
  fake_rec docker '
iso() { command date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000000000Z; }
row() { printf "%s\t%s\t%s\t%s\n" "$@"; }
gone="$CALLS.gone"
[[ -n "${FAKE_DOCKER_PS_FAIL:-}" && "$1" == ps ]] && exit 1
case "$1 ${2:-}" in
  "ps "*) printf "%s\n" c-old c-recent c-never-old c-never-new
    [[ "$*" == *--filter* ]] || echo c-running ;;
  "container inspect")
    if [[ "$*" == *"{{.Image}}"* ]]; then
      shift 4
      for c; do
        case $c in c-old) echo sha256:app ;; c-recent) echo sha256:postgres ;; c-running) echo sha256:web ;; *) echo sha256:alpine ;; esac
      done
    else
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        c-old /old-api exited "$(iso "10 days ago")" "$(iso "90 days ago")" app:1 1000 \
        c-recent /long-lived-db exited "$(iso "1 hour ago")" "$(iso "100 days ago")" postgres:16 2000 \
        c-never-old /never-ran created 0001-01-01T00:00:00Z "$(iso "20 days ago")" alpine 0 \
        c-never-new /fresh created 0001-01-01T00:00:00Z "$(iso "1 day ago")" alpine 0
    fi ;;
  "image ls") printf "%s\n" sha256:old sha256:multi sha256:pulled sha256:fresh sha256:web sha256:postgres sha256:app \
    sha256:alpine sha256:dangling sha256:multi ;;
  "image inspect")
    row sha256:old "old/tool:1" "$(iso "90 days ago")" "$(iso "90 days ago")"
    row sha256:multi "multi:a multi:b" "$(iso "200 days ago")" 0001-01-01T00:00:00Z
    row sha256:pulled "base:12" "$(iso "90 days ago")" "$(iso "2 days ago")"
    row sha256:fresh "fresh:1" "$(iso "3 days ago")" "$(iso "3 days ago")"
    for i in web:1 postgres:16 app:1 alpine:latest; do
      row "sha256:${i%%:*}" "$i" "$(iso "200 days ago")" "$(iso "200 days ago")"
    done
    row sha256:dangling "" "$(iso "300 days ago")" 0001-01-01T00:00:00Z ;;
  "image rm") echo "$*" >>"$gone" ;;
  "images "*) echo 12MB ;;
  "builder du") echo "Reclaimable: 1.5GB" ;;
  "volume ls") echo vol-db ;;
  "system df")
    case "$*" in
      *Volumes*) printf "vol-db\t1.8GB\n" ;;
      *UniqueSize*) printf "%s\t%s\n" sha256:old 1.2GB sha256:multi 800MB sha256:pulled 50MB sha256:web 300MB ;;
      *) mb=5000
        grep -q "old/tool:1" "$gone" 2>/dev/null && mb=$((mb - 1200))
        grep -q "multi:a multi:b" "$gone" 2>/dev/null && mb=$((mb - 900))
        printf "Images\t%sMB\nContainers\t10MB\n" "$mb" ;;
    esac ;;
esac'
}

# blob PATH — a 1.1MB file (tool cleans skip caches under 1MB).
blob() { mkdir -p "$(dirname "$1")"; head -c 1100000 /dev/urandom >"$1"; }

fake_tools() {
  fake_rec npm
  fake_rec bun
  # like pnpm 9: a probe file goes into the working directory first
  fake_rec pnpm '[[ -w . ]] || { echo "EACCES: permission denied" >&2; exit 243; }
[[ "$*" == "store path" ]] && echo "$SB/store"; exit 0'
  fake_rec yarn 'case "$*" in --version) echo 1.22.22 ;; "cache dir") echo "$SB/yarncache" ;; esac'
  fake_rec uv '[[ "$*" == "cache dir" ]] && echo "$SB/uvcache"; exit 0'
  blob "$HOME/.npm/_cacache/blob"; blob "$HOME/.bun/install/cache/blob"
  blob "$SB/store/blob"; blob "$SB/yarncache/blob"; blob "$SB/uvcache/blob"
}

# ---------------------------------------------------------------- shared temp folders

# tmpfiles DIR NAME LINE... — a tmpfiles.d config file $SB/DIR/NAME.
tmpfiles() { local d="$SB/$1" f="$2"; shift 2; mkdir -p "$d"; printf '%s\n' "$@" >"$d/$f"; }
# tmpfiles_src — source clean with its tmpfiles.d search path pointed at $SB/{etc,run,usrlib}.
tmpfiles_src() { src; _CLEAN_TMPFILES_DIRS=("$SB/etc" "$SB/run" "$SB/usrlib"); }

@test "tmpfiles.d: a file in /etc replaces the same-named one in /run, which replaces /usr/lib's" {
  tmpfiles usrlib tmp.conf 'D /tmp 1777 root root -' 'q /var/tmp 1777 root root 30d'
  tmpfiles run tmp.conf 'D /tmp 1777 root root 3d'
  tmpfiles etc tmp.conf '# Age /tmp at 7 days' 'D /tmp 1777 root root 7d'
  tmpfiles_src
  [ "$(_clean_tmpfiles_age /tmp)" = "7d"$'\t'"$SB/etc/tmp.conf" ]
  [ -z "$(_clean_tmpfiles_age /var/tmp)" ]   # the whole /usr/lib file is replaced
  rm "$SB/etc/tmp.conf"
  [ "$(_clean_tmpfiles_age /tmp)" = "3d"$'\t'"$SB/run/tmp.conf" ]
}

@test "tmpfiles.d: across names the first file in order wins; a /dev/null symlink masks" {
  tmpfiles usrlib tmp.conf 'q /var/tmp 1777 root root 30d'
  tmpfiles etc zz-local.conf 'q /var/tmp 1777 root root 5d'
  tmpfiles usrlib 00-early.conf '#q /var/tmp 1777 root root 1d' 'x /var/tmp/keep-*'
  tmpfiles_src
  [ "$(_clean_tmpfiles_age /var/tmp)" = "30d"$'\t'"$SB/usrlib/tmp.conf" ]
  ln -s /dev/null "$SB/etc/tmp.conf"
  [ "$(_clean_tmpfiles_age /var/tmp)" = "5d"$'\t'"$SB/etc/zz-local.conf" ]
}

@test "/tmp and /var/tmp are reported with their OS age; a never-aged one gets the tmpfiles.d line" {
  tmpfiles usrlib tmp.conf 'D /tmp 1777 root root -'
  tmpfiles etc tmp.conf 'D /tmp 1777 root root 7d'
  tmpfiles_src
  _clean_tmpfiles_runs() { return 0; }
  run _clean_review_print
  [ "$status" -eq 0 ]
  [[ "$output" == *"Shared temp /tmp · "*"7d ($SB/etc/tmp.conf)"* ]]
  [[ "$output" == *"Shared temp /var/tmp · "*"never aged"* ]]
  grep -qF "echo 'q /var/tmp 1777 root root 30d' | sudo tee /etc/tmpfiles.d/" <<<"$output"
}

@test "a tmpfiles.d line without an age points at the file to override" {
  tmpfiles usrlib tmp.conf 'D /tmp 1777 root root -'
  tmpfiles_src
  _clean_tmpfiles_runs() { return 0; }
  run _clean_review_print
  [[ "$output" == *"Shared temp /tmp · "*"never aged"* ]]
  grep -qF "sudo cp $SB/usrlib/tmp.conf /etc/tmpfiles.d/" <<<"$output"
}

@test "without systemd nothing ages temp folders, and no tmpfiles.d fix is offered" {
  tmpfiles usrlib tmp.conf 'D /tmp 1777 root root 10d'
  tmpfiles_src
  _clean_tmpfiles_runs() { return 1; }
  run _clean_review_print
  [[ "$output" == *"Shared temp /tmp · "*"systemd-tmpfiles does not run"* ]]
  none grep -F 'tmpfiles.d/' <<<"$output"
}

@test "a real run leaves old entries in temp folders alone" {
  mkdir -p "$SB/tmp/old-dir/sub"; echo x >"$SB/tmp/old-dir/sub/f"; mm_age "$SB/tmp/old-dir" 60
  mm_test_clock 60
  full_run
  [ "$status" -eq 0 ]
  [ -e "$SB/tmp/old-dir/sub/f" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/old-dir" ]
  [ -z "$(mm_log_rows trash)" ]
}

@test "--days is not an option anymore" {
  run mm clean --days 3
  [ "$status" -ne 0 ]
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

@test "tool cleans run outside the project, so a project's yarnrc/npmrc/.yarn/cache never applies" {
  fake_tools
  mkdir -p "$SB/project/.yarn/cache"; echo 'cacheFolder: .yarn/cache' >"$SB/project/.yarnrc.yml"
  src
  mm_proc_running() { return 1; }   # isolate from tools running on the host
  cd "$SB/project"
  run _clean_dev
  grep -qxF '/ npm cache clean --force' "$CALLS"
  # pnpm writes into its working directory: it runs from HOME, not from a read-only /
  grep -qxF "$HOME pnpm store path" "$CALLS"
  grep -qxF "$HOME pnpm store prune" "$CALLS"
  grep -qxF '/ yarn cache dir' "$CALLS"
  grep -qxF '/ yarn cache clean' "$CALLS"
  grep -qxF '/ bun pm cache rm' "$CALLS"
  none grep -vE "^(/|$HOME) " "$CALLS"
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

@test "docker: unused images 30+ days old are removed by tag; used, recent and untagged ones kept" {
  fake_docker
  src
  mm_confirm() { return 0; }
  _clean_docker_images >"$BATS_TEST_TMPDIR/out"
  grep -qE ' docker image rm old/tool:1$' "$CALLS"
  grep -qE ' docker image rm multi:a multi:b$' "$CALLS"
  [ "$(grep -c ' docker image rm ' "$CALLS")" -eq 2 ]           # not base:12, fresh:1, web:1, postgres:16, app:1, alpine
  none grep -E ' docker (image rm|rmi) .*(-f|--force)' "$CALLS"
  [ "$_CLEAN_TOOL_BYTES" -eq 2100000000 ]                         # measured by docker system df, not estimated
}

@test "docker: unused images are listed, not removed, without a terminal; dry-run estimates" {
  fake_docker
  src
  run _clean_docker_images
  none grep ' docker image rm ' "$CALLS"
  [[ "$output" == *"old/tool:1"* ]]
  MM_DRY_RUN=1 _clean_docker_images >/dev/null
  none grep ' docker image rm ' "$CALLS"
  [ "$_CLEAN_TOOL_BYTES" -eq 2000000000 ]                         # unique sizes of the two offered images
}

@test "docker: no image is offered when the container list cannot be read" {
  fake_docker
  export FAKE_DOCKER_PS_FAIL=1
  src
  mm_confirm() { return 0; }
  run _clean_docker_images
  none grep -E ' docker image (rm|inspect) ' "$CALLS"
  [[ "$output" == *"Unused images · skipped"* ]]
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

# full_run ARGS... — `mm clean` with every machine-changing tool faked.
full_run() { fake_tools; fake_docker; run mm clean "$@"; }

# busy_proc NAME — run a process called NAME (a script, so its process name is NAME) until teardown.
busy_proc() {
  mkdir -p "$SB/bin"; printf '#!/bin/bash\nsleep 60\n:\n' >"$SB/bin/$1"; chmod +x "$SB/bin/$1"
  mm_test_bg "$SB" "$SB/bin/$1"
}

@test "a catalog cache is emptied permanently but its folder is kept" {
  mkdir -p "$HOME/.cache/pip/http-v2/a" "$HOME/.cache/pip/wheels"
  echo x >"$HOME/.cache/pip/http-v2/a/body"; echo y >"$HOME/.cache/pip/wheels/w.whl"
  catalog
  run _clean_catalog_caches
  [ -d "$HOME/.cache/pip" ]
  [ -z "$(ls -A "$HOME/.cache/pip")" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/wheels" ]          # regenerable: removed, not trashed
  [ "$(mm_log_rows remove | grep -c "^$HOME/.cache/pip/")" -eq 2 ]
}

@test "a catalog cache is skipped while its tool runs" {
  mkdir -p "$HOME/.cache/pip/wheels"; echo x >"$HOME/.cache/pip/wheels/w"
  busy_proc pip
  catalog
  run _clean_catalog_caches
  [ -e "$HOME/.cache/pip/wheels/w" ]
  [[ "$output" == *"pip cache · skipped (pip busy)"* ]]
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

# ---------------------------------------------------------------- dry run

@test "dry-run calls no state-changing command and changes nothing" {
  fake_tools; fake_docker
  trash_item old 30
  mkdir -p "$SB/tmp/old"; echo x >"$SB/tmp/old/f"; mm_age "$SB/tmp/old" 30
  mkdir -p "$HOME/.cache/go-build/aa" "$HOME/.vscode-server/cli/servers/Stable-a" "$HOME/.vscode-server/cli/servers/Stable-b"
  touch -d '10 days ago' "$HOME/.vscode-server/cli/servers/Stable-a"
  mm_test_clock 40
  run mm clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run complete"* ]]
  none grep -E ' (prune|rm|clean|purge)( |$)' "$CALLS"
  exist "$SB/tmp/old/f" "$XDG_DATA_HOME/Trash/files/old" "$HOME/.cache/go-build/aa"
  [ -d "$HOME/.vscode-server/cli/servers/Stable-a" ]
  exist "$HOME/.npm/_cacache/blob" "$SB/store/blob" "$SB/yarncache/blob"
  [ ! -e "$XDG_STATE_HOME/marmot/operations.log" ]
}

@test "tool-reported sizes above 2 GiB convert to exact bytes" {
  src
  [ "$(_clean_to_bytes 3GiB)" = 3221225472 ]
  [ "$(_clean_to_bytes 2.5GB)" = 2500000000 ]
}

# ---------------------------------------------------------------- agent session retention

# sessions_fixture — Claude Code and Codex CLI homes, everything 90 days old except one fresh
# session: sessions in two Claude projects (one only old), a dated Codex session, credentials in
# both state dirs, and a live plus a rotated Codex log.
sessions_fixture() {
  local cl="$HOME/.claude" cx="$HOME/.codex"
  mkdir -p "$cl/projects/p1" "$cl/projects/p2" "$cx/sessions/2026/01/02" "$cx/log"
  echo old >"$cl/projects/p1/old.jsonl"; echo new >"$cl/projects/p1/new.jsonl"
  echo old >"$cl/projects/p2/only.jsonl"; echo '{"t":1}' >"$cl/.credentials.json"
  echo '{}' >"$cx/auth.json"; echo r >"$cx/sessions/2026/01/02/rollout-a.jsonl"
  echo l >"$cx/log/codex-tui.log.1"; echo live >"$cx/log/codex-tui.log"
  mm_age "$cl" 90; mm_age "$cx" 90
  touch "$cl/projects/p1/new.jsonl"
}

# sessions_run DAYS — the retention step on its own, confirmed as if on a terminal.
sessions_run() {
  src; mm_inuse_refresh >/dev/null 2>&1
  mm_confirm() { return 0; }
  _clean_sessions "$1" flag
}

@test "agent sessions are not touched by default" {
  sessions_fixture
  full_run
  [ "$status" -eq 0 ]
  exist "$HOME/.claude/projects/p1/old.jsonl" "$HOME/.claude/projects/p2/only.jsonl" \
    "$HOME/.codex/sessions/2026/01/02/rollout-a.jsonl" "$HOME/.codex/log/codex-tui.log.1"
  [ ! -e "$XDG_DATA_HOME/Trash/files" ]
}

@test "retention moves old sessions and rotated logs to the Trash; recent ones, live logs and credentials stay" {
  sessions_fixture
  run sessions_run 30
  [ "$status" -eq 0 ]
  local cl="$HOME/.claude" cx="$HOME/.codex" t="$XDG_DATA_HOME/Trash"
  gone "$cl/projects/p1/old.jsonl" "$cl/projects/p2/only.jsonl" "$cx/sessions/2026/01/02/rollout-a.jsonl" \
    "$cx/log/codex-tui.log.1"
  exist "$cl/projects/p1/new.jsonl" "$cx/log/codex-tui.log" "$cl/.credentials.json" "$cx/auth.json"
  exist "$t/files/old.jsonl" "$t/files/only.jsonl" "$t/files/rollout-a.jsonl" "$t/files/codex-tui.log.1"
  grep -qxF "Path=$cl/projects/p1/old.jsonl" "$t/info/old.jsonl.trashinfo"
  gone "$cl/projects/p2" "$cx/sessions/2026"             # folders the moves emptied
  exist "$cl/projects" "$cx/sessions" "$cl/projects/p1"  # session roots and non-empty folders stay
  [ -z "$(mm_log_rows remove | grep -v -e "^$cl/projects/p2" -e "^$cx/sessions/2026")" ]
}

@test "retention keeps session files in use and whitelisted ones" {
  sessions_fixture
  local p="$HOME/.claude/projects"
  mkdir -p "$XDG_CONFIG_HOME/marmot"; printf '%s\n' "$p/p2" >"$XDG_CONFIG_HOME/marmot/whitelist"
  mm_test_bg "$p/p1" tail -f "$p/p1/old.jsonl"
  run sessions_run 30
  exist "$p/p1/old.jsonl" "$p/p2/only.jsonl"
  [ -e "$XDG_DATA_HOME/Trash/files/rollout-a.jsonl" ]     # the rest still goes
}

@test "a configured retention runs without a terminal; --sessions alone needs one" {
  sessions_fixture
  full_run --sessions 30
  [ "$status" -eq 0 ]
  [ -e "$HOME/.claude/projects/p1/old.jsonl" ]
  mkdir -p "$XDG_CONFIG_HOME/marmot"
  printf '# retention\nsessions_keep_days = 30   # a month\n' >"$XDG_CONFIG_HOME/marmot/config"
  full_run
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/projects/p1/old.jsonl" ]
  [ -e "$XDG_DATA_HOME/Trash/files/old.jsonl" ]
  [ -e "$HOME/.claude/projects/p1/new.jsonl" ]
  [ -e "$HOME/.claude/.credentials.json" ]
}

@test "retention dry-run lists what would move and changes nothing" {
  sessions_fixture
  mkdir -p "$XDG_CONFIG_HOME/marmot"; echo 'sessions_keep_days=30' >"$XDG_CONFIG_HOME/marmot/config"
  full_run --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude Code"*"2 files"* ]]
  [ -e "$HOME/.claude/projects/p1/old.jsonl" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files" ]
}

@test "--sessions needs a whole number of days; a bad config value is ignored" {
  local v
  for v in abc 0 -3 ""; do
    run mm clean --sessions "$v"
    [ "$status" -ne 0 ] || { echo "accepted --sessions '$v'"; false; }
  done
  sessions_fixture
  mkdir -p "$XDG_CONFIG_HOME/marmot"; echo 'sessions_keep_days=soon' >"$XDG_CONFIG_HOME/marmot/config"
  full_run
  [ "$status" -eq 0 ]
  [ -e "$HOME/.claude/projects/p1/old.jsonl" ]
}

# ---------------------------------------------------------------- tool cache cleans: bytes freed, uv

# hide_tool NAME — NAME is not installed: drop its stub and every PATH directory holding it.
hide_tool() {
  rm -f "$BATS_TEST_TMPDIR/stubs/$1"
  local d p="" IFS=:
  for d in $PATH; do [[ -x "$d/$1" ]] || p+="${p:+:}$d"; done
  PATH=$p
}

@test "tool cleans count only what they free: cache files hard-linked from elsewhere stay on disk" {
  fake_tools
  fake_rec npm '[[ "$*" == "cache clean --force" ]] && rm -rf "$HOME/.npm/_cacache"; exit 0'
  blob "$HOME/.npm/_cacache/linked"; mkdir -p "$SB/venv"; ln "$HOME/.npm/_cacache/linked" "$SB/venv/linked"
  src
  mm_proc_running() { return 1; }
  MM_DRY_RUN=1 _clean_npm >/dev/null
  local est=$_CLEAN_TOOL_BYTES
  _CLEAN_TOOL_BYTES=0
  _clean_npm >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq "$est" ]        # dry-run matches the run
  [ "$_CLEAN_TOOL_BYTES" -ge 1100000 ]       # the unlinked blob
  [ "$_CLEAN_TOOL_BYTES" -lt 2200000 ]       # not the one a link outside keeps
}

@test "uv installed: its cache is pruned by uv from /, never removed by marmot" {
  fake_tools
  fake_rec uv '[[ "$*" == "cache dir" ]] && echo "$SB/uvcache"; [[ "$*" == "cache prune" ]] && rm -rf "$SB/uvcache/archive-v0"; exit 0'
  blob "$SB/uvcache/archive-v0/dangling"
  mkdir -p "$HOME/.cache/uv/wheels-v5"; echo w >"$HOME/.cache/uv/wheels-v5/w"
  catalog
  mm_proc_running() { return 1; }   # isolate from tools running on the host
  _clean_uv >/dev/null
  _clean_catalog_caches >/dev/null
  grep -qxF '/ uv cache prune' "$CALLS"
  none grep -E 'uv cache (clean|prune .*-)' "$CALLS"   # never clean, --ci or --force
  exist "$SB/uvcache/blob" "$HOME/.cache/uv/wheels-v5/w"
  gone "$SB/uvcache/archive-v0"
  [ -z "$(mm_log_rows remove)" ]
  [ "$_CLEAN_TOOL_BYTES" -ge 1100000 ]              # measured: the pruned entry
  [ "$_CLEAN_TOOL_BYTES" -lt 2200000 ]              # not the whole cache
}

@test "uv dry-run claims no bytes and prunes nothing" {
  fake_tools
  src
  mm_proc_running() { return 1; }
  MM_DRY_RUN=1 _clean_uv >/dev/null
  none grep -F 'uv cache prune' "$CALLS"
  [ "$_CLEAN_TOOL_BYTES" -eq 0 ]
  exist "$SB/uvcache/blob"
}

@test "uv not installed: its leftover cache folder is emptied from the catalog" {
  mkdir -p "$HOME/.cache/uv/wheels-v5"; echo w >"$HOME/.cache/uv/wheels-v5/w"
  hide_tool uv
  none command -v uv
  catalog
  run _clean_catalog_caches
  [ -d "$HOME/.cache/uv" ]
  [ -z "$(ls -A "$HOME/.cache/uv")" ]
}

@test "uv cache prune is skipped while uv runs" {
  fake_tools
  busy_proc uv
  src
  run _clean_uv
  none grep -F 'uv cache prune' "$CALLS"
  [[ "$output" == *"uv busy"* ]]
}
