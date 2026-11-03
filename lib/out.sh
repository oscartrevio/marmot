# shellcheck shell=bash
# shellcheck disable=SC2153,SC2154 # globals set by the commands and the other out files (dynamic scope)
# lib/out.sh: how every marmot command prints its progress and results. lib/core.sh loads it last,
# so the primitives below are the ones commands call.
#
# A run reads as a short plan: a bold title with a dim line about the machine, aligned rows with
# the numbers flush right, a bar you can watch while it works (on a terminal, when the length is
# known: bytes, items or steps), and a bordered card that closes the command with what matters.
# Without a terminal, in a pipe or with NO_COLOR it is the same text with no bar, no cursor tricks
# and no color. lib/out_common.sh holds the measuring, the card and the live line; lib/out_cmds.sh
# draws what the commands that print by hand (status, history, uninstall's list, analyze, purge's
# table) hand over.
#
# The primitives, named as the commands call them:
#   header     mm_header TITLE
#   section    mm_section TITLE            (and mm_section_lazy, in lib/core.sh)
#   row        mm_ok, mm_skip, mm_act, mm_warn, mm_info, mm_err      ✓ ◎ → ! · ✗
#   progress   mm_prog_plan STEPS · mm_prog_step LABEL · mm_prog_items N [BYTES] · mm_prog_item LABEL
#   card       mm_banner TITLE LINE...  (what a change did)  ·  mm_result KIND TITLE [KEY VALUE]...
#   empty      mm_done_empty MESSAGE
#   error      mm_die MESSAGE, mm_err MESSAGE
# and the confirmations (mm_confirm, mm_pick, mm_sudo_ask), which take the live line away first.
# shellcheck source=out_common.sh
. "$MM_HOME/lib/out_common.sh"

# ---- what is drawn: title, rows, the live line, cards
_OUT_IND=2

# _out_draw_mark KIND — the mark for KIND, colored, in REPLY.
_out_draw_mark() {
  case "$1" in
    ok) REPLY="${C_GREEN}✓${C_RESET}" ;;
    skip | kept) REPLY="${C_DIM}◎${C_RESET}" ;;
    warn) REPLY="${C_YELLOW}!${C_RESET}" ;;
    act) REPLY="${C_CYAN}→${C_RESET}" ;;
    err) REPLY="${CE_RED}✗${CE_RESET}" ;;
    *) REPLY=" " ;;
  esac
}

# _out_draw_title TITLE — the command's name; "dry run" beside it when nothing will change.
_out_draw_title() {
  printf '\n%s%s%s' "$C_BOLD" "$1" "$C_RESET"
  [[ "$MM_DRY_RUN" == 1 ]] && printf '  %sdry run: nothing will change%s' "$C_YELLOW" "$C_RESET"
  printf '\n'
}

_out_draw_header() {
  local away
  _out_draw_title "$1"
  _out_sys
  away=$(mm_away_line)
  [[ -n "$away" ]] && _out_wrap "$away" 0 "$C_DIM"
  return 0
}

_out_draw_section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

# _out_draw_row KIND LABEL DETAIL — a result of the run.
_out_draw_row() {
  case "$1" in
    info) _out_info "$2" ;;
    warn) _out_line "${C_YELLOW}!${C_RESET}" "$2" "" "$_OUT_IND" ;;
    err) _out_draw_mark err; _out_line "$REPLY" "$2" "" "$_OUT_IND" ;;
    *) _out_draw_mark "$1"; _out_line "$REPLY" "$2" "$3" "$_OUT_IND" ;;
  esac
}

# _out_draw_drow MARK LABEL DETAIL — a row of a list the user reads: MARK is already colored.
_out_draw_drow() { _out_line "$1" "$2" "$3" "$_OUT_IND"; }

# _out_draw_kv KEY VALUE [MARK] — an aligned "key  value" row of a report.
_out_draw_kv() { _out_kv "$1" "$2" "${3:- }" "$_OUT_IND"; }

