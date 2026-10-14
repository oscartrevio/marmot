#!/usr/bin/env bats
# cmd/schedule.sh: the unattended profile (`mm schedule run`) in a sandbox home, its lock and
# summary, and enable/disable/status against fake systemctl, crontab and loginctl.

# The profile's busy checks see the whole machine (processes named after tools), and runs share
# nothing else: keep this file's tests sequential, like clean.bats.
setup_file() { export BATS_NO_PARALLELIZE_WITHIN_FILE=true; }

setup() {
  load helpers/common
  mm_test_setup
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  UNITS="$XDG_CONFIG_HOME/systemd/user"
  LAST="$XDG_STATE_HOME/marmot/last-run.json"
}
teardown() { mm_test_teardown; }

exist() { local p; for p; do [ -e "$p" ] || { echo "missing: $p"; return 1; }; done; }
gone() { local p; for p; do [ ! -e "$p" ] || { echo "still there: $p"; return 1; }; done; }
none() { if "$@"; then return 1; fi; }
needs_jq() { command -v jq >/dev/null || skip "jq not installed"; }

# rec NAME [BODY] — a double that appends "NAME <args>" to $CALLS, then runs BODY.
rec() { mm_test_fake "$1" "echo \"$1 \$*\" >>\"\$CALLS\"
${2:-}"; }

blob() { mkdir -p "$(dirname "$1")"; head -c 1100000 /dev/urandom >"$1"; }

# trash_item NAME DAYS_AGO — a Trash entry with a spec .trashinfo.
trash_item() {
  local t="$XDG_DATA_HOME/Trash"
  mkdir -p "$t/files" "$t/info"
  echo data >"$t/files/$1"
  printf '[Trash Info]\nPath=/somewhere/%s\nDeletionDate=%s\n' "$1" \
    "$(command date -d "$2 days ago" +%Y-%m-%dT%H:%M:%S)" >"$t/info/$1.trashinfo"
}

# profile_tools — every tool the profile may call, recorded: sudo says no (even to -n true), git
# is the real one, yarn 1 empties its cache, the other tool cleans find nothing to do. docker
# stays the fail-loud stub.
profile_tools() {
  local g; g=$(command -v git)
  rec sudo 'exit 1'
  rec git "exec '$g' \"\$@\""
  local t
  for t in npm pnpm bun uv go mise conda brew nix-collect-garbage; do rec "$t"; done
  rec yarn 'case "$*" in --version) echo 1.22.22 ;; "cache dir") echo "$SB/yarncache" ;;
  "cache clean") rm -rf "$SB/yarncache/"* ;; esac'
}

# profile_home — a home with something for every step of the profile, and things it must keep.
profile_home() {
  trash_item old31 31; trash_item new29 29
  mkdir -p "$HOME/.cache/pip/wheels"; echo w >"$HOME/.cache/pip/wheels/w.whl"   # catalog cache row
  blob "$SB/yarncache/blob"                                                  # a tool's own clean
  mkdir -p "$HOME/.cache/ms-playwright/chromium-1000" "$HOME/.cache/ms-playwright/chromium-1100"
  local v="$HOME/.local/share/claude/versions"
  mkdir -p "$v" "$HOME/.local/bin"
  echo 1 >"$v/1.0.0"; echo 2 >"$v/1.0.1"; echo 3 >"$v/1.0.2"
  ln -s "$v/1.0.2" "$HOME/.local/bin/claude"
  mkdir -p "$HOME/.omp/logs"; echo o >"$HOME/.omp/logs/omp.old.log"; echo n >"$HOME/.omp/logs/omp.new.log"
  mm_age "$HOME/.omp/logs/omp.old.log" 10
  mkdir -p "$HOME/.config/gcloud/logs/2026.01.01"; echo g >"$HOME/.config/gcloud/logs/2026.01.01/run.log"
  echo c >"$HOME/.config/gcloud/credentials.db"
  mm_age "$HOME/.config/gcloud/logs/2026.01.01" 10
  mkdir -p "$HOME/.vscode-server/cli/servers/Stable-a" "$HOME/.vscode-server/cli/servers/Stable-b"
  touch -d '20 days ago' "$HOME/.vscode-server/cli/servers/Stable-a"
  blob "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-x1/Default/Cache/data_1"
  mkdir -p "$HOME/.claude/projects/p1"; echo s >"$HOME/.claude/projects/p1/old.jsonl"
  mm_age "$HOME/.claude/projects" 90
  # projects: one idle 30 days (its node_modules goes), one active (kept)
  mkdir -p "$HOME/work/old/node_modules/x" "$HOME/work/new/node_modules/y"
  echo '{}' >"$HOME/work/old/package.json"; echo '{}' >"$HOME/work/new/package.json"
  blob "$HOME/work/old/node_modules/x/index.js"; echo y >"$HOME/work/new/node_modules/y/index.js"
  mm_age "$HOME/work/old" 30
  # a clean linked worktree nobody touched for 40 days: purge would offer it; the profile never
  git -C "$HOME/work" init -q -b main repo
  git -C "$HOME/work/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$HOME/work/repo" worktree add -q "$HOME/work/repo-wt" -b done
  mm_age "$HOME/work/repo-wt" 40; mm_age "$HOME/work/repo/.git" 40
  # browser leftovers are idle by ctime too, which cannot be faked: move "now" 3 hours ahead
  # (the 29-day Trash item stays under 30 days)
  mm_test_clock 0
  export MM_TEST_CLOCK_SHIFT=$((3 * 3600))
  : >"$CALLS"
}

