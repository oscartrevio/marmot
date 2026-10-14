# shellcheck shell=bash
# mm clean [--sessions DAYS] [--whitelist] — remove caches, old builds, package and Docker leftovers.
# Regenerable caches are removed; the Trash keeps items for 7 days. Shared temp folders (/tmp,
# /var/tmp) are only reported: other programs keep runtime state there and the OS ages them.
# Tool-driven cleans (npm, apt, docker...) add measured sizes on top of mm_rm's totals.
# What counts as a cache, an old build, or a store to only report comes from lib/catalog.sh.

# shellcheck source=../lib/catalog.sh
. "$MM_HOME/lib/catalog.sh"

_CLEAN_REVIEW=()         # "Kept for you to review" lines, printed at the end
_CLEAN_TOOL_BYTES=0      # bytes freed by tool-driven cleans (estimates in dry-run)
_CLEAN_TOOL_ITEMS=0      # items cleaned by tool-driven cleans
_CLEAN_CATS=0            # categories that freed something
_CLEAN_CAT_MARK=""       # "bytes items" snapshot at category start
_CLEAN_MIN_TOOL=1048576  # below this a tool cache is not worth running the tool for
_CLEAN_TRASH_DAYS=7      # Trash retention: items trashed longer ago than this are removed for good
_CLEAN_IMAGE_DAYS=30     # unused Docker images built and pulled longer ago than this are offered

_clean_usage() {
  cat <<EOF
Usage: mm clean [--whitelist] [--dry-run] [--debug]

Removes thumbnails and developer caches (npm, pnpm, yarn, bun, uv, pip, Go, Cargo downloads,
Gradle build cache, Deno, Bazel, Zig, Prisma, Electron, ... see lib/catalog.sh), old
Playwright/Puppeteer/Cypress browser builds, old versions of coding-agent CLIs (the active one
and one previous are kept), apt/journal/snap leftovers, old kernels, stopped Docker containers,
dangling images, images no container uses (pulled or built 30+ days ago), old build cache, and
stale editor server builds.
Trash items deleted more than 7 days ago are removed for good. /tmp and /var/tmp are not
swept: they hold other programs' runtime state, and the OS ages them (systemd-tmpfiles); their
size and the OS policy are reported. Model stores, dependency repositories, Node versions,
Docker volumes and agent state are never touched: they are listed with their size under
"Kept for you to review". Steps that cannot be undone (Trash sweep, packages, containers,
images) ask first and are skipped without a terminal.

Agent sessions are kept unless you opt in: with a retention of N days, session files (and
rotated logs in agent state) last written more than N days ago and not in use move to the
Trash; credentials, whitelisted paths and files in use are never touched. Turn it on with
sessions_keep_days=N in $MM_CONFIG_FILE (runs without a terminal act only then), or use
--sessions N for one run (asks first).

Options:
  --sessions N  move agent session files older than N days to the Trash (this run)
  --whitelist   edit protected paths ($MM_WHITELIST_FILE)
  -n, --dry-run show what would be cleaned; change nothing

Add your own cache folders (inside your home folder) to $MM_CONFIG_DIR/catalog, one per line:
  cache|My tool cache|~/.cache/mytool|mytool
EOF
}

# ---------------------------------------------------------------- accounting helpers

# _clean_track BYTES ITEMS — account a tool-driven clean.
_clean_track() { _CLEAN_TOOL_BYTES=$((_CLEAN_TOOL_BYTES + $1)); _CLEAN_TOOL_ITEMS=$((_CLEAN_TOOL_ITEMS + $2)); }

_clean_cat() {
  mm_section "$1"
  _CLEAN_CAT_MARK="$((MM_FREED + MM_TRASHED + _CLEAN_TOOL_BYTES)) $((MM_COUNT + _CLEAN_TOOL_ITEMS))"
}
_clean_cat_end() {
  local b i; read -r b i <<<"$_CLEAN_CAT_MARK"
  (( MM_FREED + MM_TRASHED + _CLEAN_TOOL_BYTES > b || MM_COUNT + _CLEAN_TOOL_ITEMS > i )) && _CLEAN_CATS=$((_CLEAN_CATS + 1))
  return 0
}

# _clean_to_bytes "1.2GB" | "186.7M" | "12kB" | "3MiB" — single-letter and *iB units are binary.
_clean_to_bytes() {
  awk -v s="$1" 'BEGIN {
    if (!match(s, /^[0-9.]+/)) { print 0; exit }
    n = substr(s, 1, RLENGTH); u = toupper(substr(s, RLENGTH + 1)); gsub(/[^A-Z]/, "", u)
    base = (u ~ /I/ || length(u) == 1) ? 1024 : 1000
    p = index("KMGTP", substr(u, 1, 1))
    printf "%.0f\n", n * (p ? base ^ p : 1)
  }'
}

# _clean_detail COUNT NOUN BYTES [KEPT] [FAILED] — "3 items, 1.2GB, 1 kept (in use/whitelisted)".
_clean_detail() {
  local noun="$2" d
  (( $1 == 1 )) && noun="${noun%s}"
  d="$1 $noun, $(mm_human "$3")"
  (( ${4:-0} > 0 )) && d+=", $4 kept (in use/whitelisted)"
  (( ${5:-0} > 0 )) && d+=", $5 failed"
  printf '%s' "$d"
}

# _clean_contents LABEL DIR — permanently empty a regenerable cache DIR via mm_rm (ALLOWED_ROOT=DIR).
_clean_contents() {
  local label="$1" dir="$2" e n=0 b=0 kept=0 fail=0
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' e; do
    mm_rm "$e" "$dir"
    case $? in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if (( n + kept + fail == 0 )); then mm_ok "$label" "nothing to clean"; return; fi
  mm_ok "$label" "$(_clean_detail "$n" items "$b" "$kept" "$fail")"
}

