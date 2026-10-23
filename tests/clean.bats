#!/usr/bin/env bats
# cmd/clean.sh: shared temp report, Trash retention sweep, tool cleans, Docker, dry-run.

# Busy-tool tests start processes named after real tools (pip, pnpm, npx, uv, go); clean's busy
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
# (built 90 days ago, pulled 2 days ago), fresh:1 (3 days), mydev:snapshot (45 days, no repo
# digests: built or committed here), and an untagged one. Removing the two old pulled ones drops
# the `system df` Images total by 2.1GB (estimate from unique sizes: 2.0GB).
# FAKE_DOCKER_PS_FAIL=1 makes `docker ps` fail.
fake_docker() {
  fake_rec docker '
iso() { command date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000000000Z; }
row() { printf "%s\t%s\t%s\t%s\t%s\n" "$@"; }
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
  "image ls") printf "%s\n" sha256:old sha256:multi sha256:pulled sha256:fresh sha256:local sha256:web \
    sha256:postgres sha256:app sha256:alpine sha256:dangling sha256:multi ;;
  "image inspect")
    row sha256:old "old/tool:1" "$(iso "90 days ago")" "$(iso "90 days ago")" 1
    row sha256:multi "multi:a multi:b" "$(iso "200 days ago")" 0001-01-01T00:00:00Z 1
    row sha256:pulled "base:12" "$(iso "90 days ago")" "$(iso "2 days ago")" 1
    row sha256:fresh "fresh:1" "$(iso "3 days ago")" "$(iso "3 days ago")" 1
    row sha256:local "mydev:snapshot" "$(iso "45 days ago")" "$(iso "45 days ago")" 0
    for i in web:1 postgres:16 app:1 alpine:latest; do
      row "sha256:${i%%:*}" "$i" "$(iso "200 days ago")" "$(iso "200 days ago")" 1
    done
    row sha256:dangling "" "$(iso "300 days ago")" 0001-01-01T00:00:00Z 0 ;;
  "image rm") echo "$*" >>"$gone" ;;
  "images "*) if [[ "$*" == *" -q "* ]]; then grep -q sha256:dangling "$gone" 2>/dev/null || echo sha256:dangling
    else printf "%s\t%s\n" sha256:dangling 12MB; fi ;;
  "builder du") echo "Reclaimable: 1.5GB" ;;
  "builder prune") echo "Total reclaimed space: 1.2GB" ;;
  "volume ls") echo vol-db ;;
  "system df")
    case "$*" in
      *Volumes*) printf "vol-db\t1.8GB\n" ;;
      *UniqueSize*) printf "%s\t%s\n" sha256:old 1.2GB sha256:multi 800MB sha256:pulled 50MB sha256:local 2.0GB sha256:web 300MB ;;
      *) mb=5000
        grep -q "old/tool:1" "$gone" 2>/dev/null && mb=$((mb - 1200))
        grep -q "multi:a multi:b" "$gone" 2>/dev/null && mb=$((mb - 900))
        printf "Images\t%sMB\nContainers\t10MB\n" "$mb" ;;
    esac ;;
esac'
}

# fake_docker_many — a stand-in with 12 containers stopped 30 days ago and 12 unused images,
# more than any listing cap.
fake_docker_many() {
  fake_rec docker '
iso() { command date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000000000Z; }
case "$1 ${2:-}" in
  "ps "*) for i in 01 02 03 04 05 06 07 08 09 10 11 12; do echo "c$i"; done ;;
  "container inspect")
    if [[ "$*" == *"{{.Image}}"* ]]; then shift 4; for c; do echo "sha256:running-$c"; done
    else
      for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
        printf "c%s\t/box-%s\texited\t%s\t%s\tubuntu:24.04\t%s\n" \
          "$i" "$i" "$(iso "30 days ago")" "$(iso "90 days ago")" "${i#0}0000000"
      done
    fi ;;
  "image ls") for i in 01 02 03 04 05 06 07 08 09 10 11 12; do echo "sha256:im$i"; done ;;
  "image inspect")
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
      printf "sha256:im%s\tolder/tool:%s \t%s\t%s\t1\n" "$i" "$i" "$(iso "60 days ago")" "$(iso "60 days ago")"
    done ;;
  "image rm"|"rm "*) echo "$*" >>"$CALLS.gone" ;;
  "images "*) ;;
  "builder du") ;;
  "volume ls") ;;
  "system df") printf "Images\t5GB\nContainers\t1GB\n" ;;
esac'
}

# blob PATH — a 1.1MB file (tool cleans skip caches under 1MB).
blob() { mkdir -p "$(dirname "$1")"; head -c 1100000 /dev/urandom >"$1"; }

# fake_bun [BODY] — like bun 1.3.14: from a folder without a package.json every `pm` command fails
# (exit 1, its two lines on stderr); `pm cache` prints the cache folder without a newline; then BODY.
fake_bun() {
  fake_rec bun '[[ -f package.json ]] || { printf "error: No package.json was found for directory \"%s\"\nnote: Run \"bun init\" to initialize a project\n" "$PWD" >&2; exit 1; }
[[ "$*" == "pm cache" ]] && printf %s "$HOME/.bun/install/cache"
'"${1:-}"
}

