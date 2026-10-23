#!/usr/bin/env bats
# lib/mascot.sh: the calendar (which occasions a date falls on), how occasions dress the marmot
# around its face (slots, priority, problem faces first), the greetings that come from the
# operations log, and the drawing: its fixed geometry and nothing but printable ASCII.

setup() {
  load helpers/common
  mm_test_setup
  mm_core
  export TZ=UTC
}
teardown() { mm_test_teardown; }

# occ DATE [SINCE] — the occasions of DATE (YYYY-MM-DD), space-separated ("-" for none).
occ() {
  mm_occasions "$1" "${2:+$(date -d "$2 12:00" +%s)}"
  local o="${MM_OCC[*]}"
  echo "${o:--}"
}

# dress MOOD ATWORK ID... — "hat|mark|eyes|teeth|rule|greetings" for those occasions.
dress() {
  mm_marmot_dress "$@"
  local IFS=/
  echo "$MM_LOOK_HAT|$MM_LOOK_MARK|$MM_LOOK_EYES|$MM_LOOK_TEETH|$MM_LOOK_RULE|${MM_LOOK_GREETS[*]}"
}

@test "the calendar: seasons, fixed days and ranges, by the local date" {
  [ "$(occ 2026-11-30)" = - ]
  [ "$(occ 2026-12-01)" = winter ]
  [ "$(occ 2027-02-28)" = winter ]
  [ "$(occ 2027-03-01)" = - ]
  [ "$(occ 2028-02-29)" = "leapday winter" ]
  [ "$(occ 2026-12-23)" = winter ]
  [ "$(occ 2026-12-24)" = "christmas winter" ]
  [ "$(occ 2026-12-26)" = "christmas winter" ]
  [ "$(occ 2026-12-27)" = winter ]
  [ "$(occ 2026-12-31)" = "newyear winter" ]
  [ "$(occ 2027-01-01)" = "newyear review winter" ]
  [ "$(occ 2027-01-07)" = "review winter" ]
  [ "$(occ 2027-01-08)" = winter ]
  [ "$(occ 2027-02-02)" = winter ]
  [ "$(occ 2026-10-23)" = - ]
  [ "$(occ 2026-10-24)" = spooky ]
  [ "$(occ 2026-10-31)" = halloween ]
  [ "$(occ 2026-11-01)" = muertos ]
  [ "$(occ 2026-09-16)" = mexico ]
  # The epoch form gives the same day as the date form.
  [ "$(occ "$(date -d '2026-12-24 23:59' +%s)")" = "christmas winter" ]
}

@test "the calendar: rule-based days (256th day, last Friday, 4th Thursday, Friday the 13th, Unix time)" {
  [ "$(occ 2027-09-13)" = programmers ]          # the 256th day of a common year
  [ "$(occ 2027-09-12)" = - ]
  [ "$(occ 2028-09-12)" = programmers ]          # ... and of a leap year
  [ "$(occ 2028-09-13)" = - ]
  [ "$(occ 2026-07-31)" = sysadmin ]             # the last Friday of July
  [ "$(occ 2026-07-24)" = - ]                    # a Friday, not the last
  [ "$(occ 2027-07-30)" = sysadmin ]
  [ "$(occ 2026-11-26)" = thanksgiving ]         # the 4th Thursday of November
  [ "$(occ 2026-11-19)" = - ]
  [ "$(occ 2027-11-25)" = thanksgiving ]
  [ "$(occ 2026-11-13)" = friday13 ]
  [ "$(occ 2026-10-13)" = ada ]                  # a Tuesday 13th: the 2nd Tuesday of October
  [ "$(occ 2027-01-15)" = "unixtime winter" ]    # 1800000000 is 2027-01-15 08:00 UTC
  [ "$(occ 2027-01-14)" = winter ]
}

