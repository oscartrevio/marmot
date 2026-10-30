#!/usr/bin/env bash
# draw.sh MOOD WIDTH TITLE BLINK — the marmot for the website, drawn by lib/mascot.sh so the site
# shows what install.sh and mm status draw. Colors come out as "\x1b<ink>" markers (one letter, as
# in MM_PARTS; e for the eyes) and "\x1b0" for the end of a run: scripts/mascot.ts reads them.
set -uo pipefail

root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)
# shellcheck source=../../../lib/mascot.sh
. "$root/lib/mascot.sh"

E=$'\x1b'
C_BOLD=${E}w C_DIM=${E}d C_RED=${E}r C_GREEN=${E}g C_YELLOW=${E}y C_BLUE=${E}b C_MAGENTA=${E}m \
  C_CYAN=${E}c C_RESET=${E}0

mm_marmot_dress "$1" 0
MM_LOOK_BLINK=$4
mm_marmot_draw "$1" "$2" "$3" "" "${E}e"
printf '%s\n' "${MM_ART[@]}"
