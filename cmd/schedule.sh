# shellcheck shell=bash
# mm schedule [status | enable [--daily|--weekly] | disable | run] — marmot's cleanup on a timer.
#
# `run` is the unattended profile: one process, no terminal, no prompts, no sudo. It does only
# what is safe with nobody watching, reusing mm clean's and mm purge's steps:
#   - Trash items deleted more than trash_keep_days days ago (only when set in the config file),
#     and thumbnails
#   - regenerable caches: catalog cache rows and the tools' own cleans (npm, pnpm, uv, Go, ...),
#     cache folders of agent browser profiles, gcloud/Azure CLI logs older than 7 days
#   - old browser and test-runner builds (newest kept), old coding-agent CLI versions
#   - agent log files older than 7 days
#   - agent sessions, only when sessions_keep_days is set in the config file
#   - the Trash sweep and session retention above are the only steps that touch personal files,
#     and both run only when their config key opts in
#   - automation-browser leftovers in /tmp, idle 2+ hours
#   - old editor server builds and their leftovers
#   - build artifacts of projects idle 14+ days (what `mm purge --yes` removes)
# Never: anything that needs sudo (apt, kernels, journal, snaps, system logs, crash dumps), Docker,
# git worktrees, uninstalls, and mm optimize's process kills and upgrades. A lock keeps two runs
# from overlapping; each real run leaves its summary in last-run.json (lib/schedule.sh).

# shellcheck source=../lib/schedule.sh
. "$MM_HOME/lib/schedule.sh"
# shellcheck source=clean.sh
. "$MM_HOME/cmd/clean.sh"
# shellcheck source=purge.sh
. "$MM_HOME/cmd/purge.sh"

_SCHEDULE_PURGE_DAYS=14   # build artifacts of projects idle longer than this are removed