@test "the calendar: the yearly anniversary of the first run, Feb 29 on Feb 28 in other years" {
  [ "$(occ 2026-06-10 2025-06-10)" = anniversary ]
  [ "$(occ 2025-06-10 2025-06-10)" = - ]         # the day itself is no anniversary
  [ "$(occ 2026-06-11 2025-06-10)" = - ]
  [ "$(occ 2025-02-28 2024-02-29)" = "anniversary winter" ]
  [ "$(occ 2028-02-28 2024-02-29)" = winter ]
  [ "$(occ 2028-02-29 2024-02-29)" = "anniversary leapday winter" ]
  mm_occasions 2027-06-10 "$(date -d '2025-06-10 12:00' +%s)"
  [ "$_MM_OCC_YEARS" -eq 2 ]
}

@test "dress: a problem face keeps its eyes and still wears the day's hat, mark, teeth and rule" {
  [ "$(dress dizzy 0 christmas winter)" = "santa||||snow|Merry Christmas" ]
  [ "$(dress happy 0 halloween)" = "|pumpkin|jack|fangs|web|Happy Halloween" ]
  # Spooky week: fangs and the web, no jack-o'-lantern; that is Halloween's own.
  [ "$(dress happy 0 spooky)" = "|||fangs|web|" ]
  [ "$(dress happy 0 halloween | cut -d'|' -f2)" = pumpkin ]
  [ "$(dress sleepy 0 halloween | cut -d'|' -f3)" = jack ]
  [ "$(dress proud 0 halloween | cut -d'|' -f3)" = jack ]
  local mood
  for mood in alert dizzy squint neutral night tired; do
    [ "$(dress "$mood" 0 halloween)" = "|pumpkin||fangs|web|Happy Halloween" ] || { echo "$mood"; false; }
  done
  [ "$(dress dizzy 0 aprilfools | cut -d'|' -f3)" = "" ]
  [ "$(dress happy 0 aprilfools | cut -d'|' -f3)" = groucho ]
  [ "$(dress dizzy 0 muertos | cut -d'|' -f1-5)" = "|picado|||marigolds" ]
  [ "$(dress happy 0 muertos | cut -d'|' -f3)" = calavera ]
}

@test "dress: one occasion per slot by calendar order; a cleanup at work wears the hard hat" {
  [ "$(dress happy 0 winter christmas)" = "$(dress happy 0 christmas winter)" ]
  [ "$(dress happy 1 christmas winter | cut -d'|' -f1)" = hardhat ]
  [ "$(dress happy 1 | cut -d'|' -f1)" = hardhat ]
  _MM_OCC_YEARS=3
  [ "$(dress happy 0 newyear anniversary)" = "party|fireworks||||Happy New Year/3 years keeping this machine tidy" ]
  [ "$(dress happy 0 valentine anniversary | cut -d'|' -f1,2)" = "party|heart" ]
  # The rule: one prop per place, the upper row's; one for each place combines.
  [ "$(dress happy 0 friday13 spooky | cut -d'|' -f5)" = web ]
  [ "$(dress happy 0 friday13 winter | cut -d'|' -f5)" = "cat snow" ]
  # The teeth: the upper row's too, the other row's other slots still show.
  MM_CALENDAR=('first|01-01|||||fangs|' 'second|01-01||heart|||gap|')
  [ "$(dress happy 0 second first | cut -d'|' -f2,4)" = "heart|fangs" ]
  [ "$(dress happy 0 second | cut -d'|' -f4)" = gap ]
}

# log_rows ROW... — operations-log rows (TSV).
log_rows() { mkdir -p "$XDG_STATE_HOME/marmot"; printf '%s\n' "$@" >>"$XDG_STATE_HOME/marmot/operations.log"; }

