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

@test "with sudo but no CAP_SYS_PTRACE this user's processes are still seen and the snapshot is partial" {
  (( EUID != 0 )) || skip "root needs no sudo"
  mkdir -p "$SB/devsrv/node_modules/vite" "$SB/idle" "$BATS_TEST_TMPDIR/rootbin"
  mm_test_bg "$SB/devsrv/node_modules/vite" sleep 30
  # Root without CAP_SYS_PTRACE (a container's default capabilities) lists /proc but cannot read
  # another user's cwd, root, exe, fd or maps: the sudo double runs the scan with find and cat
  # that deny exactly the entries of this user's processes, the way the kernel does.
  cat >"$BATS_TEST_TMPDIR/rootbin/find" <<'EOF'
#!/usr/bin/env bash
keep=()
for a in "$@"; do
  if [[ "$a" =~ ^/proc/[0-9]+/(cwd|root|exe|fd)$ && "$(stat -c %u "${a%/*}" 2>/dev/null)" == "$UID" ]]; then
    echo "find: '$a': Permission denied" >&2
  else keep+=("$a"); fi
done
(( ${#keep[@]} )) || exit 1
exec /usr/bin/find "${keep[@]}"
EOF
  cat >"$BATS_TEST_TMPDIR/rootbin/cat" <<'EOF'
#!/usr/bin/env bash
keep=()
for a in "$@"; do
  if [[ "$a" =~ ^/proc/[0-9]+/maps$ && "$(stat -c %u "${a%/*}" 2>/dev/null)" == "$UID" ]]; then
    echo "cat: $a: Permission denied" >&2
  else keep+=("$a"); fi
done
(( ${#keep[@]} )) || exit 1
exec /usr/bin/cat "${keep[@]}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/rootbin/find" "$BATS_TEST_TMPDIR/rootbin/cat"
  mm_test_fake sudo "[[ \"\$1\" == -n ]] && shift; [[ \"\$*\" == true ]] && exit 0
    PATH=\"$BATS_TEST_TMPDIR/rootbin:\$PATH\" exec \"\$@\""
  mm_inuse_refresh >/dev/null 2>&1
  [ "$MM_INUSE_PARTIAL" = 1 ]
  run try_rm "$SB/devsrv"; [ "$output" = "1 in use" ]
  run try_rm "$SB/idle";   [ "$output" = "0 " ]
}

@test "mount paths are decoded and mapped into this namespace through the filesystem they are on" {
  printf '%s\n' '30 1 0:40 / /home rw,relatime - tmpfs tmpfs rw' '25 1 8:1 / / rw - ext4 /dev/sda1 rw' \
    '40 1 8:1 /srv/bind\040src /mnt/at\040bind rw - ext4 /dev/sda1 rw' >"$SB/host"
  run _mm_mount_paths "$SB/host" <<<'36 35 0:40 /tester/proj /work rw - tmpfs tmpfs rw
37 35 8:1 /srv/bind\040src/a\011b\134c /opt/x rw - ext4 /dev/sda1 rw
38 35 0:66 / /proc rw - proc proc rw'
  [ "$status" -eq 0 ]
  local want
  want=$(printf '%s\n' /tester/proj /work /home/tester/proj "/srv/bind src/a"$'\t''b\c' /opt/x "/mnt/at bind/a"$'\t''b\c' / /proc | sort -u)
  [ "$(sort -u <<<"$output")" = "$want" ]
}

@test "a mount of another namespace on a filesystem this one does not see makes the snapshot partial" {
  printf '%s\n' '25 1 8:1 / / rw - ext4 /dev/sda1 rw' >"$SB/host"
  run _mm_mount_paths "$SB/host" <<<'38 35 0:99 / /data rw - ext4 /dev/sdb1 rw'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"P"$'\t'* || "$output" == "P"$'\t'* ]]
  # the refresh turns any such line of the scan into a partial snapshot
  _mm_inuse_scan() { printf '%s\n' "$SB/seen" $'P\tsomething could not be read'; }
  mm_inuse_refresh >/dev/null 2>&1
  [ "$MM_INUSE_PARTIAL" = 1 ]
}

@test "a process that started after the snapshot is seen right before acting, and an old snapshot is retaken" {
  mkdir -p "$SB/late/node_modules" "$SB/job"; echo 'x' >"$SB/job/run.sh"
  mm_inuse_refresh >/dev/null 2>&1
  mm_test_bg "$SB/late/node_modules" sleep 30
  run try_rm "$SB/late"; [ "$output" = "1 in use" ]
  # a reference that appeared since is only seen by a new snapshot, taken once the last is old
  mm_test_fake crontab "[[ \"\$1\" == -l ]] && echo '0 1 * * * $SB/job/run.sh'"
  MM_INUSE_AT=$(( $(date +%s) - 10 ))
  run try_rm "$SB/job"; [ "$output" = "1 used by crontab" ]
}

@test "a crontab line reaching a script through a symlinked folder keeps the real folder" {
  mkdir -p "$SB/Dropbox/code/reports/dist" "$SB/Dropbox/code/billing/dist"
  echo 'x' >"$SB/Dropbox/code/reports/dist/job.js"; echo 'x' >"$SB/Dropbox/code/billing/dist/job.js"
  ln -s "$SB/Dropbox/code" "$SB/code"
  mm_test_fake crontab "[[ \"\$1\" == -l ]] && printf '%s\n' '0 6 * * * node $SB/code/reports/dist/job.js'"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/Dropbox/code/reports/dist"; [ "$output" = "1 used by crontab" ]
  run try_rm "$SB/Dropbox/code/reports";      [ "$output" = "1 used by crontab" ]
  run try_rm "$SB/Dropbox/code/billing/dist"; [ "$output" = "0 " ]
}

@test "relative paths after cd DIR in the crontab keep what the job runs, resolved against that DIR" {
  mkdir -p "$SB/jobs/a/dist" "$SB/jobs/x/dist" "$SB/bots/rel/node_modules/.bin"
  echo 'x' >"$SB/jobs/a/dist/job.js"; echo 'x' >"$SB/jobs/x/dist/job.js"
  echo 'x' >"$SB/bots/rel/node_modules/.bin/tsx"; echo 'x' >"$SB/bots/rel/index.ts"
  mm_test_fake crontab "[[ \"\$1\" == -l ]] && printf '%s\n' \
    '0 3 * * * cd $SB/jobs/a && node dist/job.js' \
    '0 4 * * * cd \"$SB/bots/rel\"; ./node_modules/.bin/tsx index.ts >/dev/null 2>&1'"
  mm_inuse_refresh >/dev/null 2>&1
  run try_rm "$SB/jobs/a/dist";           [ "$output" = "1 used by crontab" ]
  run try_rm "$SB/bots/rel/node_modules"; [ "$output" = "1 used by crontab" ]
  run try_rm "$SB/jobs/x/dist";           [ "$output" = "0 " ]
}

@test "systemd units keep what %h and WorkingDirectory-relative Exec lines run, system units included" {
  mkdir -p "$HOME/jobs/b/dist" "$HOME/jobs/c/dist" "$HOME/jobs/x/dist" "$SB/svc" "$HOME/.config/systemd/user" "$SB/etc-systemd"
  echo 'x' >"$HOME/jobs/b/dist/job.js"; echo 'x' >"$HOME/jobs/c/dist/job.js"; echo 'x' >"$HOME/jobs/x/dist/job.js"
  echo 'x' >"$SB/svc/sys.py"
  printf '[Service]\nType=oneshot\nExecStart=/usr/bin/node %%h/jobs/b/dist/job.js\n' >"$HOME/.config/systemd/user/report-b.service"
  printf '[Service]\nType=oneshot\nExecStart=-/usr/bin/node dist/job.js\nWorkingDirectory=%%h/jobs/c\n' >"$HOME/.config/systemd/user/report-c.service"
  printf '[Service]\nExecStart=/usr/bin/python3 %s/svc/sys.py\n' "$SB" >"$SB/etc-systemd/sys.service"
  MM_TEST_SYSTEMD_SYSTEM="$SB/etc-systemd" mm_inuse_refresh >/dev/null 2>&1
  why "$HOME/jobs/b/dist"; [ "$status" -eq 0 ]; [ "$output" = "used by systemd unit report-b.service" ]
  why "$HOME/jobs/c/dist"; [ "$status" -eq 0 ]; [ "$output" = "used by systemd unit report-c.service" ]
  why "$HOME/jobs/x/dist"; [ "$status" -eq 1 ]
  run try_rm "$SB/svc"; [ "$output" = "1 used by systemd unit sys.service" ]
}

@test "shell startup files keep what their aliases, sourced files and PATH exports name" {
  mkdir -p "$HOME/.local/share/claude/versions/1.0.50" "$HOME/.cargo" "$HOME/n/bin" "$HOME/n/lib/node_modules/codex/bin" \
    "$HOME/work" "$HOME/.config/fish" "$HOME/tools"
  echo 'x' >"$HOME/.local/share/claude/versions/1.0.50/claude"; echo 'x' >"$HOME/.cargo/env"
  echo 'x' >"$HOME/n/lib/node_modules/codex/bin/codex.js"; ln -s ../lib/node_modules/codex/bin/codex.js "$HOME/n/bin/codex"
  echo 'x' >"$HOME/tools/helper.fish"
  printf 'alias claude=~/.local/share/claude/versions/1.0.50/claude\nexport PATH="$HOME/n/bin:$PATH"\ncd ~/work\n' >"$HOME/.bashrc"
  printf '. "${HOME}/.cargo/env"\n' >"$HOME/.zshenv"
  printf 'source $HOME/tools/helper.fish\n' >"$HOME/.config/fish/config.fish"
  mm_inuse_refresh >/dev/null 2>&1
  why "$HOME/.local/share/claude/versions/1.0.50"; [ "$status" -eq 0 ]; [ "$output" = "used by ~/.bashrc" ]
  why "$HOME/.cargo";                               [ "$status" -eq 0 ]; [ "$output" = "used by ~/.zshenv" ]
  why "$HOME/tools";                                [ "$status" -eq 0 ]; [ "$output" = "used by ~/.config/fish/config.fish" ]
  why "$HOME/n/lib/node_modules";                   [ "$status" -eq 0 ]; [ "$output" = "used by ~/n/bin/codex" ]
  why "$HOME/work";                                 [ "$status" -eq 1 ]   # a folder named in a startup file keeps nothing
}
