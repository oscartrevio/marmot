#!/usr/bin/env bats
# Personal data that only looks regenerable survives every unattended run: `mm schedule run`,
# `mm purge --yes` and `mm clean` without a terminal. Each case below is a way marmot once
# deleted something a person wanted; the regenerable controls prove the runs still act.

# Runs share the machine's process list (busy checks): keep this file's tests sequential.
setup_file() { export BATS_NO_PARALLELIZE_WITHIN_FILE=true; }

setup() {
  load helpers/common
  mm_test_setup
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  SUMS="$BATS_TEST_TMPDIR/personal.sha256"
  PERSONAL=()
}
teardown() { mm_test_teardown; }

gone() { local p; for p; do [ ! -e "$p" ] || { echo "still there: $p"; return 1; }; done; }

# rec NAME [BODY] — a double that appends "NAME <args>" to $CALLS, then runs BODY.
rec() { mm_test_fake "$1" "echo \"$1 \$*\" >>\"\$CALLS\"
${2:-}"; }

# tools — every tool an unattended run may call: sudo says no, git is the real one, the tools'
# own cleans find nothing to do, and no Docker daemon answers.
tools() {
  local g t; g=$(command -v git)
  rec sudo 'exit 1'
  rec git "exec '$g' \"\$@\""
  for t in npm pnpm bun uv go mise conda brew nix-collect-garbage; do rec "$t"; done
  rec yarn 'case "$*" in --version) echo 1.22.22 ;; "cache dir") echo "$SB/yarncache" ;; esac'
  rec docker 'exit 1'
}

# mine PATH [CONTENT] — a personal file, listed for the survival check.
mine() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-$1}" >"$1"; PERSONAL+=("$1"); }

# whitelisted_project DIR — a stale package.json project whose node_modules a whitelist entry
# must keep.
whitelisted_project() { mine "$1/package.json" '{}'; mine "$1/node_modules/dep/index.js"; }

# trash_item NAME DAYS_AGO — something its owner moved to the Trash DAYS_AGO days ago.
trash_item() {
  local t="$XDG_DATA_HOME/Trash"
  mine "$t/files/$1"
  mkdir -p "$t/info"
  printf '[Trash Info]\nPath=%s/Documents/%s\nDeletionDate=%s\n' "$HOME" "$1" \
    "$(command date -d "$2 days ago" +%Y-%m-%dT%H:%M:%S)" >"$t/info/$1.trashinfo"
}