@test "greetings from the log: last year's review only with data, the ofrenda, this year's thanks" {
  # The review needs a run that freed something last year; without one there is nothing to say.
  log_rows $'2026-03-01T10:00:00+00:00\tclean\trefused\t/x\t0\tin use\tR0'
  mm_log_facts "$(date -d '2027-01-03 12:00' +%s)"
  [ "$(dress happy 0 review)" = "|||||" ]
  log_rows $'2026-03-01T10:00:00+00:00\tclean\tremove\t'"$HOME"$'/code/web/node_modules\t2254857830\t\tR1' \
    $'2026-03-01T10:00:01+00:00\tclean\trun\tnpm cache\t1048576\t\tR1' \
    $'2026-05-01T10:00:00+00:00\tpurge\ttrash\t/t/doc\t9999999999\t/t\tR2' \
    $'2026-05-02T10:00:00+00:00\tschedule\tremove\t/x/a\t1048576\t\tR3' \
    $'2027-01-02T10:00:00+00:00\tclean\tremove\t/x/b\t1048576\t\tR4'
  mm_log_facts "$(date -d '2027-01-03 12:00' +%s)"
  [ "$MM_FACT_PREV_RUNS" = 2 ]
  [ "$MM_FACT_PREV_BIG_AT" = "~/code/web/node_modules" ]
  [ "$MM_FACT_BIG_AT" = "~/code/web/node_modules" ]
  [ "$MM_FACT_SINCE" = "$(date -d '2026-03-01T10:00:00+00:00' +%s)" ]
  [ "$(dress happy 0 review)" != "|||||" ]
  [[ "$(dress happy 0 muertos)" == *"~/code/web/node_modules"* ]]
  [[ "$(dress happy 0 thanksgiving)" == *"$MM_FACT_YEAR_FREED"* ]]
  [ "$MM_FACT_YEAR_FREED" = 1.0MB ]
  # Without a log: the plain greetings, no placeholders.
  rm "$XDG_STATE_HOME/marmot/operations.log"
  mm_log_facts
  [ -z "$MM_FACT_BIG_AT$MM_FACT_YEAR_FREED$MM_FACT_SINCE" ]
  [[ "$(dress happy 0 muertos thanksgiving)" != *"("* ]]
}

# names SLOT — the names MM_PARTS draws for SLOT (hat, mark, rule, teeth), one per line.
names() {
  local p
  for p in "${MM_PARTS[@]}"; do p=${p%%|*} && [[ "$p" == "$1":* ]] && echo "${p#*:}"; done | sort -u
}

