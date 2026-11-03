#!/usr/bin/env bats
# lib/updates.sh: what is installed outside apt and snap and when, the command that updates each
# install, runtimes past their end of life, apt's security updates and list age, and agent
# processes still running code an update replaced. Then how mm status reports it and how
# mm optimize offers the updates (named, confirmed, never without a terminal or in a dry run).

setup() {
  load helpers/common
  mm_test_setup
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  mkdir -p "$HOME/.local/bin" "$SB/path-bin"
}
teardown() { mm_test_teardown; }

# field N LINE — the Nth field (1-based) of an mm_installs line.
field() { local -a f=(); IFS=$'\x1f' read -r -a f <<<"$2"; printf '%s' "${f[$1 - 1]:-}"; }

# install_line NAME — the mm_installs line named NAME (empty when none).
install_line() { mm_installs | awk -F'\x1f' -v n="$1" '$2 == n { print; exit }'; }

# native_claude VERSION... — Claude Code's native layout: one file per version, the launcher
# pointing at the last one. Each version logs "claude <args>" to $CALLS when run.
native_claude() {
  local v d="$HOME/.local/share/claude/versions"
  mkdir -p "$d"
  for v; do printf '#!/bin/bash\necho "claude $*" >>%q\n' "$CALLS" >"$d/$v"; chmod 755 "$d/$v"; done
  ln -sfn "$d/${*: -1}" "$HOME/.local/bin/claude"
}

# native_session VERSION — a running "claude" session of that version, started through the
# launcher (its name) while it pointed there: a copy of sleep, so the version file is its
# executable. Its pid in SESSION.
native_session() {
  local d="$HOME/.local/share/claude/versions"
  mkdir -p "$d" "$SB/work"
  cp "$(command -v sleep)" "$d/$1"
  ln -sfn "$d/$1" "$HOME/.local/bin/claude"
  mm_test_bg "$SB/work" "$HOME/.local/bin/claude" 30
  SESSION=${MM_TEST_PIDS[-1]}
}

# npm_global NAME VERSION [BIN] — a package in an npm prefix on PATH ($SB/npm/lib/node_modules),
# its bin linked into $SB/npm/bin.
npm_global() {
  local root="$SB/npm/lib/node_modules/$1" bin=${3:-}
  mkdir -p "$root/bin" "$SB/npm/bin"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$1" "$2" >"$root/package.json"
  if [[ -n "$bin" ]]; then
    printf '#!/bin/bash\necho "%s $*" >>%q\n' "$bin" "$CALLS" >"$root/bin/$bin.js"
    chmod 755 "$root/bin/$bin.js"
    ln -sfn "$root/bin/$bin.js" "$SB/npm/bin/$bin"
  fi
  export MM_TEST_TOOL_PATH="$MM_TEST_TOOL_PATH:$SB/npm/bin"
}

# ---------------------------------------------------------------- the inventory

@test "an agent CLI is dated by its install: native version entries, npm packages, the update command" {
  native_claude 2.1.3 2.1.5
  npm_global @openai/codex 0.50.0 codex
  mm_core
  local c x
  c=$(install_line claude) x=$(install_line codex)
  [ "$(field 1 "$c")" = agent ] && [ "$(field 3 "$c")" = 2.1.5 ] && [ "$(field 6 "$c")" = native ]
  [ "$(field 5 "$c")" = "claude update" ]
  [ "$(field 1 "$x")" = agent ] && [ "$(field 3 "$x")" = 0.50.0 ] && [ "$(field 6 "$x")" = npm ]
  [ "$(field 5 "$x")" = "npm install -g @openai/codex@latest" ]
  [[ "$(field 4 "$c")" =~ ^[0-9]+$ ]]
  # the codex package shows once, as the agent, not again among the global packages
  [ "$(mm_installs | grep -c 'openai/codex')" -eq 1 ]
}