fake_tools() {
  fake_rec npm '[[ "$*" == "config get cache" ]] && echo "$HOME/.npm"; exit 0'
  fake_bun
  # like pnpm 9: a probe file goes into the working directory first
  fake_rec pnpm '[[ -w . ]] || { echo "EACCES: permission denied" >&2; exit 243; }
[[ "$*" == "store path" ]] && echo "$SB/store"; exit 0'
  fake_rec yarn 'case "$*" in --version) echo 1.22.22 ;; "cache dir") echo "$SB/yarncache" ;; esac'
  fake_rec uv '[[ "$*" == "cache dir" ]] && echo "$SB/uvcache"; exit 0'
  fake_rec go
  fake_rec mise; fake_rec conda; fake_rec brew; fake_rec nix-collect-garbage
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

@test "mm clean --help documents every option the parser accepts" {
  run mm clean --help
  [ "$status" -eq 0 ]
  local o
  for o in --sessions --whitelist --dry-run --debug --help; do [[ "$output" == *"$o"* ]] || { echo "missing $o"; return 1; }; done
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
  # bun needs a package.json: it runs from a folder marmot made for it, which is gone afterwards
  local bun_cwd; bun_cwd=$(awk '$2 == "bun" && $3 == "pm" && $4 == "cache" && $5 == "rm" { print $1 }' "$CALLS")
  [[ "$bun_cwd" == /*/marmot-bun.* ]]
  [ ! -e "$bun_cwd" ]
  none grep -vE "^(/|$HOME|$bun_cwd) " "$CALLS"
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

@test "docker: dry and real runs count the same untagged images; build cache is docker's estimate, then its report" {
  fake_docker
  src
  mm_confirm() { return 0; }
  MM_DRY_RUN=1 _clean_docker_dangling >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq 12000000 ]
  _CLEAN_TOOL_BYTES=0
  MM_CMD=clean _clean_docker_dangling >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq 12000000 ]
  # the build cache: 1.5GB estimated by `builder du`, 1.2GB reclaimed by docker's own report
  _clean_docker_images() { :; }; _clean_docker_containers() { :; }; _clean_docker_dangling() { :; }
  _CLEAN_TOOL_BYTES=0; MM_DRY_RUN=1 _clean_docker >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq 1500000000 ]
  _CLEAN_TOOL_BYTES=0; MM_CMD=clean _clean_docker >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq 1200000000 ]
  [ "$(awk -F'\t' '$3 == "run" && $4 == "docker builder prune" { print $5 }' "$XDG_STATE_HOME/marmot/operations.log")" = 1200000000 ]
}

@test "docker: when docker removes only some untagged images, those count and the rest are failed" {
  fake_rec docker 'case "$1 ${2:-}" in
  "images "*) if [[ "$*" == *" -q "* ]]; then [[ -e "$CALLS.gone" ]] || echo sha256:a; echo sha256:b
    else printf "%s\t%s\n" sha256:a 10MB sha256:b 20MB; fi ;;
  "image rm") : >"$CALLS.gone"; echo "Error response from daemon: conflict: unable to delete b" >&2; exit 1 ;;
esac'
  src
  mm_confirm() { return 0; }
  MM_CMD=clean _clean_docker_dangling >/dev/null 2>&1
  [ "$_CLEAN_TOOL_BYTES" -eq 10000000 ]
  [ "${#MM_ERRORS[@]}" -eq 1 ]
  [ "$(awk -F'\t' '$3 == "run" { s += $5 } END { printf "%.0f", s }' "$XDG_STATE_HOME/marmot/operations.log")" = 10000000 ]
  [ "$(mm_log_rows failed | wc -l)" -eq 1 ]
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

@test "docker: untagged images are listed and asked about, never pruned unattended" {
  fake_docker
  src
  run _clean_docker                                  # no terminal: every prompt declines
  none grep -E ' docker image (prune|rm)' "$CALLS"
  [[ "$output" == *"Dangling images"* ]]             # still listed
  : >"$CALLS"
  mm_confirm() { return 0; }
  _clean_docker >/dev/null
  grep -qE ' docker image rm sha256:dangling$' "$CALLS"
  none grep ' docker image prune' "$CALLS"
  none grep -E ' docker image rm .*(-f|--force)' "$CALLS"
}

@test "docker: an image no registry has is kept and listed for review, not offered for removal" {
  fake_docker
  src
  mm_confirm() { return 0; }
  images_then_review() { _clean_docker_images; _clean_review_print; }
  run images_then_review
  none grep ' docker image rm mydev:snapshot' "$CALLS"
  [[ "$output" == *"Kept for you to review"*"mydev:snapshot"* ]]
}

@test "docker: every container and image that would go is listed, none hidden behind a count" {
  fake_docker_many
  src
  mm_confirm() { return 0; }
  run _clean_docker
  local i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    [[ "$output" == *"box-$i"* ]] || { echo "container box-$i not listed"; false; }
    [[ "$output" == *"older/tool:$i"* ]] || { echo "image older/tool:$i not listed"; false; }
  done
  none grep -F '(+' <<<"$output"
}

# unix_socket PATH — a listening-less unix socket file at PATH (what a mounted docker.sock looks like).
unix_socket() {
  command -v python3 >/dev/null || skip "python3 not installed"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
}

@test "docker: in a container the daemon behind a mounted socket is left alone unless MM_DOCKER_PRUNE=1" {
  fake_docker
  src
  unix_socket "$SB/docker.sock"
  mm_confirm() { return 0; }
  _clean_dockerd_here() { return 1; }   # whatever dockerd runs on the machine running the tests
  export MM_CONTAINER=1 DOCKER_HOST="unix://$SB/docker.sock"
  run _clean_docker
  [[ "$output" == *"Docker · skipped (in a container: DOCKER_HOST reaches a daemon outside it; MM_DOCKER_PRUNE=1 cleans it anyway)"* ]]
  none grep -E ' docker (info|ps|rm|images?|builder|system|volume) ' "$CALLS"
  MM_DOCKER_PRUNE=1 run _clean_docker
  grep -qE ' docker rm c-old c-never-old$' "$CALLS"
}

@test "docker: a dockerd running inside the container itself (Docker-in-Docker) is cleaned" {
  fake_docker
  src
  unix_socket "$SB/docker.sock"
  _clean_dockerd_here() { return 0; }
  export MM_CONTAINER=1 DOCKER_HOST="unix://$SB/docker.sock"
  run _clean_docker
  [[ "$output" != *"Docker · skipped"* ]]
  grep -qE ' docker ps ' "$CALLS"
}

@test "docker: a daemon on another machine (DOCKER_HOST or the docker context) is left alone" {
  fake_docker
  src
  export DOCKER_HOST=tcp://10.0.0.5:2376
  run _clean_docker
  [[ "$output" == *"Docker · skipped (the daemon at tcp://10.0.0.5:2376 is another machine's"* ]]
  unset DOCKER_HOST
  mm_test_fake docker "echo \"\$(pwd) docker \$*\" >>\"\$CALLS\"
[[ \"\$1 \$2\" == 'context inspect' ]] && echo ssh://me@build-box"
  run _clean_docker
  [[ "$output" == *"Docker · skipped (the daemon at ssh://me@build-box is another machine's"* ]]
  none grep -E ' docker (info|ps) ' "$CALLS"
}

@test "kernels: none installed says nothing; in a container they are never offered" {
  src
  mm_test_fake dpkg-query 'exit 0'
  run _clean_kernels
  [ -z "$output" ]
  # apt-get stays a fail-loud stub: nothing may simulate or purge.
  mm_test_fake dpkg-query "printf 'ii\tlinux-image-1.0.0-1-generic\nii\tlinux-image-99.0.0-1-generic\n'"
  MM_CONTAINER=1 run _clean_kernels
  [[ "$output" == *"Old kernels · skipped (in a container: the running kernel is the host's)"* ]]
}

# ---------------------------------------------------------------- apt

# apt_src — clean with a sudo double that runs the command as the test user, an apt-get that only
# records what it was asked to do, and dpkg's maintainer scripts in the sandbox.
apt_src() {
  mm_test_fake sudo '[[ "$1" == -n ]] && shift; [[ "$1" == -k ]] && exit 0; exec "$@"'
  mm_test_fake apt-get 'echo "apt-get $*" >>"$CALLS"
[[ "$1 $2" == "-s autoremove" ]] && echo "Remv demo-agentd [1.0]"
exit 0'
  mm_test_fake dpkg-query 'exit 0'
  src
  _CLEAN_DPKG_INFO="$SB/dpkg-info"
  mkdir -p "$_CLEAN_DPKG_INFO"
}
# postrm PKG LINE — PKG's purge script, running LINE when dpkg purges it.
postrm() {
  printf '#!/bin/sh\nset -e\ncase "$1" in\n  purge)\n    %s\n    ;;\nesac\n' "$2" >"$_CLEAN_DPKG_INFO/$1.postrm"
  chmod 755 "$_CLEAN_DPKG_INFO/$1.postrm"
}

@test "apt: unused packages are removed, not purged, so edited config files stay" {
  apt_src
  mm_confirm() { return 0; }
  run _clean_apt_autoremove
  [ "$status" -eq 0 ]
  grep -qxF 'apt-get -y autoremove' "$CALLS"
  none grep -E 'autoremove.*--purge' "$CALLS"
}

@test "apt: rc packages whose purge script deletes data keep their config; the rest are purged" {
  apt_src
  postrm docker.io 'nuke-graph-directory /var/lib/docker'
  postrm postgresql-15 'pg_dropcluster --stop 15 main'
  postrm weird-daemon 'rm -rf /var/lib/weird-daemon'
  postrm web-thing 'rm -rf /var/www/thing'
  postrm user-daemon 'deluser --quiet --system --remove-home userd'
  postrm vague-tool 'rm -rf "$STATE_DIR"'
  postrm tidy-tool 'rm -f /etc/tidy-tool.conf; rm -rf /var/lib/ucf/cache/tidy-tool'
  mm_test_fake dpkg 'printf "rc   %s   1.0   all\n" docker.io postgresql-15 weird-daemon web-thing user-daemon vague-tool tidy-tool no-script'
  mm_confirm() { return 0; }
  residual_then_review() { _clean_apt_residual; _clean_review_print; }
  run residual_then_review
  [ "$status" -eq 0 ]
  grep -qxF 'apt-get -y purge tidy-tool no-script' "$CALLS"
  none grep -F 'purge ~c' "$CALLS"
  local p
  for p in docker.io postgresql-15 weird-daemon web-thing user-daemon vague-tool; do
    none grep -E "apt-get .*purge .*(^| )$p( |$)" "$CALLS"
    [[ "$output" == *"$p"* ]] || { echo "$p not listed for review"; false; }
  done
}

@test "apt: an rc package whose purge script cannot be read is kept" {
  (( EUID != 0 )) || skip "root can read every file"
  apt_src
  postrm secret-tool 'rm -rf /var/lib/secret-tool'
  chmod 000 "$_CLEAN_DPKG_INFO/secret-tool.postrm"
  mm_test_fake dpkg 'printf "rc   %s   1.0   all\n" secret-tool'
  mm_confirm() { return 0; }
  run _clean_apt_residual
  [ "$status" -eq 0 ]
  none grep 'apt-get' "$CALLS"
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
  mm_age "$HOME/.cache/pip" 30
  catalog
  run _clean_catalog_caches
  [ -d "$HOME/.cache/pip" ]
  [ -z "$(ls -A "$HOME/.cache/pip")" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files/wheels" ]          # regenerable: removed, not trashed
  [ "$(mm_log_rows remove | grep -c "^$HOME/.cache/pip/")" -eq 2 ]
}

@test "a catalog cache entry whose size walk times out is kept; the others go" {
  mkdir -p "$HOME/.cache/pip/http-v2/a" "$HOME/.cache/pip/wheels"
  echo x >"$HOME/.cache/pip/http-v2/a/body"; echo y >"$HOME/.cache/pip/wheels/w.whl"
  mm_age "$HOME/.cache/pip" 30
  catalog
  local real; real=$(command -v find)
  # the sizing walk (find -printf '%D:%i ...') of wheels never finishes; every other find is real
  mm_test_fake find "[[ \"\$1\" == */.cache/pip/wheels && \"\$*\" == *%D:%i* ]] && exec sleep 5
exec $real \"\$@\""
  hash -r
  MM_SIZE_TIMEOUT=0.3 run _clean_catalog_caches
  exist "$HOME/.cache/pip/wheels/w.whl"
  gone "$HOME/.cache/pip/http-v2"
  [ "$(mm_log_rows refused)" = "$HOME/.cache/pip/wheels"$'\t'"size unknown (timed out)" ]
  [[ "$output" == *"1 kept (size unknown (timed out))"* ]]   # the actual reason, not a guess
}

@test "catalog cache entries used in the last 7 days stay (an MCP server npx runs); older ones go" {
  local x="$HOME/.npm/_npx" e
  mkdir -p "$x/old/node_modules/a" "$x/read/node_modules/b" "$x/written/node_modules/c" "$x/nested/node_modules/d/dist"
  echo '{}' >"$x/old/package.json"; echo '{}' >"$x/read/package.json"; echo '{}' >"$x/written/package.json"
  echo '{}' >"$x/nested/package.json"; echo 'run()' >"$x/nested/node_modules/d/dist/index.js"
  for e in old read written nested; do : >"$x/$e/node_modules/.package-lock.json"; done
  mm_age "$x" 30
  # npm writes the lockfile last, so a cache entry nothing wrote into has no file newer than it.
  for e in old read written nested; do touch -d '29 days ago' "$x/$e/node_modules/.package-lock.json"; done
  touch -a "$x/read/package.json"           # npx -y read it: only its access time moves
  echo '{"v":2}' >"$x/written/package.json"  # reinstalled today
  touch -a "$x/nested/node_modules/d/dist/index.js"  # a server loaded only a nested file
  catalog
  run _clean_catalog_caches
  [ "$status" -eq 0 ]
  gone "$x/old"
  exist "$x/read/node_modules/b" "$x/written/node_modules/c" "$x/nested/node_modules/d/dist/index.js"
  [[ "$output" == *"npx package cache"*"1 item"*"3 used in the last 7 days kept"* ]]
}

# caches_then_review — the catalog cache rows plus the "Kept for you to review" block.
caches_then_review() { _clean_catalog_caches; _clean_review_print; }

# npx_entry NAME — an npx cache entry: an installed package tree 30 days old, with npm's install
# marker written last, the way a real `npx -y` install leaves it.
npx_entry() {
  local e="$HOME/.npm/_npx/$1"
  mkdir -p "$e/node_modules/@modelcontextprotocol/server-memory/dist"
  echo '{"_npx":{"packages":["@modelcontextprotocol/server-memory"]}}' >"$e/package.json"
  echo 'run()' >"$e/node_modules/@modelcontextprotocol/server-memory/dist/index.js"
  : >"$e/node_modules/.package-lock.json"
  mm_age "$e" 30
  touch -d '29 days ago' "$e/node_modules/.package-lock.json"
}

@test "npx: an entry a server wrote into after its install is kept and listed; a plain one goes" {
  local x="$HOME/.npm/_npx" m="$HOME/.npm/_npx/mem/node_modules/@modelcontextprotocol/server-memory/dist"
  npx_entry plain; npx_entry mem
  echo '{"type":"entity","name":"Oscar"}' >"$m/memory.jsonl"   # the server's knowledge graph
  touch -d '20 days ago' "$m/memory.jsonl" "$m"   # written 10 days after the install, not since
  mkdir -p "$x/partial/node_modules/x"; echo i >"$x/partial/node_modules/x/index.js"
  echo '{}' >"$x/partial/package.json"; mm_age "$x/partial" 30   # an install with no marker
  catalog
  _clean_busy() { return 1; }
  run caches_then_review
  [ "$status" -eq 0 ]
  gone "$x/plain"
  exist "$m/memory.jsonl" "$m/index.js" "$x/partial/node_modules/x/index.js"
  [[ "$output" == *"files written after install"*"memory.jsonl"* ]]
  [ -z "$(mm_log_rows remove | grep -E "^$x/(mem|partial)")" ]
}

@test "Deno's npm cache is kept and reported; its other caches are still emptied" {
  local d="$HOME/.cache/deno"
  mkdir -p "$d/npm/registry.npmjs.org/@modelcontextprotocol/server-memory/2.0.0/dist" "$d/gen/file" "$d/deps/https"
  echo '{"name":"server-memory"}' >"$d/npm/registry.npmjs.org/@modelcontextprotocol/server-memory/2.0.0/package.json"
  echo '{"type":"entity"}' >"$d/npm/registry.npmjs.org/@modelcontextprotocol/server-memory/2.0.0/dist/memory.jsonl"
  echo c >"$d/gen/file/x.js"; echo h >"$d/deps/https/body"
  mm_age "$d" 30
  catalog
  _clean_busy() { return 1; }
  run caches_then_review
  [ "$status" -eq 0 ]
  exist "$d/npm/registry.npmjs.org/@modelcontextprotocol/server-memory/2.0.0/dist/memory.jsonl"
  gone "$d/gen/file" "$d/deps/https"
  [[ "$output" == *"Deno npm packages"* ]]
  [ -z "$(mm_log_rows remove | grep -E "^$d/npm/")" ]
}

@test "opencode: a plugin that wrote into its own folder keeps the cache's node_modules" {
  local c="$HOME/.cache/opencode"
  mkdir -p "$c/node_modules/marmot-plugin"
  : >"$c/node_modules/.package-lock.json"; echo p >"$c/node_modules/marmot-plugin/index.js"
  echo '{}' >"$c/models.json"
  mm_age "$c" 30
  touch -d '29 days ago' "$c/node_modules/.package-lock.json"
  echo '{"seen":1}' >"$c/node_modules/marmot-plugin/state.json"
  touch -d '20 days ago' "$c/node_modules/marmot-plugin/state.json" "$c/node_modules/marmot-plugin"
  catalog
  _clean_busy() { return 1; }
  run caches_then_review
  [ "$status" -eq 0 ]
  exist "$c/node_modules/marmot-plugin/state.json" "$c/node_modules/marmot-plugin/index.js"
  gone "$c/models.json"
}

@test "a big cache folder no catalog row knows is listed for review and kept" {
  mkdir -p "$HOME/.cache/mytool/blobs" "$HOME/.cache/tiny" "$HOME/.cache/pip"
  head -c 53000000 /dev/zero >"$HOME/.cache/mytool/blobs/b"; echo t >"$HOME/.cache/tiny/t"
  head -c 53000000 /dev/zero >"$HOME/.cache/pip/big"   # a catalog row's: not "unknown"
  full_run
  [ "$status" -eq 0 ]
  exist "$HOME/.cache/mytool/blobs/b" "$HOME/.cache/tiny/t"
  [[ "$output" == *"Other cache folders"*"mytool 5"*"MB"* ]]
  [[ "$output" == *"/catalog (cache|"* ]]
  none grep -E 'Other cache folders.*(tiny|pip)' <<<"$output"
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

@test "agent versions: a version a directory on PATH points into is kept" {
  local d="$HOME/.local/share/cursor-agent/versions" v
  mkdir -p "$HOME/.local/bin"
  for v in 2025.08.01-aaa 2025.09.01-bbb 2025.10.01-ccc 2025.11.01-ddd; do
    mkdir -p "$d/$v"; echo bin >"$d/$v/cursor-agent"; chmod +x "$d/$v/cursor-agent"
  done
  ln -sfn "$d/2025.11.01-ddd/cursor-agent" "$HOME/.local/bin/cursor-agent"
  PATH="$d/2025.08.01-aaa:$PATH"
  catalog
  run _clean_builds
  [ "$status" -eq 0 ]
  exist "$d/2025.08.01-aaa/cursor-agent" "$d/2025.10.01-ccc" "$d/2025.11.01-ddd"
  gone "$d/2025.09.01-bbb"
}

@test "Playwright: newest revision per browser kept, plus ones in use or still referenced by a project" {
  local p="$HOME/.cache/ms-playwright" r
  for r in chromium-1100 chromium-1200 chromium_headless_shell-1100 chromium_headless_shell-1200 \
           firefox-1400 firefox-1500 webkit-1900 webkit-2000 ffmpeg-1009; do
    mkdir -p "$p/$r"; echo bin >"$p/$r/browser"; : >"$p/$r/INSTALLATION_COMPLETE"
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

@test "Playwright: folders without the install marker (MCP browser profiles) are never old builds" {
  local p="$HOME/.cache/ms-playwright" r
  for r in chromium-1100 chromium-1200; do
    mkdir -p "$p/$r"; echo bin >"$p/$r/browser"; : >"$p/$r/INSTALLATION_COMPLETE"
  done
  # @playwright/mcp persistent profiles: mcp-<browser>-<7 hex of a workspace hash>, here all digits.
  for r in mcp-chrome-4471023 mcp-chrome-9310577; do
    mkdir -p "$p/$r/Default"; echo session >"$p/$r/Default/Cookies"
  done
  catalog
  run _clean_builds
  gone "$p/chromium-1100"
  exist "$p/chromium-1200" "$p/mcp-chrome-4471023/Default/Cookies" "$p/mcp-chrome-9310577/Default/Cookies"
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
  echo keep >"$SB/data/f"; echo x >"$HOME/mine/stuff/f"; echo keep >"$HOME/top"; mm_age "$HOME/mine" 30
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

@test "an interactive clean asks for sudo once, up front; refused, the system steps are skipped" {
  (( EUID != 0 )) || skip "root needs no sudo"
  fake_tools; fake_docker
  mm_test_fake sudo 'echo "$*" >>"$BATS_TEST_TMPDIR/sudo.calls"; exit 1'   # needs a password; refused
  local mode
  for mode in --dry-run ""; do
    rm -f "$BATS_TEST_TMPDIR/sudo.calls"
    # a terminal run (setsid: no terminal to block on if something else asked)
    MM_TTY=1 run setsid -w mm clean $mode
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/sudo.calls")" = $'-n true\n-v' ] || { echo "mm clean $mode:"; cat "$BATS_TEST_TMPDIR/sudo.calls"; false; }
    [[ "$output" == *"System cleanup · skipped (needs sudo)"* ]]
  done
}

@test "tool-reported sizes above 2 GiB convert to exact bytes" {
  src
  [ "$(_clean_to_bytes 3GiB)" = 3221225472 ]
  [ "$(_clean_to_bytes 2.5GB)" = 2500000000 ]
}

@test "the bytes a tool's own clean frees are on its history row and in the history totals" {
  blob "$HOME/.npm/_cacache/gone"; blob "$HOME/.npm/_cacache/stays"
  fake_rec npm '[[ "$*" == "cache clean --force" ]] && rm -f "$HOME/.npm/_cacache/gone"; exit 0'
  src
  local want; want=$(mm_frees "$HOME/.npm/_cacache/gone")
  MM_CMD=clean _clean_tool "npm cache" npm "$HOME/.npm/_cacache" / npm cache clean --force >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq "$want" ]          # what the closing banner counts
  run mm history --json
  [ "$(jq -r 'map(select(.action == "run" and .target == "npm cache")) | .[0].bytes' <<<"$output")" -eq "$want" ]
  run mm history
  [[ "$output" == *"clean · 1 ran $(mm_human "$want")"* ]]
  [[ "$output" == *": 1 run · $(mm_human "$want") freed"* ]]
}

@test "the closing banner names the category that freed the most" {
  full_run --dry-run
  [ "$status" -eq 0 ]
  grep -qE '^Biggest win: Docker, [0-9.]+[KMG]B$' <<<"$output"   # its images and build cache
}

# no_bare_headings — every "➤" heading in $output has a line under it.
no_bare_headings() {
  awk '/➤/ { h = $0; next } h != "" { if ($0 == "") { print "bare heading: " h; bad = 1 } h = "" } END { exit bad }' <<<"$output"
}

@test "a clean machine gets a success line, not a banner of zeros, and no empty headings" {
  # the tools work and point at caches that are not there
  local t; for t in npm pnpm bun uv conda brew mise; do mm_test_fake "$t" 'echo "$SB/none"'; done
  for t in yarn docker go nix-collect-garbage; do mm_test_fake "$t" 'exit 1'; done
  run mm clean
  [ "$status" -eq 0 ]
  [[ "$output" != *"======"* ]]                                 # no closing banner
  grep -qE '^  ✓ ' <<<"$(tail -2 <<<"$output")"                  # it ends on a success
  [[ "$(tail -1 <<<"$output")" == *"mm schedule enable"* ]]       # and how to keep it that way
  no_bare_headings
  run mm clean --dry-run
  [[ "$output" != *"======"* ]]
  no_bare_headings
}

@test "docker cleanups log the bytes they are counted with" {
  fake_docker
  src
  mm_confirm() { return 0; }
  MM_CMD=clean _clean_docker >/dev/null 2>&1
  local logged
  logged=$(awk -F'\t' '$3 == "run" { s += $5 } END { printf "%.0f", s }' "$XDG_STATE_HOME/marmot/operations.log")
  [ "$_CLEAN_TOOL_BYTES" -gt 0 ]
  [ "$logged" -eq "$_CLEAN_TOOL_BYTES" ]
}

# ---------------------------------------------------------------- agent session retention

# sessions_fixture — Claude Code and Codex CLI homes, everything 90 days old except one fresh
# session: sessions in two Claude projects (one only old), a dated Codex session, credentials in
# both state dirs, and a live plus a rotated log in Codex state (outside its logs dir).
sessions_fixture() {
  local cl="$HOME/.claude" cx="$HOME/.codex"
  mkdir -p "$cl/projects/p1" "$cl/projects/p2" "$cx/sessions/2026/01/02" "$cx/debug"
  echo old >"$cl/projects/p1/old.jsonl"; echo new >"$cl/projects/p1/new.jsonl"
  echo old >"$cl/projects/p2/only.jsonl"; echo '{"t":1}' >"$cl/.credentials.json"
  echo '{}' >"$cx/auth.json"; echo r >"$cx/sessions/2026/01/02/rollout-a.jsonl"
  echo l >"$cx/debug/codex.log.1"; echo live >"$cx/debug/codex.log"
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
    "$HOME/.codex/sessions/2026/01/02/rollout-a.jsonl" "$HOME/.codex/debug/codex.log.1"
  [ ! -e "$XDG_DATA_HOME/Trash/files" ]
}

@test "retention moves old sessions and rotated logs to the Trash; recent ones, live logs and credentials stay" {
  sessions_fixture
  run sessions_run 30
  [ "$status" -eq 0 ]
  local cl="$HOME/.claude" cx="$HOME/.codex" t="$XDG_DATA_HOME/Trash"
  gone "$cl/projects/p1/old.jsonl" "$cl/projects/p2/only.jsonl" "$cx/sessions/2026/01/02/rollout-a.jsonl" \
    "$cx/debug/codex.log.1"
  exist "$cl/projects/p1/new.jsonl" "$cx/debug/codex.log" "$cl/.credentials.json" "$cx/auth.json"
  exist "$t/files/old.jsonl" "$t/files/only.jsonl" "$t/files/rollout-a.jsonl" "$t/files/codex.log.1"
  grep -qxF "Path=$cl/projects/p1/old.jsonl" "$t/info/old.jsonl.trashinfo"
  gone "$cl/projects/p2" "$cx/sessions/2026"             # folders the moves emptied
  exist "$cl/projects" "$cx/sessions" "$cl/projects/p1"  # session roots and non-empty folders stay
  [ -z "$(mm_log_rows remove | grep -v -e "^$cl/projects/p2" -e "^$cx/sessions/2026")" ]
}

@test "retention never touches an agent's memory folder or files that are not transcripts" {
  sessions_fixture
  local p="$HOME/.claude/projects/p1"
  mkdir -p "$p/memory"
  printf -- '- [User role](user_role.md)\n' >"$p/memory/MEMORY.md"
  printf -- 'Staff engineer, owns billing.\n' >"$p/memory/user_role.md"
  echo '{}' >"$p/settings.json"
  mm_age "$HOME/.claude" 90
  run sessions_run 30
  [ "$status" -eq 0 ]
  exist "$p/memory/MEMORY.md" "$p/memory/user_role.md" "$p/settings.json"
  gone "$p/old.jsonl"                                      # transcripts still move
  [ ! -e "$XDG_DATA_HOME/Trash/files/MEMORY.md" ]
}

@test "retention keeps project files in agent worktrees and in git checkouts under agent state" {
  sessions_fixture
  local w="$HOME/.codex/worktrees/7f3a/logparse" g="$HOME/.codex/scratch/proj"
  mkdir -p "$w/tests/fixtures" "$w/.git" "$g"
  echo entry >"$w/tests/fixtures/access.log.1"
  echo 'ref: refs/heads/main' >"$w/.git/HEAD"
  printf 'gitdir: /home/x/repo/.git/worktrees/proj\n' >"$g/.git"   # a checkout, .git is a file
  echo entry >"$g/app.log.1"
  mm_age "$HOME/.codex" 90
  run sessions_run 30
  [ "$status" -eq 0 ]
  exist "$w/tests/fixtures/access.log.1" "$g/app.log.1"
  gone "$HOME/.codex/debug/codex.log.1"                    # rotated logs in state still move
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

# ---------------------------------------------------------------- tool cache cleans: bytes freed, uv, Go modules

# hide_tool NAME — NAME is not installed: drop its stub and every PATH directory holding it.
hide_tool() {
  rm -f "$BATS_TEST_TMPDIR/stubs/$1"
  local d p="" IFS=:
  for d in $PATH; do [[ -x "$d/$1" ]] || p+="${p:+:}$d"; done
  PATH=$p
}

@test "tool cleans count only what they free: cache files hard-linked from elsewhere stay on disk" {
  fake_tools
  fake_rec npm 'case "$*" in "config get cache") echo "$HOME/.npm" ;; "cache clean --force") rm -rf "$HOME/.npm/_cacache" ;; esac'
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

@test "bun, which refuses to run without a package.json (1.3.14 from /), frees what its dry run counted" {
  fake_bun '[[ "$*" == "pm cache rm" ]] && rm -rf "$HOME/.bun/install/cache"; exit 0'
  blob "$HOME/.bun/install/cache/blob"
  src
  mm_proc_running() { return 1; }
  cd /
  MM_DRY_RUN=1 _clean_bun >/dev/null 2>&1
  local est=$_CLEAN_TOOL_BYTES
  [ "$est" -ge 1100000 ]
  exist "$HOME/.bun/install/cache/blob"
  _CLEAN_TOOL_BYTES=0
  MM_CMD=clean _clean_bun >/dev/null 2>&1
  [ "$_CLEAN_TOOL_BYTES" -eq "$est" ]
  gone "$HOME/.bun/install/cache"
  [ "${#MM_ERRORS[@]}" -eq 0 ]
  run mm history --json
  [ "$(jq -r 'map(select(.action == "run" and .target == "bun cache")) | .[0].bytes' <<<"$output")" -eq "$est" ]
  [ "$(jq 'map(select(.action == "failed")) | length' <<<"$output")" -eq 0 ]
}

@test "bun's clean also counts the packages bun x unpacked in the temp folder, which it clears too" {
  export TMPDIR="$SB/tmp"
  local bunx; bunx="$TMPDIR/bunx-$(id -u)-cowsay@latest"
  fake_bun '[[ "$*" == "pm cache rm" ]] && rm -rf "$HOME/.bun/install/cache" "$TMPDIR"/bunx-*; exit 0'
  blob "$HOME/.bun/install/cache/blob"; blob "$bunx/node_modules/cowsay/index.js"
  src
  mm_proc_running() { return 1; }
  MM_DRY_RUN=1 _clean_bun >/dev/null 2>&1
  local est=$_CLEAN_TOOL_BYTES
  [ "$est" -ge $((2 * 1100000)) ]
  _CLEAN_TOOL_BYTES=0
  MM_CMD=clean _clean_bun >/dev/null 2>&1
  gone "$bunx"
  [ "$_CLEAN_TOOL_BYTES" -eq "$est" ]
}

@test "delegated cache cleans: the dry run counts exactly what the real run frees and logs" {
  fake_tools
  fake_rec npm 'case "$*" in "config get cache") echo "$HOME/.npm" ;; "cache clean --force") rm -rf "$HOME/.npm/_cacache" ;; esac'
  fake_bun '[[ "$*" == "pm cache rm" ]] && rm -rf "$HOME/.bun/install/cache"; exit 0'
  fake_rec yarn 'case "$*" in --version) echo 1.22.22 ;; "cache dir") echo "$SB/yarncache" ;; "cache clean") rm -rf "$SB/yarncache" ;; esac'
  src
  mm_proc_running() { return 1; }
  steps() { _clean_npm; _clean_bun; _clean_yarn; }
  MM_DRY_RUN=1 steps >/dev/null 2>&1
  local est=$_CLEAN_TOOL_BYTES logged
  [ "$est" -ge $((3 * 1100000)) ]
  _CLEAN_TOOL_BYTES=0
  MM_CMD=clean steps >/dev/null 2>&1
  [ "$_CLEAN_TOOL_BYTES" -eq "$est" ]
  logged=$(awk -F'\t' '$3 == "run" { s += $5 } END { printf "%.0f", s }' "$XDG_STATE_HOME/marmot/operations.log")
  [ "$logged" -eq "$est" ]
  [ "${#MM_ERRORS[@]}" -eq 0 ]
}

@test "a tool whose probe fails: the dry run reports the step failing and counts nothing, like the real run" {
  local t
  for t in npm bun uv pnpm; do fake_rec "$t" 'echo "error: ${0##*/} is broken" >&2; exit 3'; done
  fake_rec yarn '[[ "$*" == --version ]] && { echo 1.22.22; exit 0; }; echo "error: yarn is broken" >&2; exit 3'
  blob "$HOME/.npm/_cacache/blob"; blob "$HOME/.bun/install/cache/blob"
  src
  mm_proc_running() { return 1; }
  fake_rec nix-collect-garbage 'echo "error: cannot open connection to remote store" >&2; exit 3'
  mkdir -p "$(dirname "$MM_CONFIG_FILE")"; echo 'nix_gc = on' >"$MM_CONFIG_FILE"
  steps() { _clean_npm; _clean_bun; _clean_yarn; _clean_uv; _clean_pnpm; _clean_nix; }
  MM_DRY_RUN=1 steps >/dev/null 2>&1
  [ "$_CLEAN_TOOL_BYTES" -eq 0 ]
  [ "${#MM_ERRORS[@]}" -eq 6 ]
  MM_ERRORS=()
  MM_CMD=clean steps >/dev/null 2>&1
  [ "$_CLEAN_TOOL_BYTES" -eq 0 ]
  [ "${#MM_ERRORS[@]}" -eq 6 ]
  none grep -E 'cache (clean|rm|prune)|store prune' "$CALLS"
  exist "$HOME/.npm/_cacache/blob" "$HOME/.bun/install/cache/blob"
  [ "$(mm_log_rows failed | grep -c $'\texit 3: error: ')" -eq 6 ]
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
  mkdir -p "$HOME/.cache/uv/wheels-v5"; echo w >"$HOME/.cache/uv/wheels-v5/w"; mm_age "$HOME/.cache/uv" 30
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

@test "Go module cache is reported for review, never removed" {
  blob "$HOME/go/pkg/mod/cache/download/example.com/m/@v/v1.0.0.zip"
  mm_age "$HOME/go" 400
  mm_test_clock 400
  full_run
  [ "$status" -eq 0 ]
  exist "$HOME/go/pkg/mod/cache/download/example.com/m/@v/v1.0.0.zip"
  none grep -F 'clean -modcache' "$CALLS"
  [[ "$output" == *"Kept for you to review"*"Go module cache"*"~/go/pkg/mod"* ]]
  [[ "$output" == *"go clean -modcache"* ]]
}

# ---------------------------------------------------------------- cloud CLI logs

# cloud_log PATH DAYS — a 6KB file last written DAYS days ago.
cloud_log() { mkdir -p "$(dirname "$1")"; head -c 6000 /dev/zero >"$1"; touch -d "$2 days ago" "$1"; }
# old_dirs DIR... — folders last changed 20 days ago (adding files made them look new).
old_dirs() { touch -d '20 days ago' "$@"; }

@test "cloud CLI logs: gcloud and Azure logs 7+ days old are deleted; recent logs and credentials kept" {
  local g="$HOME/.config/gcloud/logs" a="$HOME/.azure"
  cloud_log "$g/2026.01.01/10.00.00.000001.log" 30
  cloud_log "$g/2026.01.01/11.00.00.000002.log" 29
  cloud_log "$g/2026.01.20/09.00.00.000003.log" 9
  cloud_log "$g/2026.01.20/23.59.00.000004.log" 1
  cloud_log "$g/2026.01.28/10.00.00.000005.log" 1
  mkdir -p "$g/2026.01.05"
  old_dirs "$g/2026.01.01" "$g/2026.01.05" "$g/2026.01.20"
  cloud_log "$HOME/.config/gcloud/credentials.db" 100; cloud_log "$HOME/.config/gcloud/access_tokens.db" 100
  cloud_log "$HOME/.config/gcloud/configurations/config_default" 100
  cloud_log "$HOME/.config/gcloud/legacy_credentials/me@example.com/adc.json" 100
  cloud_log "$a/logs/az.log.1" 20; cloud_log "$a/logs/az.log" 2; cloud_log "$a/msal_token_cache.json" 100
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_cloud_logs
  [ "$status" -eq 0 ]
  gone "$g/2026.01.01" "$g/2026.01.05" "$g/2026.01.20/09.00.00.000003.log" "$a/logs/az.log.1"
  exist "$g/2026.01.20/23.59.00.000004.log" "$g/2026.01.28/10.00.00.000005.log" "$a/logs/az.log"
  exist "$HOME/.config/gcloud/credentials.db" "$HOME/.config/gcloud/access_tokens.db" \
    "$HOME/.config/gcloud/configurations/config_default" "$HOME/.config/gcloud/legacy_credentials/me@example.com/adc.json" \
    "$a/msal_token_cache.json"
  [ -d "$g" ]
  [ -d "$a/logs" ]
}

@test "cloud CLI logs: an old log held open is kept, the rest of its folder goes" {
  local d="$HOME/.config/gcloud/logs/2026.01.01"
  cloud_log "$d/a.log" 10; cloud_log "$d/b.log" 10; old_dirs "$d"
  mm_test_bg "$SB" bash -c 'exec 7<"$1"; sleep 30' _ "$d/a.log"
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_cloud_logs
  [ "$status" -eq 0 ]
  exist "$d/a.log"
  gone "$d/b.log"
}

@test "cloud CLI logs: CLOUDSDK_CONFIG and AZURE_CONFIG_DIR move the folders that are cleaned" {
  export CLOUDSDK_CONFIG="$HOME/.config/gcloud-work" AZURE_CONFIG_DIR="$HOME/.config/azure-work"
  cloud_log "$CLOUDSDK_CONFIG/logs/2026.01.01/a.log" 10; old_dirs "$CLOUDSDK_CONFIG/logs/2026.01.01"
  cloud_log "$CLOUDSDK_CONFIG/credentials.db" 100
  cloud_log "$AZURE_CONFIG_DIR/logs/az.log.2" 10
  cloud_log "$HOME/.config/gcloud/logs/2026.01.01/a.log" 10; old_dirs "$HOME/.config/gcloud/logs/2026.01.01"
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_cloud_logs
  [ "$status" -eq 0 ]
  gone "$CLOUDSDK_CONFIG/logs/2026.01.01" "$AZURE_CONFIG_DIR/logs/az.log.2"
  exist "$CLOUDSDK_CONFIG/credentials.db" "$HOME/.config/gcloud/logs/2026.01.01/a.log"
}

@test "cloud CLI logs: dry-run counts exactly what a real run frees, and changes nothing" {
  local g="$HOME/.config/gcloud/logs" i before after est
  for i in 1 2 3 4 5; do cloud_log "$g/2026.01.0$i/1$i.00.00.000000.log" $((10 + i)); done
  cloud_log "$g/2026.01.20/09.00.00.000000.log" 8; cloud_log "$g/2026.01.20/10.00.00.000000.log" 0
  old_dirs "$g"/2026.01.0? "$g/2026.01.20"
  src; mm_inuse_refresh >/dev/null 2>&1
  before=$(du -sB1 "$g" | cut -f1)
  MM_DRY_RUN=1; _clean_cloud_logs >/dev/null
  est=$MM_FREED
  [ "$(du -sB1 "$g" | cut -f1)" -eq "$before" ]
  (( est > 0 ))
  MM_DRY_RUN=0 MM_FREED=0; _clean_cloud_logs >/dev/null
  after=$(du -sB1 "$g" | cut -f1)
  [ "$MM_FREED" -eq "$est" ]
  [ $((before - after)) -eq "$est" ]
  exist "$g/2026.01.20/10.00.00.000000.log"
}

@test "cloud CLI logs: a logs folder that is a symlink is left alone" {
  mkdir -p "$SB/elsewhere" "$HOME/.config/gcloud"
  cloud_log "$SB/elsewhere/old.log" 30
  ln -s "$SB/elsewhere" "$HOME/.config/gcloud/logs"
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_cloud_logs
  [ "$status" -eq 0 ]
  exist "$SB/elsewhere/old.log"
}

# ---------------------------------------------------------------- system logs and crash dumps

# root_src — source clean with the log and crash roots under $SB, a sudo double that runs the
# command as the test user, and a find double ($ROOT_FIND, also on PATH as find) that stands in
# for root's view of /proc. Root reads every process's open files; the test user only those of
# processes the kernel lets it trace: owned by it, with the same user and group ids and no
# capabilities. The double leaves the others out: they hold none of the test's files, and on a
# CI runner some of them run as the test user with another group. Folders that are gone stay
# in, so find still fails on them like the real one.
root_src() {
  mm_test_fake sudo '[[ "$1" == -n ]] && shift; [[ "$1" == -k ]] && exit 0; exec "$@"'
  ROOT_FIND="$BATS_TEST_TMPDIR/root-find"
  {
    printf '#!/usr/bin/env bash\nreal=%q u=%q g=%q\n' "$(PATH=/usr/bin:/bin command -v find)" "$(id -u)" "$(id -g)"
    cat <<'EOF'
traceable() {
  local k a b c d bad=0
  [[ -O $1 ]] || return 1
  while read -r k a b c d; do
    case $k in
      Uid:) [[ "$a $b $c $d" == "$u $u $u $u" ]] || bad=1 ;;
      Gid:) [[ "$a $b $c $d" == "$g $g $g $g" ]] || bad=1 ;;
      CapPrm:) [[ $a == 0000000000000000 ]] || bad=1 ;;
    esac
  done <"${1%/fd}/status"
  (( ! bad ))
}
args=()
for x; do
  if [[ $x == /proc/[0-9]*/fd && -e $x ]] && ! traceable "$x" 2>/dev/null; then continue; fi
  args+=("$x")
done
[[ ${1:-} == /proc/[0-9]*/fd && ${args[0]:-} != /proc/[0-9]*/fd ]] && exit 0
exec "$real" "${args[@]}"
EOF
  } >"$ROOT_FIND"
  chmod +x "$ROOT_FIND"
  mm_test_fake find "exec '$ROOT_FIND' \"\$@\""
  src
  _CLEAN_LOG_ROOT="$SB/var/log"
  _CLEAN_CRASH_ROOTS=("$SB/var/crash" "$SB/coredump")
}
# file_aged PATH DAYS [KB] — a file of KB kilobytes (default 64) last written DAYS ago.
file_aged() {
  mkdir -p "$(dirname "$1")"
  yes 'Oct  1 00:00:00 host daemon[1]: a log line' | head -c "$(( ${3:-64} * 1024 ))" >"$1"
  touch -d "$2 days ago" "$1"
}
# blocks PATH... — allocated bytes of each PATH, summed.
blocks() { local p s=0; for p; do s=$((s + $(stat -c %b "$p") * 512)); done; echo "$s"; }

@test "rotated logs 7+ days old go; live logs, recent rotations and the journal stay; dry-run size matches" {
  local l="$SB/var/log"
  file_aged "$l/syslog.1" 9 512; file_aged "$l/syslog.2.gz" 9; file_aged "$l/apt/history.log.1.gz" 20
  file_aged "$l/dpkg.log.old" 9; file_aged "$l/linked.1" 9
  file_aged "$l/syslog" 30; file_aged "$l/auth.log" 30; file_aged "$l/kern.log.1" 2
  file_aged "$l/journal/m/system@x.journal.gz" 30
  mkdir -p "$SB/keep"; ln "$l/linked.1" "$SB/keep/linked"   # a second link outside: frees nothing
  local want; want=$(blocks "$l/syslog.1" "$l/syslog.2.gz" "$l/apt/history.log.1.gz" "$l/dpkg.log.old")
  root_src
  mm_confirm() { return 0; }
  MM_DRY_RUN=1 _clean_rotated_logs >/dev/null
  [ "$_CLEAN_TOOL_BYTES" -eq "$want" ]
  exist "$l/syslog.1" "$l/dpkg.log.old"
  _CLEAN_TOOL_BYTES=0
  _clean_rotated_logs >"$BATS_TEST_TMPDIR/out"
  gone "$l/syslog.1" "$l/syslog.2.gz" "$l/apt/history.log.1.gz" "$l/dpkg.log.old" "$l/linked.1"
  exist "$l/syslog" "$l/auth.log" "$l/kern.log.1" "$l/journal/m/system@x.journal.gz" "$SB/keep/linked"
  [ "$_CLEAN_TOOL_BYTES" -eq "$want" ]
  [ "$(mm_log_rows remove | grep -c "^$l/")" -eq 5 ]
}

@test "rotated logs: a file some process still has open is kept" {
  local l="$SB/var/log" i
  file_aged "$l/syslog.1" 9; file_aged "$l/syslog.2.gz" 9
  mm_test_bg "$SB" tail -n 0 -f "$l/syslog.1"
  for ((i = 0; i < 100; i++)); do
    [[ -n "$(find /proc/[0-9]*/fd -lname "$l/syslog.1" -print -quit 2>/dev/null)" ]] && break
    sleep 0.05
  done
  root_src
  mm_confirm() { return 0; }
  run _clean_rotated_logs
  [ -e "$l/syslog.1" ]
  gone "$l/syslog.2.gz"
}

@test "rotated logs: a file descriptor the root script cannot read stops it deleting anything" {
  local l="$SB/var/log" id real
  real=$(command -v find)
  root_src
  file_aged "$l/syslog.1" 9
  id=$("$real" "$l/syslog.1" -maxdepth 0 -printf '%D:%i')
  # One fd link whose target root cannot read (an empty %l), as in a container without SYS_PTRACE.
  mm_test_fake find "if [[ \"\$1\" == /proc/*/fd ]]; then printf '/dev/null\\0\\0/dev/zero\\0'; exit 0; fi
exec $real \"\$@\""
  run bash -c "$_CLEAN_ROOT_RM" _ 10 "$id" "$l/syslog.1"
  [ "$status" -ne 0 ]
  exist "$l/syslog.1"
}

@test "rotated logs: a process that ends while the root script scans does not stop it" {
  local l="$SB/var/log" pidf="$BATS_TEST_TMPDIR/gone.pid" x id i
  root_src
  file_aged "$l/syslog.1" 9
  id=$(find "$l/syslog.1" -maxdepth 0 -printf '%D:%i')
  # A process whose parent reaps it the moment it ends, so its /proc folder goes away for good.
  bash -c 'sleep 300 & echo $! >"$1"; wait' _ "$pidf" &
  MM_TEST_PIDS+=("$!")
  for ((i = 0; i < 100; i++)); do [[ -s "$pidf" ]] && break; sleep 0.05; done
  x=$(<"$pidf"); MM_TEST_PIDS+=("$x")
  # The scan reaches that process just as it ends: its fd folder is gone when find reads it.
  mm_test_fake find "for a; do
  if [[ \$a == /proc/$x/fd ]]; then kill $x 2>/dev/null; while [[ -e /proc/$x ]]; do sleep 0.05; done; fi
done
exec '$ROOT_FIND' \"\$@\""
  run bash -c "$_CLEAN_ROOT_RM" _ 10 "$id" "$l/syslog.1"
  [ "$status" -eq 0 ]
  gone "$l/syslog.1"
}

@test "rotated logs and crash dumps: nothing is deleted without a terminal" {
  file_aged "$SB/var/log/syslog.1" 9; file_aged "$SB/var/crash/_usr_bin_node.1000.crash" 9
  mkdir -p "$XDG_DATA_HOME/apport/r1"; mm_age "$XDG_DATA_HOME/apport" 9
  root_src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_rotated_logs
  [[ "$output" == *"syslog.1"* ]]   # listed
  run _clean_crash_dumps
  run _clean_user_crash_reports
  exist "$SB/var/log/syslog.1" "$SB/var/crash/_usr_bin_node.1000.crash" "$XDG_DATA_HOME/apport/r1"
  [ -z "$(mm_log_rows remove)" ]
}

@test "rotated logs and crash dumps are skipped without sudo" {
  [[ $EUID -ne 0 ]] || skip "root always has sudo"
  file_aged "$SB/var/log/syslog.1" 9; file_aged "$SB/coredump/core.node.1000.zst" 9
  src
  _CLEAN_LOG_ROOT="$SB/var/log"; _CLEAN_CRASH_ROOTS=("$SB/coredump")
  mm_confirm() { return 0; }
  run _clean_system
  [[ "$output" == *"skipped (needs sudo)"* ]]
  exist "$SB/var/log/syslog.1" "$SB/coredump/core.node.1000.zst"
}

@test "crash dumps 7+ days old go (system and your apport reports); recent ones and lock files stay" {
  local c="$SB/var/crash" d="$SB/coredump" a="$XDG_DATA_HOME/apport"
  file_aged "$c/_usr_bin_node.1000.crash" 9; file_aged "$c/_usr_bin_node.1000.upload" 9
  file_aged "$c/_usr_bin_python3.1000.crash" 1; file_aged "$c/.lock" 30
  file_aged "$d/core.node.1000.abc.1.zst" 9 256; file_aged "$d/core.chrome.1000.abc.2.zst" 3
  file_aged "$a/old/report" 9; file_aged "$a/fresh/report" 1; touch -d '9 days ago' "$a/old"
  root_src; mm_inuse_refresh >/dev/null 2>&1
  mm_confirm() { return 0; }
  _clean_crash_dumps >/dev/null
  _clean_user_crash_reports >/dev/null
  gone "$c/_usr_bin_node.1000.crash" "$c/_usr_bin_node.1000.upload" "$d/core.node.1000.abc.1.zst" "$a/old"
  exist "$c/_usr_bin_python3.1000.crash" "$c/.lock" "$d/core.chrome.1000.abc.2.zst" "$a/fresh/report"
  [ ! -e "$XDG_DATA_HOME/Trash/files/old" ]   # permanent, not trashed
}

# ---------------------------------------------------------------- automation-browser temp files

# browser_tmp NAME... — an entry $MM_TEST_TMP_ROOT/NAME holding a 1.1MB profile file.
browser_tmp() { local n; for n; do blob "$MM_TEST_TMP_ROOT/$n/Default/Cache/data_1"; done; }

@test "browser temp: idle Playwright/Puppeteer/Chromium leftovers are deleted for good, the rest kept" {
  src
  browser_tmp playwright_chromiumdev_profile-a1B2 puppeteer_dev_chrome_profile-c3D4 \
    .org.chromium.Chromium.e5F6 playwright-artifacts-g7H8 org.chromium.Chromium.url_fetcher_.Ab \
    .com.google.Chrome.Qr12St
  echo x >"$MM_TEST_TMP_ROOT/com.google.Chrome.file1"
  browser_tmp playwright_chromiumdev_profile-busy chrome-profile-mine x-playwright-artifacts-1 old-dir
  mm_test_clock 1   # everything above is a day old (ctime included)...
  touch -d '+1 day' "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-busy/Default/Cache/data_1"   # ...but this one was just written
  local t=$MM_TEST_TMP_ROOT
  MM_DRY_RUN=1 _clean_browser_tmp "$t" >/dev/null
  local estimate=$MM_FREED
  exist "$t/playwright_chromiumdev_profile-a1B2" "$t/com.google.Chrome.file1"
  MM_FREED=0
  _clean_browser_tmp "$t" >/dev/null
  gone "$t/playwright_chromiumdev_profile-a1B2" "$t/puppeteer_dev_chrome_profile-c3D4" \
    "$t/.org.chromium.Chromium.e5F6" "$t/playwright-artifacts-g7H8" \
    "$t/org.chromium.Chromium.url_fetcher_.Ab" "$t/.com.google.Chrome.Qr12St" "$t/com.google.Chrome.file1"
  exist "$t/playwright_chromiumdev_profile-busy" "$t/chrome-profile-mine" "$t/x-playwright-artifacts-1" "$t/old-dir"
  [ "$MM_FREED" -ge $((6 * 1100000)) ]
  [ "$MM_FREED" -eq "$estimate" ]
  [ ! -e "$XDG_DATA_HOME/Trash/files" ]
  [ "$(mm_log_rows remove | wc -l)" -eq 7 ]
}

@test "browser temp: entries a process works in or holds open are kept" {
  src
  browser_tmp playwright_chromiumdev_profile-cwd puppeteer_dev_chrome_profile-fd
  local t=$MM_TEST_TMP_ROOT
  mm_test_bg "$t/playwright_chromiumdev_profile-cwd" sleep 60
  mm_test_bg "$SB" sleep 61 3<"$t/puppeteer_dev_chrome_profile-fd/Default/Cache/data_1"
  mm_test_clock 1
  _clean_browser_tmp "$t" >/dev/null
  exist "$t/playwright_chromiumdev_profile-cwd/Default/Cache/data_1" "$t/puppeteer_dev_chrome_profile-fd/Default/Cache/data_1"
  [ "$(mm_log_rows refused | cut -f2 | sort -u)" = "in use" ]
}

@test "browser temp: a live Playwright browser keeps the artifacts folders of that run" {
  src
  local t=$MM_TEST_TMP_ROOT
  browser_tmp playwright-artifacts-LIVE puppeteer_dev_chrome_profile-OLD
  echo invoice >"$t/playwright-artifacts-LIVE/6f1c2e7a-download"
  # A live browser holds its profile's lock open, and its command line names the profile.
  mkdir -p "$t/playwright_chromiumdev_profile-LIVE"; echo lock >"$t/playwright_chromiumdev_profile-LIVE/LOCK"
  mm_test_bg "$SB" bash -c 'exec 3<"$1"; sleep 60; :' browser "$t/playwright_chromiumdev_profile-LIVE/LOCK"
  mm_test_clock 1
  mm_inuse_refresh >/dev/null 2>&1
  _clean_browser_tmp "$t" >/dev/null
  exist "$t/playwright-artifacts-LIVE/6f1c2e7a-download"
  gone "$t/puppeteer_dev_chrome_profile-OLD"
}

@test "browser temp: a browser named on a command line keeps the artifacts folders too" {
  src
  local t=$MM_TEST_TMP_ROOT
  browser_tmp playwright-artifacts-LIVE
  mm_test_bg "$SB" bash -c 'sleep 60; :' browser "--user-data-dir=$t/playwright_chromiumdev_profile-LIVE"
  mm_test_clock 1
  mm_inuse_refresh >/dev/null 2>&1
  _clean_browser_tmp "$t" >/dev/null
  exist "$t/playwright-artifacts-LIVE/Default/Cache/data_1"
}

@test "browser temp: another user's entries are never touched" {
  (( EUID == 0 )) || skip "needs root to give a file to another user"
  src
  browser_tmp playwright_chromiumdev_profile-theirs playwright_chromiumdev_profile-mine
  chown -R 65534:65534 "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-theirs"
  mm_test_clock 1
  _clean_browser_tmp "$MM_TEST_TMP_ROOT" >/dev/null
  exist "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-theirs/Default/Cache/data_1"
  gone "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-mine"
}

@test "browser temp: the test root override only works inside the test sandbox" {
  src
  [ "$(_clean_browser_tmp_root)" = "$MM_TEST_TMP_ROOT" ]
  none env MM_TEST_TMP_ROOT=/tmp bash -c '. "$1/lib/core.sh"; . "$1/cmd/clean.sh"; _clean_browser_tmp_root' _ "$MM_SRC"
  none env MM_TEST_TMP_ROOT="$SB/tmp/../../../.." bash -c '. "$1/lib/core.sh"; . "$1/cmd/clean.sh"; _clean_browser_tmp_root' _ "$MM_SRC"
  [ "$(env -u MM_TEST_TMP_ROOT bash -c '. "$1/lib/core.sh"; . "$1/cmd/clean.sh"; _clean_browser_tmp_root' _ "$MM_SRC")" = /tmp ]
}

@test "browser temp: mm clean removes them from the temp root and leaves everything else there" {
  browser_tmp playwright_chromiumdev_profile-old
  mkdir -p "$MM_TEST_TMP_ROOT/some-build"; echo x >"$MM_TEST_TMP_ROOT/some-build/f"
  mm_test_clock 1
  full_run
  [ "$status" -eq 0 ]
  gone "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-old"
  exist "$MM_TEST_TMP_ROOT/some-build/f"
}

# ---------------------------------------------------------------- agent logs

# logs_fixture — oh-my-pi, Copilot CLI and Goose logs dirs and an oh-my-pi session dir, everything
# 30 days old except one fresh log: old, rotated and compressed logs, a log named like a token, a
# non-log file, Copilot extension logs, Goose dated CLI logs, and old .log files in a session dir.
logs_fixture() {
  local o="$HOME/.omp/logs" c="$HOME/.copilot/logs" g="$HOME/.local/state/goose/logs"
  local s="$HOME/.omp/agent/sessions/-proj"
  mkdir -p "$o" "$c/extensions" "$g/cli/2026-01-01" "$s"
  echo old >"$o/omp.2026-01-01.111.log"; echo rot >"$o/omp.log.1"; echo gz >"$o/omp.log.2.gz"
  echo tok >"$o/token-refresh.log"; echo note >"$o/notes.txt"; echo new >"$o/omp.2026-10-10.222.log"
  echo old >"$c/process-1700000000-42.log"; echo old >"$c/extensions/ext.log"
  echo old >"$g/cli/2026-01-01/goose.log"; echo jl >"$g/llm_request.0.jsonl"
  echo sess >"$s/tool.log"; echo sess >"$s/run.log.1"; echo '{}' >"$s/s.jsonl"
  mm_age "$HOME/.omp" 30; mm_age "$HOME/.copilot" 30; mm_age "$HOME/.local/state" 30
  touch "$o/omp.2026-10-10.222.log"
}

# logs_run — the agent logs step on its own.
logs_run() { src; mm_inuse_refresh >/dev/null 2>&1; _clean_agent_logs; }

@test "agent logs: old logs and their rotations are deleted for good; recent, other and credential-named files stay" {
  logs_fixture
  run logs_run
  [ "$status" -eq 0 ]
  local o="$HOME/.omp/logs" c="$HOME/.copilot/logs" g="$HOME/.local/state/goose/logs"
  gone "$o/omp.2026-01-01.111.log" "$o/omp.log.1" "$o/omp.log.2.gz" \
    "$c/process-1700000000-42.log" "$c/extensions/ext.log" "$g/cli/2026-01-01/goose.log"
  exist "$o/omp.2026-10-10.222.log" "$o/token-refresh.log" "$o/notes.txt" "$g/llm_request.0.jsonl"
  exist "$o" "$c/extensions" "$g/cli/2026-01-01"
  [ ! -e "$XDG_DATA_HOME/Trash/files" ]
}

@test "agent logs: session dirs are never searched, even for old .log files" {
  logs_fixture
  local s="$HOME/.omp/agent/sessions/-proj" n="$HOME/.omp/logs/run"
  mkdir -p "$HOME/.claude/projects/p" "$n"
  echo x >"$HOME/.claude/projects/p/debug.log"; echo x >"$n/nested.log"
  mm_age "$HOME/.claude" 30; mm_age "$n" 30
  src; mm_inuse_refresh >/dev/null 2>&1
  local i
  for i in "${!MM_AGENT_NAME[@]}"; do   # a session dir nested in a logs dir is pruned too
    [[ "${MM_AGENT_NAME[i]}" == oh-my-pi ]] && MM_AGENT_SESSIONS[i]+=" $n"
  done
  run _clean_agent_logs
  [ "$status" -eq 0 ]
  exist "$s/tool.log" "$s/run.log.1" "$s/s.jsonl" "$HOME/.claude/projects/p/debug.log" "$n/nested.log"
  gone "$HOME/.omp/logs/omp.log.1"
}

@test "agent logs: files in use and whitelisted ones are kept" {
  logs_fixture
  local o="$HOME/.omp/logs"
  mkdir -p "$XDG_CONFIG_HOME/marmot"; printf '%s\n' "$HOME/.copilot/logs" >"$XDG_CONFIG_HOME/marmot/whitelist"
  mm_test_bg "$o" tail -f "$o/omp.2026-01-01.111.log"
  run logs_run
  [ "$status" -eq 0 ]
  exist "$o/omp.2026-01-01.111.log" "$HOME/.copilot/logs/process-1700000000-42.log" "$HOME/.copilot/logs/extensions/ext.log"
  gone "$o/omp.log.1" "$HOME/.local/state/goose/logs/cli/2026-01-01/goose.log"   # the rest still goes
}

@test "agent logs: a logs dir that is a symlink out of the home folder is left alone" {
  mkdir -p "$SB/elsewhere" "$HOME/.omp"; echo keep >"$SB/elsewhere/omp.log"; mm_age "$SB/elsewhere" 30
  ln -s "$SB/elsewhere" "$HOME/.omp/logs"
  run logs_run
  [ "$status" -eq 0 ]
  exist "$SB/elsewhere/omp.log"
}

@test "agent logs: dry-run reports exactly what the real run then removes, and changes nothing" {
  logs_fixture
  MM_DRY_RUN=1 run logs_run
  [ "$status" -eq 0 ]
  local dry=$output
  [[ "$dry" == *"oh-my-pi logs"* ]]
  exist "$HOME/.omp/logs/omp.log.1" "$HOME/.copilot/logs/extensions/ext.log"
  run logs_run
  [ "$status" -eq 0 ]
  [ "$output" = "$dry" ]
  gone "$HOME/.omp/logs/omp.log.1" "$HOME/.copilot/logs/extensions/ext.log"
}

@test "agent logs: on by default, permanent even with session retention on; sessions stay opt-in" {
  logs_fixture
  mkdir -p "$HOME/.codex/log"; echo l >"$HOME/.codex/log/codex-tui.log"; mm_age "$HOME/.codex" 30
  full_run
  [ "$status" -eq 0 ]
  gone "$HOME/.omp/logs/omp.log.1" "$HOME/.codex/log/codex-tui.log"
  exist "$HOME/.omp/agent/sessions/-proj/tool.log" "$HOME/.omp/agent/sessions/-proj/s.jsonl"
  [ ! -e "$XDG_DATA_HOME/Trash/files" ]
  logs_fixture
  mkdir -p "$XDG_CONFIG_HOME/marmot"; echo 'sessions_keep_days=7' >"$XDG_CONFIG_HOME/marmot/config"
  full_run
  [ "$status" -eq 0 ]
  gone "$HOME/.omp/logs/omp.log.1"
  [ ! -e "$XDG_DATA_HOME/Trash/files/omp.log.1" ]          # logs are not moved to the Trash
  [ -e "$XDG_DATA_HOME/Trash/files/s.jsonl" ]              # the configured retention still runs
}

# ---------------------------------------------------------------- more tool caches

@test "more caches: tool caches are emptied; filters keep gem notes, Gradle daemon state, opencode snapshots" {
  local h="$HOME"
  mkdir -p "$h/.pyenv/cache" "$h/.gem/ruby/3.2.0/cache" "$h/.gem/ruby/3.3.0/cache" "$h/.gradle/daemon/8.5" \
    "$h/.cache/opencode/node_modules/ai" "$h/.cache/opencode/snapshots/s1" "$h/.npm/_logs" \
    "$h/.cache/composer/files/acme" "$h/.oh-my-zsh/cache/completions" "$h/.android/build-cache/x" \
    "$h/.local/share/jupyter/runtime" "$h/.hex/packages/hexpm" "$h/.opam/download-cache/sha256"
  echo t >"$h/.pyenv/cache/Python-3.12.1.tar.xz"
  echo g >"$h/.gem/ruby/3.2.0/cache/rake-13.0.6.gem"; echo g >"$h/.gem/ruby/3.3.0/cache/json-2.7.1.gem"
  echo n >"$h/.gem/ruby/3.2.0/cache/notes.txt"
  echo l >"$h/.gradle/daemon/8.5/daemon-4242.out.log"; echo r >"$h/.gradle/daemon/8.5/registry.bin"
  echo m >"$h/.cache/opencode/node_modules/ai/index.js"; echo j >"$h/.cache/opencode/models.json"
  : >"$h/.cache/opencode/node_modules/.package-lock.json"   # the plugin install, nothing written into it since
  echo s >"$h/.cache/opencode/snapshots/s1/f"
  echo l >"$h/.npm/_logs/2026-01-01T00_00_00_000Z-debug-0.log"; echo c >"$h/.cache/composer/files/acme/p.zip"
  echo z >"$h/.oh-my-zsh/cache/completions/_docker"; echo b >"$h/.android/build-cache/x/b"
  echo '{}' >"$h/.local/share/jupyter/runtime/kernel-1.json"; echo t >"$h/.hex/packages/hexpm/jason-1.4.1.tar"
  echo o >"$h/.opam/download-cache/sha256/ab"
  mm_age "$h" 30
  touch -d '29 days ago' "$h/.cache/opencode/node_modules/.package-lock.json"
  catalog
  _clean_busy() { return 1; }   # isolate from tools running on the host
  run _clean_catalog_caches
  [ "$status" -eq 0 ]
  gone "$h/.pyenv/cache/Python-3.12.1.tar.xz" "$h/.gem/ruby/3.2.0/cache/rake-13.0.6.gem" \
    "$h/.gem/ruby/3.3.0/cache/json-2.7.1.gem" "$h/.gradle/daemon/8.5/daemon-4242.out.log" \
    "$h/.cache/opencode/node_modules" "$h/.cache/opencode/models.json" "$h/.npm/_logs/2026-01-01T00_00_00_000Z-debug-0.log" \
    "$h/.cache/composer/files" "$h/.oh-my-zsh/cache/completions" "$h/.android/build-cache/x" \
    "$h/.local/share/jupyter/runtime/kernel-1.json" "$h/.hex/packages/hexpm" "$h/.opam/download-cache/sha256"
  exist "$h/.gem/ruby/3.2.0/cache/notes.txt" "$h/.gradle/daemon/8.5/registry.bin" "$h/.cache/opencode/snapshots/s1/f"
  exist "$h/.pyenv/cache" "$h/.gradle/daemon/8.5" "$h/.cache/opencode"
  [ ! -e "$XDG_DATA_HOME/Trash/files/rake-13.0.6.gem" ]   # regenerable: removed, not trashed
}

@test "more caches: Gradle daemon logs and Jupyter runtime files are kept while Gradle or Jupyter runs" {
  mkdir -p "$HOME/.gradle/daemon/8.5" "$HOME/.local/share/jupyter/runtime"
  echo l >"$HOME/.gradle/daemon/8.5/daemon-1.out.log"; echo '{}' >"$HOME/.local/share/jupyter/runtime/kernel-1.json"
  busy_proc jupyter-lab
  mm_test_bg "$SB" bash -c 'sleep 60; :' org.gradle.launcher.daemon.bootstrap.GradleDaemon
  catalog
  run _clean_catalog_caches
  [ "$status" -eq 0 ]
  exist "$HOME/.gradle/daemon/8.5/daemon-1.out.log" "$HOME/.local/share/jupyter/runtime/kernel-1.json"
}

@test "more caches: a Jupyter connection file held open is kept, stale ones go" {
  local r="$HOME/.local/share/jupyter/runtime"
  mkdir -p "$r"; echo '{}' >"$r/kernel-live.json"; echo '{}' >"$r/kernel-dead.json"; echo '{}' >"$r/jpserver-9.json"
  mm_age "$r" 30
  mm_test_bg "$SB" bash -c 'exec 7<"$1"; sleep 30' _ "$r/kernel-live.json"
  catalog
  _clean_busy() { return 1; }   # no Jupyter process: only the per-file in-use check is left
  run _clean_catalog_caches
  [ "$status" -eq 0 ]
  exist "$r/kernel-live.json"
  gone "$r/kernel-dead.json" "$r/jpserver-9.json"
}

@test "more caches: kubectl discovery and HTTP caches are emptied; ~/.kube/config and plugin token caches stay" {
  local k="$HOME/.kube"
  mkdir -p "$k/cache/discovery/api.example.com_443/apps/v1" "$k/cache/http" "$k/cache/oidc-login"
  echo 'apiVersion: v1' >"$k/config"; echo '{}' >"$k/cache/discovery/api.example.com_443/apps/v1/serverresources.json"
  echo r >"$k/cache/http/0a1b2c"; echo t >"$k/cache/oidc-login/abc"; mm_age "$k" 30
  catalog
  _clean_busy() { return 1; }
  run _clean_catalog_caches
  [ "$status" -eq 0 ]
  gone "$k/cache/discovery/api.example.com_443" "$k/cache/http/0a1b2c"
  exist "$k/config" "$k/cache/oidc-login/abc" "$k/cache/discovery" "$k/cache/http"
  [ -z "$(mm_log_rows remove | grep -E "^$k/(config|cache/oidc-login)")" ]
}

@test "more caches: a folder named by two rows is counted once; dry-run frees what a real run frees" {
  export PYENV_ROOT="$HOME/.pyenv"
  mkdir -p "$PYENV_ROOT/cache" "$HOME/.npm/_prebuilds"
  head -c 300000 /dev/urandom >"$PYENV_ROOT/cache/Python-3.12.1.tar.xz"
  head -c 200000 /dev/urandom >"$HOME/.npm/_prebuilds/sharp-linux-x64.tar.gz"
  mm_age "$HOME" 30
  catalog
  _clean_busy() { return 1; }
  local before after est
  sizes() { du -scB1 "$PYENV_ROOT/cache" "$HOME/.npm/_prebuilds" | tail -1 | cut -f1; }
  before=$(sizes)
  MM_DRY_RUN=1; _clean_catalog_caches >/dev/null
  est=$MM_FREED
  [ "$(sizes)" -eq "$before" ]
  MM_DRY_RUN=0 MM_FREED=0; _clean_catalog_caches >/dev/null
  after=$(sizes)
  [ "$MM_FREED" -eq "$est" ]
  [ $((before - after)) -eq "$est" ]
  (( est >= 500000 ))
}

@test "more caches: Corepack's lastKnownGood.json and oh-my-zsh's dotenv lists stay; the caches around them go" {
  local c="$HOME/.cache/node/corepack" z="$HOME/.oh-my-zsh/cache"
  mkdir -p "$c/v1/pnpm/8.15.9" "$z/completions"
  echo '{"pnpm":"8.15.9"}' >"$c/lastKnownGood.json"; echo '{}' >"$c/v1/pnpm/8.15.9/package.json"
  echo "$HOME/work" >"$z/dotenv-allowed.list"; echo "$HOME/Downloads" >"$z/dotenv-disallowed.list"
  echo z >"$z/completions/_docker"; echo x >"$z/grep-alias"
  mm_age "$HOME" 30
  catalog
  _clean_busy() { return 1; }
  run _clean_catalog_caches
  [ "$status" -eq 0 ]
  exist "$c/lastKnownGood.json" "$z/dotenv-allowed.list" "$z/dotenv-disallowed.list"
  gone "$c/v1" "$z/completions" "$z/grep-alias"
}

# ---------------------------------------------------------------- mise, conda, Homebrew, nix

# fake_pkg_tools — mise, conda and brew doubles that remove what the real commands would: mise a
# stale download (prune; the one in use stays); conda tarballs, index cache and logs in
# $SB/conda/pkgs (the extracted package stays); brew an old formula version and an old download
# (its own -n estimate says 2.1MB).
fake_pkg_tools() {
  fake_rec mise '[[ "$*" == "cache prune" ]] && rm -f "$HOME/.cache/mise/node/node-v18.tar.gz"; exit 0'
  fake_rec conda 'case "$*" in
    "config --show pkgs_dirs") printf "pkgs_dirs:\n  - %s\n  - /nonexistent/pkgs\n" "$SB/conda/pkgs" ;;
    clean*) rm -rf "$SB/conda/pkgs/"*.tar.bz2 "$SB/conda/pkgs/"*.conda "$SB/conda/pkgs/cache" "$SB/conda/pkgs/.logs" ;;
  esac'
  fake_rec brew 'case "$*" in
    --cache) echo "$SB/brewcache" ;;
    --cellar) echo "$SB/Cellar" ;;
    "cleanup --prune=30 -n") echo "Would remove: $SB/Cellar/jq/1.6 (1.0MB)"
      echo "==> This operation would free approximately 2.1MB of disk space." ;;
    "cleanup --prune=30") rm -rf "$SB/Cellar/jq/1.6" "$SB/brewcache/downloads/old" ;;
  esac'
  blob "$HOME/.cache/mise/node/node-v20.tar.gz"; blob "$HOME/.cache/mise/node/node-v18.tar.gz"
  blob "$SB/conda/pkgs/numpy-1.26.tar.bz2"; blob "$SB/conda/pkgs/scipy-1.11.conda"; blob "$SB/conda/pkgs/cache/repodata.json"
  blob "$SB/conda/pkgs/numpy-1.26/lib/core.so"
  blob "$SB/Cellar/jq/1.6/bin/jq"; blob "$SB/Cellar/jq/1.7/bin/jq"; blob "$SB/brewcache/downloads/old"
}
pkg_tools() { _clean_mise; _clean_conda; _clean_brew; }