# check MOOD LABEL — draw MOOD as the MM_LOOK_* say, 60 columns wide with every color on, and
# print LABEL when the drawing breaks a rule: printable ASCII or MM_GLYPHS only once the color
# escapes are stripped (a glyph counts as one column), five or six rows, the rule 60 columns and nothing longer, and the title, facts and
# greeting from column 21 with a blank column before them.
check() {
  local r g n bad=""
  local -a rows=()
  mm_marmot_draw "$1" 60 title facts "$C_GREEN"
  for r in "${MM_ART[@]}"; do
    r=${r//"$esc"[0-9]m/} && r=${r//"$esc"[0-9][0-9]m/}
    for g in "${MM_GLYPHS[@]}"; do r=${r//"$g"/G}; done
    [[ "$r" == *[!\ -~]* ]] && bad=" not ASCII nor MM_GLYPHS"
    rows+=("$r")
  done
  n=${#rows[@]}
  ((n == 5 || n == 6)) || bad+=" $n rows"
  [[ ${#rows[n - 1]} -eq 60 && ${#rows[0]} -le 60 && ${#rows[1]} -le 60 && "${rows[n - 4]:20}" == " title" &&
    "${rows[n - 3]:20}" == " facts" && "${rows[n - 2]:20}" == " hi" ]] || bad+=" out of place"
  [[ -z "$bad" ]] || echo "$2:$bad"
}

# look HAT MARK EYES RULE TEETH OVERLAY — the MM_LOOK_* for a drawing; OVERLAY is "", CHEEKS=1,
# BLINK=N or WAVE=N.
look() {
  MM_LOOK_HAT=$1 MM_LOOK_MARK=$2 MM_LOOK_EYES=$3 MM_LOOK_RULE=$4 MM_LOOK_TEETH=$5
  MM_LOOK_CHEEKS=0 MM_LOOK_BLINK=0 MM_LOOK_WAVE=0 MM_LOOK_GREET=hi
  [[ -z "$6" ]] || printf -v "MM_LOOK_${6%=*}" %s "${6#*=}"
}

# draw_all MOOD — check MOOD with every hat, mark, eyes, rule and teeth (the caller's arrays), each
# combination with one overlay in turn so that every overlay meets every value of every slot; then
# every overlay with every hat, rule and teeth, which share its cells.
draw_all() {
  local mood=$1 h m e r t o LC_ALL=C esc=$'\e['
  local C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
  local C_BLUE=$'\e[34m' C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
  for h in "${!hats[@]}"; do for m in "${!marks[@]}"; do for e in "${!eyes[@]}"; do
    for r in "${!rules[@]}"; do for t in "${!teeth[@]}"; do
      o=${overs[(h + m + e + r + t) % ${#overs[@]}]}
      look "${hats[h]}" "${marks[m]}" "${eyes[e]}" "${rules[r]}" "${teeth[t]}" "$o"
      check "$mood" "$mood/${hats[h]}/${marks[m]}/${eyes[e]}/${rules[r]}/${teeth[t]}/$o"
    done; done
  done; done; done
  for o in "${overs[@]}"; do for h in "${hats[@]}"; do for r in "${rules[@]}"; do for t in "${teeth[@]}"; do
    look "$h" "" "" "$r" "$t" "$o"
    check "$mood" "$mood/$h///$r/$t/$o"
  done; done; done; done
}

@test "draw: every mood, hat, mark, eyes, rule, teeth and overlay is ASCII or MM_GLYPHS, in its place" {
  local -a hats marks rules teeth eyes overs pids=()
  local mood
  mapfile -t hats < <(echo; names hat)
  mapfile -t marks < <(echo; names mark)
  mapfile -t rules < <(echo; names rule; echo "snow cat")
  mapfile -t teeth < <(echo; names teeth)
  eyes=("" "${!MM_EYES[@]}")
  overs=("" CHEEKS=1 BLINK=1 BLINK=2 WAVE=1 WAVE=2)
  [ "${#hats[@]}" -eq 4 ] && [ "${#marks[@]}" -eq 6 ] && [ "${#rules[@]}" -eq 8 ] && [ "${#teeth[@]}" -eq 2 ]
  # One process per mood, 2304 drawings each, without bats' per-command trap (it would take the
  # loop from seconds to an hour).
  for mood in "${!MM_FACES[@]}"; do
    (trap - DEBUG ERR && set +eET && draw_all "$mood") >"$BATS_TEST_TMPDIR/broken.$mood" &
    pids+=("$!")
  done
  wait "${pids[@]}"
  cat "$BATS_TEST_TMPDIR"/broken.*
  [ -z "$(cat "$BATS_TEST_TMPDIR"/broken.*)" ]
}

# emoji CODEPOINT — 0 if CODEPOINT is in a block where Unicode gives characters an emoji
# presentation (Emoji_Presentation or common text-default emoji).
emoji() {
  local r lo hi
  for r in 00A9-00A9 00AE-00AE 203C-203C 2049-2049 2122-2122 2139-2139 2194-21AA 231A-23FF \
    24C2-24C2 25AA-25FE 2600-27BF 2934-2935 2B05-2B55 3030-3030 303D-303D 3297-3299 FE0F-FE0F \
    1F000-1FAFF; do
    lo=$((16#${r%-*})) hi=$((16#${r#*-}))
    (($1 >= lo && $1 <= hi)) && return 0
  done
  return 1
}

@test "draw: beyond ASCII only the allowlisted glyphs, each one column wide and none an emoji" {
  # Adding a glyph is a decision: it has to be added here too.
  [ "${MM_GLYPHS[*]}" = ∆ ]
  local g cp
  for g in "${MM_GLYPHS[@]}"; do
    cp=$(export LC_ALL=C.UTF-8 && printf '%d' "'$g")
    ((cp > 126)) || { echo "$g is ASCII"; false; }
    [ "$(printf '%s' "$g" | LC_ALL=C.UTF-8 wc -L)" -eq 1 ] || { echo "$g is not one column"; false; }
    ! emoji "$cp" || { echo "$g can show as an emoji"; false; }
  done
  emoji $((16#2726)) && emoji $((16#1F383))
}

@test "draw: a sky row only when something reaches above the head; the texts keep their rows" {
  local MM_LOOK_GREET=hi MM_LOOK_HAT="" MM_LOOK_MARK="" MM_LOOK_EYES="" MM_LOOK_RULE="" MM_LOOK_TEETH=""
  mm_marmot_draw happy 60 title facts
  [ "${#MM_ART[@]}" -eq 5 ] && [ "${MM_ART[1]:21}" = title ] && [ "${MM_ART[3]:21}" = hi ]
  MM_LOOK_HAT=party
  mm_marmot_draw happy 60 title facts
  [ "${#MM_ART[@]}" -eq 6 ] && [ "${MM_ART[2]:21}" = title ] && [ "${MM_ART[3]:21}" = facts ] && [ "${MM_ART[4]:21}" = hi ]
  MM_LOOK_HAT=""
  # The night shift's mug stands on the rule beside the paw: no sky row for it.
  mm_marmot_draw night 60 title
  [ "${#MM_ART[@]}" -eq 5 ] && [[ "${MM_ART[4]}" == "--(mm)--UU--(mm)-[__]D"* ]]
  # Fireworks over the title need the room: on a narrow rule the ones that do not fit are left out.
  MM_LOOK_MARK=fireworks
  mm_marmot_draw happy 30 title
  [ "${#MM_ART[@]}" -eq 6 ] && [ "${#MM_ART[0]}" -le 30 ] && [ "${#MM_ART[1]}" -le 30 ]
}

@test "draw: open eyes blink through a half lid; closed ones and festive eyes stay as they are" {
  local MM_LOOK_HAT="" MM_LOOK_MARK="" MM_LOOK_EYES="" MM_LOOK_RULE="" MM_LOOK_TEETH="" b
  for b in 0 1 2; do MM_LOOK_BLINK=$b mm_marmot_draw happy 60 && echo "${MM_ART[2]}"; done >"$BATS_TEST_TMPDIR/happy"
  [ "$(cat "$BATS_TEST_TMPDIR/happy")" = "$(printf '   |  %s    %s  |\n' ^ ^ - - _ _)" ]
  MM_LOOK_BLINK=2 mm_marmot_draw sleepy 60
  [ "${MM_ART[2]}" = "   |  -    -  |" ]
  MM_LOOK_BLINK=2 MM_LOOK_EYES=jack mm_marmot_draw happy 60
  [ "${MM_ART[2]}" = '   |  ∆    ∆  |' ]
}

@test "festive = off takes the calendar off everything and leaves the moods, milestones and eggs" {
  mkdir -p "$HOME/.config/marmot"
  mm_test_now '2026-12-25 12:00'
  mm_occasions_now "$(date -d '2026-12-25 12:00' +%s)"
  [ "${MM_OCC[*]}" = "christmas winter" ]
  mm_greeting
  [ "$REPLY" = "Merry Christmas" ]
  printf 'festive = off\n' >"$HOME/.config/marmot/config"
  mm_occasions_now "$(date -d '2026-12-25 12:00' +%s)"
  [ "${#MM_OCC[@]}" -eq 0 ]
  mm_greeting
  [ -z "$REPLY" ]
  # mm status reads the same switch when it looks the day up (tests/status.bats runs it whole).
  . "$MM_SRC/cmd/status.sh"
  ST_NOW=$(date -d '2026-12-25 12:00' +%s) ST_LAST=0 ST_DAY=""
  _status_facts
  [ "${#ST_OCC[@]}" -eq 0 ]
  run mm moo
  [ "$status" -eq 0 ]
  # Off is also no, false and 0; anything else, and no config at all, is on.
  local v
  for v in no false 0 OFF; do
    printf 'festive = %s\n' "$v" >"$HOME/.config/marmot/config"
    ! mm_festive || { echo "festive = $v should be off"; false; }
  done
  for v in on yes 1 maybe; do
    printf 'festive = %s\n' "$v" >"$HOME/.config/marmot/config"
    mm_festive || { echo "festive = $v should be on"; false; }
  done
  rm "$HOME/.config/marmot/config"
  mm_festive
}
