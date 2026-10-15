# shellcheck shell=bash
# Shared bats setup for marmot. Load with `load helpers/common`, then call mm_test_setup in setup()
# and mm_test_teardown in teardown().
#
# Isolation (adapted from tw93/Mole tests/helpers/common.bash):
#   - HOME, XDG dirs, marmot config/state and the Trash live under $BATS_TEST_TMPDIR; setup refuses to
#     continue unless HOME really is that sandbox.
#   - Commands that change the real machine are replaced, first on PATH, by fail-loud stubs. A
#     stub records `UNSTUBBED <cmd> <args>` and exits 97; teardown fails the test if any stub ran,
#     so a forgotten mock is a red test, not a silent host-dependent pass. A test that needs one
#     installs a double with mm_test_fake.
#   - `sudo -n true` answers "no" quietly, so marmot runs its unprivileged paths; so does
#     `gh auth token` (logged out), so no test asks GitHub anything.

MM_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
MM_TEST_STUBBED=(sudo apt apt-get apt-mark snap docker systemctl journalctl swapon swapoff mount umount
  resolvectl fstrim npm npx pnpm yarn bun uv uvx go pip pip3 pipx ncdu fzf pkill killall reboot shutdown
  trash-put trash-empty gio tmux gh)

mm_test_setup() {
  local sandbox
  sandbox=$(realpath -e -- "$BATS_TEST_TMPDIR") || return 1
  export HOME="$sandbox/home" SB="$sandbox/sb"
  mkdir -p "$HOME" "$SB"
  if [[ "$(realpath -e -- "$HOME")" != "$sandbox/home" || "$HOME" != /tmp/* ]]; then
    echo "FATAL: HOME ($HOME) is not the test sandbox" >&2
    return 1
  fi
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  # Newer git starts background maintenance after commits; its short-lived lock files would race
  # helpers that walk a tree (mm_age), so tests run git with it switched off.
  export GIT_CONFIG_GLOBAL="$sandbox/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n' >"$GIT_CONFIG_GLOBAL"
  unset MM_CONFIG_DIR MM_CONFIG_FILE MM_STATE_DIR MM_WHITELIST_FILE MM_PURGE_PATHS_FILE MM_LOG_FILE MM_DRY_RUN MM_DEBUG
  # Tool caches and the host's gcloud/Azure config folders located through the environment would
  # point outside the sandbox (lib/core.sh carve-outs).
  unset UV_CACHE_DIR GOPATH GOMODCACHE GOFLAGS GOPROXY GOTOOLCHAIN CLOUDSDK_CONFIG AZURE_CONFIG_DIR
  export MM_TTY=0 NO_COLOR=1 LC_ALL=C.UTF-8
  export MM_TEST_UNSTUBBED_LOG="$sandbox/unstubbed.log"
  : >"$MM_TEST_UNSTUBBED_LOG"
  # The automation-browser sweep of /tmp runs in this folder instead (cmd/clean.sh honors the
  # override only inside $BATS_TEST_TMPDIR).
  export MM_TEST_TMP_ROOT="$SB/tmp"
  mkdir -p "$MM_TEST_TMP_ROOT"
  mm_test_install_stubs
  MM_TEST_PIDS=()
}

mm_test_install_stubs() {
  local d="$BATS_TEST_TMPDIR/stubs" c
  mkdir -p "$d"
  for c in "${MM_TEST_STUBBED[@]}"; do
    cat >"$d/$c" <<EOF
#!/usr/bin/env bash
# fail-loud stub: tests must never run the real $c
if [[ "$c" == sudo && ( "\$*" == "-n true" || "\$*" == "-k" ) ]]; then exit 1; fi
if [[ "$c" == gh && "\$*" == "auth token" ]]; then exit 1; fi
printf 'UNSTUBBED %s %s\n' "$c" "\$*" >>"\$MM_TEST_UNSTUBBED_LOG"
echo "UNSTUBBED $c \$*" >&2
exit 97
EOF
    chmod +x "$d/$c"
  done
  ln -sf "$MM_SRC/marmot" "$d/mm"
  export PATH="$d:$PATH"
}

# mm_test_fake NAME [BODY] — replace NAME's stub with a double whose script is BODY (default:
# succeed silently). Lasts for the current test only.
mm_test_fake() {
  printf '#!/usr/bin/env bash\n%s\n' "${2:-exit 0}" >"$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
}

# mm_test_bg DIR CMD... — start CMD in the background with cwd DIR; killed at teardown. Returns
# once the process runs CMD inside DIR: a fixed sleep raced on slow machines, where a test could
# delete DIR before the background shell had even changed into it.
mm_test_bg() {
  local dir="$1"; shift
  (cd "$dir" && exec "$@") &
  local pid=$! want i
  MM_TEST_PIDS+=("$pid")
  want=$(realpath -e -- "$dir")
  for ((i = 0; i < 200; i++)); do
    if [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$want" ]] &&
       tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -qxF -- "$1"; then
      return 0
    fi
    sleep 0.05
  done
}

mm_test_teardown() {
  local p
  for p in "${MM_TEST_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  if [[ -s "$MM_TEST_UNSTUBBED_LOG" ]]; then
    echo "commands ran unstubbed:" >&2
    cat "$MM_TEST_UNSTUBBED_LOG" >&2
    return 1
  fi
}

# mm_core — source lib/core.sh into the test shell (after mm_test_setup).
mm_core() {
  # shellcheck source=../../lib/core.sh
  . "$MM_SRC/lib/core.sh"
}

# mm_log_rows ACTION — operations-log rows (target<TAB>detail) with that action.
mm_log_rows() {
  local log="$XDG_STATE_HOME/marmot/operations.log"
  [[ -f "$log" ]] || return 0
  awk -F'\t' -v a="$1" '$3 == a { print $4 "\t" $6 }' "$log"
}

# mm_age PATH DAYS — make PATH (recursively) look DAYS old by mtime and atime. ctime cannot be
# faked; tests that need old ctime override `date` instead (see mm_test_clock).
mm_age() { find "$1" -exec touch -c -h -d "$2 days ago" {} +; }

# mm_test_clock DAYS — move marmot's notion of "now" DAYS days into the future for child bash
# processes (age checks such as the Trash retention sweep call `date +%s`).
mm_test_clock() {
  export MM_TEST_CLOCK_SHIFT=$(( $1 * 86400 ))
  date() {
    if [[ "${1:-}" == +%s ]]; then echo $(( $(command date +%s) + MM_TEST_CLOCK_SHIFT ))
    else command date "$@"; fi
  }
  export -f date
}

# mm_test_pids [--parent PID] [--comm NAME] [--cmdline TEXT] [--cmdline-has TEXT] — PIDs matching
# every filter given: parent, exact name, exact command line (arguments joined by spaces), or a
# command line containing TEXT. Read from /proc: procps (pgrep) is not installed everywhere.
mm_test_pids() {
  local parent="" comm="" exact="" has="" p st c f=() argv=() IFS=' '
  while (( $# )); do
    case "$1" in
      --parent) parent=$2 ;; --comm) comm=$2 ;; --cmdline) exact=$2 ;; --cmdline-has) has=$2 ;;
    esac
    shift 2
  done
  for p in /proc/[0-9]*; do
    [[ "${p#/proc/}" == "$BASHPID" ]] && continue
    { IFS= read -r st <"$p/stat"; IFS= read -r c <"$p/comm"; mapfile -d '' -t argv <"$p/cmdline"; } 2>/dev/null || continue
    read -r -a f <<<"${st##*) }"
    [[ -z "$parent" || "${f[1]:-}" == "$parent" ]] || continue
    [[ -z "$comm" || "$c" == "$comm" ]] || continue
    [[ -z "$exact" || "${argv[*]}" == "$exact" ]] || continue
    [[ -z "$has" || "${argv[*]}" == *"$has"* ]] || continue
    echo "${p#/proc/}"
  done
  return 0
}