@test "run: removes what the profile covers, keeps the rest, never prompts, sudo, docker or worktree remove" {
  profile_tools; profile_home
  # A terminal would make clean's Trash and session steps ask; setsid leaves no controlling
  # terminal, so an ask that slipped through declines and the items would stay.
  MM_TTY=1 run setsid -w mm schedule run
  [ "$status" -eq 0 ]
  gone "$XDG_DATA_HOME/Trash/files/old31" "$XDG_DATA_HOME/Trash/info/old31.trashinfo"
  exist "$XDG_DATA_HOME/Trash/files/new29"
  gone "$HOME/.cache/pip/wheels" "$SB/yarncache/blob" "$HOME/.cache/ms-playwright/chromium-1000"
  exist "$HOME/.cache/ms-playwright/chromium-1100"
  gone "$HOME/.local/share/claude/versions/1.0.0"
  exist "$HOME/.local/share/claude/versions/1.0.1" "$HOME/.local/share/claude/versions/1.0.2"
  gone "$HOME/.omp/logs/omp.old.log" "$HOME/.config/gcloud/logs/2026.01.01"
  exist "$HOME/.omp/logs/omp.new.log" "$HOME/.config/gcloud/credentials.db"
  gone "$HOME/.vscode-server/cli/servers/Stable-a" "$MM_TEST_TMP_ROOT/playwright_chromiumdev_profile-x1"
  exist "$HOME/.vscode-server/cli/servers/Stable-b"
  gone "$HOME/work/old/node_modules"
  exist "$HOME/work/new/node_modules/y/index.js" "$HOME/work/repo-wt"
  exist "$HOME/.claude/projects/p1/old.jsonl"                         # sessions: not configured
  grep -qx 'yarn cache clean' "$CALLS"
  none grep -E '^sudo ' "$CALLS"
  none grep -E '^git .*worktree (remove|prune)' "$CALLS"
  [[ "$output" != *"[y/N]"* ]]
}

@test "run: writes last-run.json with totals, skips with reasons and errors; logs under 'schedule'" {
  needs_jq
  profile_tools; profile_home
  run mm schedule run
  [ "$status" -eq 0 ]
  jq -e . "$LAST" >/dev/null
  [ "$(jq -r '.trigger' "$LAST")" = manual ]
  [ "$(jq -r '.freed_bytes > 1000000 and .items >= 8 and .duration_seconds >= 0' "$LAST")" = true ]
  [ "$(jq -r '.errors | length' "$LAST")" = 0 ]
  jq -e '.skipped | map(select(.step == "Agent sessions" and (.reason | test("sessions_keep_days")))) | length == 1' "$LAST"
  [ "$(jq -r '.started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$LAST")" = true ]
  [ "$(awk -F'\t' '$3 == "remove" { print $2 }' "$XDG_STATE_HOME/marmot/operations.log" | sort -u)" = schedule ]
}