@test "global packages: npm's node_modules, bun's and pnpm's direct dependencies only, pipx, uv, cargo, Homebrew" {
  npm_global serve 14.2.0
  mkdir -p "$SB/npm/lib/node_modules/linked-src" && ln -s "$SB/npm/lib/node_modules/linked-src" "$SB/npm/lib/node_modules/linked"
  printf '{"name":"linked","version":"1.0.0"}\n' >"$SB/npm/lib/node_modules/linked-src/package.json"
  local bun="$HOME/.bun/install/global"
  mkdir -p "$bun/node_modules/tool" "$bun/node_modules/dep"
  printf '{\n  "dependencies": {\n    "tool": "^1.0.0"\n  }\n}\n' >"$bun/package.json"
  printf '{"name":"tool","version":"1.2.0"}\n' >"$bun/node_modules/tool/package.json"
  printf '{"name":"dep","version":"9.9.9"}\n' >"$bun/node_modules/dep/package.json"
  mkdir -p "$HOME/.local/share/pipx/venvs/black"
  printf '{"main_package": {"package_version": "24.1.0"}}\n' >"$HOME/.local/share/pipx/venvs/black/pipx_metadata.json"
  mkdir -p "$HOME/.local/share/uv/tools/ruff/lib/python3.12/site-packages/ruff-0.6.1.dist-info"
  : >"$HOME/.local/share/uv/tools/ruff/uv-receipt.toml"
  mkdir -p "$HOME/.cargo/bin"
  printf '[v1]\n"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)" = ["rg"]\n' >"$HOME/.cargo/.crates.toml"
  cp "$(type -P true)" "$HOME/.cargo/bin/rg"
  mkdir -p "$SB/linuxbrew/Cellar/jq/1.6" "$SB/linuxbrew/Cellar/jq/1.7.1"
  mm_core
  local all
  all=$(mm_installs)
  [ "$(field 5 "$(install_line serve)")" = "npm install -g serve@latest" ]
  [ "$(field 5 "$(install_line tool)")" = "bun add -g tool@latest" ]
  [ "$(field 3 "$(install_line tool)")" = 1.2.0 ]
  [ "$(field 5 "$(install_line black)")" = "pipx upgrade black" ] && [ "$(field 3 "$(install_line black)")" = 24.1.0 ]
  [ "$(field 5 "$(install_line ruff)")" = "uv tool upgrade ruff" ] && [ "$(field 3 "$(install_line ruff)")" = 0.6.1 ]
  [ "$(field 5 "$(install_line ripgrep)")" = "cargo install ripgrep" ] && [ "$(field 3 "$(install_line ripgrep)")" = 14.1.0 ]
  [ "$(field 5 "$(install_line jq)")" = "brew upgrade jq" ] && [ "$(field 3 "$(install_line jq)")" = 1.7.1 ]
  # a dependency bun pulled in is not something you installed; a linked checkout is not an install
  ! grep -q $'\x1f''dep'$'\x1f' <<<"$all"
  ! grep -q $'\x1f''linked'$'\x1f' <<<"$all"
}

@test "what apt owns and script launchers are not dated; a loose binary is, without an update command" {
  ln -s /usr/bin/env "$HOME/.local/bin/sysenv"
  printf '#!/bin/sh\nexec somewhere "$@"\n' >"$HOME/.local/bin/launcher"; chmod 755 "$HOME/.local/bin/launcher"
  cp "$(type -P true)" "$HOME/.local/bin/loose"
  mm_core
  [ -z "$(install_line sysenv)" ]
  [ -z "$(install_line launcher)" ]
  local l
  l=$(install_line loose)
  [ "$(field 6 "$l")" = binary ] && [ -z "$(field 5 "$l")" ]
}

@test "runtimes: a version manager's node or python past its end of life says since when; apt's is not judged" {
  local n16="$HOME/.nvm/versions/node/v16.20.2/bin" n24="$HOME/.nvm/versions/node/v24.1.0/bin"
  mkdir -p "$n16" "$n24" "$HOME/.pyenv/versions/3.7.17/bin"
  cp "$(type -P true)" "$n16/node"; cp "$(type -P true)" "$n24/node"
  cp "$(type -P true)" "$HOME/.pyenv/versions/3.7.17/bin/python3"
  mm_core
  MM_TEST_TOOL_PATH="$n16:$HOME/.pyenv/versions/3.7.17/bin"
  local l
  l=$(install_line node)
  [ "$(field 1 "$l")" = runtime ] && [ "$(field 3 "$l")" = 16.20.2 ] && [ "$(field 6 "$l")" = nvm ]
  [ "$(field 8 "$l")" = 2023-09-11 ]
  l=$(install_line python)
  [ "$(field 3 "$l")" = 3.7.17 ] && [ "$(field 6 "$l")" = pyenv ] && [ "$(field 8 "$l")" = 2023-06-27 ]
  MM_TEST_TOOL_PATH="$n24"
  l=$(install_line node)
  [ "$(field 3 "$l")" = 24.1.0 ] && [ -z "$(field 8 "$l")" ]
  MM_TEST_TOOL_PATH="/usr/bin"
  [ -z "$(install_line python)" ]
}