@test "tool cleans: mise prunes, conda and Homebrew clean through their own commands; dry-run is within 5%" {
  fake_pkg_tools
  src
  _clean_busy() { return 1; }   # isolate from tools running on the host
  local est real mise
  MM_DRY_RUN=1; pkg_tools >/dev/null
  est=$_CLEAN_TOOL_BYTES        # a prune cannot be previewed: mise adds nothing
  none grep -E 'cache prune|conda clean|cleanup --prune=30$' "$CALLS"
  exist "$HOME/.cache/mise/node/node-v18.tar.gz" "$SB/conda/pkgs/numpy-1.26.tar.bz2" "$SB/Cellar/jq/1.6/bin/jq"
  MM_DRY_RUN=0 _CLEAN_TOOL_BYTES=0; _clean_mise >/dev/null
  mise=$_CLEAN_TOOL_BYTES; _clean_conda >/dev/null; _clean_brew >/dev/null
  real=$((_CLEAN_TOOL_BYTES - mise))
  grep -qxF '/ mise cache prune' "$CALLS"
  none grep -F 'mise cache clear' "$CALLS"
  grep -qxF '/ conda clean --yes --index-cache --tarballs --logfiles' "$CALLS"
  grep -qxF '/ brew cleanup --prune=30' "$CALLS"
  gone "$HOME/.cache/mise/node/node-v18.tar.gz" "$SB/conda/pkgs/numpy-1.26.tar.bz2" "$SB/conda/pkgs/cache" "$SB/Cellar/jq/1.6"
  exist "$HOME/.cache/mise/node/node-v20.tar.gz" "$SB/conda/pkgs/numpy-1.26/lib/core.so" "$SB/Cellar/jq/1.7/bin/jq"
  (( mise >= 1100000 && real >= 5 * 1100000 ))              # measured: 3 conda + 2 brew blobs
  (( est * 100 >= real * 95 && est * 100 <= real * 105 ))
}