# _out_draw_live — the live line: a bar and what it counts. Nothing to draw without a plan.
_out_draw_live() {
  local bw=20 num den txt room
  ((OUT_W < 60)) && bw=10
  if ((_OUT_ITEM_N > 0)); then
    num=$_OUT_ITEM_I den=$_OUT_ITEM_N
    txt="$_OUT_ITEM_I/$_OUT_ITEM_N"
    if ((_OUT_BYTES > 0)); then
      num=$_OUT_BYTES_DONE den=$_OUT_BYTES
      txt+=" · $(mm_human "$_OUT_BYTES_DONE") of $(mm_human "$_OUT_BYTES")"
    fi
    if [[ -n "$_OUT_ITEM" ]]; then mm_tilde "$_OUT_ITEM"; txt+=" · removing $REPLY"; fi
  elif ((_OUT_STEP_N > 0)); then
    num=$((_OUT_STEP_I > 0 ? _OUT_STEP_I - 1 : 0)) den=$_OUT_STEP_N
    txt="${_OUT_STEP_I}/$_OUT_STEP_N"
    [[ -n "$_OUT_STEP" ]] && txt+=" · $_OUT_STEP"
  else
    return 1
  fi
  room=$((OUT_W - _OUT_IND - bw - 2))
  _out_cut "$txt" "$room"; txt=$REPLY
  _out_bar_cells "$num" "$den" "$bw"
  REPLY="$(printf '%*s' "$_OUT_IND" '')$REPLY  $C_DIM$txt$C_RESET"
}

# _out_draw_summary — mm_banner's card (_out_banner_parse has split what it was given).
_out_draw_summary() {
  local kind=ok free_key=freed
  local -a rows=()
  if ((OUT_DRY)); then kind=dry free_key="would free"; else _out_draw_marmot; fi
  [[ -n "$OUT_FREED" ]] && rows+=("*$free_key" "$OUT_FREED")
  [[ -n "$OUT_HEAD" ]] && rows+=("*result" "$OUT_HEAD")
  [[ -n "$OUT_COUNTS" ]] && rows+=(items "$OUT_COUNTS")
  [[ -n "$OUT_TRASH" ]] && rows+=("to Trash" "$OUT_TRASH")
  local r
  for r in "${OUT_ROWS[@]}"; do rows+=("${r%%$'\t'*}" "${r#*$'\t'}"); done
  _out_card "$kind" "$OUT_TITLE" "${rows[@]}"
  for r in "${OUT_NOTES[@]}"; do _out_wrap "$r" 2 "$C_DIM"; done
  return 0
}

# _out_draw_marmot — the marmot over the card that closes a real run on a terminal: proud when the
# run freed 1GB or more, happy otherwise, dressed for the day (lib/mascot.sh) but saying nothing:
# the card says the day's greetings and milestones, once. Its rule is as wide as the card. Only when marmot runs from a terminal (MM_TTY), like the day's greeting: not in a dry
# run, cron or a script, where the card stays the whole closing.
_out_draw_marmot() {
  [[ "$MM_TTY" == 1 ]] || return 0
  local mood=happy w=64 line
  ((${MM_FREED:-0} >= 1073741824)) && mood=proud
  ((w > OUT_W - 2)) && w=$((OUT_W - 2))
  ((w >= 32)) || return 0
  mm_now
  mm_occasions_now "$REPLY"
  mm_marmot_dress "$mood" 0 "${MM_OCC[@]}"
  MM_LOOK_GREET=""
  mm_marmot_draw "$mood" "$w" "" "" "$C_GREEN"
  printf '\n'
  for line in "${MM_ART[@]}"; do printf '%s\n' "$line"; done
}

# _out_draw_result KIND TITLE [KEY VALUE]... — the card that closes a report (KIND info) or a change.
_out_draw_result() { _out_card "$@"; }

# _out_draw_empty MESSAGE GREETING HINT — a run that had nothing to do.
_out_draw_empty() { _out_card ok "Nothing to do" "*" "$1" "~" "$3" "~" "$2"; }

# _out_draw_error MESSAGE — a command stopped. A closing "(see mm X --help)" becomes its own row.
_out_draw_error() {
  local msg=$1 next=""
  if [[ "$msg" =~ ^(.*)\ \((see\ (mm\ [a-z]+\ --help|mm\ --help))\)$ ]]; then msg=${BASH_REMATCH[1]} next=${BASH_REMATCH[3]}; fi
  _out_card err "✗ Stopped" "*" "$msg" "next" "$next"
}

# ---- the primitives

# Commands that do work get a live line (and, for the rest, mm_prog_items starts it).
_out_work_title() {
  case "$1" in
    "Clean your system" | Optimize | "Scheduled cleanup") _OUT_WORK=1 ;;
  esac
  return 0
}
_OUT_LEFT=""

# _out_do FUNCTION ARGS... — run one printing function with the live line out of the way.
_out_do() {
  _out_live_clear
  "$@"
  _out_live_show
}

