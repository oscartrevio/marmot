# shellcheck shell=bash
# shellcheck disable=SC2153,SC2154 # the locals of the commands that call these, read by bash's dynamic scope
# lib/out_cmds.sh: what the commands that print by hand draw with lib/out.sh's primitives: mm
# status --once, mm history, mm uninstall's list, mm analyze's overview, mm purge's table and its
# two progress hooks, mm clean's "kept for you to review". lib/out.sh loads this file.

# ---------------------------------------------------------------- mm purge

# The artifacts mm purge found, biggest first; ● stale, ○ recent, ◎ pick only.
_purge_show_table() {
  local i mark path note age n
  _out_live_clear
  mm_section "Found $(_out_plural "${#order[@]}" artifact; printf '%s' "$REPLY")"
  for i in "${order[@]}"; do
    ((shown[i])) || continue
    n=${frees[${arts[$i]}]:-0}
    if [[ "${kind[i]}" == pick ]]; then mark="${C_DIM}◎${C_RESET}"
    elif ((stale[i])); then mark="${C_YELLOW}●${C_RESET}"
    else mark="${C_DIM}○${C_RESET}"; fi
    mm_tilde "${arts[$i]}"; path=$REPLY note=""
    _purge_to_trash "${arts[$i]}" && note+=" → Trash"
    [[ -n "${picks[$i]}" ]] && note+=" (${picks[$i]})"
    if ((n < ${size[${arts[$i]}]:-0})); then   # hard-linked elsewhere: only part of it is released
      if ((pnpm_art[i])); then note+=" (rest in the pnpm store)"; else note+=" (of $(mm_human "${size[${arts[$i]}]}"))"; fi
    fi
    age=$(_purge_age "${idle[i]}")
    _out_drow "$mark" "$path$note" "$(printf '%8s  %4s' "$(mm_human "$n")" "$age")"
  done
  _out_live_clear
  ((shared)) && _out_wrap "Sizes are what deleting releases: files also hard-linked elsewhere (the pnpm store, other copies) stay on disk." "$_OUT_IND" "$C_DIM"
  ((hidden_n)) && printf '%*s%s○ … %d more recent under 1MB each (%s)%s\n' "$_OUT_IND" '' "$C_DIM" "$hidden_n" "$(mm_human "$hidden_bytes")" "$C_RESET"
  local sep="   " pad; ((OUT_W < 70)) && sep=$'\n'$(printf '%*s' "$_OUT_IND" '')
  printf -v pad '%*s' "$_OUT_IND" ''
  printf '\n%s%s●%s %s stale (idle > %sd)' "$pad" "$C_YELLOW" "$C_RESET" "$(mm_human "$stale_bytes")" "$days"
  printf '%s%s○ %s recent, kept by default%s' "$sep" "$C_DIM" "$(mm_human "$recent_bytes")" "$C_RESET"
  ((pick_n)) && printf '%s%s◎ %s pick only%s' "$sep" "$C_DIM" "$(mm_human "$pick_bytes")" "$C_RESET"
  printf '\n'
}

# The two hooks of mm purge's removal loop: the plan for the live line, and each removal.
_purge_begin_delete() {
  local i bytes=0
  [[ "$MM_DRY_RUN" == 1 ]] && return 0
  for i in "${sel[@]}"; do bytes=$((bytes + ${frees[${arts[$i]}]:-0})); done
  mm_prog_items "${#sel[@]}" "$bytes"
}
_purge_item_start() { ((_OUT_ITEM_N > 0)) && mm_prog_item "$1"; return 0; }
_purge_kept() { _out_drow "${C_DIM}◎${C_RESET}" "$1" "$2"; }

# ---------------------------------------------------------------- mm clean

_clean_review_row() {
  _out_drow "${C_DIM}◎${C_RESET}" "$1" "$2"
  [[ -n "$3" ]] && _out_do _out_wrap "$3" $((_OUT_IND + 2)) "$C_DIM"
  return 0
}

# ---------------------------------------------------------------- mm uninstall

# The removable packages, largest first: name, then source, size and age flush right.
_uninstall_table() { # IDX...
  local i size mark
  for i in "$@"; do
    size='?'; [[ -n "${_UN_BYTES[i]}" ]] && size=$(mm_human "${_UN_BYTES[i]}")
    mark=" "; [[ -n "${_UN_NOTE[i]}" ]] && mark="${C_YELLOW}!${C_RESET}"
    _out_drow "$mark" "${_UN_NAME[i]}" "$(printf '%-6s %8s  %7s' "${_UN_SRC[i]}" "$size" "$(_uninstall_ago "${_UN_TIME[i]}")")"
  done
  return 0
}

# ---------------------------------------------------------------- mm analyze

# _analyze_render USED ROWS... — the overview: number, bar, label, size and share of the used disk;
# the folder too when the line has room for it.
_analyze_render() {
  local used=$1; shift
  local max=0 row label bytes status target access n=0 size pct note bar lw path
  (($#)) && { IFS=$'\t' read -r _ max _ <<<"$1"; }
  local bw=14; ((OUT_W < 64)) && bw=8
  lw=$((OUT_W - 5 - 9 - 5 - 2)); ((bw)) && lw=$((lw - bw - 1))
  ((lw > 28)) && lw=28
  for row in "$@"; do
    IFS=$'\t' read -r label bytes status target access <<<"$row"
    n=$((n + 1))
    pct=$(awk -v b="$bytes" -v u="$used" 'BEGIN { printf "%.0f", (u > 0 ? b * 100 / u : 0) }')
    size=$(mm_human "$bytes"); [[ "$status" == partial ]] && size+="+"
    note=""
    [[ "$label" == Old\ Downloads* ]] && note=" >3mo"
    [[ "$access" == keep ]] && note=" report only"
    bar=""; if ((bw)); then _out_bar_cells "$bytes" "$max" "$bw"; bar="$REPLY "; fi
    _out_cut "$label$note" "$lw"; label=$REPLY
    path=""
    if ((OUT_W >= 78)); then mm_tilde "$target"; path="  $C_DIM$REPLY$C_RESET"; fi
    printf ' %2d. %s%-*s %9s %4s%s\n' "$n" "$bar" "$lw" "$label" "$size" "$pct%" "$path"
  done
}

# ---------------------------------------------------------------- mm status --once

# _out_status_once — one snapshot, in the output primitives: agents, resources, checks, then a card
# with the health score. The rows are the dashboard's own lines (_status_compact), re-laid: the
# dashboard's bars and sparklines are replaced by the bar, and every row gets a mark.
_out_status_once() {
  local line plain label rest group="" cur="" mark kind pct n lim=${#ST_AGENTS[@]} bw=10 notes
  local -a labels=() texts=() conts=()
  ((lim < 1)) && lim=1
  ((OUT_W < 60)) && bw=6
  # the dashboard's header, the marmot, as wide as the card
  _status_compact $((OUT_W < 66 ? OUT_W - 2 : 64)) 1 0
  if ((ST_MM_N)); then printf '\n'; printf '%s\n' "${ST_FRAME[@]:0:ST_MM_N}"; fi
  ST_MASCOT=0
  _status_compact 100 "$lim" 1
  for line in "${ST_FRAME[@]:1}"; do
    _out_plain "$line"; plain=$REPLY
    if [[ "$plain" =~ ^([A-Z]{2,6})\ +(.*)$ ]]; then
      labels+=("${BASH_REMATCH[1]}") texts+=("${BASH_REMATCH[2]}") conts+=("")
    elif ((${#labels[@]})); then
      plain=${plain#"${plain%%[! ]*}"}
      conts[-1]+="${conts[-1]:+$'\n'}$plain"
    fi
  done
  OUT_KW=8
  mm_header "Status"
  for n in "${!labels[@]}"; do
    label=${labels[$n]} rest=${texts[$n]}
    [[ "$rest" =~ ^[█░]+\ +(.*)$ ]] && rest=${BASH_REMATCH[1]}
    while [[ "${rest: -1}" == [▁▂▃▄▅▆▇█\ ] ]]; do rest=${rest%?}; done
    mark=ok pct=-1
    case "$label" in
      AGENTS) group=Agents; [[ "$rest" == none* ]] && mark=skip; [[ "${conts[$n]}" == *"! "* ]] && mark=warn ;;
      YOU) group=Agents; ((ST_CL_LAGGY)) && mark=warn ;;
      CPU) group=Resources; pct=$(((${ST_CPU[0]:-0} + 5) / 10)); ((pct >= 85)) && mark=warn ;;
      MEM) group=Resources; pct=$(((ST_MEM_USED_PCT + 5) / 10)); ((pct >= 85)) && mark=warn ;;
      DISK) group=Resources; pct=$(((ST_ROOT_PCT + 5) / 10)); ((pct >= MM_DISK_WARN_PCT)) && mark=warn ;;
      NET) group=Resources; [[ "$rest" == *"no default route"* ]] && mark=warn ;;
      CHECKS) group=Checks; [[ "$rest ${conts[$n]}" == *"!"* || "$rest ${conts[$n]}" == *"✗"* ]] && mark=warn ;;
      CLEAN) group=Checks; [[ "$rest" == "not scheduled"* ]] && mark=skip ;;
      TOP) group=Checks; mark=skip ;;
    esac
    [[ "$group" != "$cur" ]] && { cur=$group; mm_section "$group"; }
    local key=$label val=$rest
    case "$label" in AGENTS) key=sessions ;; MEM) key=memory ;; NET) key=network ;; CLEAN) key=cleanup ;; TOP) key="top mem" ;; *) key=${label,,} ;; esac
    if ((pct >= 0)); then _out_bar_cells "$pct" 100 "$bw"; val="$REPLY $rest"; fi
    _out_draw_mark "$mark"
    _out_kv_row "$key" "$val" "$REPLY"
    while IFS= read -r line; do
      while [[ "${line: -1}" == [▁▂▃▄▅▆▇█\ ] ]]; do line=${line%?}; done
      [[ -n "$line" ]] && _out_kv_row "" "$line"
    done <<<"${conts[$n]}"
  done
  kind=good; ((ST_SCORE < 80)) && kind=warn; ((ST_SCORE < 60)) && kind=bad
  notes="nothing needs attention"
  ((${#ST_REASONS[@]})) && { notes=${ST_REASONS[0]}; ((${#ST_REASONS[@]} > 1)) && notes+=" · ${ST_REASONS[1]}"; }
  # the link to the viewer is their network, not this machine's health: said, never scored
  ((ST_CL_LAGGY)) && notes+=" · link to you is laggy"
  mm_result "$kind" "Health $ST_SCORE of 100" "*notes" "$notes"
}

# ---------------------------------------------------------------- mm history

# _out_history LIMIT FILE... — the newest runs, each a heading with its rows, and the story so far.
_out_history() {
  local limit=$1 kind a b c d e f wins="" k
  shift
  mm_header "History"
  while IFS=$'\t' read -r kind a b c d e f; do
    case "$kind" in
      H)
        a=${a:0:16}; k="$a  $b${c:+ · $c}"
        _out_cut "$k" $((OUT_W - 2)); mm_section "$REPLY" ;;
      R)
        # a=action b=target c=size d=note ("-" when empty)
        [[ "$c" == - ]] && c=""; [[ "$d" == - ]] && d=""
        case "$a" in
          refused) _out_do _out_draw_row skip "$b" "refused${d:+ $d}" ;;
          failed) _out_do _out_draw_row warn "$b failed${d:+ $d}" "" ;;
          trash) _out_do _out_draw_row act "$b" "${c:+$c }→ Trash" ;;
          *) _out_do _out_draw_row ok "$b" "$c" ;;
        esac ;;
      S)
        # a=since b=runs c=freed d=trash e=refused
        local -a rows=("runs" "$b" "*freed" "$c")
        [[ "$d" != - ]] && rows+=("to Trash" "$d (restore: trash-restore)")
        ((e > 0)) && rows+=(refused "$e")
        _HIST_ROWS=("${rows[@]}") _HIST_SINCE=$a ;;
      W) wins+="${wins:+, }$a $b" ;;
    esac
  done < <(_history_awk "$limit" 2 "$@")
  [[ -n "$wins" ]] && _HIST_ROWS+=("biggest" "$wins")
  mm_result info "Since $_HIST_SINCE" "${_HIST_ROWS[@]}"
}

# ---------------------------------------------------------------- mm analyze

_analyze_head() {
  _out_live_clear
  _out_draw_title "Analyze disk"
  printf '%*s%s%s free%s\n' "$_OUT_IND" '' "$C_DIM" "$1" "$C_RESET"
  [[ -n "${2:-}" ]] && printf '%*s%s%s%s\n' "$_OUT_IND" '' "$C_DIM" "$2" "$C_RESET"
  printf '\n'
}
_analyze_entries_head() {
  _out_live_clear
  mm_tilde "$1"
  mm_section "Largest entries under $REPLY"
  mm_info "${C_DIM}$2${C_RESET}"
}
_analyze_entry() { mm_tilde "$2"; _out_drow " " "$REPLY" "$(mm_human "$1")"; }