@test "tool cleans: mise, conda and Homebrew are skipped while they run" {
  fake_pkg_tools
  busy_proc mise; busy_proc conda; busy_proc brew
  src
  run pkg_tools
  [ "$status" -eq 0 ]
  none grep -E 'cache prune|conda clean|cleanup --prune=30' "$CALLS"
  exist "$HOME/.cache/mise/node/node-v20.tar.gz" "$SB/conda/pkgs/numpy-1.26.tar.bz2" "$SB/Cellar/jq/1.6/bin/jq"
}

@test "nix: garbage collection runs only when opted in, and reports what nix freed" {
  fake_rec nix-collect-garbage 'echo "deleting garbage..."; echo "12 store paths deleted, 3.50 MiB freed"'
  src
  _clean_busy() { return 1; }
  mkdir -p "$(dirname "$MM_CONFIG_FILE")"
  run _clean_nix
  [ "$status" -eq 0 ]
  echo 'nix_gc = off' >"$MM_CONFIG_FILE"
  run _clean_nix
  [ ! -s "$CALLS" ]
  printf '# opt in\nnix_gc = on\n' >"$MM_CONFIG_FILE"
  MM_DRY_RUN=1 _clean_nix >/dev/null
  [ "$(cat "$CALLS")" = "/ nix-collect-garbage --delete-older-than 30d --dry-run" ]   # read-only rehearsal only
  [ "$_CLEAN_TOOL_BYTES" -eq 0 ]
  _clean_nix >/dev/null
  grep -qxF '/ nix-collect-garbage --delete-older-than 30d' "$CALLS"
  [ "$_CLEAN_TOOL_BYTES" -eq 3670016 ]
}