# _clean_busy "PROC..." — print the first listed process that is running (f:REGEX tokens match
# full command lines); 1 when none runs.
_clean_busy() {
  local -a toks; local p
  read -r -a toks <<<"$1"
  for p in "${toks[@]}"; do
    if [[ "$p" == f:* ]]; then
      mm_proc_match "" "${p#f:}" && { p=${p#f:}; printf '%s' "${p//\\/}"; return 0; }
    elif mm_proc_running "$p"; then
      printf '%s' "${p%-cli.js}"; return 0
    fi
  done
  return 1
}

# _clean_tool LABEL "BUSY_PROC..." SIZE_DIR CMD... — run a tool's own cache clean, measured by what
# it frees in SIZE_DIR: files hard-linked from outside (a store linked into projects) stay on disk,
# so they are not counted. CMD runs from / so project-local config (.npmrc, .yarnrc.yml, committed
# .yarn/cache) never applies. Dry-run estimates what removing all of SIZE_DIR would free. Callers
# only invoke it when the tool is installed.
_clean_tool() {
  local label="$1" procs="$2" dir="$3" busy size before after freed; shift 3
  [[ -d "$dir" ]] || { mm_ok "$label" "nothing to clean"; return; }
  if mm_whitelisted "$dir"; then mm_skip "$label" "whitelisted"; return; fi
  if busy=$(_clean_busy "$procs"); then mm_skip "$label" "$busy busy"; return; fi
  read -r size before < <(mm_size_frees "$dir")
  if (( size < _CLEAN_MIN_TOOL )); then mm_ok "$label" "nothing to clean ($(mm_human "$size"))"; return; fi
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_run "$label" env -C / "$@"; _clean_track "$before" 1; mm_ok "$label" "$(mm_human "$before")"; return
  fi
  mm_run "$label" env -C / "$@" || return 0
  after=$(mm_frees "$dir"); freed=$(( before > after ? before - after : 0 ))
  _clean_track "$freed" 1
  mm_ok "$label" "cleaned, $(mm_human "$freed")"
}

# _clean_home_dir LABEL DIR — 0 if DIR is a non-empty directory that resolves strictly inside $HOME
# and is not protected. Prints a skip line for protected/outside dirs; silent when absent or empty.
_clean_home_dir() {
  local label="$1" dir="$2" real
  [[ -d "$dir" ]] || return 1
  [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || return 1
  real=$(realpath -e -- "$dir" 2>/dev/null) || return 1
  if [[ "$real" != "$HOME"/?* ]]; then mm_skip "$label" "resolves outside your home folder"; return 1; fi
  if mm_whitelisted "$dir" || mm_whitelisted "$real"; then mm_skip "$label" "protected"; return 1; fi
  return 0
}

# _clean_cache_row LABEL DIR BUSY — catalog "cache" row: empty DIR (kept) unless a busy process runs.
_clean_cache_row() {
  local label="$1" dir="$2" busy
  _clean_home_dir "$label" "$dir" || return 0
  if busy=$(_clean_busy "$3"); then mm_skip "$label" "$busy busy"; return 0; fi
  _clean_contents "$label" "$dir"
}

# _clean_playwright_refs DIR — "<dir-name>-<revision>" for every browser an installed playwright-core
# (recorded by Playwright in DIR/.links) still expects.
_clean_playwright_refs() {
  local link target
  for link in "$1"/.links/*; do
    [[ -f "$link" ]] || continue
    IFS= read -r target <"$link" || [[ -n "$target" ]] || continue
    [[ "$target" == /* && -f "$target/browsers.json" ]] || continue
    awk '/"name"[[:space:]]*:/ { n = $0; sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", n); sub(/".*/, "", n) }
      /"revision"[[:space:]]*:/ { r = $0; sub(/.*"revision"[[:space:]]*:[[:space:]]*"/, "", r); sub(/".*/, "", r)
        if (n != "" && r ~ /^[0-9]+$/) { gsub(/-/, "_", n); print n "-" r } }' "$target/browsers.json"
  done
}

# _clean_revisions_row LABEL DIR BUSY SPEC — catalog "revisions" row (see lib/catalog.sh): keep the
# newest version of every product (plus referenced and in-use builds), remove the older ones.
_clean_revisions_row() {
  local label="$1" dir="$2" spec="$4" busy depth regex refs="" rel prod ver n=0 b=0 kept=0 fail=0 refkept=0
  local -A newest=() keep=()
  local -a rels=() prods=() vers=()
  _clean_home_dir "$label" "$dir" || return 0
  if busy=$(_clean_busy "$3"); then mm_skip "$label" "$busy busy"; return 0; fi
  depth=${spec%%:*} regex=${spec#*:}
  [[ "$regex" == *:refs=* ]] && { refs=${regex##*:refs=}; regex=${regex%:refs=*}; }
  [[ "$depth" =~ ^[1-9]$ ]] || { mm_debug "$label: bad spec $spec"; return 0; }
  while IFS= read -r -d '' rel; do
    [[ "$rel" != .* && "$rel" != */.* && "$rel" =~ $regex ]] || continue
    prod=${BASH_REMATCH[1]:-.} ver=${BASH_REMATCH[2]}   # "." = single-product layouts (empty group 1)
    rels+=("$rel") prods+=("$prod") vers+=("$ver")
    if [[ -z "${newest[$prod]+x}" || "$(printf '%s\n%s\n' "${newest[$prod]}" "$ver" | sort -V | tail -1)" == "$ver" ]]; then
      newest[$prod]=$ver
    fi
  done < <(find "$dir" -mindepth "$depth" -maxdepth "$depth" -type d -printf '%P\0' 2>/dev/null)
  (( ${#rels[@]} )) || return 0
  if [[ "$refs" == playwright ]]; then
    while IFS= read -r rel; do keep[$rel]=1; done < <(_clean_playwright_refs "$dir")
  fi
  local i
  for i in "${!rels[@]}"; do
    [[ "${vers[$i]}" == "${newest[${prods[$i]}]}" ]] && continue
    if [[ -n "${keep[${rels[$i]}]+x}" ]]; then refkept=$((refkept + 1)); continue; fi
    mm_rm "$dir/${rels[$i]}" "$dir"
    case $? in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done
  local note=", newest of ${#newest[@]} kept" uses=""
  (( refkept )) && { note+=", $refkept still used by installed projects"; uses=", $refkept used by installed projects"; }
  if (( n + kept + fail == 0 )); then mm_ok "$label" "up to date (${#rels[@]} builds$uses)"; return 0; fi
  mm_ok "$label" "$(_clean_detail "$n" "old builds" "$b" "$kept" "$fail")$note"
}

# _clean_versions_row NAME DIR ACTIVE_LINK — an agent that keeps one entry per installed version.
# Keeps the active version (resolved through ACTIVE_LINK), any newer staged ones, and the newest
# older one; removes the rest. When the active version cannot be resolved, everything is kept.
_clean_versions_row() {
  local label="$1 old versions" dir="$2" link="$3" real act v n=0 b=0 kept=0 fail=0 prev=""
  local -a names=() older=()
  [[ -d "$dir" ]] || return 0
  mapfile -t names < <(find "$dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -name '[0-9]*' -printf '%f\n' 2>/dev/null | sort -V)
  (( ${#names[@]} > 1 )) || return 0
  real=$(realpath -e -- "$dir" 2>/dev/null) || return 0
  act=""
  if [[ -n "$link" ]] && v=$(realpath -e -- "$link" 2>/dev/null) && [[ "$v" == "$real"/?* ]]; then
    act=${v#"$real"/}; act=${act%%/*}
  fi
  if [[ -z "$act" || " ${names[*]} " != *" $act "* ]]; then
    mm_ok "$label" "${#names[@]} installed, all kept (active version unknown)"; return 0
  fi
  for v in "${names[@]}"; do
    [[ "$v" == "$act" ]] && break
    older+=("$v")
  done
  (( ${#older[@]} > 1 )) || { mm_ok "$label" "none (active $act)"; return 0; }
  prev=${older[-1]}
  for v in "${older[@]:0:${#older[@]}-1}"; do
    mm_rm "$dir/$v" "$dir"
    case $? in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done
  mm_ok "$label" "$(_clean_detail "$n" versions "$b" "$kept" "$fail"), kept $act (active) and $prev"
}

# ---------------------------------------------------------------- 1. user essentials

_clean_user() {
  _clean_cat "User essentials"
  [[ -d "$MM_TRASH_DIR/files" ]] && _clean_trash "$MM_TRASH_DIR"
  _clean_contents "Thumbnails" "$(mm_catalog_expand %CACHE%/thumbnails)"
  _clean_cat_end
}

# _clean_trashinfo_epoch FILE — epoch of a spec-valid .trashinfo's DeletionDate (local time,
# YYYY-MM-DDThh:mm:ss); fails for anything else.
_clean_trashinfo_epoch() {
  local line head="" path="" when=""
  [[ -f "$1" && ! -L "$1" ]] || return 1
  { IFS= read -r head
    while IFS= read -r line; do
      case "$line" in
        Path=?*) path=${line#Path=} ;;
        DeletionDate=*) when=${line#DeletionDate=} ;;
      esac
    done; } <"$1"
  [[ "${head%$'\r'}" == "[Trash Info]" && -n "$path" ]] || return 1
  when=${when%$'\r'}
  [[ "$when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  date -d "$when" +%s 2>/dev/null
}

# _clean_trash DIR — retention sweep: permanently remove items whose .trashinfo says they were
# trashed 7+ days ago (file and .trashinfo together). Recent items and entries without a valid
# .trashinfo are never touched. Lists count/size/largest, then asks.
_clean_trash() {
  local trash="$1" now name t size b=0 recent=0 unrec=0 n=0 kept=0 fail=0 freed=0 top="" line note=""
  local -a pick=() sizes=()
  now=$(date +%s)
  while IFS= read -r -d '' name; do
    t=$(_clean_trashinfo_epoch "$trash/info/$name.trashinfo") || { unrec=$((unrec + 1)); continue; }
    (( now - t >= _CLEAN_TRASH_DAYS * 86400 )) || { recent=$((recent + 1)); continue; }
    size=$(mm_size "$trash/files/$name" "$trash/info/$name.trashinfo")
    pick+=("$name") sizes+=("$size"$'\t'"$name") b=$((b + size))
  done < <(find "$trash/files" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null)
  (( recent )) && note+=", $recent recent kept"
  (( unrec )) && note+=", $unrec unrecognized left alone"
  if (( ${#pick[@]} == 0 )); then mm_ok "Trash" "nothing trashed ${_CLEAN_TRASH_DAYS}+ days ago${note}"; return; fi
  while IFS= read -r line; do
    top+="${top:+, }${line#*$'\t'} ($(mm_human "${line%%$'\t'*}"))"
  done < <(printf '%s\n' "${sizes[@]}" | sort -rn | head -5)
  mm_act "Trash: ${#pick[@]} items trashed ${_CLEAN_TRASH_DAYS}+ days ago, $(mm_human "$b"); largest: $top"
  _clean_ask "Trash" "Permanently delete ${#pick[@]} Trash items older than $_CLEAN_TRASH_DAYS days ($(mm_human "$b"))?" || return 0
  for name in "${pick[@]}"; do
    mm_rm "$trash/files/$name" "$trash"
    case $? in
      0) n=$((n + 1)) freed=$((freed + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)); continue ;;
      *) fail=$((fail + 1)); continue ;;
    esac
    # The .trashinfo goes with its item; it is metadata, not a counted item.
    mm_rm "$trash/info/$name.trashinfo" "$trash" && { MM_COUNT=$((MM_COUNT - 1)); freed=$((freed + MM_LAST_BYTES)); }
  done
  mm_ok "Trash" "$(_clean_detail "$n" items "$freed" "$kept" "$fail") trashed ${_CLEAN_TRASH_DAYS}+ days ago${note}"
}

# ---------------------------------------------------------------- 2. developer caches

_clean_dev() {
  _clean_cat "Developer caches"
  command -v npm >/dev/null && _clean_npm
  command -v pnpm >/dev/null && _clean_pnpm
  command -v bun >/dev/null && _clean_bun
  command -v yarn >/dev/null && _clean_yarn
  _clean_catalog_caches
  _clean_cat_end
}

# Catalog "cache" rows (built-in and the user's): emptied directly, whether or not the tool is
# still installed (then they are pure leftovers).
_clean_catalog_caches() {
  local r i
  for r in "${MM_CAT_REJECTED[@]}"; do mm_warn "catalog row ignored: $r"; done
  for i in "${!MM_CAT_KIND[@]}"; do
    [[ "${MM_CAT_KIND[$i]}" == cache ]] && _clean_cache_row "${MM_CAT_LABEL[$i]}" "${MM_CAT_PATH[$i]}" "${MM_CAT_BUSY[$i]}"
  done
  return 0
}

# Old browser/test-runner builds and old coding-agent CLI versions (catalog revisions + versions).
# Rows only print when they find something, so output is buffered and the section is shown only
# when non-empty (no row here prompts).
_clean_builds() {
  local i buf
  buf=$(mktemp -t marmot-clean.XXXXXX) || return 0
  _CLEAN_CAT_MARK="$((MM_FREED + MM_TRASHED + _CLEAN_TOOL_BYTES)) $((MM_COUNT + _CLEAN_TOOL_ITEMS))"
  for i in "${!MM_CAT_KIND[@]}"; do
    case ${MM_CAT_KIND[$i]} in
      revisions) _clean_revisions_row "${MM_CAT_LABEL[$i]}" "${MM_CAT_PATH[$i]}" "${MM_CAT_BUSY[$i]}" "${MM_CAT_SPEC[$i]}" ;;
      versions) _clean_versions_row "${MM_CAT_LABEL[$i]}" "${MM_CAT_PATH[$i]}" "${MM_CAT_SPEC[$i]}" ;;
    esac
  done >"$buf"
  if [[ -s "$buf" ]]; then mm_section "Old builds and versions"; cat -- "$buf"; fi
  rm -f -- "$buf" # SAFE: the mktemp output buffer created above
  _clean_cat_end
}

# npm's own cache (wherever `npm config get cache` points; asked from / so no project .npmrc applies).
_clean_npm() {
  local dir
  dir=$(env -C / timeout 15 npm config get cache 2>/dev/null | tail -1)
  [[ "$dir" == /* ]] || dir="$HOME/.npm"
  _clean_tool "npm cache" "npm npm-cli.js npx npx-cli.js" "${dir%/}/_cacache" npm cache clean --force
}

_clean_bun() {
  local dir
  dir=$(env -C / timeout 15 bun pm cache 2>/dev/null | tail -1)
  [[ "$dir" == /* ]] || dir="$HOME/.bun/install/cache"
  _clean_tool "bun cache" bun "$dir" bun pm cache rm
}

# Yarn 1 has one global cache (`yarn cache dir`). Berry caches live per project (often committed for
# zero-installs), so it is never touched. Queried from / so no project's yarnrc is picked up.
_clean_yarn() {
  local -a yarn=(env -C / COREPACK_ENABLE_DOWNLOAD_PROMPT=0 timeout 20 yarn)
  local ver dir
  ver=$("${yarn[@]}" --version 2>/dev/null) || { mm_skip "yarn cache" "yarn unavailable"; return; }
  if [[ "$ver" != 1.* ]]; then mm_skip "yarn cache" "Yarn $ver caches per project"; return; fi
  dir=$("${yarn[@]}" cache dir 2>/dev/null | tail -1)
  [[ "$dir" == /* ]] || { mm_skip "yarn cache" "cache dir unknown"; return; }
  _clean_tool "yarn cache" yarn "$dir" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 yarn cache clean
}

# pnpm writes a probe file into its working directory before it answers anything, so it runs from
# $HOME: from / every non-root user got EACCES and the store was never pruned.
_clean_pnpm() {
  local store before after freed
  store=$(env -C "$HOME" timeout 15 pnpm store path 2>/dev/null) || return 0
  [[ -d "$store" ]] || return 0
  if mm_whitelisted "$store"; then mm_skip "pnpm store" "whitelisted"; return; fi
  if mm_proc_running pnpm; then mm_skip "pnpm store" "pnpm busy"; return; fi
  before=$(mm_size "$store")
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_run "pnpm store prune" env -C "$HOME" pnpm store prune
    mm_ok "pnpm store" "$(mm_human "$before") store, would prune unreferenced packages (size unknown until run)"
    return
  fi
  mm_run "pnpm store prune" env -C "$HOME" pnpm store prune || return 0
  after=$(mm_size "$store"); freed=$(( before > after ? before - after : 0 ))
  _clean_track "$freed" 1
  mm_ok "pnpm store" "pruned, $(mm_human "$freed")"
}

# ---------------------------------------------------------------- agent sessions (opt-in)

# Session transcripts are the user's conversations: untouched unless they set a retention
# (sessions_keep_days=N in the config file, or --sessions N for one run). Then files under each
# agent's session dirs (lib/agents.sh) and rotated logs in its state dirs, last written more than
# N days ago and not in use, move to the Trash (restorable); folders they leave empty are removed.
# The config file is standing consent: without a terminal only a configured retention acts.
_CLEAN_ROTATED_LOGS=('*.log.[0-9]*' '*.log.*.gz' '*.log.old')

# _clean_trash_dev — device id of the Trash files dir (or its nearest existing ancestor).
_clean_trash_dev() {
  local p="$MM_TRASH_DIR/files"
  while [[ ! -e "$p" && "$p" == /?* ]]; do p=$(dirname -- "$p"); done
  stat -c %d -- "$p" 2>/dev/null
}

# _clean_agent_root DIR TRASH_DEV — set _CLEAN_ROOT to DIR resolved when it is one agent's own
# directory inside $HOME on the Trash's filesystem (mm_rm --trash only renames); says so when not.
_clean_agent_root() {
  _CLEAN_ROOT=$(realpath -e -- "$1" 2>/dev/null) && mm_agent_dir "$_CLEAN_ROOT" || return 1
  if [[ "$(stat -c %d -- "$_CLEAN_ROOT" 2>/dev/null)" != "$2" ]]; then
    mm_skip "${1/#$HOME/\~}" "Trash is on another filesystem"; return 1
  fi
}

# _clean_sessions DAYS SOURCE — SOURCE is "config" (the config file) or "flag" (--sessions).
_clean_sessions() {
  local days="$1" from="$2" now tdev i dir root rec t blk path n b old rc d
  local total=0 tb=0
  local -a units=() names=() logs=() match=()
  # Per agent index: candidates, their bytes, oldest mtime; moved, moved bytes, kept, failed,
  # emptied folders. s_up: every folder above a moved file (inside its root) -> "index<TAB>root".
  local -A seen=() s_cnt=() s_bytes=() s_old=() s_n=() s_b=() s_kept=() s_fail=() s_empty=() s_up=()
  _clean_cat "Agent sessions older than $days days"
  now=$(date +%s) tdev=$(_clean_trash_dev)
  for d in "${_CLEAN_ROTATED_LOGS[@]}"; do logs+=(-o -name "$d"); done
  for i in "${!MM_AGENT_NAME[@]}"; do
    # Session files first, then rotated logs in the agent's state dirs (each file listed once).
    # shellcheck disable=SC2153 # set by lib/agents.sh
    for dir in ${MM_AGENT_SESSIONS[$i]} ${MM_AGENT_STATE[$i]}; do
      [[ -d "$dir" ]] || continue
      _clean_agent_root "$dir" "$tdev" || continue
      root=$_CLEAN_ROOT match=(-type f)
      [[ " ${MM_AGENT_SESSIONS[$i]} " == *" $dir "* ]] || match=(-type f \( "${logs[@]:1}" \))
      while IFS= read -r -d '' rec; do
        t=${rec%% *} rec=${rec#* } blk=${rec%% *} path=${rec#* }
        [[ -z "${seen[$path]+x}" ]] || continue
        seen[$path]=1
        units+=("$i"$'\t'"$root"$'\t'"$path")
        s_cnt[$i]=$(( ${s_cnt[$i]:-0} + 1 )) s_bytes[$i]=$(( ${s_bytes[$i]:-0} + blk * 512 ))
        t=${t%.*}; (( t < ${s_old[$i]:-$now} )) && s_old[$i]=$t
      done < <(find "$root" -xdev "${match[@]}" -mmin +$((days * 1440)) -printf '%T@ %b %p\0' 2>/dev/null)
    done
  done
  if (( ${#units[@]} == 0 )); then mm_ok "Agent sessions" "nothing older than $days days"; _clean_cat_end; return 0; fi
  for i in "${!MM_AGENT_NAME[@]}"; do
    [[ -n "${s_cnt[$i]+x}" ]] || continue
    names+=("$i") total=$((total + s_cnt[$i])) tb=$((tb + s_bytes[$i]))
    mm_act "${MM_AGENT_NAME[$i]}: $(_clean_detail "${s_cnt[$i]}" files "${s_bytes[$i]}"), oldest $(( (now - s_old[$i]) / 86400 ))d"
  done
  if [[ "$MM_DRY_RUN" == 1 || "$MM_TTY" == 1 || "$from" != config ]]; then
    _clean_ask "Agent sessions" "Move $total session files ($(mm_human "$tb")) older than $days days to the Trash?" || { _clean_cat_end; return 0; }
  fi
  for rec in "${units[@]}"; do
    IFS=$'\t' read -r i root path <<<"$rec"
    MM_AGENT_WAIVER=$root mm_rm --trash "$path" "$root"; rc=$?
    case $rc in
      0) s_n[$i]=$(( ${s_n[$i]:-0} + 1 )) s_b[$i]=$(( ${s_b[$i]:-0} + MM_LAST_BYTES ))
         d=${path%/*}
         while [[ "$d" == "$root"/?* ]]; do s_up[$d]=$i$'\t'$root; d=${d%/*}; done ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && s_kept[$i]=$(( ${s_kept[$i]:-0} + 1 )) ;;
      *) s_fail[$i]=$(( ${s_fail[$i]:-0} + 1 )) ;;
    esac
  done
  # Folders the moves emptied, deepest first. They are housekeeping, not counted as items.
  if [[ "$MM_DRY_RUN" != 1 ]] && (( ${#s_up[@]} )); then
    while IFS= read -r d; do
      IFS=$'\t' read -r i root <<<"${s_up[$d]}"
      [[ -d "$d" && ! -L "$d" && -z "$(find "$d" -mindepth 1 -print -quit 2>/dev/null)" ]] || continue
      MM_AGENT_WAIVER=$root mm_rm "$d" "$root" && { MM_COUNT=$((MM_COUNT - 1)); s_empty[$i]=$(( ${s_empty[$i]:-0} + 1 )); }
    done < <(printf '%s\n' "${!s_up[@]}" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
  fi
  for i in "${names[@]}"; do
    n=${s_n[$i]:-0} b=${s_b[$i]:-0}
    old="$(_clean_detail "$n" files "$b") to Trash, oldest $(( (now - s_old[$i]) / 86400 ))d"
    (( ${s_kept[$i]:-0} )) && old+=", ${s_kept[$i]} kept (in use, whitelisted or named like credentials)"
    (( ${s_fail[$i]:-0} )) && old+=", ${s_fail[$i]} failed"
    (( ${s_empty[$i]:-0} )) && old+=", ${s_empty[$i]} empty folders removed"
    mm_ok "${MM_AGENT_NAME[$i]} sessions" "$old"
  done
  _clean_cat_end
}

# ---------------------------------------------------------------- 3. system

_clean_system() {
  _clean_cat "System"
  if ! mm_can_sudo; then mm_skip "System cleanup" "needs sudo"; return; fi
  local busy
  if busy=$(mm_apt_busy); then
    mm_skip "APT cleanup" "$busy"
  else
    _clean_apt_cache
    _clean_apt_autoremove
    _clean_apt_residual
    _clean_kernels
  fi
  _clean_journal
  _clean_snaps
  _clean_cat_end
}

# _clean_apt_run DESC ARGS... — noninteractive apt-get as root.
_clean_apt_run() { local d="$1"; shift; mm_run "$d" mm_sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

# _clean_pkg_bytes PKG... — Installed-Size total in bytes.
_clean_pkg_bytes() {
  (( $# )) || { echo 0; return; }
  dpkg-query -W -f='${Installed-Size}\n' "$@" 2>/dev/null | awk '{ s += $1 } END { printf "%.0f\n", s * 1024 }'
}

# _clean_ask LABEL QUESTION — gate an irreversible step. Dry-run: proceed (callers only list).
# Otherwise mm_confirm, which declines without a terminal; declined → mm_skip.
_clean_ask() {
  [[ "$MM_DRY_RUN" == 1 ]] && return 0
  mm_confirm "$2" && return 0
  if [[ "$MM_TTY" == 1 ]]; then mm_skip "$1" "declined"; else mm_skip "$1" "needs a terminal to confirm"; fi
  return 1
}

# _clean_confirm_pkgs LABEL QUESTION PKG... — list packages, then _clean_ask.
_clean_confirm_pkgs() {
  local label="$1" q="$2"; shift 2
  local shown=("${@:1:8}") more=""
  (( $# > 8 )) && more=" (+$(($# - 8)) more)"
  mm_act "$label: $(IFS=' '; echo "${shown[*]}")$more"
  _clean_ask "$label" "$q"
}

_clean_apt_cache() {
  local n b
  read -r n b < <(mm_sudo find /var/cache/apt/archives -type f \( -name '*.deb' -o -path '*/partial/*' \) \
    -printf '%b\n' 2>/dev/null | awk '{ n++; s += $1 * 512 } END { printf "%.0f %.0f\n", n, s }')
  if (( n == 0 )); then mm_ok "APT package cache" "nothing to clean"; return; fi
  _clean_apt_run "apt-get clean" clean || return 0
  _clean_track "$b" "$n"
  mm_ok "APT package cache" "$(_clean_detail "$n" packages "$b")"
}

_clean_apt_autoremove() {
  local -a pkgs; local b
  mapfile -t pkgs < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv / { print $2 }')
  if (( ${#pkgs[@]} == 0 )); then mm_ok "Unused packages" "none"; return; fi
  b=$(_clean_pkg_bytes "${pkgs[@]}")
  _clean_confirm_pkgs "Unused packages" "Autoremove ${#pkgs[@]} packages?" "${pkgs[@]}" || return 0
  _clean_apt_run "apt-get autoremove" -y autoremove --purge || return 0
  _clean_track "$b" "${#pkgs[@]}"
  mm_ok "Unused packages" "$(_clean_detail "${#pkgs[@]}" packages "$b")"
}

_clean_apt_residual() {
  local -a pkgs
  mapfile -t pkgs < <(dpkg -l 2>/dev/null | awk '$1 == "rc" { print $2 }')
  if (( ${#pkgs[@]} == 0 )); then mm_ok "Residual configs" "none"; return; fi
  _clean_confirm_pkgs "Residual configs" "Purge leftover config files of ${#pkgs[@]} removed packages?" "${pkgs[@]}" || return 0
  _clean_apt_run "purge residual configs" -y purge '~c' || return 0
  _clean_track 0 "${#pkgs[@]}"
  mm_ok "Residual configs" "${#pkgs[@]} packages purged"
}

_clean_kernels() {
  local running newest b
  local -a pkgs auto
  [[ "$(uname -r)" =~ ^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+) ]] || { mm_skip "Old kernels" "unknown running kernel"; return; }
  running=${BASH_REMATCH[1]}
  newest=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 2>/dev/null |
    awk '$1 == "ii" { print $2 }' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | sort -V | tail -1)
  [[ -n "$newest" ]] || { mm_skip "Old kernels" "no kernel images found"; return; }
  # Packages already queued by autoremove are reported there, not twice.
  mapfile -t auto < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv / { print $2 }')
  mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-*' 2>/dev/null |
    awk -v r="$running" -v n="$newest" -v skip="${auto[*]}" '
      BEGIN { split(skip, a, " "); for (i in a) q[a[i]] = 1 }
      $1 == "ii" && match($2, /[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/) {
        abi = substr($2, RSTART, RLENGTH)
        if (abi != r && abi != n && !($2 in q)) print $2
      }')
  if (( ${#pkgs[@]} == 0 )); then mm_ok "Old kernels" "none (running $running, newest $newest)"; return; fi
  b=$(_clean_pkg_bytes "${pkgs[@]}")
  _clean_confirm_pkgs "Old kernels" "Purge ${#pkgs[@]} old kernel packages (keeping $running and $newest)?" "${pkgs[@]}" || return 0
  _clean_apt_run "purge old kernels" -y purge "${pkgs[@]}" || return 0
  _clean_track "$b" "${#pkgs[@]}"
  mm_ok "Old kernels" "$(_clean_detail "${#pkgs[@]}" packages "$b"), kept $running and $newest"
}

_clean_journal() {
  local used limit=$((500 * 1048576)) target=$((300 * 1048576)) after freed
  used=$(_clean_journal_bytes)
  (( used > 0 )) || return 0
  if (( used <= limit )); then mm_ok "Journal" "$(mm_human "$used"), under 500MB"; return; fi
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    freed=$((used - target))
  else
    mm_run "journalctl --vacuum-size=300M" mm_sudo journalctl --vacuum-size=300M || return 0
    after=$(_clean_journal_bytes); freed=$(( used > after ? used - after : 0 ))
  fi
  _clean_track "$freed" 1
  mm_ok "Journal" "vacuumed to 300MB, $(mm_human "$freed")"
}
_clean_journal_bytes() {
  _clean_to_bytes "$(mm_sudo journalctl --disk-usage 2>/dev/null | grep -oE 'take up [0-9.]+[A-Za-z]+' | awk '{ print $3 }')"
}

_clean_snaps() {
  command -v snap >/dev/null || return 0
  local name rev f n=0 b=0 s
  local -a revs
  mapfile -t revs < <(timeout 20 snap list --all 2>/dev/null | awk 'NR > 1 && $NF ~ /disabled/ { print $1, $3 }')
  if (( ${#revs[@]} == 0 )); then mm_ok "Old snap revisions" "none"; return; fi
  for f in "${revs[@]}"; do
    read -r name rev <<<"$f"
    s=$(stat -c %s "/var/lib/snapd/snaps/${name}_${rev}.snap" 2>/dev/null || echo 0)
    mm_run "snap remove $name --revision=$rev" mm_sudo timeout 300 snap remove "$name" --revision="$rev" || continue
    n=$((n + 1)) b=$((b + s))
    mm_debug "snap $name revision $rev ($(mm_human "$s"))"
  done
  _clean_track "$b" "$n"
  mm_ok "Old snap revisions" "$(_clean_detail "$n" revisions "$b")"
}

# ---------------------------------------------------------------- 4. docker

_clean_docker() {
  command -v docker >/dev/null || return 0
  _clean_cat "Docker"
  if ! timeout 5 docker info >/dev/null 2>&1; then mm_skip "Docker" "daemon not reachable"; _clean_cat_end; return; fi
  local n b size
  _clean_docker_containers

  # Dangling images.
  n=0 b=0
  while IFS= read -r size; do
    n=$((n + 1)) b=$((b + $(_clean_to_bytes "$size")))
  done < <(timeout 30 docker images -f dangling=true --format '{{.Size}}' 2>/dev/null)
  if (( n == 0 )); then mm_ok "Dangling images" "none"
  elif mm_run "docker image prune" timeout 600 docker image prune -f; then
    _clean_track "$b" "$n"; mm_ok "Dangling images" "$(_clean_detail "$n" images "$b")"
  fi

  _clean_docker_images

  # Build cache unused for 7 days.
  b=$(timeout 30 docker builder du --filter until=168h 2>/dev/null | awk '/^Reclaimable:/ { print $2 }')
  b=$(_clean_to_bytes "${b:-0}")
  if (( b == 0 )); then mm_ok "Build cache" "nothing older than 7 days"
  elif mm_run "docker builder prune" timeout 600 docker builder prune -f --filter until=168h; then
    _clean_track "$b" 1; mm_ok "Build cache" "$(mm_human "$b") older than 7 days"
  fi

  _clean_docker_volumes
  _clean_cat_end
}

# Stopped containers whose last run ended 7+ days ago (never-started ones: created 7+ days ago).
# `container prune --filter until=` goes by creation time and would take a long-lived container
# stopped minutes ago, so candidates come from inspect data, are listed and confirmed, then removed
# by ID. `docker rm` without -f refuses running containers and keeps their volumes.
_clean_docker_containers() {
  local now cutoff row id name status finished created image size t what n=0 b=0
  local -a ids=() rows=() pick=() lines=()
  now=$(date +%s); cutoff=$((now - 7 * 86400))
  mapfile -t ids < <(timeout 30 docker ps -aq --no-trunc --filter status=exited --filter status=created 2>/dev/null)
  (( ${#ids[@]} )) && mapfile -t rows < <(timeout 60 docker container inspect --size \
    -f $'{{.Id}}\t{{.Name}}\t{{.State.Status}}\t{{.State.FinishedAt}}\t{{.Created}}\t{{.Config.Image}}\t{{.SizeRw}}' \
    "${ids[@]}" 2>/dev/null)
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id name status finished created image size <<<"$row"
    case $status in
      exited) t=$finished what="stopped" ;;
      created) t=$created what="created, never started," ;;
      *) continue ;;
    esac
    t=$(date -d "$t" +%s 2>/dev/null) || continue
    (( t > 0 && t < cutoff )) || continue
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    pick+=("$id") n=$((n + 1)) b=$((b + size))
    lines+=("${name#/} ($image) · $what $(( (now - t) / 86400 ))d ago, $(mm_human "$size")")
  done
  if (( n == 0 )); then mm_ok "Stopped containers" "none stopped for 7+ days"; return; fi
  for row in "${lines[@]:0:10}"; do mm_act "$row"; done
  (( n > 10 )) && mm_act "(+$((n - 10)) more)"
  _clean_ask "Stopped containers" "Remove $n stopped containers ($(mm_human "$b"))?" || return 0
  mm_run "docker rm $n containers" timeout 300 docker rm "${pick[@]}" || return 0 # SAFE: listed, confirmed set of containers stopped 7+ days; no -f, so running ones are refused
  _clean_track "$b" "$n"
  mm_ok "Stopped containers" "$(_clean_detail "$n" containers "$b") stopped 7+ days"
}

# Unused images: tagged images no container (running, stopped or never started) was created from,
# built and last pulled or tagged 30+ days ago. Listed with the space only they hold (`docker
# system df -v` unique size), confirmed, then removed one by one with `docker image rm` naming
# every tag (an ID with several tags would need -f). Without -f the daemon still refuses an image
# a container uses or that other images build on. Space freed is `docker system df` before/after.
_clean_docker_images() {
  local now cutoff out row id tags created tagged t last what n=0 b=0 est before after freed ok=0 fail=0
  local -A used=() uniq=()
  local -a cids=() ids=() lines=() rm_tags=() argv=()
  now=$(date +%s); cutoff=$((now - _CLEAN_IMAGE_DAYS * 86400))
  # Fail closed: an image whose container went unseen would be offered.
  if ! out=$(timeout 30 docker ps -aq --no-trunc 2>/dev/null); then mm_skip "Unused images" "cannot list containers"; return; fi
  [[ -n "$out" ]] && mapfile -t cids <<<"$out"
  if (( ${#cids[@]} )); then
    if ! out=$(timeout 60 docker container inspect -f '{{.Image}}' "${cids[@]}" 2>/dev/null); then
      mm_skip "Unused images" "containers changed while listing"; return
    fi
    while IFS= read -r id; do [[ -n "$id" ]] && used[$id]=1; done <<<"$out"
  fi
  mapfile -t ids < <(timeout 30 docker image ls -q --no-trunc 2>/dev/null | awk 'NF && !seen[$0]++')
  (( ${#ids[@]} )) || { mm_ok "Unused images" "none"; return; }
  while IFS=$'\t' read -r id est; do [[ -n "$id" ]] && uniq[$id]=$(_clean_to_bytes "$est"); done < <(timeout 60 docker system df -v \
    --format $'{{range .Images}}{{.ID}}\t{{.UniqueSize}}\n{{end}}' 2>/dev/null)
  # `join` rejects RepoTags on older clients (Docker 27 decodes it as []interface{}); range works.
  if ! out=$(timeout 60 docker image inspect -f $'{{.Id}}\t{{range .RepoTags}}{{.}} {{end}}\t{{.Created}}\t{{.Metadata.LastTagTime}}' \
    "${ids[@]}" 2>/dev/null); then
    mm_skip "Unused images" "cannot inspect images"; return
  fi
  while IFS=$'\t' read -r id tags created tagged; do
    tags=${tags% }
    [[ -n "$id" && -n "$tags" && -z "${used[$id]+x}" ]] || continue
    t=$(date -d "$created" +%s 2>/dev/null) || continue
    # Pulling or tagging counts as use: a base image built long ago may have been pulled today.
    # Docker's classic image store records no pull time (LastTagTime stays zero until a local
    # `docker tag`); then only the build date is known, and the listing says so.
    what="built"
    if last=$(date -d "$tagged" +%s 2>/dev/null) && (( last > 0 )); then
      what="last pulled or tagged"; (( last > t )) && t=$last
    fi
    (( t > 0 && t < cutoff )) || continue
    est=${uniq[$id]:-0}
    rm_tags+=("$tags") n=$((n + 1)) b=$((b + est))
    read -r row _ <<<"$tags"
    [[ "$tags" == *" "* ]] && row+=" (+$(( $(wc -w <<<"$tags") - 1 )) tags)"
    lines+=("$row · $what $(( (now - t) / 86400 ))d ago, $(mm_human "$est")")
  done <<<"$out"
  if (( n == 0 )); then mm_ok "Unused images" "none unused for ${_CLEAN_IMAGE_DAYS}+ days"; return; fi
  for row in "${lines[@]:0:10}"; do mm_act "$row"; done
  (( n > 10 )) && mm_act "(+$((n - 10)) more)"
  _clean_ask "Unused images" "Remove $n images no container uses ($(mm_human "$b"))?" || return 0
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    _clean_track "$b" "$n"; mm_ok "Unused images" "$(_clean_detail "$n" images "$b") unused for ${_CLEAN_IMAGE_DAYS}+ days"; return
  fi
  before=$(_clean_docker_images_bytes)
  for tags in "${rm_tags[@]}"; do
    read -r -a argv <<<"$tags"
    if mm_run "docker image rm $tags" timeout 300 docker image rm "${argv[@]}"; then # SAFE: listed, confirmed image unused by every container; no -f, so the daemon refuses images in use
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done
  after=$(_clean_docker_images_bytes); freed=$(( before > after ? before - after : 0 ))
  _clean_track "$freed" "$ok"
  mm_ok "Unused images" "$(_clean_detail "$ok" images "$freed" 0 "$fail") unused for ${_CLEAN_IMAGE_DAYS}+ days"
}

# _clean_docker_images_bytes — the Images total of `docker system df` (4 significant digits).
_clean_docker_images_bytes() {
  _clean_to_bytes "$(timeout 60 docker system df --format $'{{.Type}}\t{{.Size}}' 2>/dev/null |
    awk -F'\t' '$1 == "Images" { print $2; exit }')"
}

# Volumes are never pruned (they hold databases); unused ones are listed for review.
_clean_docker_volumes() {
  local -a vols short=(); local sizes b=0 v s
  mapfile -t vols < <(timeout 30 docker volume ls -q -f dangling=true 2>/dev/null)
  (( ${#vols[@]} )) || return 0
  sizes=$(timeout 60 docker system df -v --format $'{{range .Volumes}}{{.Name}}\t{{.Size}}\n{{end}}' 2>/dev/null)
  for v in "${vols[@]}"; do
    s=$(awk -F'\t' -v v="$v" '$1 == v { print $2; exit }' <<<"$sizes")
    [[ "$s" =~ ^[0-9]+$ ]] || s=$(_clean_to_bytes "${s:-0}")
    b=$((b + s))
    short+=("${v:0:12}")
  done
  (( ${#short[@]} > 3 )) && short=("${short[@]:0:3}" "...")
  _clean_review "Unused Docker volumes" "$(mm_human "$b"), ${#vols[@]} volumes (may hold databases): ${short[*]}" \
    "docker volume inspect <name>; remove by hand: docker volume rm <name>"
}

# ---------------------------------------------------------------- 5. editor servers

# Remote-editor servers (VS Code family) unpack one build per editor update and never remove old ones.
_CLEAN_EDITOR_SERVERS=(
  "VS Code|$HOME/.vscode-server"
  "VS Code Insiders|$HOME/.vscode-server-insiders"
  "VSCodium|$HOME/.vscodium-server"
  "Cursor|$HOME/.cursor-server"
  "Windsurf|$HOME/.windsurf-server"
)

_clean_editors() {
  local row name dir p any=0
  local -a roots
  for row in "${_CLEAN_EDITOR_SERVERS[@]}"; do [[ -d "${row#*|}" ]] && any=1; done
  (( any )) || return 0
  _clean_cat "Editor servers"
  for row in "${_CLEAN_EDITOR_SERVERS[@]}"; do
    name=${row%%|*} dir=${row#*|}
    [[ -d "$dir" ]] || continue
    roots=("$dir/cli/servers" "$dir/bin")
    for p in "$dir/bin"/*/; do [[ -d "$p" ]] && roots+=("${p%/}"); done
    _clean_editor_builds "$name server builds" "${roots[@]}"
  done
  _clean_cat_end
}

# _clean_editor_builds LABEL ROOT... — in each ROOT keep the newest build (by mtime), remove the rest.
_clean_editor_builds() {
  local label="$1" root b rc total=0 n=0 bytes=0 kept=0 fail=0; shift
  local -a builds
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    mapfile -t builds < <(find "$root" -mindepth 1 -maxdepth 1 -regextype posix-extended -type d \
      \( -name 'Stable-*' -o -name 'Insiders-*' -o -name 'Exploration-*' -o -regex '.*/[0-9a-f]{40}' \) \
      -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    total=$((total + ${#builds[@]}))
    (( ${#builds[@]} > 1 )) || continue
    mm_debug "$label: keeping newest $(basename -- "${builds[0]}")"
    for b in "${builds[@]:1}"; do
      mm_rm "$b" "$root"; rc=$?
      case $rc in
        0) n=$((n + 1)); bytes=$((bytes + MM_LAST_BYTES)) ;;
        1) kept=$((kept + 1)) ;;
        2) fail=$((fail + 1)) ;;
      esac
    done
  done
  (( total )) || return 0
  if (( n + kept + fail == 0 )); then mm_ok "$label" "only the current build installed"; return; fi
  mm_ok "$label" "$(_clean_detail "$n" "old builds" "$bytes" "$kept" "$fail"), newest kept"
}

# ---------------------------------------------------------------- 6. kept for you to review

# _clean_review LABEL DETAIL [HINT] — queue a line for "Kept for you to review".
_clean_review() { _CLEAN_REVIEW+=("$1"$'\t'"$2"$'\t'"${3:-}"); }

# _clean_ago EPOCH — "today" / "3d ago".
_clean_ago() {
  local d=$(( ($(date +%s) - ${1%.*}) / 86400 ))
  if (( d <= 0 )); then printf 'today'; else printf '%dd ago' "$d"; fi
}

# Coding-agent state (settings, credentials, session transcripts) is never cleaned: report its size
# and when its sessions were last written.
_clean_review_agents() {
  local i p size newest detail added=0 last
  local -a state sess
  for i in "${!MM_AGENT_NAME[@]}"; do
    state=() sess=()
    for p in ${MM_AGENT_STATE[$i]}; do [[ -e "$p" ]] && state+=("$p"); done
    (( ${#state[@]} )) || continue
    # shellcheck disable=SC2153 # set by lib/agents.sh
    for p in ${MM_AGENT_SESSIONS[$i]}; do [[ -d "$p" ]] && sess+=("$p"); done
    size=$(mm_size "${state[@]}")
    detail="$(mm_human "$size")"
    if (( ${#sess[@]} )); then
      newest=$(timeout 30 find "${sess[@]}" -xdev -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
      detail+=", sessions $(mm_human "$(mm_size "${sess[@]}")")"
      [[ -n "$newest" ]] && detail+=", last active $(_clean_ago "$newest")"
    fi
    _clean_review "${MM_AGENT_NAME[$i]} state" "$detail · ${state[*]/#$HOME/\~}"
    added=1
  done
  if (( added )); then   # one hint under the last agent row
    last=${_CLEAN_REVIEW[-1]}
    _CLEAN_REVIEW[-1]="${last%$'\t'*}"$'\t'"agent settings and sessions: opt in to session retention with mm clean --sessions DAYS or sessions_keep_days=DAYS in ${MM_CONFIG_FILE/#$HOME/\~}"
  fi
}

# Catalog "report" rows: big stores that are never touched, shown with size (and version count).
_clean_review_catalog() {
  local i dir real detail n
  local -A seen=()
  for i in "${!MM_CAT_KIND[@]}"; do
    [[ "${MM_CAT_KIND[$i]}" == report ]] || continue
    dir=${MM_CAT_PATH[$i]}
    [[ -d "$dir" ]] || continue
    real=$(realpath -e -- "$dir" 2>/dev/null) || continue
    [[ -z "${seen[$real]+x}" ]] || continue
    seen[$real]=1
    detail=$(mm_human "$(mm_size "$dir")")
    if [[ "${MM_CAT_SPEC[$i]}" == count ]]; then
      n=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' -printf x 2>/dev/null | wc -c)
      detail+=", $n installed"
    fi
    _clean_review "${MM_CAT_LABEL[$i]}" "$detail · ${dir/#$HOME/\~}" "${MM_CAT_HINT[$i]}"
  done
}

# Shared temp folders are never swept: other programs keep runtime state there (sockets, locks,
# the working files of running builds and agents), and the OS ages them with systemd-tmpfiles.
# They are reported with their size and that policy. Directories in tmpfiles.d precedence order.
_CLEAN_TMPFILES_DIRS=(/etc/tmpfiles.d /run/tmpfiles.d /usr/local/lib/tmpfiles.d /usr/lib/tmpfiles.d)

# _clean_tmpfiles_age PATH — "AGE<TAB>FILE" for the tmpfiles.d line systemd-tmpfiles applies to
# PATH, nothing when no line configures it. Per tmpfiles.d(5): a file replaces same-named files in
# later directories (/etc over /run over /usr/lib; a /dev/null symlink masks), and across names the
# first file in lexicographic order that configures PATH wins. AGE is "-" when not set.
_clean_tmpfiles_age() {
  local d f base hit
  local -A conf=()
  for d in "${_CLEAN_TMPFILES_DIRS[@]}"; do
    for f in "$d"/*.conf; do
      [[ -e "$f" || -L "$f" ]] || continue
      base=${f##*/}
      [[ -n "${conf[$base]+x}" ]] || conf[$base]=$f
    done
  done
  (( ${#conf[@]} )) || return 0
  while IFS= read -r base; do
    hit=$(awk -v p="$1" '$2 == p && $1 ~ /^[dDevqQC][-!=~^+]*$/ { print (NF >= 6 ? $6 : "-"); exit }' \
      "${conf[$base]}" 2>/dev/null)
    [[ -n "$hit" ]] && { printf '%s\t%s\n' "$hit" "${conf[$base]}"; return 0; }
  done < <(printf '%s\n' "${!conf[@]}" | LC_ALL=C sort)
}

# _clean_tmpfiles_runs — 0 when systemd is the init system, so its tmpfiles timer ages temp folders.
_clean_tmpfiles_runs() { [[ -d /run/systemd/system ]]; }

# _clean_review_tmp — /tmp and /var/tmp: size (every user's files when root or passwordless sudo,
# else only what this user can read) and the OS aging policy, with a fix when nothing ages them.
_clean_review_tmp() {
  local dir all=0 size age file detail hint fs suggest name
  if (( EUID != 0 )) && command -v sudo >/dev/null && sudo -n true 2>/dev/null; then all=1; fi
  for dir in /tmp /var/tmp; do
    [[ -d "$dir" ]] || continue
    size=$(MM_SIZE_SUDO=$all mm_size "$dir")
    detail=$(mm_human "$size")
    (( EUID != 0 && ! all )) && detail+=" (your files)"
    fs=$(awk -v d="$dir" '$2 == d { t = $3 } END { print t }' /proc/self/mounts 2>/dev/null)
    [[ "$fs" == tmpfs ]] && detail+=", tmpfs (emptied at reboot)"
    age="" file="" hint=""
    IFS=$'\t' read -r age file < <(_clean_tmpfiles_age "$dir")
    if ! _clean_tmpfiles_runs; then
      detail+=" · not aged: systemd-tmpfiles does not run here"
    elif [[ -n "$age" && "$age" != - ]]; then
      detail+=" · the OS removes entries unused for $age ($file)"
    else
      detail+=" · never aged by the OS"
      suggest=10d; [[ "$dir" == /var/tmp ]] && suggest=30d
      name=${dir#/}; name=${name//\//-}-age.conf
      if [[ -z "$file" ]]; then
        hint="to age it: echo 'q $dir 1777 root root $suggest' | sudo tee /etc/tmpfiles.d/$name"
      elif [[ "$file" == /etc/tmpfiles.d/* ]]; then
        hint="to age it: set an age (e.g. $suggest) on the $dir line of $file"
      else
        hint="to age it: sudo cp $file /etc/tmpfiles.d/ and set an age (e.g. $suggest) on its $dir line"
      fi
    fi
    _clean_review "Shared temp $dir" "$detail" "$hint"
  done
}

_clean_review_print() {
  _clean_review_agents
  _clean_review_catalog
  _clean_review_tmp
  (( ${#_CLEAN_REVIEW[@]} )) || return 0
  mm_section "Kept for you to review"
  local row label detail hint
  for row in "${_CLEAN_REVIEW[@]}"; do
    IFS=$'\t' read -r label detail hint <<<"$row"
    printf '  %s◦%s %s · %s\n' "$C_CYAN" "$C_RESET" "$label" "$detail"
    [[ -n "$hint" ]] && printf '    %s%s%s\n' "$C_DIM" "$hint" "$C_RESET"
  done
  return 0
}

# ---------------------------------------------------------------- main

mm_cmd_main() {
  local sessions="" from="" v
  while (( $# )); do
    case "$1" in
      --whitelist) mm_whitelist_edit; return ;;
      --sessions) sessions="${2:-}"; from=flag; shift ;;
      --sessions=*) sessions="${1#*=}"; from=flag ;;
      -h|--help) _clean_usage; return 0 ;;
      *) mm_die "unknown option: $1 (see mm clean --help)" ;;
    esac
    shift
  done
  if [[ -n "$from" ]]; then
    if ! [[ "$sessions" =~ ^[0-9]+$ ]] || (( 10#$sessions < 1 )); then mm_die "--sessions needs a number of days (1 or more)"; fi
    sessions=$((10#$sessions))
  elif v=$(mm_config sessions_keep_days); then
    if [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v >= 1 )); then sessions=$((10#$v)) from=config
    elif [[ -n "$v" && "$v" != 0 && "$v" != off ]]; then
      mm_warn "ignoring sessions_keep_days=$v in $MM_CONFIG_FILE: not a number of days"
    fi
  fi

  mm_header "Clean Your System"
  mm_catalog_load
  mm_inuse_refresh
  local free0 free1 total items delta sign=+
  free0=$(mm_free_bytes /)

  _clean_user
  _clean_dev
  _clean_builds
  [[ -n "$sessions" ]] && _clean_sessions "$sessions" "$from"
  _clean_system
  _clean_docker
  _clean_editors
  _clean_review_print

  total=$((MM_FREED + _CLEAN_TOOL_BYTES)) items=$((MM_COUNT + _CLEAN_TOOL_ITEMS))
  free1=$(mm_free_bytes /)
  local trashed=""
  (( MM_TRASHED > 0 )) && trashed=" | Moved to Trash: $(mm_human "$MM_TRASHED") (restore: trash-restore)"
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_banner "Dry run complete" \
      "Would free: $(mm_human "$total")${trashed/Moved/Would move} | Items to clean: $items | Categories: $_CLEAN_CATS" \
      "Free space: $(mm_human "$free1") now, ~$(mm_human $((free1 + total))) after" \
      "Run without --dry-run to apply."
  else
    delta=$((free1 - free0)); (( delta < 0 )) && { sign=-; delta=$((-delta)); }
    mm_banner "Cleanup complete" \
      "Space freed: $(mm_human "$total")$trashed | Items cleaned: $items | Categories: $_CLEAN_CATS" \
      "Free space: $(mm_human "$free1") ($sign$(mm_human "$delta"))"
  fi
}
