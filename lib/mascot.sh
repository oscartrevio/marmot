# shellcheck shell=bash
# The marmot: how it is drawn (mm status's header, install.sh's closing art) and what day it is.
# Two layers that never hide each other:
#   face         how the machine is: the eyes, a mark after the head (z Z, !, c[_], ✦) and the
#                cheeks. The caller picks the mood (mm status: _status_mood); it is drawn as is.
#   decorations  what day it is: a hat, a mark before the head, patterns on the rule, eyes for a
#                calm face, greeting lines. mm_occasions finds the day's rows in MM_CALENDAR,
#                mm_marmot_dress turns them into MM_LOOK_* slots.
# mm_marmot_draw draws both from MM_LOOK_*, so any combination can also be drawn on purpose.
# Sourcing this file defines names only; nothing here writes a file or runs a command but `date`
# for a YYYY-MM-DD argument: install.sh sources it as it is.
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
declare -gA MM_HATS=([hardhat]='C_YELLOW _/====\_' [santa]='C_RED {~~~~~}o' [party]='C_CYAN _../\.._')
# Marks → "COLOR TEXT": at most four columns before the head.
declare -gA MM_MARKS=(
  [heart]='C_RED <3' [confetti]="C_YELLOW *.'*" [pi]='C_CYAN 3.14' [leaf]='C_GREEN ❧'
  [saber]='C_CYAN [|==' [pumpkin]='C_YELLOW (|)' [flower]='C_YELLOW ✿'
)
# Rule patterns → where they go on the rule: bg (the whole rule), left or right (its ends). One
# pattern per place; see mm_marmot_draw for their shapes.
declare -gA MM_RULE_AT=([snow]=bg [shadow]=left [web]=right [cat]=right)

# The calendar: one occasion per row, "id|when|hat|mark|rule|eyes|greeting", in priority order:
# when two occasions want the same slot (a hat, a mark, the eyes, one place on the rule) the upper
# row's wins and the other's other slots still show; every greeting is kept, in this order.
#   when      MM-DD; MM-DD~MM-DD, a range (it may wrap the new year); nth:MONTH:WEEKDAY:N, the
#             Nth WEEKDAY (1 Monday ... 7 Sunday) of MONTH, N = -1 the last; yday:N, the Nth day
#             of the year; dow:WEEKDAY:DAY, that weekday on that day of a month; epoch, the day
#             Unix time passes a multiple of 100 million seconds; anniv, the day marmot first ran
#             here (mm_occasions' SINCE), every year after.
#   hat, mark, rule, eyes
#             names in MM_HATS, MM_MARKS, MM_RULE_AT, and jack, groucho or pirate for the eyes,
#             worn by a calm face only (happy, sleepy, proud); a problem face keeps its own.
#   greeting  a line beside the paws; "@" has _mm_greeting word it.
MM_CALENDAR=(
  'christmas|12-24~12-26|santa||||Merry Christmas'
  "newyear|12-31~01-01|party|confetti|||Happy New Year"
  'anniversary|anniv|party|heart|||@'
  'review|01-01~01-07|||||@'
  'groundhog|02-02|||shadow||@'
  "valentine|02-14||heart|||Happy Valentine's Day"
  'leapday|02-29|||||A bonus day: 24 more hours for your agents'
  'piday|03-14||pi|||Happy Pi Day: 3.14159265...'
  "stpatrick|03-17|||||Happy St. Patrick's Day"
  'backup|03-31|||||World Backup Day: marmot frees space and keeps no copies, so back up today'
  'aprilfools|04-01||||groucho|April Fools: the glasses are fake, the numbers are real'
  'earthday|04-22||leaf|||Earth Day: every byte freed is a byte nobody stores'
  'starwars|05-04||saber|||May the free space be with you.'
  "towel|05-25|||||Towel Day: Don't panic."
  "sysadmin|nth:7:5:-1|||||Happy Sysadmin Day (that's you)"
  'debian|08-16|party||||@'
  'linux|08-25|party||||@'
  'programmers|yday:256|||||Happy 0x100th day, programmers'
  'mexico|09-15~09-16|||||Viva Mexico!'
  'pirate|09-19||||pirate|Arr, it be Talk Like a Pirate Day'
  "ada|nth:10:2:2|||||Ada Lovelace Day: she programmed a machine nobody had built yet"
  'halloween|10-31||pumpkin|web|jack|Happy Halloween'
  'spooky|10-24~10-30||pumpkin|web||'
  'muertos|11-01~11-02||flower|||@'
  'thanksgiving|nth:11:4:4|||||@'
  'friday13|dow:5:13|||cat||Friday the 13th: marmot checks twice, as always'
  'unixtime|epoch|||||@'
  'winter|12-01~02-29|||snow||'
)

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