# ---------------------------------------------------------------- Firebase emulators, agent-browser builds

# firebase_and_agent_browser — two versions of several Firebase emulators (jars, a UI zip plus its
# unpacked folder, a never-versioned snapshot) and three agent-browser Chrome builds.
firebase_and_agent_browser() {
  F="$HOME/.cache/firebase/emulators" A="$HOME/.agent-browser/browsers"
  mkdir -p "$F/ui-v1.14.0/server" "$F/ui-v1.15.0/server" "$F/ui-vSNAPSHOT/server" \
    "$A/chrome-99.0.4844.51/chrome-linux64" "$A/chrome-131.0.6778.85/chrome-linux64" "$A/chrome-152.0.7977.82/chrome-linux64"
  local v
  for v in v1.19.7 v1.22.0; do echo j >"$F/cloud-firestore-emulator-$v.jar"; done
  for v in v4.10.0 v4.11.2; do echo j >"$F/firebase-database-emulator-$v.jar"; done
  echo z >"$F/ui-v1.14.0.zip"; echo z >"$F/ui-v1.15.0.zip"; echo s >"$F/ui-v1.14.0/server/server.mjs"
  for v in 99.0.4844.51 131.0.6778.85 152.0.7977.82; do echo c >"$A/chrome-$v/chrome-linux64/chrome"; done
  echo '{}' >"$HOME/.agent-browser/config.json"
}

