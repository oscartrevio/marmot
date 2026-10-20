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

# ---------------------------------------------------------------- the in-use snapshot and the gate's last checks

# why PATH — mm_inuse_why's status and output for PATH, in $status/$output.
why() { run mm_inuse_why "$1"; }

@test "a library a process loaded keeps its folder even with a space in its path (maps, no fd)" {
  command -v python3 >/dev/null || skip "python3 is not installed"
  local lib p i
  for lib in /usr/lib/*-linux-gnu/libz.so.1 /lib/*-linux-gnu/libz.so.1; do [[ -f "$lib" ]] && break; done
  [[ -f "$lib" ]] || skip "no libz.so.1 to load"
  mkdir -p "$SB/my proj/cache" "$SB/my-proj/cache" "$SB/idle"
  # dlopen keeps no fd open and the path is not in argv: only /proc/PID/maps names the file
  for p in "$SB/my proj/cache/model.so" "$SB/my-proj/cache/model.so"; do
    cp "$lib" "$p"
    MM_TEST_LIB="$p" mm_test_bg / python3 -c 'import ctypes, os, time
ctypes.CDLL(os.environ["MM_TEST_LIB"]); time.sleep(30)'
    for ((i = 0; i < 100; i++)); do grep -qF -- "$p" "/proc/${MM_TEST_PIDS[-1]}/maps" 2>/dev/null && break; sleep 0.05; done
    grep -qF -- "$p" "/proc/${MM_TEST_PIDS[-1]}/maps"
  done
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/my proj/cache"; [ "$output" = "1 in use" ]
  run try_rm "$SB/my-proj/cache"; [ "$output" = "1 in use" ]
  run try_rm "$SB/idle";          [ "$output" = "0 " ]
}

@test "a unix socket bound at a path with a space keeps its folder" {
  command -v python3 >/dev/null || skip "python3 is not installed"
  mkdir -p "$SB/sock dir"
  mm_test_bg "$SB" python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(30)' "$SB/sock dir/s"
  local i; for ((i = 0; i < 100; i++)); do [[ -S "$SB/sock dir/s" ]] && break; sleep 0.05; done
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/sock dir"; [ "$output" = "1 in use" ]
}

@test "a bind mount at a path with a space is seen and the mounted source survives" {
  unshare -rm true 2>/dev/null || skip "unprivileged mount namespaces unavailable"
  mkdir -p "$SB/src/pkg" "$SB/work/Client Site/node_modules/@acme/ui" "$SB/work/Client Site/node_modules/react"
  echo precious >"$SB/src/pkg/Button.tsx"; echo r >"$SB/work/Client Site/node_modules/react/index.js"
  run unshare -rm bash -c '
    . "$1/lib/core.sh"; /usr/bin/mount --bind "$2/src/pkg" "$2/work/Client Site/node_modules/@acme/ui" || exit 3
    mm_inuse_refresh >/dev/null 2>&1
    rc=0; mm_rm "$2/work/Client Site/node_modules" "$2/work" >/dev/null 2>&1 || rc=$?
    echo "$rc $MM_SKIP_REASON"; /usr/bin/umount "$2/work/Client Site/node_modules/@acme/ui"' _ "$MM_SRC" "$SB"
  [ "$output" = "1 in use" ]
  [ "$(cat "$SB/src/pkg/Button.tsx")" = precious ]
}

@test "a mount point inside the target stops the removal even when the snapshot predates it" {
  unshare -rm true 2>/dev/null || skip "unprivileged mount namespaces unavailable"
  mkdir -p "$SB/src/pkg" "$SB/work/site/node_modules/@acme/ui"; echo precious >"$SB/src/pkg/Button.tsx"
  run unshare -rm bash -c '
    . "$1/lib/core.sh"; mm_inuse_refresh >/dev/null 2>&1
    /usr/bin/mount --bind "$2/src/pkg" "$2/work/site/node_modules/@acme/ui" || exit 3
    rc=0; mm_rm "$2/work/site/node_modules" "$2/work" >/dev/null 2>&1 || rc=$?
    echo "$rc $MM_SKIP_REASON"; /usr/bin/umount "$2/work/site/node_modules/@acme/ui"' _ "$MM_SRC" "$SB"
  [ "${output%% *}" = 1 ]; [ -n "${output#* }" ]
  [ "$(cat "$SB/src/pkg/Button.tsx")" = precious ]
  [ "$(mm_log_rows refused | cut -f2)" = "${output#* }" ]
}
