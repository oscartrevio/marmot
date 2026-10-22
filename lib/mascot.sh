# shellcheck shell=bash
# The marmot: how it is drawn (mm status's header, install.sh's closing art) and what day it is.
# Two layers that never hide each other:
#   face         how the machine is: the eyes, a mark beside the head (z Z, !, a mug of coffee,
#                +*) and the cheeks. The caller picks the mood (mm status: _status_mood); it is
#                drawn as is.
#   decorations  what day it is: a hat, a mark around the head, props on the rule, eyes for a calm
#                face, the teeth, greeting lines. mm_occasions finds the day's rows in MM_CALENDAR,
#                mm_marmot_dress turns them into MM_LOOK_* slots.
# mm_marmot_draw draws both from MM_LOOK_*, so any combination can also be drawn on purpose; all
# of it is art in MM_PARTS and MM_EYES, none in code.
# Sourcing this file defines names only; nothing here writes a file or runs a command but `date`
# for a YYYY-MM-DD argument: install.sh sources it as it is.
# Every character drawn is printable ASCII (0x20-0x7E) or on MM_GLYPHS: one column in every
# terminal and font, never an emoji or a glyph from a fallback font. The shapes carry the meaning
# without color.

# The only characters drawn beyond ASCII: ∆ (U+2206, jack-o'-lantern eyes), East Asian Width N,
# no emoji presentation, in JetBrains Mono, Menlo, DejaVu Sans Mono and Ubuntu Mono.
MM_GLYPHS=(∆)