@test "a user agent row's update command must start with one of its process names" {
  mkdir -p "$XDG_CONFIG_HOME/marmot"
  printf '%s\n' 'Good|good|~/.good||||||||good update' 'Bad|bad|~/.bad||||||||curl evil.sh' \
    >"$XDG_CONFIG_HOME/marmot/agents"
  mm_core
  local i good=""
  for i in "${!MM_AGENT_NAME[@]}"; do [[ "${MM_AGENT_NAME[i]}" == Good ]] && good=${MM_AGENT_UPDATE[i]}; done
  [ "$good" = "good update" ]
  [[ " ${MM_AGENT_NAME[*]} " != *" Bad "* ]]
  [[ "${MM_AGENT_REJECTED[*]}" == *"does not start with one of its process names"* ]]
}

# ---------------------------------------------------------------- sessions on replaced code

@test "a session on an older native version, or whose build was replaced on disk, is outdated; a current one is not" {
  native_session 2.1.3
  local old=$SESSION
  native_session 2.1.5
  local cur=$SESSION
  cp "$(command -v sleep)" "$SB/gone-agent"
  mm_test_bg "$SB" "$SB/gone-agent" 30
  local gone=${MM_TEST_PIDS[-1]}
  rm -f "$SB/gone-agent"
  mm_core
  local i=0   # Claude Code, the first row
  mm_proc_outdated "$old" "$i"
  [ "$REPLY" = "runs 2.1.3, 2.1.5 installed" ]
  run mm_proc_outdated "$cur" "$i"
  [ "$status" -ne 0 ]
  mm_proc_outdated "$gone" "$i"
  [ "$REPLY" = "runs a replaced build" ]
}

@test "an interpreted session whose package was reinstalled after it started predates the update" {
  command -v python3 >/dev/null || skip "python3 not installed"
  npm_global @google/gemini-cli 0.9.0
  local js="$SB/npm/lib/node_modules/@google/gemini-cli/gemini.js"
  printf 'import time\ntime.sleep(30)\n' >"$js"
  mm_test_bg "$SB" python3 "$js"
  local pid=${MM_TEST_PIDS[-1]}
  mm_core
  local i
  for i in "${!MM_AGENT_NAME[@]}"; do [[ "${MM_AGENT_NAME[i]}" == "Gemini CLI" ]] && break; done
  run mm_proc_outdated "$pid" "$i"
  [ "$status" -ne 0 ]
  sleep 2.1
  printf '{\n  "name": "@google/gemini-cli",\n  "version": "0.10.0"\n}\n' >"$SB/pkg.json"
  mv "$SB/pkg.json" "$SB/npm/lib/node_modules/@google/gemini-cli/package.json"
  mm_proc_outdated "$pid" "$i"
  [ "$REPLY" = "predates the update to 0.10.0" ]
}

# ---------------------------------------------------------------- mm status