@test "Firebase emulators and agent-browser: older versions go; the newest, snapshots and builds in use stay" {
  firebase_and_agent_browser
  mm_test_bg "$SB" bash -c 'exec 7<"$1"; sleep 30' _ "$F/firebase-database-emulator-v4.10.0.jar"
  catalog
  _clean_busy() { return 1; }   # isolate from tools running on the host
  run _clean_builds
  [ "$status" -eq 0 ]
  gone "$F/cloud-firestore-emulator-v1.19.7.jar" "$F/ui-v1.14.0" "$F/ui-v1.14.0.zip" \
    "$A/chrome-99.0.4844.51" "$A/chrome-131.0.6778.85"
  exist "$F/cloud-firestore-emulator-v1.22.0.jar" "$F/firebase-database-emulator-v4.11.2.jar" \
    "$F/firebase-database-emulator-v4.10.0.jar" "$F/ui-v1.15.0/server" "$F/ui-v1.15.0.zip" "$F/ui-vSNAPSHOT/server" \
    "$A/chrome-152.0.7977.82/chrome-linux64/chrome" "$HOME/.agent-browser/config.json"
}

@test "Firebase emulators and agent-browser builds are kept while the tools run" {
  firebase_and_agent_browser
  busy_proc firebase; busy_proc agent-browser
  catalog
  run _clean_builds
  [ "$status" -eq 0 ]
  exist "$F/cloud-firestore-emulator-v1.19.7.jar" "$F/ui-v1.14.0" "$A/chrome-99.0.4844.51"
}