# Moods → "LEFT RIGHT OPEN": the eyes, and 1 when they are open (only open eyes blink).
declare -gA MM_FACES=(
  [happy]='^ ^ 1' [proud]='^ ^ 1' [neutral]='o o 1' [alert]='O O 1' [squint]='> < 0'
  [dizzy]='x x 0' [sleepy]='- - 0' [night]='- o 0' [tired]='= = 0'
)
# Festive eyes → "INK|EYES": the ten columns inside the face on the eyes row. L and R are the
# mood's own eyes (and blink); the rest is drawn in INK (see MM_PARTS).
declare -gA MM_EYES=(
  [groucho]='.| (L)--(R) ' [pirate]='.|  #    R  ' [jack]='y|  ∆    ∆  ' [calavera]='y| (*)  (*) '
)
# Everything else drawn, one part per line: "NAME|ROW|COL|INK|TEXT", in drawing order (a later
# part covers an earlier one, spaces too). NAME is SLOT:NAME (the slots of mm_marmot_draw).
#   ROW   0 the sky (a row above the head, drawn only when a part is there), 1 the top of the
#         head, 2 the ears, 3 the eyes, 4 the cheeks, 5 the rule.
#   COL   the first column. On rows 2 to 4 a part ends before column 20, a blank column ahead of
#         the caller's text; on the others it ends inside the width. -N: N columns from the rule's
#         right end; START+STEP: again every STEP columns to the end; +N: N after the head or hat
#         on row 1 (the face's marks).
#   INK   . plain, d dim, w bold, r g y b m c red green yellow blue magenta cyan.
# A part that does not fit is left out.
# shellcheck disable=SC1003 # art ends in a backslash inside single quotes, as meant
MM_PARTS=(
  'marmot:|1|5|.|_..--.._'
  "marmot:|2|2|.|()'        '()"
  'marmot:|3|3|.||          |'
  'marmot:|4|2|.|.--.  \/  .--.'
  'marmot:|5|2|.|(mm)--UU--(mm)'
  'marmot:|5|6|d|--'
  'marmot:|5|10|d|--'
  # Hats, all on the hard hat's footprint (the sky row and the top of the head): a pointed cone
  # with dots on a small brim; a rounded cap flopping to one side into its pom-pom over a fur
  # brim; a dome with a ridge and a brim.
  'hat:party|0|8|y|/\'
  'hat:party|1|5|c|_/o*o*\_'
  'hat:party|1|7|y|o'
  'hat:party|1|9|y|o'
  'hat:party|1|8|m|*'
  'hat:party|1|10|m|*'
  'hat:santa|0|5|r|.-"""-.'
  'hat:santa|0|12|r|\'
  'hat:santa|0|13|w|o'
  'hat:santa|1|4|w|(########)'
  'hat:hardhat|0|6|y|.-||-.'
  'hat:hardhat|1|4|y|_/__||__\_'
  # Marks: before the head, in the sky, over the title.
  'mark:heart|1|0|r|<3'
  'mark:pi|1|0|c|3.14'
  'mark:fireworks|0|0|y|\|/'
  'mark:fireworks|1|0|y|/|\'
  'mark:fireworks|0|27|r|\|/'
  'mark:fireworks|1|27|r|/|\'
  'mark:fireworks|1|32|m|*'
  'mark:fireworks|0|35|c|.\|/.'
  "mark:fireworks|1|35|c|'/|\\'"
  'mark:fireworks|0|42|y|*'
  'mark:fireworks|0|45|m|\|/'
  'mark:fireworks|1|45|m|/|\'
  'mark:picado|0|0|d|~[#]~[#]~[#]~[#]~[#]~'
  'mark:picado|0|1|m|[#]'
  'mark:picado|0|5|y|[#]'
  'mark:picado|0|9|c|[#]'
  'mark:picado|0|13|r|[#]'
  'mark:picado|0|17|g|[#]'
  # A jack-o'-lantern beside the head: ribbed and round, a green stem, triangle eyes, a toothy
  # grin; clear of the face's marks (they end by column 21).
  'mark:pumpkin|0|23|y|_.--)--._'
  'mark:pumpkin|0|27|g|)'
  'mark:pumpkin|1|22|y|(( ^vVv^ ))'
  # On the rule, by place (MM_RULE_AT): all of it first, then its ends and beside the right paw.
  'rule:snow|5|23+17|d|*'
  'rule:snow|5|26+11|d|.'
  'rule:marigolds|5|18+5|g|,@,'
  'rule:marigolds|5|19+5|y|@'
  'rule:web|5|-9|d|/\oo/\'
  'rule:cat|5|-8|d|=^.^='
  'rule:saber|5|16|w|[|||]'
  'rule:saber|5|21|c|===================='
  'rule:tree|2|18|g|^'
  'rule:tree|3|17|g|/ \'
  'rule:tree|4|17|g|/_\'
  'rule:tree|5|18|y||'
  # Teeth: vampire fangs beside the incisors.
  'teeth:fangs|5|7|w|V'
  'teeth:fangs|5|10|w|V'
  # The face's marks, after the head or hat.
  'face:sleepy|1|+0|d|z Z'
  'face:alert|1|+0|y|!'
  'face:proud|1|+0|y|+*'
  'face:night|4|17|d|) )'
  'face:night|5|17|.|[__]D'
  'face:cheeks|3|2|.|('
  'face:cheeks|3|15|.|)'
  # Waving (mm status's live view, key w): the right paw up beside the face, motion marks
  # swinging between two poses (a blank column before the title), its place on the rule empty.
  'wave:1|2|17|.|\\'
  'wave:1|3|16|.|(mm)'
  'wave:1|4|16|.|/'
  'wave:1|5|12|d|----'
  'wave:2|2|18|.|//'
  'wave:2|3|16|.|(mm)'
  'wave:2|4|16|.|/'
  'wave:2|5|12|d|----'
)
# Rule props → their place: bg (along the whole rule), right (its right end) or paw (beside the
# right paw). One prop per place.
declare -gA MM_RULE_AT=([snow]=bg [marigolds]=bg [web]=right [cat]=right [saber]=paw [tree]=paw)

