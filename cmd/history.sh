# shellcheck shell=bash
# mm history [-l N | --all] [--json] — show recorded operations (read-only).
# (-n is marmot's global --dry-run, so the row limit is -l/--limit.)
# Log rows: time, command, action (remove|trash|refused|failed|run), target, bytes, detail.
# Rows written before the detail column existed have 5 fields; detail is then empty.

mm_cmd_main() {
  local limit=30 json=0
  while (( $# )); do
    case "$1" in
      -l|--limit) [[ "${2:-}" =~ ^[0-9]+$ ]] || mm_die "$1 needs a number"; limit="$2"; shift ;;
      --all) limit=0 ;;
      --json) json=1 ;;
      -h|--help) echo "Usage: mm history [-l N | --all] [--json]"; return 0 ;;
      *) mm_die "unknown option: $1" ;;
    esac
    shift
  done
  [[ -s "$MM_LOG_FILE" ]] || { echo "No operations recorded yet ($MM_LOG_FILE)."; return 0; }

  local src=(cat "$MM_LOG_FILE"); (( limit > 0 )) && src=(tail -n "$limit" "$MM_LOG_FILE")
  if (( json )); then
    "${src[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {time: .[0], command: .[1], action: .[2], target: .[3], bytes: ((.[4] // "0") | tonumber? // 0),
         detail: (.[5] // "")})'
    return
  fi
  local ts cmd action target bytes detail color size note
  while IFS=$'\t' read -r ts cmd action target bytes detail; do
    case "$action" in
      refused) color=$C_DIM ;; failed) color=$C_RED ;; trash) color=$C_YELLOW ;; *) color="" ;;
    esac
    size=""; [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )) && size=" $(mm_human "$bytes")"
    note=""
    case "$action" in
      refused|failed) note=" ($detail)" ;;
      trash) note=" → Trash" ;;
    esac
    printf '%s%s%s  %-9s %s%-7s %s%s%s%s%s%s\n' "$C_DIM" "${ts/T/ }" "$C_RESET" "$cmd" "$color" "$action" \
      "$target" "$C_RESET" "$C_DIM" "$size" "$note" "$C_RESET"
  done < <("${src[@]}")
  local removed trashed
  read -r removed trashed < <(awk -F'\t' '$3 == "remove" { r += $5 } $3 == "trash" { t += $5 }
    END { printf "%.0f %.0f\n", r, t }' "$MM_LOG_FILE")
  printf '\nAll-time: %s removed, %s moved to Trash (restore: trash-restore), %s log rows\n' \
    "$(mm_human "$removed")" "$(mm_human "$trashed")" "$(wc -l <"$MM_LOG_FILE")"
}
