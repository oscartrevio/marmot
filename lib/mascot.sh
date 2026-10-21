# shellcheck shell=bash
# The marmot: how it is drawn (the header of mm status). Its face says how the machine is: the
# caller picks the mood (mm status: _status_mood) and mm_marmot_draw draws exactly that.
# Sourcing this file defines names only; nothing here writes a file or runs a command.
# Every glyph is one terminal column wide in every locale (Unicode East Asian Width N or Na) and
# none is an emoji; the face's shape carries its meaning without color.

# Moods → "LEFT RIGHT OPEN": the eyes, and 1 when they are open (only open eyes blink).
declare -gA MM_FACES=(
  [happy]='^ ^ 1' [proud]='^ ^ 1' [neutral]='o o 1' [alert]='O O 1' [squint]='> < 0'
  [dizzy]='x x 0' [sleepy]='- - 0' [night]='- o 0' [tired]='¬ ¬ 0'
)
# Moods → "COLOR TEXT": the mark after the head (COLOR names a C_* variable).
declare -gA MM_FACE_MARKS=(
  [alert]='C_YELLOW !' [sleepy]='C_DIM z Z' [night]='C_DIM c[_]' [proud]='C_YELLOW ✦'
)
# Hats → "COLOR TEXT": eight columns that replace the top of the head.
declare -gA MM_HATS=([hardhat]='C_YELLOW _/====\_')

# mm_now — the time now (epoch seconds) in REPLY. The test suite points MM_TEST_NOW at a file
# holding an epoch to stand for another moment; that is honored only inside bats' per-test
# directory, and looked at once.
mm_now() {
  if [[ -n "${MM_TEST_NOW:-}" && -z "${_MM_NOW_SEEN:-}" ]]; then
    local f box
    _MM_NOW_SEEN=1 _MM_NOW_FIXED=""
    if f=$(realpath -e -- "$MM_TEST_NOW" 2>/dev/null) &&
      box=$(realpath -e -- "${BATS_TEST_TMPDIR:-/nonexistent}" 2>/dev/null) && [[ "$f" == "$box"/?* ]]; then
      read -r _MM_NOW_FIXED <"$f" || true
      [[ "$_MM_NOW_FIXED" =~ ^[0-9]+$ ]] || _MM_NOW_FIXED=""
    fi
  fi
  REPLY=${_MM_NOW_FIXED:-$EPOCHSECONDS}
}

# mm_marmot_draw MOOD WIDTH [TITLE] [FACTS] [COLOR] — the marmot as five rows in MM_ART: TITLE
# beside its ears, FACTS (dimmed) beside its eyes, MM_LOOK_GREET (dimmed) beside its paws, and
# its paws and teeth on a rule WIDTH columns wide. The marmot takes the first 21 columns; the
# caller fits the texts into the rest. MOOD is one of MM_FACES, its eyes in COLOR (an escape
# sequence). MM_LOOK_CHEEKS=1 stuffs its cheeks, MM_LOOK_BLINK=1 closes open eyes,
# MM_LOOK_HAT puts on one of MM_HATS.
mm_marmot_draw() {
  local LC_ALL=C.UTF-8
  local mood=$1 w=$2 title=${3:-} facts=${4:-} col=${5:-} l r open c t mark="" head row3 vis rule
  read -r l r open <<<"${MM_FACES[$mood]:-o o 1}"
  ((${MM_LOOK_BLINK:-0} && open)) && l=- r=-
  if [[ -n "${MM_FACE_MARKS[$mood]:-}" ]]; then
    read -r c t <<<"${MM_FACE_MARKS[$mood]}"
    mark="  ${!c}$t$C_RESET"
  fi
  head=_..--.._
  if [[ -n "${MM_LOOK_HAT:-}" && -n "${MM_HATS[$MM_LOOK_HAT]:-}" ]]; then
    read -r c t <<<"${MM_HATS[$MM_LOOK_HAT]}"
    head=${!c}$t$C_RESET
  fi
  row3="|  $col$l$C_RESET    $col$r$C_RESET  |" vis=12
  if ((${MM_LOOK_CHEEKS:-0})); then row3="  ($row3)" vis=$((vis + 4)); else row3="   $row3" vis=$((vis + 3)); fi
  [[ -n "$facts" ]] && printf -v row3 '%s%*s%s%s%s' "$row3" $((21 - vis)) '' "$C_DIM" "$facts" "$C_RESET"
  printf -v rule '%*s' $((w > 18 ? w - 18 : 0)) ''
  MM_ART=("     $head$mark"
    "  ()'        '()${title:+     $title}"
    "$row3"
    "  .--.  \\/  .--.${MM_LOOK_GREET:+     $C_DIM$MM_LOOK_GREET$C_RESET}"
    "$C_DIM--$C_RESET(mm)$C_DIM--${C_RESET}UU$C_DIM--$C_RESET(mm)$C_DIM--${rule// /-}$C_RESET")
}
