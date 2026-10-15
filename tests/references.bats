#!/usr/bin/env bats
# lib/core.sh references: files that running processes, launchers, tool configs, systemd user
# units or the crontab name are kept, with the folders containing them, for any tool.

setup() {
  load helpers/common
  mm_test_setup
  mm_core
  mkdir -p "$SB/proj/dist" "$SB/other"
  echo 'x' >"$SB/proj/dist/index.js"
}
teardown() { mm_test_teardown; }

# try_rm PATH — "<rc> <reason>" for one dry-run mm_rm of PATH inside $SB.
try_rm() { local rc=0; MM_DRY_RUN=1 mm_rm "$1" "$SB" >/dev/null 2>&1 || rc=$?; printf '%s %s\n' "$rc" "$MM_SKIP_REASON"; }

@test "a file an MCP config in a dot-folder runs keeps its project and every folder above it" {
  mkdir -p "$HOME/.codeium/windsurf" "$HOME/tools/x"
  echo 'x' >"$HOME/tools/x/server.py"
  printf '{"mcpServers": {"mine": {"command": "node", "args": ["%s/proj/dist/../dist/index.js"]},\n "py": {"command": "python", "args": ["~/tools/x/server.py"]}}}\n' "$SB" \
    >"$HOME/.codeium/windsurf/mcp_config.json"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/proj";      [ "$output" = "1 used by ~/.codeium/windsurf/mcp_config.json" ]
  run try_rm "$SB/proj/dist"; [ "$output" = "1 used by ~/.codeium/windsurf/mcp_config.json" ]
  mm_in_use "$SB"
  run mm_inuse_why "$HOME/tools"
  [ "$status" -eq 0 ]; [ "$output" = "used by ~/.codeium/windsurf/mcp_config.json" ]
  run try_rm "$SB/other";     [ "$output" = "0 " ]
}

@test "a symlink in ~/.local/bin into a project's dist keeps the project" {
  mkdir -p "$HOME/.local/bin" "$SB/linked/dist"; echo 'x' >"$SB/linked/dist/cli.js"
  ln -s "$SB/proj/dist/index.js" "$HOME/.local/bin/mytool"
  ln -s ../../../sb/linked/dist/cli.js "$HOME/.local/bin/reltool"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/proj";   [ "$output" = "1 used by ~/.local/bin/mytool" ]
  run try_rm "$SB/linked"; [ "$output" = "1 used by ~/.local/bin/reltool" ]
}

@test "a wrapper script in ~/.local/bin keeps the file it runs" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nexec node %s/proj/dist/index.js "$@"\n' "$SB" >"$HOME/.local/bin/wrap"
  chmod +x "$HOME/.local/bin/wrap"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/proj"; [ "$output" = "1 used by ~/.local/bin/wrap" ]
}

@test "a process running a script by absolute path keeps the script's folder whatever its cwd" {
  command -v python3 >/dev/null || skip "python3 is not installed"
  mkdir -p "$SB/daemon"; printf 'import time\ntime.sleep(30)\n' >"$SB/daemon/server.py"
  mm_test_bg / python3 "$SB/daemon/server.py"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/daemon"
  [[ "$output" =~ ^"1 used by process "[0-9]+" (python3)"$ ]]
}

@test "a config that only lists a project folder does not keep it" {
  printf '{"projects": {"%s/proj": {"allowedTools": []}}}\n' "$SB" >"$HOME/.claude.json"
  mkdir -p "$HOME/.cursor"; printf '{"mcpServers": {"x": {"cwd": "%s/proj"}}}\n' "$SB" >"$HOME/.cursor/mcp.json"
  mm_inuse_refresh >/dev/null 2>&1
  run mm_inuse_why "$SB/proj"
  [ "$status" -eq 1 ]; [ -z "$output" ]
  run try_rm "$SB/proj"; [ "$output" = "0 " ]
}

@test "a crontab line and a systemd user unit keep the scripts they run" {
  mkdir -p "$SB/cron" "$SB/svc" "$HOME/.config/systemd/user"
  echo 'x' >"$SB/cron/job.sh"; echo 'x' >"$SB/svc/run.sh"
  mm_test_fake crontab "[[ \"\$1\" == -l ]] && printf '*/5 * * * *\\t%s/cron/job.sh >/dev/null 2>&1\\n' '$SB'"
  printf '[Service]\nWorkingDirectory=%s/other\nExecStart=/bin/sh %s/svc/run.sh\n' "$SB" "$SB" >"$HOME/.config/systemd/user/foo.service"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/cron";  [ "$output" = "1 used by crontab" ]
  run try_rm "$SB/svc";   [ "$output" = "1 used by systemd unit foo.service" ]
  run try_rm "$SB/other"; [ "$output" = "0 " ]
}