# ---------------------------------------------------------------- more stores to review

@test "Ivy, sbt, pub, torch, W&B and Terraform plugin stores are listed for review, never touched" {
  local h="$HOME" f
  local -a files=("$h/.ivy2/cache/org.scala-lang/scala-library/jars/scala-library-2.13.12.jar"
    "$h/.sbt/boot/scala-2.12.18/lib/scala-library.jar" "$h/.pub-cache/hosted/pub.dev/http-1.2.0/pubspec.yaml"
    "$h/.cache/torch/hub/checkpoints/resnet50.pth" "$h/.cache/wandb/artifacts/obj/md5/ab/cd"
    "$h/.local/share/wandb/artifacts/staging/f" "$h/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/5.31.0/linux_amd64/p")
  for f in "${files[@]}"; do mkdir -p "$(dirname "$f")"; echo x >"$f"; done
  mm_age "$h" 400
  mm_test_clock 400
  full_run
  [ "$status" -eq 0 ]
  exist "${files[@]}"
  [ -z "$(mm_log_rows remove | grep -E '/(\.ivy2|\.sbt|\.pub-cache|torch|wandb|\.terraform\.d)/')" ]
  for f in '~/.ivy2' '~/.sbt' '~/.pub-cache' '~/.cache/torch' '~/.cache/wandb' '~/.local/share/wandb' '~/.terraform.d/plugin-cache'; do
    grep -qF "$f" <<<"${output#*Kept for you to review}" || { echo "not reviewed: $f"; false; }
  done
}

