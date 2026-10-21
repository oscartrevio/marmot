# shellcheck shell=bash
# Shared bats setup for marmot. Load with `load helpers/common`, then call mm_test_setup in setup()
# and mm_test_teardown in teardown().
#
# Isolation:
#   - HOME, XDG dirs, marmot config/state and the Trash live under $BATS_TEST_TMPDIR; setup refuses to
#     continue unless HOME really is that sandbox.
#   - Every command in MM_TEST_GUARDED is, first on PATH, a link to one guard script that writes
#     "<cmd> <args>" to $MM_TEST_HOST_CALLS and exits 86. Teardown fails the test when that file is
#     not empty, so code that reaches the real machine turns a test red instead of passing on one
#     host and failing on another. A test that needs the command installs a double: mm_test_fake.
#   - `sudo -n true` answers "no" quietly and `sudo -v` (the one password prompt) is refused, so
#     marmot runs its unprivileged paths; so does `gh auth token` (logged out), so no test asks
#     GitHub anything.

MM_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
MM_TEST_GUARDED=(sudo apt apt-get apt-mark snap docker systemctl journalctl swapon swapoff mount umount
  resolvectl fstrim npm npx pnpm yarn bun uv uvx go pip pip3 pipx ncdu fzf pkill killall reboot shutdown
  trash-put trash-empty gio tmux gh mise conda brew nix-collect-garbage)

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
  unset MM_CONFIG_DIR MM_CONFIG_FILE MM_STATE_DIR MM_WHITELIST_FILE MM_PURGE_PATHS_FILE MM_LOG_FILE MM_DRY_RUN MM_DEBUG \
    MM_NO_SUDO MM_TEST_SUDO_INTERVAL MM_SUDO_KEEPALIVE_PID
  # Tool caches and the host's gcloud/Azure config folders located through the environment would
  # point outside the sandbox (lib/core.sh carve-outs).
  unset UV_CACHE_DIR GOPATH GOMODCACHE GOFLAGS GOPROXY GOTOOLCHAIN CLOUDSDK_CONFIG AZURE_CONFIG_DIR \
    MISE_CACHE_DIR PYENV_ROOT RBENV_ROOT COMPOSER_CACHE_DIR HEX_HOME OPAMROOT \
    FIREBASE_EMULATORS_PATH PUB_CACHE TORCH_HOME WANDB_CACHE_DIR WANDB_DATA_DIR TF_PLUGIN_CACHE_DIR
  export MM_TTY=0 NO_COLOR=1 LC_ALL=C.UTF-8
  # Tests run on hosts and inside CI containers alike: container awareness is off unless a test
  # turns it on (MM_CONTAINER=1), and no outside Docker daemon setting leaks in.
  export MM_CONTAINER=0
  unset DOCKER_HOST DOCKER_CONTEXT MM_DOCKER_PRUNE MM_TEST_CGROUP_FS
  # Purge discovery looks in /workspaces and /workspace under this stand-in for / instead
  # (cmd/purge.sh honors it only inside $BATS_TEST_TMPDIR); it does not exist unless a test makes it.
  export MM_TEST_WORKSPACE_PREFIX="$SB/fakeroot"
  export MM_TEST_HOST_CALLS="$sandbox/host-calls"
  : >"$MM_TEST_HOST_CALLS"
  # The automation-browser sweep of /tmp runs in this folder instead (cmd/clean.sh honors the
  # override only inside $BATS_TEST_TMPDIR).
  export MM_TEST_TMP_ROOT="$SB/tmp"
  mkdir -p "$MM_TEST_TMP_ROOT"
  mm_test_guard_host
  MM_TEST_PIDS=()
}

# mm_test_guard_host — put the guard (see the header) first on PATH, plus `mm` for this checkout.
mm_test_guard_host() {
  local bin="$BATS_TEST_TMPDIR/stubs" cmd
  mkdir -p "$bin"
  cat >"$bin/.guard" <<'GUARD'
#!/usr/bin/env bash
cmd=${0##*/}
case "$cmd $*" in
  "sudo -n true" | "sudo -v" | "sudo -k" | "gh auth token") exit 1 ;;   # no sudo, logged out of GitHub
esac
echo "$cmd $*" >>"$MM_TEST_HOST_CALLS"
echo "test reached the real machine: $cmd $*" >&2
exit 86
GUARD
  chmod 755 "$bin/.guard"
  for cmd in "${MM_TEST_GUARDED[@]}"; do ln -sfn .guard "$bin/$cmd"; done
  ln -sfn "$MM_SRC/marmot" "$bin/mm"
  export PATH="$bin:$PATH"
}

# mm_test_fake NAME [SCRIPT] — for the rest of this test, NAME runs SCRIPT (bash; default: do
# nothing and succeed) instead of the guard or the real command.
mm_test_fake() {
  local f="$BATS_TEST_TMPDIR/stubs/$1"
  rm -f -- "$f"
  printf '#!/usr/bin/env bash\n%s\n' "${2:-:}" >"$f"
  chmod 755 "$f"
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
  if [[ -s "$MM_TEST_HOST_CALLS" ]]; then
    echo "the test reached the real machine:" >&2
    cat "$MM_TEST_HOST_CALLS" >&2
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

# mm_test_checkout DIR — make DIR a git checkout (branch main, one commit) of the marmot sources
# under test, for install records and `mm update`. Commits use mm_test_git's identity.
mm_test_checkout() {
  mkdir -p "$1"
  cp -R "$MM_SRC/marmot" "$MM_SRC/install.sh" "$MM_SRC/lib" "$MM_SRC/cmd" "$MM_SRC/completion" "$1/"
  git -C "$1" init -q -b main
  git -C "$1" add -A
  mm_test_git "$1" commit -qm "marmot under test"
}

# mm_test_git DIR ARGS... — git in DIR with a test author.
mm_test_git() {
  local d=$1; shift
  git -C "$d" -c user.name=marmot-test -c user.email=test@example.invalid "$@"
}
