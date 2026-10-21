# shellcheck shell=bash
# The scheduled cleanup's shared facts, for `mm schedule` and `mm status`: where `mm schedule
# enable` puts its systemd user units or crontab line, the note of what it installed, and the
# summary every scheduled run writes. Reading them runs no external command.

MM_SCHEDULE_UNIT=marmot-schedule    # marmot-schedule.service, run by marmot-schedule.timer
# Where systemd looks for user units; cmd/schedule.sh follows systemd's own XDG_CONFIG_HOME when
# `systemctl --user` answers.
MM_SCHEDULE_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# First line of both unit files: disable removes only files that carry it.
MM_SCHEDULE_MARK="# Written by mm schedule enable; mm schedule disable removes it."
MM_SCHEDULE_CRON_TAG="# marmot"     # ends the crontab line enable adds
MM_SCHEDULE_NOTE="$MM_STATE_DIR/schedule"         # "systemd daily", "cron weekly": what enable installed
MM_SCHEDULE_LAST="$MM_STATE_DIR/last-run.json"    # the last real `mm schedule run`
MM_SCHEDULE_HOUR=3                                # runs start at 03:00 local time (+ a random delay)

# mm_schedule_hint — one closing line for a run with nothing to do: when the next scheduled
# cleanup is due ("Next scheduled cleanup: in 9h (03:00)"), or how to schedule one.
mm_schedule_hint() {
  local inst next
  if ! inst=$(mm_schedule_installed); then
    printf 'Keep it that way without thinking about it: mm schedule enable'
    return
  fi
  if [[ "${inst#* }" == weekly ]]; then next=$(date -d "sunday $MM_SCHEDULE_HOUR:00" +%s)
  else next=$(date -d "today $MM_SCHEDULE_HOUR:00" +%s); fi
  (( next > $(date +%s) )) || next=$((next + $([[ "${inst#* }" == weekly ]] && echo 604800 || echo 86400)))
  printf 'Next scheduled cleanup: %s' "$(mm_when "$next")"
}

# mm_schedule_installed — print "BACKEND FREQUENCY" (systemd|cron, daily|weekly) as recorded by
# `mm schedule enable`; 1 when nothing is scheduled.
mm_schedule_installed() {
  local backend freq
  [[ -r "$MM_SCHEDULE_NOTE" ]] || return 1
  read -r backend freq _ <"$MM_SCHEDULE_NOTE" || [[ -n "${backend:-}" ]] || return 1
  [[ "$backend" == systemd || "$backend" == cron ]] && [[ "$freq" == daily || "$freq" == weekly ]] || return 1
  printf '%s %s\n' "$backend" "$freq"
}

# mm_schedule_last — read the last run's summary into MM_LAST_EPOCH (when it finished), MM_LAST_AT
# (same, ISO 8601), MM_LAST_DURATION (seconds), MM_LAST_FREED and MM_LAST_TRASHED (bytes),
# MM_LAST_ITEMS, MM_LAST_TRIGGER (systemd|cron|manual), MM_LAST_SKIPPED and MM_LAST_ERRORS (counts).
# 1 when there is no readable summary.
mm_schedule_last() {
  local out
  [[ -r "$MM_SCHEDULE_LAST" ]] || return 1
  # The file is written by _schedule_record: top-level scalars one per line at two spaces, the
  # skipped and errors arrays one entry per line below their key.
  out=$(awk '
    /^  "skipped": \[/ { sec = "s"; if ($0 ~ /\]/) sec = ""; next }
    /^  "errors": \[/ { sec = "e"; if ($0 ~ /\]/) sec = ""; next }
    /^  \]/ { sec = ""; next }
    sec == "s" && /^    \{/ { ns++; next }
    sec == "e" && /^    "/ { ne++; next }
    /^  "[a-z_]+": / {
      k = $1; gsub(/[":]/, "", k); v = substr($0, index($0, ": ") + 2)
      sub(/,$/, "", v); gsub(/^"|"$/, "", v); f[k] = v
    }
    END {
      if (f["finished_epoch"] !~ /^[0-9]+$/) exit 1
      # Tabs around an empty field would collapse in read: every field gets a value.
      split("finished_at duration_seconds freed_bytes trashed_bytes items trigger", ks, " ")
      for (i in ks) if (f[ks[i]] == "") f[ks[i]] = "-"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.0f\t%.0f\n", f["finished_epoch"], f["finished_at"],
        f["duration_seconds"], f["freed_bytes"], f["trashed_bytes"], f["items"], f["trigger"], ns, ne
    }' "$MM_SCHEDULE_LAST" 2>/dev/null) || return 1
  IFS=$'\t' read -r MM_LAST_EPOCH MM_LAST_AT MM_LAST_DURATION MM_LAST_FREED MM_LAST_TRASHED MM_LAST_ITEMS \
    MM_LAST_TRIGGER MM_LAST_SKIPPED MM_LAST_ERRORS <<<"$out"
  local v
  for v in "$MM_LAST_DURATION" "$MM_LAST_FREED" "$MM_LAST_TRASHED" "$MM_LAST_ITEMS"; do
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
  done
  [[ -n "$MM_LAST_AT" ]]
}