_schedule_usage() {
  cat <<EOF
Usage: mm schedule [status | enable [--daily | --weekly] | disable | run] [--dry-run]

Runs a safe part of marmot's cleanup on a timer, with nobody at the terminal.

  status    what is scheduled, the next and the last run (default)
  enable    schedule it daily (default) or weekly: a systemd user timer when \`systemctl --user\`
            works (catches up on missed runs at boot), else a crontab line tagged "$MM_SCHEDULE_CRON_TAG";
            runs get this shell's PATH and folders (XDG_CONFIG_HOME, XDG_STATE_HOME, XDG_DATA_HOME,
            XDG_CACHE_HOME, MM_CONFIG_DIR, ...), so they read the same whitelist and config
  disable   remove only what enable created
  run       the scheduled cleanup itself, now

What a run cleans: thumbnails, regenerable caches (lib/catalog.sh cache rows and the tools' own
cleans: npm, pnpm, yarn, bun, uv, Go, mise, conda, Homebrew), old browser/test-runner builds and
old coding-agent CLI versions, agent and gcloud/Azure CLI logs older than 7 days,
automation-browser leftovers in /tmp, old editor server builds and their leftovers, and build
artifacts of projects idle $_SCHEDULE_PURGE_DAYS+ days (like mm purge --yes). Personal files only with your
opt-in in $MM_CONFIG_FILE: Trash items trashed more than
trash_keep_days days ago, and agent sessions older than sessions_keep_days days.
Never: anything that needs sudo (apt, kernels, journal, snaps, system logs, crash dumps), Docker,
git worktrees, uninstalls, process kills or upgrades. It never asks and never runs sudo.

Each real run writes its summary to $MM_SCHEDULE_LAST (mm status shows
it) and logs its changes under "schedule" (mm history). Two runs never overlap.
EOF
}

# ---------------------------------------------------------------- run

# _schedule_lock — hold an exclusive lock on the state dir's schedule.lock until this process
# ends; fails (saying so) while another run holds it.
_schedule_lock() {
  local f="$MM_STATE_DIR/schedule.lock"
  command -v flock >/dev/null || { mm_err "flock (util-linux) is needed to keep runs from overlapping"; return 1; }
  mkdir -p "$MM_STATE_DIR" 2>/dev/null
  if ! exec {_SCHEDULE_LOCK_FD}>>"$f"; then mm_err "cannot open $f"; return 1; fi
  if ! flock -n "$_SCHEDULE_LOCK_FD"; then
    mm_err "another scheduled run is still going (lock held on $f): not starting a second one"
    return 1
  fi
}

# _schedule_json_str S — S as a JSON string literal.
_schedule_json_str() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"} s=${s//$'\t'/\\t} s=${s//$'\n'/\\n} s=${s//$'\r'/\\r}
  printf '"%s"' "${s//[[:cntrl:]]/?}"
}

# _schedule_record START_ISO START_EPOCH FREED TRASHED ITEMS — write last-run.json (replaced in
# one rename) from this run's totals, MM_SKIPS and MM_ERRORS.
_schedule_record() {
  local now tmp e sep trigger=${MM_SCHEDULE_TRIGGER:-manual}
  [[ "$trigger" == systemd || "$trigger" == cron ]] || trigger=manual
  now=$(date +%s)
  mkdir -p "$MM_STATE_DIR" 2>/dev/null
  if ! tmp=$(mktemp "$MM_STATE_DIR/.last-run.XXXXXX"); then mm_err "cannot write $MM_SCHEDULE_LAST"; return 1; fi
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "started_at": %s,\n' "$(_schedule_json_str "$1")"
    printf '  "finished_at": %s,\n' "$(_schedule_json_str "$(date -Iseconds)")"
    printf '  "finished_epoch": %s,\n' "$now"
    printf '  "duration_seconds": %s,\n' "$(( now > $2 ? now - $2 : 0 ))"
    printf '  "trigger": "%s",\n' "$trigger"
    printf '  "freed_bytes": %s,\n' "$3"
    printf '  "trashed_bytes": %s,\n' "$4"
    printf '  "items": %s,\n' "$5"
    printf '  "skipped": ['
    sep=$'\n'
    for e in "${MM_SKIPS[@]}"; do
      printf '%s    {"step": %s, "reason": %s}' "$sep" "$(_schedule_json_str "${e%%$'\t'*}")" "$(_schedule_json_str "${e#*$'\t'}")"
      sep=$',\n'
    done
    (( ${#MM_SKIPS[@]} )) && printf '\n  '
    printf '],\n'
    printf '  "errors": ['
    sep=$'\n'
    for e in "${MM_ERRORS[@]}"; do printf '%s    %s' "$sep" "$(_schedule_json_str "$e")"; sep=$',\n'; done
    (( ${#MM_ERRORS[@]} )) && printf '\n  '
    printf ']\n}\n'
  } >"$tmp" && mv -f -- "$tmp" "$MM_SCHEDULE_LAST"
}

# _schedule_abort — EXIT trap of a real run: a run that dies part way (mm_die) still leaves a
# summary saying so.
_schedule_abort() {
  [[ -n "${_SCHEDULE_STARTED:-}" ]] || return 0
  MM_ERRORS+=("the run stopped before it finished")
  _schedule_record "$_SCHEDULE_STARTED" "$_SCHEDULE_T0" "$((MM_FREED + _CLEAN_TOOL_BYTES + _PURGE_STORE_BYTES))" \
    "$MM_TRASHED" "$((MM_COUNT + _CLEAN_TOOL_ITEMS))"
}

# _schedule_trash_days — 0 with _SCHEDULE_TRASH_KEEP set when the config file turns the scheduled
# Trash sweep on (trash_keep_days=N, N >= 1); 1 when it is unset or off (a value that is not a
# number of days is ignored with a warning). The Trash holds what people deliberately set aside,
# so an unattended run deletes there only with this opt-in; mm clean asks instead.
_schedule_trash_days() {
  local v
  _SCHEDULE_TRASH_KEEP=""
  v=$(mm_config trash_keep_days) || return 1
  if [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v >= 1 )); then _SCHEDULE_TRASH_KEEP=$((10#$v)); return 0; fi
  [[ -n "$v" && "$v" != 0 && "$v" != off ]] && mm_warn "ignoring trash_keep_days=$v in $MM_CONFIG_FILE: not a number of days"
  return 1
}

_schedule_run() {
  # No prompts and no sudo, whoever started the run: every confirmation declines, every picker
  # selects nothing, and steps that need root report "needs sudo".
  MM_TTY=0 MM_NO_SUDO=1
  if [[ "$MM_DRY_RUN" != 1 ]]; then
    _schedule_lock || return 1
    _SCHEDULE_STARTED=$(date -Iseconds) _SCHEDULE_T0=$(date +%s)
    trap '_schedule_abort' EXIT
  fi
  mm_header "Scheduled cleanup"
  mm_catalog_load
  mm_inuse_refresh
  local free0 free1 total items delta sign=+
  free0=$(mm_free_bytes /)

  if _schedule_trash_days; then
    _clean_user --yes "$_SCHEDULE_TRASH_KEEP"
  else
    _clean_cat "User essentials"
    mm_tilde "$MM_CONFIG_FILE"
    mm_skip "Trash" "kept: no trash_keep_days in $REPLY"
    _clean_contents "Thumbnails" "$(mm_catalog_expand %CACHE%/thumbnails)"
    _clean_cat_end
  fi
  _clean_dev
  _clean_builds
  _clean_agent_logs
  if _clean_config_sessions; then
    _clean_sessions "$_CLEAN_KEEP_DAYS" config
  else
    mm_section "Agent sessions"
    mm_tilde "$MM_CONFIG_FILE"
    mm_skip "Agent sessions" "kept: no sessions_keep_days in $REPLY"
  fi
  _clean_browsers
  _clean_editors
  _purge_run scheduled "$_SCHEDULE_PURGE_DAYS"

  total=$((MM_FREED + _CLEAN_TOOL_BYTES + _PURGE_STORE_BYTES)) items=$((MM_COUNT + _CLEAN_TOOL_ITEMS))
  free1=$(mm_free_bytes /)
  local trash="" notes="Skipped: ${#MM_SKIPS[@]} | Errors: ${#MM_ERRORS[@]}"
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    (( MM_TRASHED )) && trash=" | Would move to Trash: $(mm_human "$MM_TRASHED")"
    mm_banner "Dry run complete" \
      "Would free: $(mm_human "$total")$trash | Items: $items" \
      "$notes" \
      "Run without --dry-run to apply."
    return 0
  fi
  (( MM_TRASHED )) && trash=" | Moved to Trash: $(mm_human "$MM_TRASHED") (restore: trash-restore)"
  delta=$((free1 - free0)); (( delta < 0 )) && { sign=-; delta=$((-delta)); }
  trap - EXIT
  _schedule_record "$_SCHEDULE_STARTED" "$_SCHEDULE_T0" "$total" "$MM_TRASHED" "$items"
  mm_tilde "$MM_SCHEDULE_LAST"
  mm_banner "Scheduled cleanup complete" \
    "Space freed: $(mm_human "$total")$trash | Items: $items" \
    "$notes" \
    "Free space: $(mm_human "$free1") ($sign$(mm_human "$delta")) | Summary: $REPLY"
}

# ---------------------------------------------------------------- enable, disable, status

_SCHEDULE_HOUR=3          # runs start at 03:00 local time, plus a random delay
_SCHEDULE_DELAY=1h        # systemd RandomizedDelaySec: many machines do not all start at once

_SCHEDULE_SD=""          # 1 or 0 once _schedule_systemd_ok has asked
_SCHEDULE_SD_ENV=""      # systemd's user environment, "NAME=VALUE" lines: what a unit starts with

# _schedule_systemd_ok — 0 when this user's systemd instance answers (`systemctl --user`); asks
# once. Its environment goes to _SCHEDULE_SD_ENV, and MM_SCHEDULE_UNIT_DIR follows its
# XDG_CONFIG_HOME: systemd looks for user units there, whatever this shell sets.
_schedule_systemd_ok() {
  local d
  if [[ -z "$_SCHEDULE_SD" ]]; then
    _SCHEDULE_SD=0
    if command -v systemctl >/dev/null && _SCHEDULE_SD_ENV=$(timeout 10 systemctl --user show-environment 2>/dev/null); then
      _SCHEDULE_SD=1
      d=$(_schedule_env_get XDG_CONFIG_HOME "$_SCHEDULE_SD_ENV")
      [[ "$d" == /* ]] || d="$HOME/.config"
      MM_SCHEDULE_UNIT_DIR="$d/systemd/user"
    fi
  fi
  (( _SCHEDULE_SD ))
}

# _schedule_env_get NAME ENV — NAME's value in ENV ("NAME=VALUE" lines, the last one counts);
# empty when ENV does not set it.
_schedule_env_get() { awk -v k="$1=" 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { printf "%s", v }' <<<"$2"; }

# _schedule_plain S — 0 if S is a path a unit file or crontab line can carry unquoted.
_schedule_plain() { [[ "$1" =~ ^/[A-Za-z0-9/._+-]*$ ]]; }

# _schedule_path — the PATH scheduled runs get: this shell's absolute, existing folders that
# _schedule_plain accepts, once each, then the system folders. Tools found only through the
# user's PATH (nvm, ~/.local/bin, Homebrew) are then cleaned too.
_schedule_path() {
  local d out="" IFS=:
  local -a parts
  read -r -a parts <<<"$PATH:/usr/local/bin:/usr/bin:/bin"
  for d in "${parts[@]}"; do
    _schedule_plain "$d" && [[ -d "$d" && ":$out:" != *":$d:"* ]] && out+="${out:+:}$d"
  done
  printf '%s' "$out"
}

# The variables that place marmot's whitelist, config, purge_paths, state and log, the Trash and
# the caches (lib/core.sh, cmd/purge.sh). A scheduled run must see the same values as the shell
# that ran enable, or it keeps a whitelist the user never wrote.
_SCHEDULE_DIR_VARS=(XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME MM_CONFIG_DIR MM_STATE_DIR
  MM_CONFIG_FILE MM_WHITELIST_FILE MM_PURGE_PATHS_FILE MM_LOG_FILE)

# _schedule_dir NAME VALUE — the folder VALUE (NAME's value in some environment, empty when
# unset) stands for: an unset XDG variable means its default.
_schedule_dir() {
  local v=$2
  if [[ -z "$v" ]]; then
    case "$1" in
      XDG_CONFIG_HOME) v="$HOME/.config" ;;
      XDG_STATE_HOME) v="$HOME/.local/state" ;;
      XDG_DATA_HOME) v="$HOME/.local/share" ;;
      XDG_CACHE_HOME) v="$HOME/.cache" ;;
    esac
  fi
  printf '%s' "$v"
}

# _schedule_pins ENV — "NAME=VALUE" for each of _SCHEDULE_DIR_VARS that a scheduled run starting
# with ENV ("NAME=VALUE" lines) would see differently from this shell, VALUE being this shell's.
_schedule_pins() {
  local n mine
  for n in "${_SCHEDULE_DIR_VARS[@]}"; do
    # lib/core.sh fills in the MM_ ones: only exported ones came from this shell's environment.
    mine=""
    [[ "$n" == XDG_* || "${!n@a}" == *x* ]] && mine=${!n:-}
    [[ "$(_schedule_dir "$n" "$mine")" == "$(_schedule_dir "$n" "$(_schedule_env_get "$n" "$1")")" ]] && continue
    printf '%s=%s\n' "$n" "$(_schedule_dir "$n" "${!n:-}")"
  done
}

# _schedule_pins_check PINS — stop at the first of PINS ("NAME=VALUE" lines) whose value a unit
# file or crontab line cannot carry: without it a scheduled run would read other folders.
_schedule_pins_check() {
  local n v
  while IFS='=' read -r n v; do
    [[ -z "$n" ]] || _schedule_plain "$v" ||
      mm_die "$n is \"$v\" here, which a unit file or crontab line cannot carry, and without it scheduled runs would use another whitelist, config and Trash. Set it to an absolute path of letters, digits and / . _ + - and run mm schedule enable again."
  done <<<"$1"
}

# _schedule_drift ENV — warn about each folder variable a scheduled run starting with ENV
# ("NAME=VALUE" lines, the unit's or crontab line's own settings last) sees differently from this
# shell.
_schedule_drift() {
  local n v run
  while IFS='=' read -r n v; do
    [[ -n "$n" ]] || continue
    run=$(_schedule_dir "$n" "$(_schedule_env_get "$n" "$1")")
    mm_warn "Scheduled runs use $n=${run:-(unset)}, this shell $n=$v: run mm schedule enable here to give them this shell's folders"
  done < <(_schedule_pins "$1")
}

# _schedule_cron_env CRONTAB — "NAME=VALUE" for the variable settings in CRONTAB, which cron gives
# the jobs after them (crontab(5): blanks around name and value dropped, one pair of quotes too).
_schedule_cron_env() {
  printf '%s\n' "$1" | awk '/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {
    i = index($0, "="); k = substr($0, 1, i - 1); v = substr($0, i + 1)
    gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
    print k "=" v
  }'
}

# _schedule_ours FILE — 0 if FILE is a regular file whose first line is MM_SCHEDULE_MARK.
_schedule_ours() {
  local first=""
  [[ -f "$1" && ! -L "$1" ]] || return 1
  IFS= read -r first <"$1"
  [[ "$first" == "$MM_SCHEDULE_MARK" ]]
}

# _schedule_crontab — read the current crontab into _SCHEDULE_CRONTAB, byte for byte (empty when the
# user has none); 1 if it cannot be read.
_schedule_crontab() {
  local out rc=0
  # The dot keeps the trailing newlines $(...) would strip.
  out=$(crontab -l 2>/dev/null; rc=$?; printf .; exit "$rc") || rc=$?
  if (( rc )); then [[ "$(crontab -l 2>&1 >/dev/null)" == *"no crontab"* ]] || return 1; out=.; fi
  _SCHEDULE_CRONTAB=${out%.}
}

# _SCHEDULE_CRON_RE — the crontab line enable writes, in every version: five time fields, PATH and
# the folder variables, the trigger, marmot's path, MM_SCHEDULE_CRON_TAG. A line of the user's
# that merely ends in the tag does not match.
_SCHEDULE_CRON_RE="^([^ ]+ ){5}PATH=[^ ]+( [A-Za-z_][A-Za-z0-9_]*=[^ ]+)* MM_SCHEDULE_TRIGGER=cron /[^ ]+ schedule run >/dev/null 2>&1 $MM_SCHEDULE_CRON_TAG\$"

# _schedule_cron_lines — the crontab lines enable added.
_schedule_cron_lines() { _schedule_crontab && printf '%s' "$_SCHEDULE_CRONTAB" | grep -E "$_SCHEDULE_CRON_RE"; }

# _schedule_cron_others — _SCHEDULE_CRONTAB without the lines enable added, into
# _SCHEDULE_CRON_KEEP: every other line byte for byte (a last line without a newline gets one,
# which crontab requires).
_schedule_cron_others() {
  local out
  out=$(printf '%s' "$_SCHEDULE_CRONTAB" | grep -vE "$_SCHEDULE_CRON_RE"; printf .)
  _SCHEDULE_CRON_KEEP=${out%.}
}

# _schedule_cron_set CONTENT DESCRIPTION — install CONTENT as the crontab (through mm_run).
_schedule_cron_set() { mm_run "$2" crontab - < <(printf '%s' "$1"); }

# _schedule_cron_remove — drop the lines enable added from the crontab; with none there the crontab
# is not rewritten.
_schedule_cron_remove() {
  _schedule_crontab || { mm_err "cannot read your crontab"; return 1; }
  grep -qE "$_SCHEDULE_CRON_RE" <<<"$_SCHEDULE_CRONTAB" || return 0
  _schedule_cron_others
  _schedule_cron_set "$_SCHEDULE_CRON_KEEP" "remove marmot's crontab line"
}

# _schedule_units_remove — stop and remove the units enable wrote (only files carrying the mark).
_schedule_units_remove() {
  local svc="$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.service" tim="$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.timer"
  local want="$MM_SCHEDULE_UNIT_DIR/timers.target.wants/$MM_SCHEDULE_UNIT.timer" sd=0
  _schedule_ours "$tim" || _schedule_ours "$svc" || return 0
  _schedule_systemd_ok && sd=1
  (( sd )) && mm_run "systemctl --user disable --now $MM_SCHEDULE_UNIT.timer" systemctl --user disable --now "$MM_SCHEDULE_UNIT.timer"
  [[ "$MM_DRY_RUN" == 1 ]] && return 0
  # Without a reachable systemd, the enable link is removed by hand (only if it points at ours).
  [[ -L "$want" && "$(readlink -- "$want")" == "$tim" ]] && rm -f -- "$want" # SAFE: the enable link of marmot's own timer, checked just above
  _schedule_ours "$tim" && rm -f -- "$tim" # SAFE: the timer unit mm schedule enable wrote (mark checked)
  _schedule_ours "$svc" && rm -f -- "$svc" # SAFE: the service unit mm schedule enable wrote (mark checked)
  (( sd )) && mm_run "systemctl --user daemon-reload" systemctl --user daemon-reload
  return 0
}

# _schedule_write FILE CONTENT — write a unit file (replaced in one rename).
_schedule_write() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  printf '%s' "$2" >"$tmp" && mv -f -- "$tmp" "$1"
}

# _schedule_enable FREQ — install the systemd user timer (else the crontab line) that runs `mm
# schedule run` daily or weekly, with this shell's PATH and folder variables (_schedule_pins).
_schedule_enable() {
  local freq=$1 exe="$MM_HOME/marmot" path cal dow svc tim f line min pins p env=""
  _schedule_plain "$exe" || mm_die "marmot's path ($exe) has characters a unit file or crontab line cannot carry: install it with ./install.sh"
  path=$(_schedule_path)
  if _schedule_systemd_ok; then
    pins=$(_schedule_pins "$_SCHEDULE_SD_ENV")
    _schedule_pins_check "$pins"
    while IFS= read -r p; do [[ -n "$p" ]] && env+="Environment=$p"$'\n'; done <<<"$pins"
    cal="*-*-* $(printf '%02d' "$_SCHEDULE_HOUR"):00:00"; [[ "$freq" == weekly ]] && cal="Sun $cal"
    svc="$MM_SCHEDULE_MARK
[Unit]
Description=marmot scheduled cleanup (mm schedule run)

[Service]
Type=oneshot
Environment=PATH=$path
${env}Environment=MM_SCHEDULE_TRIGGER=systemd
ExecStart=$exe schedule run
Nice=19
IOSchedulingClass=idle
"
    tim="$MM_SCHEDULE_MARK
[Unit]
Description=Run marmot's scheduled cleanup $freq

[Timer]
OnCalendar=$cal
RandomizedDelaySec=$_SCHEDULE_DELAY
Persistent=true

[Install]
WantedBy=timers.target
"
    for f in service timer; do
      f="$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.$f"
      if [[ -e "$f" || -L "$f" ]] && ! _schedule_ours "$f"; then
        mm_die "$f exists and was not written by marmot: leaving it alone"
      fi
    done
    if [[ "$MM_DRY_RUN" == 1 ]]; then
      mm_info "Would write $MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.service and .timer ($freq at $(printf '%02d' "$_SCHEDULE_HOUR"):00 + up to $_SCHEDULE_DELAY) and enable the timer."
      return 0
    fi
    mkdir -p "$MM_SCHEDULE_UNIT_DIR" || mm_die "cannot create $MM_SCHEDULE_UNIT_DIR"
    if ! { _schedule_write "$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.service" "$svc" &&
      _schedule_write "$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.timer" "$tim"; }; then
      mm_die "cannot write the unit files in $MM_SCHEDULE_UNIT_DIR"
    fi
    if ! { mm_run "systemctl --user daemon-reload" systemctl --user daemon-reload &&
      mm_run "systemctl --user enable --now $MM_SCHEDULE_UNIT.timer" systemctl --user enable --now "$MM_SCHEDULE_UNIT.timer"; }; then
      mm_die "could not enable $MM_SCHEDULE_UNIT.timer"
    fi
    command -v crontab >/dev/null && _schedule_cron_remove   # a cron schedule from before is replaced
    _schedule_note systemd "$freq"
  elif command -v crontab >/dev/null; then
    _schedule_crontab || mm_die "cannot read your crontab (crontab -l)"
    _schedule_cron_others
    # The new line goes last: every variable setting in the crontab applies to it.
    pins=$(_schedule_pins "$(_schedule_cron_env "$_SCHEDULE_CRON_KEEP")")
    _schedule_pins_check "$pins"
    min=$((RANDOM % 60)) dow='*'; [[ "$freq" == weekly ]] && dow=0
    line="$min $_SCHEDULE_HOUR * * $dow PATH=$path${pins:+ ${pins//$'\n'/ }} MM_SCHEDULE_TRIGGER=cron $exe schedule run >/dev/null 2>&1 $MM_SCHEDULE_CRON_TAG"
    if [[ "$MM_DRY_RUN" == 1 ]]; then mm_info "Would add to your crontab: $line"; return 0; fi
    _schedule_cron_set "$_SCHEDULE_CRON_KEEP$line"$'\n' "add marmot's crontab line" || mm_die "could not install the crontab line"
    _schedule_note cron "$freq"
  else
    mm_err "Cannot schedule: \`systemctl --user\` does not answer here and crontab is not installed."
    mm_info "On a machine with systemd, log in again (or run: sudo loginctl enable-linger $(id -un)) so your user"
    mm_info "manager runs; elsewhere install cron (sudo apt-get install cron) and run mm schedule enable again."
    mm_info "Or have your own scheduler run: $exe schedule run"
    return 1
  fi
  _schedule_status
}

# _schedule_note BACKEND FREQ — record what enable installed (read by mm status).
_schedule_note() { mkdir -p "$MM_STATE_DIR" && printf '%s %s\n' "$1" "$2" >"$MM_SCHEDULE_NOTE"; }

_schedule_disable() {
  local any=0 what=removed
  [[ "$MM_DRY_RUN" == 1 ]] && what="would be removed"
  if _schedule_ours "$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.timer" || _schedule_ours "$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.service"; then
    any=1
    _schedule_units_remove
    mm_ok "systemd user timer" "$what"
  fi
  if command -v crontab >/dev/null && [[ -n "$(_schedule_cron_lines)" ]]; then
    any=1
    [[ "$MM_DRY_RUN" == 1 ]] || _schedule_cron_remove
    mm_ok "crontab line" "$what"
  fi
  [[ "$MM_DRY_RUN" == 1 ]] || rm -f -- "$MM_SCHEDULE_NOTE" # SAFE: marmot's own note of what enable installed
  (( any )) || mm_ok "Nothing scheduled" "nothing to remove"
  return 0
}

# _schedule_linger — "yes", "no" or "" (unknown) for this user's systemd linger setting.
_schedule_linger() {
  command -v loginctl >/dev/null || return 0
  local v
  v=$(timeout 10 loginctl show-user "$(id -un)" -p Linger 2>/dev/null) || return 0
  v=${v#Linger=}
  [[ "$v" == yes || "$v" == no ]] && printf '%s' "$v"
  return 0
}

# _schedule_status — what is scheduled, whether its runs see this shell's folders, the last run.
_schedule_status() {
  local svc="$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.service" tim="$MM_SCHEDULE_UNIT_DIR/$MM_SCHEDULE_UNIT.timer"
  local any=0 state next cal line linger when
  local -a f
  mm_section "Scheduled cleanup"
  if _schedule_ours "$tim"; then
    any=1
    cal=$(awk -F= '$1 == "OnCalendar" { print $2; exit }' "$tim")
    if _schedule_systemd_ok; then
      state=$(timeout 10 systemctl --user is-enabled "$MM_SCHEDULE_UNIT.timer" 2>/dev/null)
      next=$(timeout 10 systemctl --user show "$MM_SCHEDULE_UNIT.timer" -p NextElapseUSecRealtime --value 2>/dev/null)
      # systemd prints "Wed 2026-10-22 03:27:00 UTC" (or "n/a"): said as "in 9h (03:27)"
      if [[ -n "$next" ]] && when=$(date -d "$next" +%s 2>/dev/null); then next=$(mm_when "$when"); else next=""; fi
      if [[ "$state" == enabled ]]; then
        mm_ok "systemd user timer $MM_SCHEDULE_UNIT.timer" "$cal + up to $_SCHEDULE_DELAY${next:+ · next run $next}"
      else
        mm_warn "systemd user timer $MM_SCHEDULE_UNIT.timer is ${state:-unknown}: mm schedule enable"
      fi
      linger=$(_schedule_linger)
      case "$linger" in
        no) mm_warn "Linger is off: the timer runs only while you are logged in. To run it logged out: sudo loginctl enable-linger $(id -un)" ;;
        "") mm_info "Linger unknown: if the timer must run while you are logged out: sudo loginctl enable-linger $(id -un)" ;;
      esac
      _schedule_drift "$_SCHEDULE_SD_ENV"$'\n'"$(awk 'index($0, "Environment=") == 1 { print substr($0, 13) }' "$svc" 2>/dev/null)"
    else
      mm_warn "systemd user timer $MM_SCHEDULE_UNIT.timer installed, but \`systemctl --user\` does not answer here"
    fi
  elif _schedule_ours "$svc"; then
    any=1; mm_warn "$svc is there without its timer: mm schedule enable"
  fi
  if command -v crontab >/dev/null && _schedule_crontab 2>/dev/null; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      any=1
      read -r -a f <<<"$line"
      when="daily at $(printf '%02d:%02d' "${f[1]}" "${f[0]}")"
      [[ "${f[4]}" == '*' ]] || when="weekly on $(_schedule_weekday "${f[4]}") at $(printf '%02d:%02d' "${f[1]}" "${f[0]}")"
      mm_ok "crontab line" "$when"
      # The run gets the crontab's settings above the line, then the line's own NAME=VALUE words.
      _schedule_drift "$(_schedule_cron_env "${_SCHEDULE_CRONTAB%%"$line"*}")"$'\n'"$(printf '%s\n' "${f[@]:5}" | awk '/^[A-Za-z_][A-Za-z0-9_]*=/ { print; next } { exit }')"
    done < <(printf '%s' "$_SCHEDULE_CRONTAB" | grep -E "$_SCHEDULE_CRON_RE")
  fi
  (( any )) || mm_info "Not scheduled. Turn it on with: mm schedule enable (or --weekly)"
  if mm_schedule_last; then
    mm_info "Last run: $(_schedule_last_line)"
  else
    mm_info "Last run: none yet"
  fi
}