# The calendar: one occasion per row, "id|when|hat|mark|rule|eyes|teeth|greeting", in priority
# order: when two occasions want the same slot (a hat, a mark, the eyes, the teeth, one place on
# the rule) the upper row's wins and the other's other slots still show; every greeting is kept,
# in this order.
#   when      MM-DD; MM-DD~MM-DD, a range (it may wrap the new year); nth:MONTH:WEEKDAY:N, the
#             Nth WEEKDAY (1 Monday ... 7 Sunday) of MONTH, N = -1 the last; yday:N, the Nth day
#             of the year; dow:WEEKDAY:DAY, that weekday on that day of a month; epoch, the day
#             Unix time passes a multiple of 100 million seconds; anniv, the day marmot first ran
#             here (mm_occasions' SINCE), every year after.
#   hat, mark, rule, teeth
#             part names in MM_PARTS (hat:NAME, ...); rule may name several, one per place.
#   eyes      a name in MM_EYES, worn by a calm face only (happy, sleepy, proud); a problem face
#             keeps its own.
#   greeting  a line beside the paws; "@" has _mm_greeting word it.
MM_CALENDAR=(
  'christmas|12-24~12-26|santa|||||Merry Christmas'
  "newyear|12-31~01-01|party|fireworks||||Happy New Year"
  'anniversary|anniv|party|heart||||@'
  'review|01-01~01-07||||||@'
  "valentine|02-14||heart||||Happy Valentine's Day"
  'leapday|02-29||||||A bonus day: 24 more hours for your agents'
  'piday|03-14||pi||||Happy Pi Day: 3.14159265...'
  "stpatrick|03-17||||||Happy St. Patrick's Day"
  'backup|03-31||||||World Backup Day: marmot frees space and keeps no copies, so back up today'
  'aprilfools|04-01||||groucho||April Fools: the glasses are fake, the numbers are real'
  'earthday|04-22|||tree|||Earth Day: every byte freed is a byte nobody stores'
  'starwars|05-04|||saber|||May the free space be with you.'
  "towel|05-25||||||Towel Day: Don't panic."
  "sysadmin|nth:7:5:-1||||||Happy Sysadmin Day (that's you)"
  'debian|08-16|party|||||@'
  'linux|08-25|party|||||@'
  'programmers|yday:256||||||Happy 0x100th day, programmers'
  'mexico|09-15~09-16||||||Viva Mexico!'
  'pirate|09-19||||pirate||Arr, it be Talk Like a Pirate Day'
  "ada|nth:10:2:2||||||Ada Lovelace Day: she programmed a machine nobody had built yet"
  'halloween|10-31||pumpkin|web|jack|fangs|Happy Halloween'
  'spooky|10-24~10-30||pumpkin|web||fangs|'
  'muertos|11-01~11-02||picado|marigolds|calavera||@'
  'thanksgiving|nth:11:4:4||||||@'
  'friday13|dow:5:13|||cat|||Friday the 13th: marmot checks twice, as always'
  'unixtime|epoch||||||@'
  'winter|12-01~02-29|||snow|||'
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

# _mm_greeting ID — the greeting of a "@" row in REPLY, from the date mm_occasions saw and the
# operations log's MM_FACT_* (lib/core.sh mm_log_facts; empty when unknown); empty when there is
# nothing to say.
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

# mm_marmot_dress MOOD ATWORK ID... — the decorations of occasions ID... (mm_occasions' MM_OCC) on
# a marmot with face MOOD into MM_LOOK_HAT, MM_LOOK_MARK, MM_LOOK_EYES, MM_LOOK_TEETH,
# MM_LOOK_RULE (names, space-separated) and MM_LOOK_GREETS (lines). Slots go by calendar order,
# whatever the order of ID...; festive eyes only on a calm face (happy, sleepy, proud). ATWORK 1
# (a marmot cleanup is running) wears the hard hat over any other hat.
mm_marmot_dress() {
  local mood=$1 work=$2 row id hat mark rules eyes teeth greet p
  local -a pats
  local -A want=() at=()
  shift 2
  for id; do want[$id]=1; done
  MM_LOOK_HAT="" MM_LOOK_MARK="" MM_LOOK_EYES="" MM_LOOK_TEETH="" MM_LOOK_RULE="" MM_LOOK_GREETS=()
  for row in "${MM_CALENDAR[@]}"; do
    IFS='|' read -r id _ hat mark rules eyes teeth greet <<<"$row"
    [[ -n "${want[$id]:-}" ]] || continue
    [[ -z "$MM_LOOK_HAT" ]] && MM_LOOK_HAT=$hat
    [[ -z "$MM_LOOK_MARK" ]] && MM_LOOK_MARK=$mark
    [[ -z "$MM_LOOK_EYES" ]] && MM_LOOK_EYES=$eyes
    [[ -z "$MM_LOOK_TEETH" ]] && MM_LOOK_TEETH=$teeth
    read -r -a pats <<<"$rules"
    for p in "${pats[@]}"; do
      [[ -z "${at[${MM_RULE_AT[$p]}]:-}" ]] || continue
      at[${MM_RULE_AT[$p]}]=1
      MM_LOOK_RULE+="${MM_LOOK_RULE:+ }$p"
    done
    if [[ "$greet" == @ ]]; then _mm_greeting "$id"; greet=$REPLY; fi
    [[ -n "$greet" ]] && MM_LOOK_GREETS+=("$greet")
  done
  [[ "$mood" == happy || "$mood" == sleepy || "$mood" == proud ]] || MM_LOOK_EYES=""
  ((work)) && MM_LOOK_HAT=hardhat
  return 0
}

# _mm_put ROW COL INK TEXT — TEXT in INK from column COL of row ROW of mm_marmot_draw's canvas
# (its arrays R, the characters, and K, one ink letter per character).
_mm_put() {
  local inks
  printf -v inks '%*s' "${#4}" ''
  R[$1]=${R[$1]:0:$2}$4${R[$1]:$2+${#4}}
  K[$1]=${K[$1]:0:$2}${inks// /$3}${K[$1]:$2+${#4}}
}

# mm_marmot_draw MOOD WIDTH [TITLE] [FACTS] [COLOR] — the marmot into MM_ART: five rows, six when
# something reaches the sky above its head. TITLE beside its ears, FACTS (dimmed) beside its eyes,
# MM_LOOK_GREET (dimmed) beside its cheeks, its paws and teeth on a rule WIDTH columns wide. On
# the rows with text the marmot keeps to its first 20 columns and the text starts at column 21
# (the caller fits it into the rest); the sky, the top of the head and the rule may reach WIDTH.
# MOOD is one of MM_FACES, its eyes in COLOR (an escape sequence). The rest is MM_LOOK_*:
# CHEEKS=1 stuffs its cheeks, BLINK=1 half-closes open eyes and BLINK=2 shuts them (the face);
# HAT, MARK, EYES, RULE and TEETH as mm_marmot_dress sets them (the decorations); WAVE=1 or 2
# raises its right paw beside its face in one of two poses (mm status's live view, key w).
mm_marmot_draw() {
  # Characters, not bytes: MM_GLYPHS are multibyte.
  local LC_ALL=C.UTF-8
  local mood=$1 w=$2 title=${3:-} facts=${4:-} col=${5:-} l r open ink eyes t i c n row at text
  local step lim line out e run blank right=0 sky=0
  local -a R K
  local -A want=()
  # Here-strings cost a pipe each: the tables are split with expansions instead.
  t=${MM_FACES[$mood]:-o o 1} && l=${t%% *} && t=${t#* } && r=${t%% *} && open=${t#* }
  for t in marmot: "hat:${MM_LOOK_HAT:-}" "mark:${MM_LOOK_MARK:-}" "teeth:${MM_LOOK_TEETH:-}" \
    "face:$mood" "wave:${MM_LOOK_WAVE:-0}"; do
    want[$t]=1
  done
  t=${MM_LOOK_RULE:-}
  while [[ -n "$t" ]]; do
    want[rule:${t%% *}]=1
    if [[ "$t" == *" "* ]]; then t=${t#* }; else t=""; fi
  done
  ((${MM_LOOK_CHEEKS:-0})) && want[face:cheeks]=1
  printf -v blank '%*s' $((w > 21 ? w : 21)) ''
  for ((i = 0; i < 5; i++)); do R[i]=$blank K[i]=${blank// /.}; done
  R[5]=${blank// /-} K[5]=${blank// /d}
  for line in "${MM_PARTS[@]}"; do
    [[ -n "${want[${line%%|*}]:-}" ]] || continue
    t=${line#*|} && row=${t%%|*} && t=${t#*|} && at=${t%%|*} && t=${t#*|} && ink=${t%%|*} && text=${t#*|}
    lim=$w step=0
    ((row >= 2 && row <= 4)) && lim=20
    case $at in
      -*) c=$((w + at)); ((c >= 18)) || continue ;;
      +*)
        # The face's marks: two columns after whatever the head wears.
        if ((!right)); then t=${R[1]:0:17} && t=${t%"${t##*[! ]}"} && right=$((${#t} + 2)); fi
        c=$((right + ${at#+}))
        ;;
      *+*) c=${at%+*} step=${at#*+} ;;
      *) c=$at ;;
    esac
    while ((c + ${#text} <= lim)); do
      _mm_put "$row" "$c" "$ink" "$text"
      ((row)) || sky=1
      ((step)) || break
      c=$((c + step))
    done
  done
  # The eyes: the mood's, or festive ones around them; open eyes blink.
  eyes='  L    R  ' ink=.
  if [[ -n "${MM_LOOK_EYES:-}" && -n "${MM_EYES[$MM_LOOK_EYES]:-}" ]]; then
    t=${MM_EYES[$MM_LOOK_EYES]} && ink=${t%%|*} && eyes=${t#*|}
  fi
  if ((open)); then
    case ${MM_LOOK_BLINK:-0} in 1) l=- r=- ;; 2) l=_ r=_ ;; esac
  fi
  t=${eyes//L/$l} c=${eyes//[!LR]/$ink}
  R[3]=${R[3]:0:4}${t//R/$r}${R[3]:14} K[3]=${K[3]:0:4}${c//[LR]/e}${K[3]:14}
  # Rows into text: a run of one ink at a time, then the caller's text from column 21.
  MM_ART=()
  for ((row = 1 - sky; row <= 5; row++)); do
    line=${R[row]} text=""
    case $row in
      2) text=$title ;;
      3) text=${facts:+$C_DIM$facts$C_RESET} ;;
      4) text=${MM_LOOK_GREET:+$C_DIM$MM_LOOK_GREET$C_RESET} ;;
      5) line=${line:0:w} ;;
    esac
    if [[ -n "$text" ]]; then line=${line:0:21}
    elif ((row < 5)); then line=${line%"${line##*[! ]}"}; fi
    out="" i=0
    while ((i < ${#line})); do
      e=${K[row]:i:1}
      run=${K[row]:i:${#line}-i}
      run=${run%%[!"$e"]*}
      n=${#run}
      case $e in
        d) e=$C_DIM ;; w) e=$C_BOLD ;; e) e=$col ;; r) e=$C_RED ;; g) e=$C_GREEN ;;
        y) e=$C_YELLOW ;; b) e=$C_BLUE ;; m) e=$C_MAGENTA ;; c) e=$C_CYAN ;; *) e="" ;;
      esac
      if [[ -n "$e" ]]; then out+=$e${line:i:n}$C_RESET; else out+=${line:i:n}; fi
      i=$((i + n))
    done
    MM_ART+=("$out$text")
  done
}