mm_header() { _out_work_title "$1"; _out_do _out_draw_header "$1"; }
mm_section() {
  _MM_PENDING=""
  # what mm purge leaves alone is one list, not an "In use" and a "Kept" heading
  if [[ "$1" == "In use" || "$1" == Kept ]]; then
    [[ -n "$_OUT_LEFT" ]] && return 0
    _OUT_LEFT=1; set -- "Left alone"
  fi
  ((_OUT_AUTOSTEP)) && _OUT_STEP_I=$((_OUT_STEP_I + 1))
  _OUT_STEP=$1
  _out_do _out_draw_section "$1"
}
mm_ok() { _mm_flush; _out_do _out_draw_row ok "$1" "${2:-}"; _out_advance; }
mm_skip() {
  _mm_flush
  MM_SKIPS+=("$1"$'\t'"$2")
  _out_do _out_draw_row skip "$1" "$2"
  _out_advance
}
mm_act() { _mm_flush; _out_do _out_draw_row act "$1" ""; }
mm_warn() { _mm_flush; _out_do _out_draw_row warn "$1" ""; }
mm_info() { _mm_flush; _out_do _out_draw_row info "$1" ""; }
mm_err() { _mm_flush; MM_ERRORS+=("$1"); _out_do _out_draw_row err "$1" "" >&2; }
# _out_drow MARK LABEL DETAIL — a row of data (a list the user reads or picks from).
_out_drow() { _out_do _out_draw_drow "$@"; }
# _out_kv_row KEY VALUE [MARK] — an aligned "key  value" row of a report.
_out_kv_row() { _out_do _out_draw_kv "$@"; }

# _out_advance — a row that finished one item of an item plan moves the bar on.
_out_advance() {
  ((_OUT_ITEM_N > 0)) || return 0
  _OUT_ITEM_I=$((_OUT_ITEM_I + 1)) _OUT_BYTES_DONE=$((_OUT_BYTES_DONE + ${MM_LAST_BYTES:-0}))
  MM_LAST_BYTES=0
  _out_live_clear; _out_live_show
}

_OUT_AUTOSTEP=0
# mm_prog_plan STEPS [auto] — the run has STEPS steps; with auto every mm_section starts the next.
mm_prog_plan() {
  _OUT_STEP_N=$1 _OUT_STEP_I=0 _OUT_AUTOSTEP=0
  [[ "${2:-}" == auto ]] && _OUT_AUTOSTEP=1
  return 0
}
mm_prog_step() {
  _OUT_STEP_I=$((_OUT_STEP_I + 1)) _OUT_STEP=$1
  _out_live_clear; _out_live_show
}
mm_prog_items() {
  _OUT_ITEM_N=$1 _OUT_ITEM_I=0 _OUT_BYTES=${2:-0} _OUT_BYTES_DONE=0 _OUT_ITEM="" _OUT_WORK=1
  _out_live_clear; _out_live_show
}
mm_prog_item() {
  _OUT_ITEM=$1
  _out_live_clear; _out_live_show
}

mm_banner() { _out_live_end; _out_banner_parse "$@"; _out_draw_summary; }
mm_result() { _out_live_clear; _out_draw_result "$@"; }
# mm_live_pause — a command is about to print by hand: the live line goes first.
mm_live_pause() { _out_live_clear; }
mm_done_empty() {
  local g=""
  _MM_PENDING=""
  _out_live_end
  if [[ "$MM_TTY" == 1 ]]; then mm_greeting; g=$REPLY; fi
  _out_draw_empty "$1" "$g" "$(mm_schedule_hint)"
}
mm_die() { MM_ERRORS+=("$1"); _out_live_end; _out_draw_error "$1"; exit "${2:-1}"; }

# Confirmations and pickers talk to the terminal: the live line goes first and comes back after.
eval "_out_core_confirm() $(declare -f mm_confirm | tail -n +2)"
eval "_out_core_pick() $(declare -f mm_pick | tail -n +2)"
eval "_out_core_sudo_ask() $(declare -f mm_sudo_ask | tail -n +2)"
mm_confirm() { local rc; _out_live_clear; _out_core_confirm "$@"; rc=$?; _out_live_show; return "$rc"; }
mm_pick() { local rc; _out_live_clear; _out_core_pick "$@"; rc=$?; _out_live_show; return "$rc"; }
mm_sudo_ask() { local rc; _out_live_clear; _out_core_sudo_ask "$@"; rc=$?; _out_live_show; return "$rc"; }

# A run that ends without a card still leaves a clean last line (a command with its own EXIT trap
# keeps it).
[[ -z "$(trap -p EXIT)" ]] && trap '_out_live_end' EXIT

# shellcheck source=out_cmds.sh
. "$MM_HOME/lib/out_cmds.sh"