# _mm_mdays YEAR MONTH — the number of days in that month, in REPLY.
_mm_mdays() {
  case $2 in
    2) if (($1 % 4 == 0 && ($1 % 100 != 0 || $1 % 400 == 0))); then REPLY=29; else REPLY=28; fi ;;
    4 | 6 | 9 | 11) REPLY=30 ;;
    *) REPLY=31 ;;
  esac
}

# mm_occasions DATE [SINCE] — the ids of the MM_CALENDAR rows DATE falls on into MM_OCC, in
# calendar order. DATE is an epoch or YYYY-MM-DD (noon), read in local time; SINCE, the epoch
# marmot first ran on this machine, adds its anniversaries. For _mm_greeting it also sets
# _MM_OCC_YEAR, _MM_OCC_YEARS (the anniversary's) and _MM_OCC_UNIX (the day's round Unix time).
mm_occasions() {
  local e=$1 since=${2:-} row id when y m d u j hh mi ss md a b n wd mo sy sm sd day0 k
  MM_OCC=() _MM_OCC_YEARS=0 _MM_OCC_UNIX=0
  if [[ "$e" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then e=$(date -d "$e 12:00" +%s) || return 1; fi
  printf -v row '%(%Y %m %d %u %j %H %M %S)T' "$e"
  read -r y m d u j hh mi ss <<<"$row"
  y=$((10#$y)) m=$((10#$m)) d=$((10#$d)) j=$((10#$j))
  md=$((m * 100 + d)) _MM_OCC_YEAR=$y
  for row in "${MM_CALENDAR[@]}"; do
    IFS='|' read -r id when _ <<<"$row"
    case "$when" in
      anniv)
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        printf -v a '%(%Y %m %d)T' "$since"
        read -r sy sm sd <<<"$a"
        sy=$((10#$sy)) sm=$((10#$sm)) sd=$((10#$sd))
        _mm_mdays "$y" "$sm"
        ((sd > REPLY)) && sd=$REPLY # a Feb 29 start: Feb 28 in the other years
        ((y > sy && m == sm && d == sd)) || continue
        _MM_OCC_YEARS=$((y - sy))
        ;;
      epoch)
        day0=$((e - 10#$hh * 3600 - 10#$mi * 60 - 10#$ss))
        k=$(((day0 + 99999999) / 100000000 * 100000000))
        ((k < day0 + 86400)) || continue
        _MM_OCC_UNIX=$k
        ;;
      nth:*)
        IFS=: read -r _ mo wd n <<<"$when"
        ((m == mo && u == wd)) || continue
        if ((n < 0)); then
          _mm_mdays "$y" "$m"
          ((d + 7 > REPLY)) || continue
        else
          (((d - 1) / 7 + 1 == n)) || continue
        fi
        ;;
      yday:*) ((j == ${when#yday:})) || continue ;;
      dow:*)
        IFS=: read -r _ wd n <<<"$when"
        ((u == wd && d == n)) || continue
        ;;
      *~*)
        a=${when%~*} b=${when#*~}
        a=$((10#${a%-*} * 100 + 10#${a#*-})) b=$((10#${b%-*} * 100 + 10#${b#*-}))
        if ((a <= b)); then ((md >= a && md <= b)) || continue
        else ((md >= a || md <= b)) || continue; fi
        ;;
      *) ((md == 10#${when%-*} * 100 + 10#${when#*-})) || continue ;;
    esac
    MM_OCC+=("$id")
  done
  return 0
}

# _mm_greeting ID SCORE — the greeting of a "@" row in REPLY, from the date mm_occasions saw,
# the health SCORE (empty: unknown) and the operations log's MM_FACT_* (lib/core.sh
# mm_log_facts; empty when unknown); empty when there is nothing to say.
_mm_greeting() {
  local s
  REPLY=""
  case $1 in
    anniversary)
      s=s
      ((_MM_OCC_YEARS == 1)) && s=""
      REPLY="$_MM_OCC_YEARS year$s keeping this machine tidy"
      ;;
    review)
      [[ -n "${MM_FACT_PREV_RUNS:-}" ]] && ((MM_FACT_PREV_RUNS > 0)) || return 0
      s=s
      ((MM_FACT_PREV_RUNS == 1)) && s=""
      REPLY="Last year marmot freed $MM_FACT_PREV_FREED on this machine in $MM_FACT_PREV_RUNS run$s"
      REPLY+="; biggest win $MM_FACT_PREV_BIG_AT ($MM_FACT_PREV_BIG)"
      ;;
    groundhog)
      if [[ -z "$2" ]]; then REPLY="Groundhog Day, and Marmot Day in Alaska"
      elif (($2 < 100)); then REPLY="Marmot Day: it saw its shadow, six more weeks of cleanup"
      else REPLY="Marmot Day: no shadow, an early spring"; fi
      ;;
    debian) REPLY="Happy Debian Day: $((_MM_OCC_YEAR - 1993)) years of Debian" ;;
    linux) REPLY="Happy birthday, Linux: $((_MM_OCC_YEAR - 1991)) today" ;;
    muertos)
      REPLY="Dia de Muertos"
      [[ -n "${MM_FACT_BIG_AT:-}" ]] && REPLY+=": en memoria de $MM_FACT_BIG_AT ($MM_FACT_BIG)"
      ;;
    thanksgiving)
      REPLY="Happy Thanksgiving"
      [[ -n "${MM_FACT_YEAR_FREED:-}" ]] && REPLY="Thankful for $MM_FACT_YEAR_FREED freed this year"
      ;;
    unixtime) printf -v REPLY 'Unix time turns %d today at %(%H:%M)T' "$_MM_OCC_UNIX" "$_MM_OCC_UNIX" ;;
  esac
  return 0
}

# mm_marmot_dress MOOD SCORE ATWORK ID... — the decorations of occasions ID... (mm_occasions'
# MM_OCC) on a marmot with face MOOD into MM_LOOK_HAT, MM_LOOK_MARK, MM_LOOK_EYES, MM_LOOK_RULE
# (pattern names) and MM_LOOK_GREETS (lines). Slots go by calendar order, whatever the order of
# ID...; festive eyes only on a calm face (happy, sleepy, proud). ATWORK 1 (a marmot cleanup is
# running) wears the hard hat over any other hat. SCORE (health; empty: unknown) decides whether
# the marmot sees its shadow on Groundhog Day: below 100 it does.
mm_marmot_dress() {
  local mood=$1 score=$2 work=$3 row id hat mark rule eyes greet
  local -A want=() at=()
  shift 3
  for id; do want[$id]=1; done
  MM_LOOK_HAT="" MM_LOOK_MARK="" MM_LOOK_EYES="" MM_LOOK_RULE="" MM_LOOK_GREETS=()
  for row in "${MM_CALENDAR[@]}"; do
    IFS='|' read -r id _ hat mark rule eyes greet <<<"$row"
    [[ -n "${want[$id]:-}" ]] || continue
    [[ "$id" == groundhog ]] && { [[ -n "$score" ]] && ((score < 100)) || rule=""; }
    [[ -z "$MM_LOOK_HAT" ]] && MM_LOOK_HAT=$hat
    [[ -z "$MM_LOOK_MARK" ]] && MM_LOOK_MARK=$mark
    [[ -z "$MM_LOOK_EYES" ]] && MM_LOOK_EYES=$eyes
    if [[ -n "$rule" && -z "${at[${MM_RULE_AT[$rule]}]:-}" ]]; then
      at[${MM_RULE_AT[$rule]}]=1
      MM_LOOK_RULE+="${MM_LOOK_RULE:+ }$rule"
    fi
    if [[ "$greet" == @ ]]; then _mm_greeting "$id" "$score"; greet=$REPLY; fi
    [[ -n "$greet" ]] && MM_LOOK_GREETS+=("$greet")
  done
  [[ "$mood" == happy || "$mood" == sleepy || "$mood" == proud ]] || MM_LOOK_EYES=""
  ((work)) && MM_LOOK_HAT=hardhat
  return 0
}

# mm_marmot_draw MOOD WIDTH [TITLE] [FACTS] [COLOR] — the marmot as five rows in MM_ART: TITLE
# beside its ears, FACTS (dimmed) beside its eyes, MM_LOOK_GREET (dimmed) beside its paws, and
# its paws and teeth on a rule WIDTH columns wide. The marmot takes the first 21 columns; the
# caller fits the texts into the rest. MOOD is one of MM_FACES, its eyes in COLOR (an escape
# sequence). The rest is MM_LOOK_*: CHEEKS=1 stuffs its cheeks and BLINK=1 closes open eyes (the
# face); HAT, MARK, EYES and RULE as mm_marmot_dress sets them (the decorations).
mm_marmot_draw() {
  local LC_ALL=C.UTF-8
  local mood=$1 w=$2 title=${3:-} facts=${4:-} col=${5:-} l r open c t left="     " mark="" head row3 vis
  local rule n i p
  local -a pats
  read -r -a pats <<<"${MM_LOOK_RULE:-}"
  read -r l r open <<<"${MM_FACES[$mood]:-o o 1}"
  case ${MM_LOOK_EYES:-} in
    jack) l=∆ r=∆ ;;
    pirate) l='#' ;;
  esac
  ((${MM_LOOK_BLINK:-0} && open)) && l=- r=-
  # Row 1: the decoration's mark, the head or a hat, the face's mark.
  if [[ -n "${MM_LOOK_MARK:-}" && -n "${MM_MARKS[$MM_LOOK_MARK]:-}" ]]; then
    read -r c t <<<"${MM_MARKS[$MM_LOOK_MARK]}"
    printf -v left '%*s%s%s%s ' $((4 - ${#t})) '' "${!c}" "$t" "$C_RESET"
  fi
  head=_..--.._
  if [[ -n "${MM_LOOK_HAT:-}" && -n "${MM_HATS[$MM_LOOK_HAT]:-}" ]]; then
    read -r c t <<<"${MM_HATS[$MM_LOOK_HAT]}"
    head=${!c}$t$C_RESET
  fi
  if [[ -n "${MM_FACE_MARKS[$mood]:-}" ]]; then
    read -r c t <<<"${MM_FACE_MARKS[$mood]}"
    mark="  ${!c}$t$C_RESET"
  fi
  # Row 3: the eyes (in glasses on April Fools), the cheeks, then FACTS from column 21.
  if [[ "${MM_LOOK_EYES:-}" == groucho ]]; then row3="| ($col$l$C_RESET)--($col$r$C_RESET) |"
  else row3="|  $col$l$C_RESET    $col$r$C_RESET  |"; fi
  vis=12
  if ((${MM_LOOK_CHEEKS:-0})); then row3="  ($row3)" vis=$((vis + 4)); else row3="   $row3" vis=$((vis + 3)); fi
  [[ -n "$facts" ]] && printf -v row3 '%s%*s%s%s%s' "$row3" $((21 - vis)) '' "$C_DIM" "$facts" "$C_RESET"
  # Row 5: the rule, light snow over all of it, a shadow at its left end, a spider's web or a
  # black cat at its right end.
  n=$((w > 18 ? w - 18 : 0))
  printf -v rule '%*s' "$n" ''
  rule=${rule// /-}
  for p in "${pats[@]}"; do
    case $p in
      snow)
        for ((i = 3; i < n; i++)); do
          ((i % 17 == 5)) && rule=${rule:0:i}'*'${rule:i+1}
          ((i % 11 == 8)) && rule=${rule:0:i}'.'${rule:i+1}
        done
        ;;
    esac
  done
  for p in "${pats[@]}"; do
    case $p in
      shadow) ((n >= 12)) && rule='.::::::.'${rule:8} ;;
      web) ((n >= 12)) && rule=${rule:0:n-9}"/\\oo/\\"${rule:n-3} ;;
      cat) ((n >= 12)) && rule=${rule:0:n-8}'=^.^='${rule:n-3} ;;
    esac
  done
  MM_ART=("$left$head$mark"
    "  ()'        '()${title:+     $title}"
    "$row3"
    "  .--.  \\/  .--.${MM_LOOK_GREET:+     $C_DIM$MM_LOOK_GREET$C_RESET}"
    "$C_DIM--$C_RESET(mm)$C_DIM--${C_RESET}UU$C_DIM--$C_RESET(mm)$C_DIM--$rule$C_RESET")
}