# ---------------------------------------------------------------- editor server leftovers

# vscode_leftovers — $V: a VS Code server with an obsolete (updated) extension, a .obsolete entry for
# a folder that is gone and one that tries to leave the folder, a cached VSIX, an old and a new log.
vscode_leftovers() {
  V="$HOME/.vscode-server"
  local x
  for x in ms-python.python-2024.1.0-linux-x64 ms-python.python-2024.2.0-linux-x64 esbenp.prettier-vscode-10.1.0; do
    mkdir -p "$V/extensions/$x"; echo '{}' >"$V/extensions/$x/package.json"
  done
  printf '{"ms-python.python-2024.1.0-linux-x64":true,"esbenp.prettier-vscode-9.0.0":true,"../../.ssh":true}' \
    >"$V/extensions/.obsolete"
  mkdir -p "$HOME/.ssh" "$V/data/CachedExtensionVSIXs"; echo k >"$HOME/.ssh/id_ed25519"
  echo v >"$V/data/CachedExtensionVSIXs/ms-python.python-2024.2.0-linux-x64"
  cloud_log "$V/data/logs/20260101T100000/exthost1/remoteexthost.log" 20
  old_dirs "$V/data/logs/20260101T100000/exthost1" "$V/data/logs/20260101T100000"
  cloud_log "$V/data/logs/20260201T100000/remoteagent.log" 1
}

@test "editor servers: obsolete extensions, cached VSIX packages and week-old logs go; the rest stays" {
  vscode_leftovers
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_editors
  [ "$status" -eq 0 ]
  gone "$V/extensions/ms-python.python-2024.1.0-linux-x64" "$V/data/CachedExtensionVSIXs/ms-python.python-2024.2.0-linux-x64" \
    "$V/data/logs/20260101T100000"
  exist "$V/extensions/ms-python.python-2024.2.0-linux-x64/package.json" "$V/extensions/esbenp.prettier-vscode-10.1.0/package.json" \
    "$V/data/logs/20260201T100000/remoteagent.log" "$HOME/.ssh/id_ed25519" "$V/data/CachedExtensionVSIXs"
}

@test "editor servers: obsolete extensions wait while the server runs" {
  vscode_leftovers
  mm_test_bg "$V/data" sleep 60
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_editors
  [ "$status" -eq 0 ]
  exist "$V/extensions/ms-python.python-2024.1.0-linux-x64/package.json"
}

@test "JetBrains remote backends: the newest of each IDE and backends in use are kept" {
  local d="$HOME/.cache/JetBrains/RemoteDev/dist" b
  for b in a1_ideaIU-2023.3.2:40 b2_ideaIU-2024.1.1:20 c3_ideaIU-2024.2.0:10 d4_PyCharm-2024.1.4:50 e5_PyCharm-2023.2.1:60; do
    mkdir -p "$d/${b%%:*}/bin"; echo s >"$d/${b%%:*}/bin/remote-dev-server.sh"; touch -d "${b##*:} days ago" "$d/${b%%:*}"
  done
  mm_test_bg "$d/a1_ideaIU-2023.3.2/bin" sleep 60
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_editors
  [ "$status" -eq 0 ]
  gone "$d/b2_ideaIU-2024.1.1" "$d/e5_PyCharm-2023.2.1"
  exist "$d/a1_ideaIU-2023.3.2" "$d/c3_ideaIU-2024.2.0" "$d/d4_PyCharm-2024.1.4"
}

# ---------------------------------------------------------------- agent browser profile caches

# browser_profile DIR — a Chromium user-data-dir: 200KB in each cache folder of Default, plus
# logins, cookies and settings that must stay.
browser_profile() {
  local p="$1" leaf
  for leaf in Cache/Cache_Data "Code Cache/js" GPUCache DawnGraphiteCache GrShaderCache "Service Worker/CacheStorage/ab"; do
    mkdir -p "$p/Default/$leaf"; head -c 200000 /dev/urandom >"$p/Default/$leaf/data_0"
  done
  mkdir -p "$p/Default/Service Worker/ScriptCache" "$p/Default/Local Storage/leveldb"
  echo s >"$p/Default/Service Worker/ScriptCache/index"; echo c >"$p/Default/Cookies"; echo l >"$p/Default/Login Data"
  echo l >"$p/Default/Local Storage/leveldb/000003.log"; echo '{}' >"$p/Local State"
}

@test "agent browser profiles: only cache folders go; dry-run frees what a real run frees" {
  local p="$HOME/.cache/chrome-devtools-mcp/chrome-profile" before after est
  browser_profile "$p"
  src; mm_inuse_refresh >/dev/null 2>&1
  before=$(du -sB1 "$p" | cut -f1)
  MM_DRY_RUN=1; _clean_browser_profiles >/dev/null
  est=$MM_FREED
  [ "$(du -sB1 "$p" | cut -f1)" -eq "$before" ]
  MM_DRY_RUN=0 MM_FREED=0; _clean_browser_profiles >/dev/null
  after=$(du -sB1 "$p" | cut -f1)
  [ "$MM_FREED" -eq "$est" ]
  [ $((before - after)) -eq "$est" ]
  (( est >= 6 * 200000 ))
  gone "$p/Default/Cache" "$p/Default/Code Cache" "$p/Default/GPUCache" "$p/Default/Service Worker/CacheStorage"
  exist "$p/Default/Cookies" "$p/Default/Login Data" "$p/Default/Local Storage/leveldb/000003.log" \
    "$p/Default/Service Worker/ScriptCache/index" "$p/Local State"
}

@test "agent browser profiles: a profile a browser has open is skipped" {
  local m="$HOME/.cache/chrome-devtools-mcp" c="$HOME/.cache/chrome-devtools-mcp-cli" host
  browser_profile "$m/chrome-profile"; browser_profile "$m/chrome-profile-canary"
  browser_profile "$c/chrome-profile"; browser_profile "$c/chrome-profile-beta"
  IFS= read -r host </proc/sys/kernel/hostname
  mm_test_bg "$SB" bash -c 'sleep 60; :' "--user-data-dir=$m/chrome-profile"
  ln -s "$host-$$" "$m/chrome-profile-canary/SingletonLock"           # live lock: this test's shell
  ln -s "$host-999999999" "$c/chrome-profile-beta/SingletonLock"      # stale lock: no such process
  mm_test_bg "$c/chrome-profile/Default" sleep 60                     # a process works inside it
  src; mm_inuse_refresh >/dev/null 2>&1
  run _clean_browser_profiles
  [ "$status" -eq 0 ]
  exist "$m/chrome-profile/Default/Cache" "$m/chrome-profile-canary/Default/Cache" "$c/chrome-profile/Default/Cache"
  gone "$c/chrome-profile-beta/Default/Cache"
}