@test "run --dry-run changes nothing, writes no summary, and frees what the real run then frees" {
  profile_tools; profile_home
  run mm schedule run --dry-run
  [ "$status" -eq 0 ]
  exist "$XDG_DATA_HOME/Trash/files/old31" "$HOME/.cache/pip/wheels/w.whl" "$HOME/work/old/node_modules"
  gone "$LAST" "$XDG_STATE_HOME/marmot/operations.log"
  none grep -qx 'yarn cache clean' "$CALLS"
  local would; would=$(grep -oE 'Would free: [^|]+' <<<"$output")
  run mm schedule run
  [ "$status" -eq 0 ]
  [ "${would#Would free: }" = "$(grep -oE 'Space freed: [^|]+' <<<"$output" | sed 's/^Space freed: //')" ]
}

@test "run: agent sessions move to the Trash only when sessions_keep_days is configured" {
  profile_tools
  mkdir -p "$HOME/.claude/projects/p1"; echo s >"$HOME/.claude/projects/p1/old.jsonl"
  echo '{}' >"$HOME/.claude/.credentials.json"
  mm_age "$HOME/.claude" 90
  run mm schedule run
  exist "$HOME/.claude/projects/p1/old.jsonl"
  mkdir -p "$XDG_CONFIG_HOME/marmot"; echo 'sessions_keep_days = 30' >"$XDG_CONFIG_HOME/marmot/config"
  MM_TTY=1 run setsid -w mm schedule run
  [ "$status" -eq 0 ]
  gone "$HOME/.claude/projects/p1/old.jsonl"
  exist "$XDG_DATA_HOME/Trash/files/old.jsonl" "$HOME/.claude/.credentials.json"
}

@test "run: a second run while one holds the lock is refused and changes nothing" {
  profile_tools
  trash_item old31 31
  mkdir -p "$XDG_STATE_HOME/marmot"
  exec 9>>"$XDG_STATE_HOME/marmot/schedule.lock"
  flock -n 9
  run mm schedule run
  exec 9>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"another scheduled run"* ]]
  exist "$XDG_DATA_HOME/Trash/files/old31"
  gone "$LAST"
  run mm schedule run          # lock released: runs
  [ "$status" -eq 0 ]
  gone "$XDG_DATA_HOME/Trash/files/old31"
}

# ---------------------------------------------------------------- enable, disable, status

# fake_systemd [LINGER] — a user systemd that answers; loginctl reports LINGER (default no).
fake_systemd() {
  rec systemctl 'case "$*" in
  "--user show-environment") exit 0 ;;
  "--user is-enabled marmot-schedule.timer") echo enabled ;;
  "--user show marmot-schedule.timer -p NextElapseUSecRealtime --value") echo "Thu 2026-10-15 03:41:07 UTC" ;;
esac
exit 0'
  rec loginctl "echo Linger=${1:-no}"
}

# fake_cron — crontab backed by $SB/crontab ("no crontab" while it does not exist).
fake_cron() {
  rec crontab 'f="$SB/crontab"
case "$1" in
  -l) [[ -f "$f" ]] || { echo "no crontab for $(id -un)" >&2; exit 1; }; cat "$f" ;;
  -) cat >"$f" ;;
  *) exit 2 ;;
esac'
}

@test "enable: a systemd user timer (Persistent, randomized) when systemctl --user works; linger warning" {
  fake_systemd no; fake_cron
  run mm schedule enable
  [ "$status" -eq 0 ]
  grep -qx 'Persistent=true' "$UNITS/marmot-schedule.timer"
  grep -qE '^RandomizedDelaySec=.+' "$UNITS/marmot-schedule.timer"
  grep -qx 'OnCalendar=\*-\*-\* 03:00:00' "$UNITS/marmot-schedule.timer"
  grep -qx "ExecStart=$MM_SRC/marmot schedule run" "$UNITS/marmot-schedule.service"
  grep -qx 'Environment=MM_SCHEDULE_TRIGGER=systemd' "$UNITS/marmot-schedule.service"
  grep -qx 'systemctl --user daemon-reload' "$CALLS"
  grep -qx 'systemctl --user enable --now marmot-schedule.timer' "$CALLS"
  none grep -qx 'crontab -' "$CALLS"
  [[ "$output" == *"next run Thu 2026-10-15 03:41:07 UTC"* ]]
  [[ "$output" == *"sudo loginctl enable-linger $(id -un)"* ]]
  run mm schedule enable --weekly          # again: replaces its own units
  [ "$status" -eq 0 ]
  grep -qx 'OnCalendar=Sun \*-\*-\* 03:00:00' "$UNITS/marmot-schedule.timer"
}