# _schedule_weekday N — cron's day of the week as a name (0 and 7 are Sunday); N itself otherwise.
_schedule_weekday() {
  local -a d=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  if [[ "$1" =~ ^[0-7]$ ]]; then printf '%s' "${d[$1]}"; else printf 'day %s' "$1"; fi
}

# _schedule_last_line — one line about the last run (after mm_schedule_last).
_schedule_last_line() {
  printf '%s (%s, %s) · took %s · freed %s' "${MM_LAST_AT/T/ }" "$(mm_ago $(( $(date +%s) - MM_LAST_EPOCH )))" \
    "$MM_LAST_TRIGGER" "$(mm_dur "$MM_LAST_DURATION")" "$(mm_human "$MM_LAST_FREED")"
  (( MM_LAST_TRASHED )) && printf ' · %s to Trash' "$(mm_human "$MM_LAST_TRASHED")"
  printf ' · %s items · %s skipped · %s errors' "$MM_LAST_ITEMS" "$MM_LAST_SKIPPED" "$MM_LAST_ERRORS"
}

# ---------------------------------------------------------------- main

mm_cmd_main() {
  local sub=status freq=""
  if (( $# )); then
    case "$1" in
      status|enable|disable|run) sub=$1; shift ;;
      -h|--help) _schedule_usage; return 0 ;;
      *) mm_die "unknown subcommand: $1 (see mm schedule --help)" ;;
    esac
  fi
  while (( $# )); do
    case "$1" in
      --daily|--weekly) [[ "$sub" == enable ]] || mm_die "$1 goes with mm schedule enable"; freq=${1#--} ;;
      -h|--help) _schedule_usage; return 0 ;;
      *) mm_die "unknown option: $1 (see mm schedule --help)" ;;
    esac
    shift
  done
  # Finds the unit folder systemd reads (_schedule_systemd_ok) before anything looks there.
  [[ "$sub" == run ]] || _schedule_systemd_ok || :
  case "$sub" in
    run) _schedule_run ;;
    status) _schedule_status ;;
    enable) _schedule_enable "${freq:-daily}" ;;
    disable) _schedule_disable ;;
  esac
}
