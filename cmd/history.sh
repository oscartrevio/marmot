# shellcheck shell=bash
# mm history [-l N | --all] [--json] — show recorded operations (read-only), grouped by run.
# (-n is marmot's global --dry-run, so the limit is -l/--limit.)
# Log rows: time, command, action, target, bytes, detail, run id. Older rows have fewer fields:
# 5 (no detail) or 6 (no run id). operations.log.old (rotated by mm_log) is read first.
# Rows without a run id form one run per stretch of the same command with no gap over 30 minutes.

_history_usage() {
  cat <<EOF
Usage: mm history [-l N | --all] [--json]

Shows what marmot removed, moved to the Trash, refused or failed, newest last (read-only).
Each marmot run gets one line (time, command, totals), followed by its rows.

  -l, --limit N   Show the newest N runs (default 10)
      --all       Show every run
      --json      Print those runs' rows as a JSON array (needs jq); "run" is the run id
                  (null for rows logged before marmot recorded one)
EOF
}

# _history_awk LIMIT JSON FILE... — the rows of the newest LIMIT runs (0 = all) in FILEs: as
# 7-field TSV when JSON=1, else as the text listing with all-time totals.
_history_awk() {
  awk -F'\t' -v limit="$1" -v json="$2" -v dim="$C_DIM" -v red="$C_RED" -v yellow="$C_YELLOW" \
    -v bold="$C_BOLD" -v reset="$C_RESET" "$MM_AWK_HUMAN"'
    # minute(ISO time) — minutes since a fixed epoch (days from the civil date), offset ignored.
    function minute(t, y, m) {
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0
      if (m < 3) { y--; m += 12 }
      return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) \
        + substr(t, 9, 2)) * 1440 + substr(t, 12, 2) * 60 + substr(t, 15, 2)
    }
    function header(k, s, a, na, i, lbl, t) {
      na = split(substr(acts[k], 2), a, " ")
      for (i = 1; i <= na; i++) {
        lbl = a[i]
        if (lbl == "remove") lbl = "removed"; else if (lbl == "trash") lbl = "to Trash"; else if (lbl == "run") lbl = "ran"
        s = s " · " cnt[k, a[i]] " " lbl ((bytes[k, a[i]] > 0) ? " " human(bytes[k, a[i]]) : "")
      }
      t = gtime[k]; sub(/T/, " ", t)
      printf "%s%s%s%s  %s%s%s%s\n", (k > first ? "\n" : ""), dim, t, reset, bold, gcmd[k], reset, s
    }
    NF < 3 { next }
    {
      n++; row[n] = $0
      b = ($5 ~ /^[0-9]+$/) ? $5 + 0 : 0
      if ($3 == "remove") all_r += b; else if ($3 == "trash") all_t += b
      run = (NF >= 7) ? $7 : ""; min = minute($1)
      if (n == 1 || run != prun || (run == "" && ($2 != pcmd || min - pmin > 30))) { g++; gtime[g] = $1; gcmd[g] = $2 }
      prun = run; pcmd = $2; pmin = min; grp[n] = g
      if (!((g, $3) in cnt)) acts[g] = acts[g] " " $3
      cnt[g, $3]++; bytes[g, $3] += b
    }
    END {
      first = (limit > 0 && g > limit) ? g - limit + 1 : 1
      for (i = 1; i <= n; i++) {
        if (grp[i] < first) continue
        split(row[i], f, "\t")
        if (json) { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4], f[5], f[6], f[7]; continue }
        if (grp[i] != shown) { shown = grp[i]; header(shown) }
        color = ""
        if (f[3] == "refused") color = dim; else if (f[3] == "failed") color = red; else if (f[3] == "trash") color = yellow
        note = ""
        if (f[3] == "refused" || f[3] == "failed") note = " (" f[6] ")"; else if (f[3] == "trash") note = " → Trash"
        size = (f[5] ~ /^[0-9]+$/ && f[5] + 0 > 0) ? " " human(f[5] + 0) : ""
        printf "  %s%-7s %s%s%s%s%s%s\n", color, f[3], f[4], reset, dim, size, note, reset
      }
      if (!json) printf "\nAll-time: %s removed, %s moved to Trash (restore: trash-restore), %d log rows\n", human(all_r), human(all_t), n
    }' "${@:3}"
}

mm_cmd_main() {
  local limit=10 json=0
  while (( $# )); do
    case "$1" in
      -l|--limit) [[ "${2:-}" =~ ^[0-9]+$ ]] || mm_die "$1 needs a number"; limit="$2"; shift ;;
      --all) limit=0 ;;
      --json) json=1 ;;
      -h|--help) _history_usage; return 0 ;;
      *) mm_die "unknown option: $1" ;;
    esac
    shift
  done
  (( json )) && ! command -v jq >/dev/null && mm_die "jq is required for --json"
  local f; local -a logs=()
  for f in "$MM_LOG_FILE.old" "$MM_LOG_FILE"; do [[ -s "$f" ]] && logs+=("$f"); done
  (( ${#logs[@]} )) || { echo "No operations recorded yet ($MM_LOG_FILE)."; return 0; }

  if (( json )); then
    _history_awk "$limit" 1 "${logs[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {time: .[0], command: .[1], action: .[2], target: .[3], bytes: ((.[4] // "0") | tonumber? // 0),
         detail: (.[5] // ""), run: (if (.[6] // "") == "" then null else .[6] end)})'
    return
  fi
  _history_awk "$limit" 0 "${logs[@]}"
}