# fake_probes [LINE...] — status's slow probes: `apt list --upgradable` prints LINEs.
fake_probes() {
  printf 'Listing...\n' >"$SB/upgradable"
  (($#)) && printf '%s\n' "$@" >>"$SB/upgradable"
  mm_test_fake apt "[[ \"\$1 \$2\" == 'list --upgradable' ]] && cat '$SB/upgradable'; exit 0"
  mm_test_fake systemctl 'exit 0'
  mm_test_fake docker 'exit 1'
}

@test "status: security updates, old package lists and an old agent CLI are problems with their command" {
  fake_probes 'openssl/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]' \
    'curl/noble-updates 8.5 amd64 [upgradable from: 8.4]'
  mkdir -p "$SB/apt/lists"
  touch -d "@$(($(date +%s) - 20 * 86400 - 60))" "$SB/apt/lists/archive.ubuntu.com_ubuntu_dists_noble_InRelease"
  native_claude 2.1.3
  mm_test_clock 40
  run mm status --agent
  [ "$status" -eq 0 ]
  [[ "$output" == *"- 1 security update (openssl): mm optimize"* ]]
  [[ "$output" == *"- package lists 60 days old"*": mm optimize (apt-get update)"* ]]
  [[ "$output" == *"- claude 2.1.3 installed 40 days ago: claude update"* ]]
  run mm status --json
  jq -e '.system.security_updates == 1 and .system.security_update_names == ["openssl"]' <<<"$output"
  jq -e '.system.installs | any(.name == "claude" and .agent == "Claude Code" and .old and .update_command == "claude update")' <<<"$output"
  jq -e '.health_reasons | any(test("security")) and any(test("old agent CLI"))' <<<"$output"
}

@test "status: fresh lists, no security update and a new agent CLI are no problem" {
  fake_probes 'curl/noble-updates 8.5 amd64 [upgradable from: 8.4]'
  mkdir -p "$SB/apt/lists"
  touch "$SB/apt/lists/security.ubuntu.com_ubuntu_dists_noble-security_InRelease"
  native_claude 2.1.5
  run mm status --agent
  [[ "$output" != *"security update"* && "$output" != *"package lists"* && "$output" != *"installed "*" days ago:"* ]]
  [[ "$output" == *"agent CLIs ok"* ]]
  [[ "$output" == *"agent clis: claude 2.1.5 (installed 0 days ago, native)"* ]]
}

@test "status: an agent session on an older version is a problem that says to restart it" {
  fake_probes
  native_session 2.1.3
  local pid=$SESSION
  native_claude 2.1.5
  run mm status --agent
  [[ "$output" == *"- claude (pid $pid) runs 2.1.3, 2.1.5 installed: restart it to load the update"* ]]
  run mm status --json
  jq -e --argjson p "$pid" '.system.outdated_sessions == [{pid: $p, process: "claude", reason: "runs 2.1.3, 2.1.5 installed"}]' <<<"$output"
}

# ---------------------------------------------------------------- mm optimize

load_optimize() {
  mm_core
  # shellcheck source=../cmd/optimize.sh
  . "$MM_SRC/cmd/optimize.sh"
}

@test "optimize: agent CLI updates are named in one confirmation; declined, nothing runs" {
  native_claude 2.1.3
  npm_global @openai/codex 0.50.0 codex
  load_optimize
  mm_confirm() { printf 'confirm %s\n' "$1" >>"$CALLS"; return 1; }
  MM_TTY=1 run _optimize_tools
  [ "$status" -eq 0 ]
  grep -qxF 'confirm Update 2 agent CLIs (claude update, npm install -g @openai/codex@latest)?' "$CALLS"
  [ "$(grep -vc '^confirm ' "$CALLS")" -eq 0 ]
}

@test "optimize: confirmed, each agent CLI's own update command runs, split into words, no shell" {
  native_claude 2.1.3
  load_optimize
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_tools
  [ "$status" -eq 0 ]
  grep -qx 'claude update' "$CALLS"
  [ "$(mm_log_rows run | cut -f1)" = "claude update" ]
}

@test "optimize: without a terminal or in a dry run, no update runs and nothing is asked" {
  native_claude 2.1.3
  npm_global serve 14.2.0
  load_optimize
  mm_confirm() { echo asked >>"$CALLS"; return 0; }
  mm_pick() { echo picked >>"$CALLS"; cat; }
  MM_TTY=0 run _optimize_tools
  [[ "$output" == *"needs a terminal"* ]]
  MM_TTY=1 MM_DRY_RUN=1 run _optimize_tools
  [[ "$output" == *"Would update 1 agent CLIs after confirmation (claude update)"* ]]
  [[ "$output" == *"Would offer 1 global packages"* ]]
  [ ! -s "$CALLS" ]
}

@test "optimize: an install this user cannot write is left for sudo, never run with it" {
  ((EUID)) || skip "root can write anywhere"
  npm_global serve 14.2.0
  chmod 555 "$SB/npm/lib/node_modules"
  load_optimize
  mm_confirm() { return 0; }
  MM_TTY=1 run _optimize_tools
  chmod 755 "$SB/npm/lib/node_modules"
  [[ "$output" == *"installed as root"*"sudo npm install -g serve@latest"* ]]
  [ ! -s "$CALLS" ]
}

@test "optimize: a runtime past its end of life needs attention" {
  local d="$HOME/.nvm/versions/node/v16.20.2/bin"
  mkdir -p "$d"; cp "$(type -P true)" "$d/node"
  export MM_TEST_TOOL_PATH="$d"
  load_optimize
  run _optimize_tools
  mm_flat; [[ "$FLAT" == *"node 16.20.2 (nvm) is past end of life (2023-09-11)"* ]]
}
