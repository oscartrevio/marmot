#!/usr/bin/env bats
# lib/mascot.sh: the calendar (which occasions a date falls on), how occasions dress the marmot
# around its face (slots, priority, problem faces first), the greetings that come from the
# operations log, and the drawing's fixed size.

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

# dress MOOD SCORE ATWORK ID... — "hat|mark|eyes|rule|greetings" for those occasions.
dress() {
  mm_marmot_dress "$@"
  local IFS=/
  echo "$MM_LOOK_HAT|$MM_LOOK_MARK|$MM_LOOK_EYES|$MM_LOOK_RULE|${MM_LOOK_GREETS[*]}"
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
  [ "$(occ 2027-02-02)" = "groundhog winter" ]
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

@test "dress: a problem face keeps its eyes and still wears the day's hat, mark and rule" {
  [ "$(dress dizzy 40 0 christmas winter)" = "santa|||snow|Merry Christmas" ]
  [ "$(dress happy 100 0 halloween)" = "|pumpkin|jack|web|Happy Halloween" ]
  [ "$(dress sleepy 100 0 halloween | cut -d'|' -f3)" = jack ]
  [ "$(dress proud 100 0 halloween | cut -d'|' -f3)" = jack ]
  local mood
  for mood in alert dizzy squint neutral night tired; do
    [ "$(dress "$mood" 70 0 halloween)" = "|pumpkin||web|Happy Halloween" ] || { echo "$mood"; false; }
  done
  [ "$(dress dizzy 40 0 aprilfools | cut -d'|' -f3)" = "" ]
  [ "$(dress happy 100 0 aprilfools | cut -d'|' -f3)" = groucho ]
}

@test "dress: one occasion per slot by calendar order; a cleanup at work wears the hard hat" {
  [ "$(dress happy 100 0 winter christmas)" = "$(dress happy 100 0 christmas winter)" ]
  [ "$(dress happy 100 1 christmas winter | cut -d'|' -f1)" = hardhat ]
  [ "$(dress happy 100 1 | cut -d'|' -f1)" = hardhat ]
  _MM_OCC_YEARS=3
  [ "$(dress happy 100 0 newyear anniversary)" = "party|confetti|||Happy New Year/3 years keeping this machine tidy" ]
  [ "$(dress happy 100 0 valentine anniversary | cut -d'|' -f1,2)" = "party|heart" ]
  # Two patterns for one end of the rule: the upper row's; one for each place combines.
  [ "$(dress happy 100 0 friday13 spooky | cut -d'|' -f4)" = web ]
  [ "$(dress happy 100 0 friday13 winter | cut -d'|' -f4)" = "cat snow" ]
}

@test "dress: on Groundhog Day the marmot sees its shadow unless health is 100" {
  [ "$(dress neutral 90 0 groundhog winter | cut -d'|' -f4)" = "shadow snow" ]
  [ "$(dress happy 100 0 groundhog winter | cut -d'|' -f4)" = snow ]
  [ "$(dress happy "" 0 groundhog | cut -d'|' -f4)" = "" ]
  [ "$(dress neutral 90 0 groundhog | cut -d'|' -f5)" != "$(dress happy 100 0 groundhog | cut -d'|' -f5)" ]
}

# log_rows ROW... — operations-log rows (TSV).
log_rows() { mkdir -p "$XDG_STATE_HOME/marmot"; printf '%s\n' "$@" >>"$XDG_STATE_HOME/marmot/operations.log"; }

@test "greetings from the log: last year's review only with data, the ofrenda, this year's thanks" {
  # The review needs a run that freed something last year; without one there is nothing to say.
  log_rows $'2026-03-01T10:00:00+00:00\tclean\trefused\t/x\t0\tin use\tR0'
  mm_log_facts "$(date -d '2027-01-03 12:00' +%s)"
  [ "$(dress happy 100 0 review)" = "||||" ]
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
  [ "$(dress happy 100 0 review)" != "||||" ]
  [[ "$(dress happy 100 0 muertos)" == *"~/code/web/node_modules"* ]]
  [[ "$(dress happy 100 0 thanksgiving)" == *"$MM_FACT_YEAR_FREED"* ]]
  [ "$MM_FACT_YEAR_FREED" = 1.0MB ]
  # Without a log: the plain greetings, no placeholders.
  rm "$XDG_STATE_HOME/marmot/operations.log"
  mm_log_facts
  [ -z "$MM_FACT_BIG_AT$MM_FACT_YEAR_FREED$MM_FACT_SINCE" ]
  [[ "$(dress happy 100 0 muertos thanksgiving)" != *"("* ]]
}

@test "draw: always five rows, 21 columns for the marmot and the rule to the width asked" {
  local mood hat mark eyes rule row i=0
  export LC_ALL=C.UTF-8
  for mood in "${!MM_FACES[@]}"; do
    for hat in "" "${!MM_HATS[@]}"; do
      for mark in "" "${!MM_MARKS[@]}"; do
        for eyes in "" jack groucho pirate; do
          for rule in "" "snow shadow" "snow web" cat; do
            i=$((i + 1))
            MM_LOOK_HAT=$hat MM_LOOK_MARK=$mark MM_LOOK_EYES=$eyes MM_LOOK_RULE=$rule MM_LOOK_CHEEKS=$((i % 2)) MM_LOOK_BLINK=$((i / 2 % 2)) MM_LOOK_GREET=""
            mm_marmot_draw "$mood" 60
            [ "${#MM_ART[@]}" -eq 5 ]
            for row in "${MM_ART[@]:0:4}"; do ((${#row} <= 21)) || { echo "$mood/$hat/$mark/$eyes: [$row]"; false; }; done
            [ "${#MM_ART[4]}" -eq 60 ]
          done
        done
      done
    done
  done
  # The text beside it starts at column 21 on every row that has one.
  MM_LOOK_CHEEKS=1 MM_LOOK_GREET=hi
  mm_marmot_draw alert 60 title facts
  [ "${MM_ART[1]:21}" = title ] && [ "${MM_ART[2]:21}" = facts ] && [ "${MM_ART[3]:21}" = hi ]
}
