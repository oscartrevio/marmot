# shellcheck shell=bash
# shellcheck disable=SC2153,SC2154 # globals set by the commands and the other out files (dynamic scope)
# Helpers of marmot's output (lib/out.sh draws with them). Everything here measures in characters
# (the ✓ ◎ ─ █ glyphs are multibyte) and never counts color escapes.

# Terminal width: $COLUMNS, else the width of the terminal on stderr, else 80; kept in 30..100 so
# a very wide terminal does not stretch a table and a very narrow one still gets something.
_out_width() {
  local c=${COLUMNS:-}
  [[ "$c" =~ ^[0-9]+$ ]] || { c=$(stty size <&2 2>/dev/null) || c=""; c=${c#* }; }
  [[ "$c" =~ ^[0-9]+$ ]] && ((c > 0)) || c=80
  ((c > 100)) && c=100
  ((c < 30)) && c=30
  OUT_W=$c
}
_out_width

# _out_plain TEXT — TEXT without its color escapes, in REPLY.
_out_plain() {
  local s=$1
  while [[ "$s" == *$'\e['* ]]; do
    [[ "$s" =~ $'\e'\[[0-9\;]*m ]] || break
    s=${s/"${BASH_REMATCH[0]}"/}
  done
  REPLY=$s
}

# _out_vlen TEXT — visible length of TEXT (color escapes not counted), in REPLY.
_out_vlen() {
  local LC_ALL=C.UTF-8
  _out_plain "$1"
  REPLY=${#REPLY}
}

# _out_fit TEXT WIDTH — plain TEXT cut from the left with … to WIDTH characters (paths keep their
# last, most telling part), in REPLY.
_out_fit() {
  local LC_ALL=C.UTF-8 s=$1 w=$2
  if ((${#s} > w)); then ((w < 2)) && w=2; s="…${s: -$((w - 1))}"; fi
  REPLY=$s
}

# _out_cut TEXT WIDTH — plain TEXT cut from the right with … to WIDTH characters, in REPLY.
_out_cut() {
  local LC_ALL=C.UTF-8 s=$1 w=$2
  if ((${#s} > w)); then ((w < 2)) && w=2; s="${s:0:$((w - 1))}…"; fi
  REPLY=$s
}

# _out_pad TEXT WIDTH [r] — TEXT padded with spaces to WIDTH visible characters: on the right
# (text first), or with r on the left (text flush right); in REPLY.
_out_pad() {
  _out_vlen "$1"
  local n=$(($2 - REPLY)) sp=""
  ((n > 0)) && printf -v sp '%*s' "$n" ''
  if [[ "${3:-}" == r ]]; then REPLY=$sp$1; else REPLY=$1$sp; fi
}

# _out_rule WIDTH [CHAR] — CHAR (default ─) repeated WIDTH times, in REPLY.
_out_rule() {
  local LC_ALL=C.UTF-8 n=$1 c=${2:-─} s
  ((n < 0)) && n=0
  printf -v s '%*s' "$n" ''
  REPLY=${s// /$c}
}

# _out_bar VALUE MAX WIDTH — a bar WIDTH characters wide, VALUE/MAX of it full, in REPLY: whole
# blocks and one eighth-block for the rest, so small values still show (at least 1/8).
_out_bar() {
  local LC_ALL=C.UTF-8 v=$1 m=$2 w=$3 u full rem s="" i
  local -a part=("" ▏ ▎ ▍ ▌ ▋ ▊ ▉)
  ((m > 0 && w > 0)) || { REPLY=""; return; }
  u=$((v * w * 8 / m))
  ((v > 0 && u < 1)) && u=1
  ((u > w * 8)) && u=$((w * 8))
  full=$((u / 8)) rem=$((u % 8))
  for ((i = 0; i < full; i++)); do s+=█; done
  s+=${part[rem]}
  REPLY=$s
}

# _out_plural N WORD — "1 artifact", "3 artifacts" (WORD plus s), in REPLY.
_out_plural() { if (($1 == 1)); then REPLY="$1 $2"; else REPLY="$1 $2s"; fi; }

# _out_line MARK LABEL DETAIL [INDENT] — "  MARK LABEL" with DETAIL flush right, in the width of the
# terminal. LABEL is cut from the left when it does not fit; a DETAIL too long for the line goes
# under it, dimmed, hanging under LABEL. MARK may carry color; LABEL and DETAIL are plain.
_out_line() {
  local mark=$1 label=$2 detail=$3 ind=${4:-2} lead room dl
  printf -v lead '%*s%s ' "$ind" '' "$mark"
  _out_vlen "$lead"; local lw=$REPLY
  local dw=${#detail}
  local need=${#label}; ((need > 24)) && need=24; ((need < 8)) && need=8
  if ((dw && lw + need + 2 + dw <= OUT_W)); then
    room=$((OUT_W - lw - dw - 2))
    _out_fit "$label" "$room"; label=$REPLY
    _out_pad "$label" "$room"
    printf '%s%s  %s\n' "$lead" "$REPLY" "$detail"
  else
    if ((dw)); then
      _out_fit "$label" $((OUT_W - lw)); label=$REPLY
    else
      # a line with nothing but text (a warning) wraps, hanging under its first word
      local first=1 chunk
      while ((${#label} > OUT_W - lw)); do
        chunk=${label:0:OUT_W - lw}
        [[ "$chunk" == *" "* ]] && chunk=${chunk% *}
        if ((first)); then printf '%s%s\n' "$lead" "$chunk"; first=0; else printf '%*s%s\n' "$lw" '' "$chunk"; fi
        label=${label:${#chunk}}; label=${label# }
      done
      if ((first)); then printf '%s%s\n' "$lead" "$label"; else printf '%*s%s\n' "$lw" '' "$label"; fi
      return 0
    fi
    printf '%s%s\n' "$lead" "$label"
    if ((dw)); then
      dl=$((OUT_W - lw))
      while ((${#detail} > dl)); do
        local cut=${detail:0:dl}
        [[ "$cut" == *" "* ]] && cut=${cut% *}
        printf '%*s%s%s%s\n' "$lw" '' "$C_DIM" "$cut" "$C_RESET"
        detail=${detail:${#cut}}; detail=${detail# }
      done
      printf '%*s%s%s%s\n' "$lw" '' "$C_DIM" "$detail" "$C_RESET"
    fi
  fi
}

# _out_sys — the header's system line as a short dim line: "Debian 13 · 8 cores · … · up 6h".
_out_sys() {
  local s; s=$(mm_sysline)
  s=${s// | / · }
  _out_cut "$s" "$((OUT_W - 2))"
  printf '%s%s%s\n' "$C_DIM" "$REPLY" "$C_RESET"
}

# _out_banner_parse TITLE LINE... — what mm_banner was given, split so the card can lay it out. Lines hold segments joined by " | "; a segment is "Key: value" or plain text. Sets
# OUT_TITLE; OUT_DRY (1 in a dry run); OUT_FREED (the "Space freed" / "Would free" size); OUT_TRASH
# (what went to the Trash, with its note); OUT_HEAD (a plain first segment: "Applied 3 optimizations");
# OUT_COUNTS (counted keys joined with " · ": "5 artifacts · 4 projects"); OUT_ROWS ("key<TAB>value",
# the other "Key: value" segments, key lowercased); OUT_NOTES (everything else, like the closing
# hint and the milestone line).
_out_banner_parse() {
  OUT_TITLE=$1 OUT_DRY=0 OUT_FREED="" OUT_TRASH="" OUT_HEAD="" OUT_COUNTS="" OUT_ROWS=() OUT_NOTES=()
  shift
  [[ "$OUT_TITLE" == Dry* ]] && OUT_DRY=1
  local first=1 line seg key val
  for line in "$@"; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *" | "* ]] || ((first)); then
      while [[ -n "$line" ]]; do
        if [[ "$line" == *" | "* ]]; then seg=${line%% | *} line=${line#* | }; else seg=$line line=""; fi
        key=${seg%%: *} val=${seg#*: }
        if [[ "$seg" != *": "* || ${#key} -gt 24 ]]; then
          if ((first)) && [[ -z "$OUT_HEAD" && "$seg" != *": "* ]]; then OUT_HEAD=$seg
          elif [[ "$seg" == *": "* ]]; then OUT_NOTES+=("$seg")
          else OUT_COUNTS+="${OUT_COUNTS:+ · }$seg"; fi
          continue
        fi
        case "$key" in
          "Space freed" | "Would free") OUT_FREED=$val ;;
          *"to Trash") OUT_TRASH=$val ;;
          Skipped | Errors | Artifacts | Projects | Items* | Packages*)
            [[ "$key" == Errors && "$val" == 0 ]] && continue
            key=${key,,}; key=${key#items }
            [[ "$val" == 1 && "$key" == *s ]] && key=${key%s}
            OUT_COUNTS+="${OUT_COUNTS:+ · }$val ${key}" ;;
          *) OUT_ROWS+=("${key,,}"$'\t'"$val") ;;
        esac
      done
    elif [[ "${line%%: *}" == "Biggest win" || "${line%%: *}" == "Free space" ]]; then
      OUT_ROWS+=("${line%%: *}"$'\t'"${line#*: }")
      OUT_ROWS[-1]="${OUT_ROWS[-1],}"
    else
      OUT_NOTES+=("$line")
    fi
    first=0
  done
  return 0
}

# _out_wrap TEXT INDENT [COLOR] — TEXT broken at spaces to the terminal width, each line indented by
# INDENT spaces and in COLOR (an escape; default none), printed.
_out_wrap() {
  local LC_ALL=C.UTF-8 text=$1 ind=$2 col=${3:-} w line="" word
  w=$((OUT_W - ind))
  for word in $text; do
    if [[ -n "$line" && $((${#line} + 1 + ${#word})) -gt $w ]]; then
      printf '%*s%s%s%s\n' "$ind" '' "$col" "$line" "${col:+$C_RESET}"
      line=$word
    else
      line=${line:+$line }$word
    fi
  done
  [[ -n "$line" ]] && printf '%*s%s%s%s\n' "$ind" '' "$col" "$line" "${col:+$C_RESET}"
  return 0
}

# _out_info TEXT — one of mm_info's lines, wrapped to the terminal at word boundaries and indented 2;
# dim when the caller dimmed it.
_out_info() {
  local col=""
  [[ -n "$C_DIM" && "$1" == "$C_DIM"* ]] && col=$C_DIM
  _out_plain "$1"
  _out_wrap "$REPLY" "${_OUT_IND:-2}" "$col"
}

# mm purge's question, on two lines when the terminal is too narrow for the options after it.
_purge_ask() {
  local reply
  _out_live_clear
  if ((OUT_W < 72)); then
    printf '\n%s?%s Purge which artifacts?\n  %s ' "$C_YELLOW" "$C_RESET" "${1// \/ /\/}" >/dev/tty
  else
    printf '\n%s?%s Purge which artifacts? %s ' "$C_YELLOW" "$C_RESET" "$1" >/dev/tty
  fi
  read -r reply </dev/tty || return 1
  printf '%s' "$reply"
}

# ---------------------------------------------------------------- the shared engine
# The card, the live line (a bar on the last line of the screen, drawn only on a terminal and erased
# before anything else is printed) and the aligned "key  value" row.

# _out_card KIND TITLE [KEY VALUE]... — a bordered card, to stdout (stderr for KIND err). KIND:
# ok (green) and dry (yellow) for a change and its preview; good, warn and bad for a report; err
# (red, on stderr); info (dim). A KEY starting with * has its value in bold; an empty KEY is a
# line of its own ("*" bold, "~" dim, "" plain). Values wrap under their key, so nothing is cut on
# a narrow terminal. The card is at most 64 columns wide.
_out_card() {
  local kind=$1 title=$2 edge k v w inner kw=0 i line first fd=1
  local bd=$C_BOLD dm=$C_DIM rs=$C_RESET
  shift 2
  case "$kind" in ok | good) edge=$C_GREEN ;; dry | warn) edge=$C_YELLOW ;; bad) edge=$C_RED ;; err) edge=$C_RED fd=2 ;; *) edge=$dm ;; esac
  # an error card goes to stderr and takes that stream's colors (none when it is not a terminal)
  [[ "$kind" == err ]] && { edge=$CE_RED bd=${CE_RESET:+$bd} dm=$CE_DIM rs=$CE_RESET; }
  w=64; ((w > OUT_W - 2)) && w=$((OUT_W - 2)); ((w < 24)) && w=24
  inner=$((w - 4))
  local -a keys=() vals=() bold=()
  while (($# >= 2)); do
    k=$1 v=$2; shift 2
    [[ -n "$v" ]] || continue
    case "$k" in \**) bold+=(1) k=${k:1} ;; \~*) bold+=(2) k=${k:1} ;; *) bold+=(0) ;; esac
    keys+=("$k") vals+=("$v")
    ((${#k} > kw)) && kw=${#k}
  done
  ((kw > inner / 2)) && kw=$((inner / 2))
  _out_cut "$title" $((inner - 2)); title=$REPLY
  _out_rule $((w - 5 - ${#title}))
  {
    printf '\n%s╭─%s %s%s%s %s%s╮%s\n' "$edge" "$rs" "$bd" "$title" "$rs" "$edge" "$REPLY" "$rs"
    for i in "${!keys[@]}"; do
      local room=$((inner - kw - 2)) val=${vals[$i]} key=${keys[$i]} chunk
      [[ -z "$key" ]] && room=$inner
      first=1
      while :; do
        if ((${#val} > room)); then
          chunk=${val:0:room}
          [[ "$chunk" == *" "* && "${val:room:1}" != " " ]] && chunk=${chunk% *}
          val=${val:${#chunk}}; val=${val# }
        else chunk=$val val=""; fi
        if [[ -z "${keys[$i]}" ]]; then
          case "${bold[$i]}" in 1) line="$bd$chunk$rs" ;; 2) line="$dm$chunk$rs" ;; *) line=$chunk ;; esac
        else
          ((bold[i] == 1)) && [[ -n "$chunk" ]] && chunk="$bd$chunk$rs"
          if ((first)); then _out_cut "$key" "$kw"; line="$dm$(printf '%-*s' "$kw" "$REPLY")$rs  $chunk"
          else line="$(printf '%*s' "$kw" '')  $chunk"; fi
        fi
        _out_pad "$line" "$inner"
        printf '%s│%s %s %s│%s\n' "$edge" "$rs" "$REPLY" "$edge" "$rs"
        first=0
        [[ -n "$val" ]] || break
      done
    done
    _out_rule $((w - 2))
    printf '%s╰%s╯%s\n' "$edge" "$REPLY" "$rs"
  } >&"$fd"
}

# _out_kv KEY VALUE [MARK] [INDENT] — "  MARK KEY   value", the value left-aligned in a column that
# fits the longest key (OUT_KW, set by the caller), hanging when it is longer than the line.
_out_kv() {
  local key=$1 val=$2 mark=${3:- } ind=${4:-2} kw=${OUT_KW:-8} room lead chunk first=1
  printf -v lead '%*s%s ' "$ind" '' "$mark"
  room=$((OUT_W - ind - 2 - kw - 1))
  ((room < 12)) && room=12
  while :; do
    if ((${#val} > room)); then
      chunk=${val:0:room}
      [[ "$chunk" == *" "* && "${val:room:1}" != " " ]] && chunk=${chunk% *}
      val=${val:${#chunk}}; val=${val# }
    else chunk=$val val=""; fi
    if ((first)); then printf '%s%s%-*s%s %s\n' "$lead" "$C_DIM" "$kw" "$key" "$C_RESET" "$chunk"
    else printf '%*s%s\n' $((ind + 2 + kw + 1)) '' "$chunk"; fi
    first=0
    [[ -n "$val" ]] || break
  done
}

# ---- the live line
# A bar on the last line of the screen while a command works, drawn only on a terminal and erased
# before anything else is printed. It counts what the command told it (mm_prog_plan, mm_prog_items).
_OUT_LIVE=0 _OUT_WORK=0 _OUT_DRAWN=0
_OUT_STEP_N=0 _OUT_STEP_I=0 _OUT_STEP="" _OUT_ITEM="" _OUT_ITEM_N=0 _OUT_ITEM_I=0
_OUT_BYTES=0 _OUT_BYTES_DONE=0
# On a terminal only; never in a pipe, never with TERM=dumb or MM_NO_SPIN=1 (--json, --agent).
[[ -t 1 && "${TERM:-}" != dumb && "${MM_NO_SPIN:-0}" != 1 ]] && _OUT_LIVE=1

# _out_live_clear — erase the live line; call before printing anything else.
_out_live_clear() {
  ((_OUT_LIVE)) || return 0
  ((_OUT_DRAWN)) && printf '\r\e[K'
  _OUT_DRAWN=0
}

# _out_live_show — draw the live line (_out_draw_live puts it in REPLY; it returns 1 when there is
# nothing to draw yet).
_out_live_show() {
  ((_OUT_LIVE && _OUT_WORK)) || return 0
  _out_draw_live || return 0
  printf '\r\e[K%s' "$REPLY"
  _OUT_DRAWN=1
  return 0
}

# _out_live_end — the work is over: erase the line for good.
_out_live_end() { _out_live_clear; _OUT_WORK=0 _OUT_ITEM_N=0 _OUT_STEP_N=0; }

# _out_bar_cells FRACTION_NUM FRACTION_DEN WIDTH — a filled bar plus its dim track, colored, in REPLY.
_out_bar_cells() {
  local f s track
  _out_bar "$1" "$2" "$3"; f=$REPLY
  _out_pad "$f" "$3"; s=$REPLY
  track=${s#"$f"}; track=${track// /░}
  REPLY="$C_CYAN$f$C_DIM$track$C_RESET"
}