# personal_home — a home full of personal data shaped like caches and build artifacts, plus two
# regenerable controls (a stale node_modules, an old pip wheel). Everything is 40 days old except
# where a case needs otherwise.
personal_home() {
  local h="$HOME" x="$HOME/.npm/_npx/15b07286cbcc3329"
  # A folder called coverage outside any project: insurance papers.
  mine "$h/Documents/insurance/coverage/home-policy-2025.pdf"
  # The same in a folder edited today deep down (activity is not only the top level).
  mine "$h/Documents/health/coverage/policy.txt"
  mine "$h/Documents/health/claims/2026/appeal-letter.txt"
  # A Go SDK: its standard library has a package folder called coverage.
  mine "$h/sdk/go1.22.0/VERSION" go1.22.0
  mine "$h/sdk/go1.22.0/src/internal/coverage/cfile/emit.go"
  # A deployed Nuxt app: .output is all there is, no source to rebuild it from.
  mine "$h/apps/shop/.output/server/index.mjs"
  # A global npm prefix outside dot-folders (n-install) whose bin is not on PATH.
  mine "$h/n/lib/node_modules/somecli/index.js"
  # A data folder its owner tagged CACHEDIR.TAG to keep it out of backups.
  mine "$h/code/pipeline/Makefile" 'all:'
  mine "$h/code/pipeline/data/CACHEDIR.TAG" 'Signature: 8a477f597d28d172789f06886806bc55'
  mine "$h/code/pipeline/data/raw/survey-2024.csv"
  # Local Terraform state inside a Terragrunt cache.
  mine "$h/infra/live/terragrunt.hcl"
  mine "$h/infra/live/.terragrunt-cache/x1/y2/terraform.tfstate"
  # An Electron app's build/ inputs, under a dotfiles repository at ~ that ignores everything.
  mine "$h/apps/desk/package.json" '{}'
  mine "$h/apps/desk/build/icon.png"
  mine "$h/apps/desk/build/entitlements.mac.plist"
  git -C "$h" init -q
  printf '*\n' >"$h/.gitignore"
  # Whitelisted folders the whitelist must match: brackets, '#', $HOME, a symlinked parent.
  whitelisted_project "$h/work/[2024] taxes"
  whitelisted_project "$h/code/C#/app"
  whitelisted_project "$h/datasets"
  whitelisted_project "$h/Dropbox/code/client"
  ln -s "$h/Dropbox/code" "$h/code2"
  mkdir -p "$XDG_CONFIG_HOME/marmot"
  printf '%s\n' '~/work/[2024] taxes' '~/code/C#/app' '$HOME/datasets' '~/code2/client' \
    >"$XDG_CONFIG_HOME/marmot/whitelist"
  # Agent state behind a symlink (dotfiles): Claude Code's local install and its auto memory;
  # session retention is on, so old transcripts may go to the Trash, memory may not.
  mkdir -p "$h/dotfiles/claude"
  ln -s "$h/dotfiles/claude" "$h/.claude"
  mine "$h/dotfiles/claude/local/package.json" '{}'
  mine "$h/dotfiles/claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
  mine "$h/dotfiles/claude/projects/-home-p/memory/MEMORY.md"
  mine "$h/dotfiles/claude/projects/-home-p/memory/user_role.md"
  echo transcript >"$h/dotfiles/claude/projects/-home-p/old.jsonl"
  echo 'sessions_keep_days = 30' >"$XDG_CONFIG_HOME/marmot/config"
  # An MCP server that keeps its data inside its own npx package folder.
  mine "$x/package.json" '{}'
  mine "$x/node_modules/.package-lock.json" '{}'
  mine "$x/node_modules/@modelcontextprotocol/server-memory/dist/index.js"
  mine "$x/node_modules/@modelcontextprotocol/server-memory/dist/memory.jsonl" '{"type":"entity"}'
  # A Syncthing folder: deleting there deletes on every device.
  mkdir -p "$h/Sync/.stfolder"
  mine "$h/Sync/web/package.json" '{}'
  mine "$h/Sync/web/node_modules/dep/index.js"
  # Tool settings that live in cache rows.
  mine "$h/.cache/node/corepack/lastKnownGood.json" '{"pnpm":"9.12.3"}'
  mine "$h/.oh-my-zsh/cache/dotenv-allowed.list"
  # Playwright MCP persistent profiles (logins) whose names end in digits.
  mine "$h/.cache/ms-playwright/mcp-chrome-4471023/Default/Login Data"
  mine "$h/.cache/ms-playwright/mcp-chrome-9310577/Default/Login Data"
  # Something its owner moved to the Trash 40 days ago.
  trash_item thesis-draft.docx 40
  # A virtualenv not named venv, holding a hand-patched package: the Trash at most, never rm.
  mine "$h/proj/ml/requirements.txt" 'torch'
  mkdir -p "$h/proj/ml/env/lib/python3.11/site-packages"
  echo 'home = /usr/bin' >"$h/proj/ml/env/pyvenv.cfg"
  echo 'Signature: 8a477f597d28d172789f06886806bc55' >"$h/proj/ml/env/CACHEDIR.TAG"
  echo patched >"$h/proj/ml/env/lib/python3.11/site-packages/patched.py"
  # Regenerable controls: a stale node_modules next to its package.json, an old pip wheel.
  mkdir -p "$h/work/old/node_modules/dep" "$h/.cache/pip/wheels"
  echo '{}' >"$h/work/old/package.json"
  head -c 1100000 /dev/urandom >"$h/work/old/node_modules/dep/index.js"
  echo w >"$h/.cache/pip/wheels/w.whl"

  # Checksums first: reading a file refreshes its access time, which counts as use.
  sha256sum -- "${PERSONAL[@]}" >"$SUMS"
  mm_age "$h" 40
  touch "$h/Documents/health/claims/2026/appeal-letter.txt"
  touch -d '8 days ago' "$x/node_modules/@modelcontextprotocol/server-memory/dist/memory.jsonl"
}

# intact — every personal file is still where it was, unchanged.
intact() {
  local out
  out=$(sha256sum --quiet -c -- "$SUMS" 2>&1) && return 0
  echo "personal data lost:"; echo "$out"
  return 1
}

# venv_kept — the patched package is in place or in the Trash, never deleted.
venv_kept() {
  [[ -f "$HOME/proj/ml/env/lib/python3.11/site-packages/patched.py" ]] && return 0
  [[ -n "$(find "$XDG_DATA_HOME/Trash/files" -name patched.py -print -quit 2>/dev/null)" ]] && return 0
  echo "virtualenv deleted for good"; return 1
}

@test "mm schedule run keeps personal data; stale regenerable items still go" {
  tools; personal_home
  run mm schedule run
  [ "$status" -eq 0 ]
  intact
  venv_kept
  gone "$HOME/work/old/node_modules" "$HOME/.cache/pip/wheels/w.whl"
}

@test "mm purge --yes keeps personal data; a stale node_modules still goes" {
  tools; personal_home
  run mm purge --yes
  [ "$status" -eq 0 ]
  intact
  venv_kept
  gone "$HOME/work/old/node_modules"
}

@test "mm clean without a terminal keeps personal data; old cache entries still go" {
  tools; personal_home
  run mm clean
  [ "$status" -eq 0 ]
  intact
  venv_kept
  gone "$HOME/.cache/pip/wheels/w.whl"
}