@test "enable: linger on means no warning; a unit file marmot did not write is left alone" {
  fake_systemd yes; fake_cron
  run mm schedule enable
  [[ "$output" != *"enable-linger"* ]]
  run mm schedule disable
  mkdir -p "$UNITS"; printf '[Timer]\nOnCalendar=hourly\n' >"$UNITS/marmot-schedule.timer"
  run mm schedule enable
  [ "$status" -ne 0 ]
  [ "$(cat "$UNITS/marmot-schedule.timer")" = $'[Timer]\nOnCalendar=hourly' ]
}

@test "disable removes only what enable created" {
  fake_systemd; fake_cron
  mkdir -p "$UNITS"; echo '[Timer]' >"$UNITS/other.timer"
  run mm schedule enable
  : >"$CALLS"
  run mm schedule disable
  [ "$status" -eq 0 ]
  gone "$UNITS/marmot-schedule.timer" "$UNITS/marmot-schedule.service" "$XDG_STATE_HOME/marmot/schedule"
  exist "$UNITS/other.timer"
  grep -qx 'systemctl --user disable --now marmot-schedule.timer' "$CALLS"
  run mm schedule disable
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing scheduled"* ]]
}

@test "cron fallback: a tagged crontab line, kept apart from the user's own lines" {
  rec systemctl 'echo "Failed to connect to bus" >&2; exit 1'
  fake_cron
  printf '0 1 * * * /usr/local/bin/backup\n' >"$SB/crontab"
  run mm schedule enable --weekly
  [ "$status" -eq 0 ]
  [ "$(grep -c '# marmot$' "$SB/crontab")" = 1 ]
  grep -qE "^[0-9]+ 3 \* \* 0 PATH=[^ ]+ MM_SCHEDULE_TRIGGER=cron $MM_SRC/marmot schedule run >/dev/null 2>&1 # marmot\$" "$SB/crontab"
  grep -qx '0 1 \* \* \* /usr/local/bin/backup' "$SB/crontab"
  [[ "$output" == *"crontab line"*"weekly"* ]]
  run mm schedule enable                   # again: still one line, now daily
  [ "$(grep -c '# marmot$' "$SB/crontab")" = 1 ]
  grep -qE '^[0-9]+ 3 \* \* \* PATH=' "$SB/crontab"
  run mm schedule disable
  [ "$status" -eq 0 ]
  [ "$(cat "$SB/crontab")" = '0 1 * * * /usr/local/bin/backup' ]
}

@test "without systemd or cron, enable explains what to do and changes nothing" {
  rec systemctl 'exit 1'
  local d f
  mkdir -p "$SB/bin"
  for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do [[ "${f##*/}" == crontab || -e "$SB/bin/${f##*/}" ]] || ln -s "$f" "$SB/bin/${f##*/}"; done
  done
  PATH="$BATS_TEST_TMPDIR/stubs:$SB/bin" run mm schedule enable
  [ "$status" -ne 0 ]
  [[ "$output" == *"crontab is not installed"* ]]
  [[ "$output" == *"schedule run"* ]]
  gone "$UNITS" "$XDG_STATE_HOME/marmot/schedule"
}

@test "enable --dry-run writes nothing and enables nothing" {
  fake_systemd; fake_cron
  run mm schedule enable --dry-run
  [ "$status" -eq 0 ]
  gone "$UNITS" "$XDG_STATE_HOME/marmot/schedule"
  none grep -E 'daemon-reload|enable --now' "$CALLS"
}

@test "status: not scheduled says how to enable; after a run it shows the last run" {
  rec systemctl 'exit 1'; fake_cron
  run mm schedule status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not scheduled"*"mm schedule enable"* ]]
  [[ "$output" == *"Last run: none yet"* ]]
  profile_tools
  trash_item old31 31
  run mm schedule run
  run mm schedule
  [[ "$output" == *"Last run: "*"(0m ago, manual)"*"freed "* ]]
}

@test "schedule rejects unknown subcommands and options" {
  run mm schedule nope
  [ "$status" -ne 0 ]
  run mm schedule run --weekly
  [ "$status" -ne 0 ]
  run mm schedule enable --hourly
  [ "$status" -ne 0 ]
}
