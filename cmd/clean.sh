# shellcheck shell=bash
# mm clean [--sessions DAYS] [--whitelist] — remove caches, old builds, package and Docker leftovers.
# Regenerable caches are removed; the Trash keeps items for 7 days. Shared temp folders (/tmp,
# /var/tmp) are only reported: other programs keep runtime state there and the OS ages them. The
# one exception is the temp files automation browsers leave in /tmp (see _clean_browser_tmp).
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
Gradle build cache and daemon logs, Deno, Bazel, Zig, Prisma, Electron, pyenv, RubyGems,
Bundler, Composer, CPAN, Hex, opam, Android, kubectl discovery, Jupyter runtime files when no
Jupyter runs, ... see lib/catalog.sh), the mise, conda and Homebrew caches through their own
cleanup commands (nix garbage collection only with nix_gc = on in the config file), the cache
folders of chrome-devtools-mcp's browser profiles while no browser has them open (logins stay), old
Playwright/Puppeteer/Cypress browser builds, Firebase emulators and agent-browser Chrome builds,
old versions of coding-agent CLIs (the active one
and one previous are kept), gcloud and Azure CLI logs older than 7 days (their credentials are
never touched), apt/journal/snap leftovers, old kernels, rotated system logs and crash dumps
last written 7+ days ago (/var/log, /var/crash, systemd-coredump, your apport reports; never
live or open logs, never the journal files), stopped Docker containers, dangling images, images
no container uses (pulled or built 30+ days ago), old build cache, stale editor server builds
with their obsolete extensions, cached VSIX packages and week-old logs, and old JetBrains
remote backends (the newest of each IDE is kept).
Trash items deleted more than 7 days ago are removed for good. /tmp and /var/tmp are not
swept: they hold other programs' runtime state, and the OS ages them (systemd-tmpfiles); their
size and the OS policy are reported. The one exception: temp profiles and files that
automation browsers leave in /tmp when their script dies (playwright_chromiumdev_profile-*,
puppeteer_dev_chrome_profile-*, playwright-artifacts-*, [.]org.chromium.Chromium.*,
[.]com.google.Chrome.*), only your own, untouched for 2 hours and not in use, are deleted.
Model stores, dependency repositories, Node versions, Docker volumes and agent state are never
touched: they are listed with their size under "Kept for you to review". Steps that cannot be
undone (Trash sweep, packages, logs, crash dumps, containers, images) ask first and are skipped
without a terminal.

Coding agents' own log files (*.log and rotated logs in their documented logs folders, such
as ~/.omp/logs or ~/.copilot/logs) last written more than 7 days ago and not in use are removed;
session folders are not searched. Agent sessions are kept unless you opt in: with a retention
of N days, session files (and rotated logs in agent state) last written more than N days ago and
not in use move to the Trash; credentials, whitelisted paths and files in use are never touched.
Turn it on with sessions_keep_days=N in $MM_CONFIG_FILE (runs without a terminal act only then),
or use --sessions N for one run (asks first).

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

# _clean_contents LABEL DIR [FILTER] — permanently empty a regenerable cache DIR via mm_rm
# (ALLOWED_ROOT=DIR). FILTER: name globs for the entries (catalog cache spec; !GLOB = leave alone).
_clean_contents() {
  local label="$1" dir="$2" e w n=0 b=0 kept=0 fail=0
  local -a toks=() sel=() inc=()
  read -r -a toks <<<"${3:-}"
  for w in "${toks[@]}"; do
    if [[ "$w" == '!'?* ]]; then sel+=(! -name "${w#!}"); else inc+=(-o -name "$w"); fi
  done
  (( ${#inc[@]} )) && sel+=(\( "${inc[@]:1}" \))
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' e; do
    mm_rm "$e" "$dir"
    case $? in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 "${sel[@]}" -print0 2>/dev/null)
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

# _clean_tool [--prune] LABEL "BUSY_PROC..." SIZE_DIR CMD... — run a tool's own cache clean,
# measured by what it frees in SIZE_DIR: files hard-linked from outside (uv links its cache into
# virtualenvs) stay on disk, so they are not counted. CMD runs from / so project-local config
# (.npmrc, .yarnrc.yml, committed .yarn/cache) never applies. Dry-run estimates what removing all
# of SIZE_DIR would free; with --prune CMD removes only entries nothing uses, which no tool can
# preview, so dry-run claims no bytes. Callers only invoke it when the tool is installed.
_clean_tool() {
  local prune=0; [[ "$1" == --prune ]] && { prune=1; shift; }
  local label="$1" procs="$2" dir="$3" busy size before after freed; shift 3
  [[ -d "$dir" ]] || { mm_ok "$label" "nothing to clean"; return; }
  if mm_whitelisted "$dir"; then mm_skip "$label" "whitelisted"; return; fi
  if busy=$(_clean_busy "$procs"); then mm_skip "$label" "$busy busy"; return; fi
  read -r size before < <(mm_size_frees "$dir")
  if (( size < _CLEAN_MIN_TOOL )); then mm_ok "$label" "nothing to clean ($(mm_human "$size"))"; return; fi
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_run "$label" env -C / "$@"
    if (( prune )); then
      mm_ok "$label" "$(mm_human "$size") cache, would prune unused entries (size unknown until run)"; return
    fi
    _clean_track "$before" 1; mm_ok "$label" "$(mm_human "$before")"; return
  fi
  mm_run "$label" env -C / "$@" || return 0
  after=$(mm_frees "$dir"); freed=$(( before > after ? before - after : 0 ))
  _clean_track "$freed" 1
  if (( prune )); then mm_ok "$label" "pruned, $(mm_human "$freed")"; else mm_ok "$label" "cleaned, $(mm_human "$freed")"; fi
}

# _clean_home_dir LABEL DIR — 0 if DIR is a non-empty directory that resolves strictly inside $HOME
# and is not protected. Prints a skip line for protected/outside dirs; silent when absent or empty.
# A carve-out folder (lib/core.sh MM_CLEAN_CARVEOUTS) passes: mm_rm checks each entry inside it.
_clean_home_dir() {
  local label="$1" dir="$2" real
  [[ -d "$dir" ]] || return 1
  [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || return 1
  real=$(realpath -e -- "$dir" 2>/dev/null) || return 1
  if [[ "$real" != "$HOME"/?* ]]; then mm_skip "$label" "resolves outside your home folder"; return 1; fi
  [[ "$real" == "$dir" ]] && _clean_carveout_dir "$dir" && return 0
  if mm_whitelisted "$dir" || mm_whitelisted "$real"; then mm_skip "$label" "protected"; return 1; fi
  return 0
}

# _clean_carveout_dir DIR — 0 if DIR is exactly one of the carve-out folders.
_clean_carveout_dir() {
  local c
  for c in "${MM_CLEAN_CARVEOUTS[@]}"; do [[ "$1" == "$c" ]] && return 0; done
  return 1
}

# _clean_cache_row LABEL DIR BUSY [FILTER] — catalog "cache" row: empty DIR (kept) unless a busy
# process runs. FILTER is the row's spec (see _clean_contents).
_clean_cache_row() {
  local label="$1" dir="$2" busy
  _clean_home_dir "$label" "$dir" || return 0
  if busy=$(_clean_busy "$3"); then mm_skip "$label" "$busy busy"; return 0; fi
  _clean_contents "$label" "$dir" "${4:-}"
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
  local -a rels=() prods=() vers=() types=(-type d)
  _clean_home_dir "$label" "$dir" || return 0
  if busy=$(_clean_busy "$3"); then mm_skip "$label" "$busy busy"; return 0; fi
  depth=${spec%%:*} regex=${spec#*:}
  [[ "$regex" == *:files ]] && { regex=${regex%:files}; types=(\( -type d -o -type f \)); }
  [[ "$regex" == *:refs=* ]] && { refs=${regex##*:refs=}; regex=${regex%:refs=*}; }
  [[ "$depth" =~ ^[1-9]$ ]] || { mm_debug "$label: bad spec $spec"; return 0; }
  while IFS= read -r -d '' rel; do
    [[ "$rel" != .* && "$rel" != */.* && "$rel" =~ $regex ]] || continue
    prod=${BASH_REMATCH[1]:-.} ver=${BASH_REMATCH[2]}   # "." = single-product layouts (empty group 1)
    rels+=("$rel") prods+=("$prod") vers+=("$ver")
    if [[ -z "${newest[$prod]+x}" || "$(printf '%s\n%s\n' "${newest[$prod]}" "$ver" | sort -V | tail -1)" == "$ver" ]]; then
      newest[$prod]=$ver
    fi
  done < <(find "$dir" -mindepth "$depth" -maxdepth "$depth" "${types[@]}" -printf '%P\0' 2>/dev/null)
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
  command -v uv >/dev/null && _clean_uv
  command -v go >/dev/null && _clean_go_modcache
  command -v mise >/dev/null && _clean_mise
  command -v conda >/dev/null && _clean_conda
  command -v brew >/dev/null && _clean_brew
  command -v nix-collect-garbage >/dev/null && _clean_nix
  _clean_catalog_caches
  _clean_browser_profiles
  _clean_cloud_logs
  _clean_cat_end
}

# Catalog "cache" rows (built-in and the user's): emptied directly, whether or not the tool is
# still installed (then they are pure leftovers). A row with spec tool:CMD is left to CMD's own
# clean above while CMD is installed; any other spec filters the entries. A folder named by
# several rows ($VAR and its default) is handled once, so a dry run does not count it twice.
_clean_catalog_caches() {
  local r i real filter
  local -A seen=()
  for r in "${MM_CAT_REJECTED[@]}"; do mm_warn "catalog row ignored: $r"; done
  for i in "${!MM_CAT_KIND[@]}"; do
    [[ "${MM_CAT_KIND[$i]}" == cache ]] || continue
    if [[ "${MM_CAT_SPEC[$i]}" == tool:?* ]]; then
      command -v "${MM_CAT_SPEC[$i]#tool:}" >/dev/null && continue
      filter=""
    else
      filter=${MM_CAT_SPEC[$i]}
    fi
    real=$(realpath -e -- "${MM_CAT_PATH[$i]}" 2>/dev/null) || continue
    [[ -z "${seen[$real]+x}" ]] || continue
    seen[$real]=1
    _clean_cache_row "${MM_CAT_LABEL[$i]}" "${MM_CAT_PATH[$i]}" "${MM_CAT_BUSY[$i]}" "$filter"
  done
  return 0
}

# Old browser/test-runner builds and old coding-agent CLI versions (catalog revisions + versions).
# Rows only print when they find something, so output is buffered and the section is shown only
# when non-empty (no row here prompts). A folder named by several rows is handled once.
_clean_builds() {
  local i buf real
  local -A seen=()
  buf=$(mktemp -t marmot-clean.XXXXXX) || return 0
  _CLEAN_CAT_MARK="$((MM_FREED + MM_TRASHED + _CLEAN_TOOL_BYTES)) $((MM_COUNT + _CLEAN_TOOL_ITEMS))"
  for i in "${!MM_CAT_KIND[@]}"; do
    [[ "${MM_CAT_KIND[$i]}" == revisions || "${MM_CAT_KIND[$i]}" == versions ]] || continue
    real=$(realpath -e -- "${MM_CAT_PATH[$i]}" 2>/dev/null) || continue
    [[ -z "${seen[$real]+x}" ]] || continue
    seen[$real]=1
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

# ---------------------------------------------------------------- agent logs

# Coding agents' own diagnostic logs (logs dirs in lib/agents.sh) are not conversations: *.log
# files and their rotations there, last written more than _CLEAN_LOG_DAYS days ago and not in use,
# are removed for good, on every run. Session dirs are never searched (sessions stay opt-in, below).
# Each file goes through mm_rm with the agent waiver for its logs dir, so files named like
# credentials, whitelisted paths and open files are kept.
_CLEAN_LOG_DAYS=7
_CLEAN_LOG_NAMES=('*.log' '*.log.[0-9]*' '*.log.*.gz' '*.log.old')

# _clean_find_literal PATH — PATH with find's glob characters escaped, for -path.
_clean_find_literal() {
  local s=${1//\\/\\\\}
  s=${s//\*/\\*} s=${s//\?/\\?} s=${s//\[/\\[}
  printf '%s' "$s"
}

_clean_agent_logs() {
  local i dir root s rec t path now n b old kept fail any=0 shown=0 detail
  local -a names=() sess=() prune=(-false)
  local -A seen=()
  for i in "${!MM_AGENT_NAME[@]}"; do
    for dir in ${MM_AGENT_LOGS[$i]}; do [[ -d "$dir" ]] && any=1; done
  done
  (( any )) || return 0
  _clean_cat "Agent logs"
  now=$(date +%s)
  for s in "${_CLEAN_LOG_NAMES[@]}"; do names+=(-o -name "$s"); done
  for i in "${!MM_AGENT_NAME[@]}"; do
    # shellcheck disable=SC2153 # set by lib/agents.sh
    for dir in ${MM_AGENT_SESSIONS[$i]}; do
      s=$(realpath -e -- "$dir" 2>/dev/null) || continue
      sess+=("$s") prune+=(-o -path "$(_clean_find_literal "$s")")
    done
  done
  for i in "${!MM_AGENT_NAME[@]}"; do
    n=0 b=0 kept=0 fail=0 old=$now
    for dir in ${MM_AGENT_LOGS[$i]}; do
      [[ -d "$dir" ]] || continue
      if ! root=$(realpath -e -- "$dir" 2>/dev/null) || ! mm_agent_dir "$root"; then
        mm_skip "${dir/#$HOME/\~}" "outside your home folder"; continue
      fi
      for s in "${sess[@]}"; do
        [[ "$root" == "$s" || "$root" == "$s"/* ]] && { mm_skip "${dir/#$HOME/\~}" "inside a session folder"; continue 2; }
      done
      while IFS= read -r -d '' rec; do
        t=${rec%% *} path=${rec#* }
        [[ -z "${seen[$path]+x}" ]] || continue
        seen[$path]=1
        MM_AGENT_WAIVER=$root mm_rm "$path" "$root"
        case $? in
          0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) t=${t%.*}; (( t < old )) && old=$t ;;
          1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
          *) fail=$((fail + 1)) ;;
        esac
      done < <(find "$root" -xdev \( -type d \( "${prune[@]}" \) -prune \) -o \
        \( -type f \( "${names[@]:1}" \) -mmin +$((_CLEAN_LOG_DAYS * 1440)) -printf '%T@ %p\0' \) 2>/dev/null)
    done
    (( n + kept + fail )) || continue
    detail=$(_clean_detail "$n" files "$b")
    (( n )) && detail+=", oldest $(( (now - old) / 86400 ))d"
    (( kept )) && detail+=", $kept kept (in use, whitelisted or named like credentials)"
    (( fail )) && detail+=", $fail failed"
    mm_ok "${MM_AGENT_NAME[$i]} logs" "$detail"
    shown=1
  done
  (( shown )) || mm_ok "Agent logs" "nothing older than $_CLEAN_LOG_DAYS days"
  _clean_cat_end
}

# ---------------------------------------------------------------- agent sessions (opt-in)

# Session transcripts are the user's conversations: untouched unless they set a retention
# (sessions_keep_days=N in the config file, or --sessions N for one run). Then files under each
# agent's session dirs (lib/agents.sh) and rotated logs in its state dirs (outside its logs dirs,
# which the agent logs step handles), last written more than N days ago and not in use, move to
# the Trash (restorable); folders they leave empty are removed.
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
  local days="$1" from="$2" now tdev i dir root rec t blk path n b old rc d l
  local total=0 tb=0
  local -a units=() names=() logs=() match=() skip=(-false)
  # Per agent index: candidates, their bytes, oldest mtime; moved, moved bytes, kept, failed,
  # emptied folders. s_up: every folder above a moved file (inside its root) -> "index<TAB>root".
  local -A seen=() s_cnt=() s_bytes=() s_old=() s_n=() s_b=() s_kept=() s_fail=() s_empty=() s_up=()
  _clean_cat "Agent sessions older than $days days"
  now=$(date +%s) tdev=$(_clean_trash_dev)
  for d in "${_CLEAN_ROTATED_LOGS[@]}"; do logs+=(-o -name "$d"); done
  for l in "${MM_AGENT_LOGS[@]}"; do
    for d in $l; do d=$(realpath -e -- "$d" 2>/dev/null) && skip+=(-o -path "$(_clean_find_literal "$d")"); done
  done
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
      done < <(find "$root" -xdev \( -type d \( "${skip[@]}" \) -prune \) -o \
        \( "${match[@]}" -mmin +$((days * 1440)) -printf '%T@ %b %p\0' \) 2>/dev/null)
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

# uv's own prune: removes cache buckets older uv versions left behind, unpacked archives no wheel
# points to, and cached `uv run --with` environments; wheels current projects install from stay.
# Never --ci (that also drops downloaded wheels) or --force (that ignores uv's in-use lock). The
# location comes from `uv cache dir`, asked from / so UV_CACHE_DIR and the user's uv.toml apply
# but no project's.
_clean_uv() {
  local dir
  dir=$(env -C / timeout 15 uv cache dir 2>/dev/null | tail -1)
  [[ "$dir" == /* ]] || { mm_skip "uv cache" "cache dir unknown"; return; }
  _clean_tool --prune "uv cache" "uv uvx" "$dir" uv cache prune
}

# Go module cache (GOMODCACHE, default ~/go/pkg/mod) through `go clean -modcache`, which copes with
# the read-only permissions Go gives module files. Builds download missing modules again (checked
# against go.sum), so it is a cache like npm's. Skipped while go, gopls or dlv runs (a build, the
# language server or a debug session reads module sources), and with GOPROXY=off, where nothing
# could be downloaded back. GOTOOLCHAIN=local: never fetch a toolchain just to clean.
_clean_go_modcache() {
  local -a env=()
  mapfile -t env < <(env -C / GOTOOLCHAIN=local timeout 15 go env GOMODCACHE GOPROXY 2>/dev/null)
  [[ "${env[0]:-}" == /* ]] || { mm_skip "Go module cache" "location unknown"; return; }
  if [[ "${env[1]:-}" == off ]]; then mm_skip "Go module cache" "GOPROXY=off, modules could not be downloaded again"; return; fi
  _clean_tool "Go module cache" "go gopls dlv" "${env[0]}" GOTOOLCHAIN=local go clean -modcache
}

# ---------------------------------------------------------------- cloud CLI logs

# Cloud CLIs log inside their config folders, which stay protected as a whole (credentials live
# next to the logs); lib/core.sh carves the logs folders out (MM_CLEAN_CARVEOUTS). gcloud writes
# one file per invocation into a folder per day (logs/YYYY.MM.DD/) and drops them only after 30
# days (core/max_log_days); Azure CLI's optional file log (logging.enable_log_file) rotates
# logs/az.log. The AWS CLI writes no log files (--debug goes to stderr) and its ~/.aws/cli/cache
# and ~/.aws/sso/cache hold credentials, so ~/.aws is not touched.
_CLEAN_LOG_DAYS=7   # cloud CLI logs last written longer ago than this are deleted

_clean_cloud_logs() {
  _clean_cloud_log_dir "gcloud logs" "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/logs"
  _clean_cloud_log_dir "Azure CLI logs" "${AZURE_CONFIG_DIR:-$HOME/.azure}/logs"
}

# _clean_cloud_log_dir LABEL DIR — permanently delete the files in DIR last written 7+ days ago.
# A subfolder (gcloud's day folders) with nothing newer goes whole in one mm_rm, folder included;
# when that is refused, or it holds newer files, its old files go one by one and the folder stays.
# Reports files, size and the oldest one.
_clean_cloud_log_dir() {
  local label="$1" dir="$2" cutoff e t k newer n=0 b=0 kept=0 fail=0 empty=0 oldest="" d
  [[ -d "$dir" ]] || return 0
  # The carve-out in lib/core.sh only covers canonical paths; a link here could point anywhere.
  if [[ "$(realpath -e -- "$dir" 2>/dev/null)" != "$dir" ]]; then
    mm_skip "$label" "${dir/#$HOME/\~} is a symlink or not a canonical path"; return 0
  fi
  cutoff=$(( $(date +%s) - _CLEAN_LOG_DAYS * 86400 ))
  while IFS= read -r -d '' e; do
    if [[ -f "$e" && ! -L "$e" ]]; then
      t=$(stat -c %Y -- "$e" 2>/dev/null) || continue
      (( t <= cutoff )) && _clean_cloud_log_rm "$e" "$t"
    elif [[ -d "$e" && ! -L "$e" ]]; then
      # Unreadable parts count as newer: then only what find lists as old is touched.
      newer=$(find "$e" -xdev -newermt "@$cutoff" -print -quit 2>/dev/null) || newer=unreadable
      if [[ -z "$newer" ]]; then
        read -r k t < <(find "$e" -xdev -type f -printf '%T@\n' 2>/dev/null |
          awk 'NR == 1 || $1 < m { m = $1 } END { printf "%.0f %.0f\n", NR, m }')
        mm_rm "$e" "$dir"
        case $? in
          0) n=$((n + k)) b=$((b + MM_LAST_BYTES)) MM_COUNT=$((MM_COUNT + k - 1))
             if (( k == 0 )); then empty=$((empty + 1)); elif [[ -z "$oldest" ]] || (( t < oldest )); then oldest=$t; fi
             continue ;;
          1) [[ "$MM_SKIP_REASON" == missing ]] && continue ;;
          *) fail=$((fail + 1)); continue ;;
        esac
      fi
      while IFS=' ' read -r -d '' t e; do
        _clean_cloud_log_rm "$e" "${t%.*}"
      done < <(find "$e" -xdev -type f ! -newermt "@$cutoff" -printf '%T@ %p\0' 2>/dev/null)
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if (( n + kept + fail + empty == 0 )); then
    mm_ok "$label" "nothing older than $_CLEAN_LOG_DAYS days ($(mm_human "$(mm_size "$dir")") newer)"; return
  fi
  d="$(_clean_detail "$n" files "$b" "$kept" "$fail")"
  [[ -n "$oldest" ]] && d+=", oldest $(_clean_ago "$oldest")"
  (( empty )) && d+=", $empty empty folders"
  mm_ok "$label" "$d"
}

# _clean_cloud_log_rm FILE MTIME — one old log file (counters are _clean_cloud_log_dir's locals).
_clean_cloud_log_rm() {
  mm_rm "$1" "$dir"
  case $? in
    0) n=$((n + 1)) b=$((b + MM_LAST_BYTES))
       if [[ -z "$oldest" ]] || (( $2 < oldest )); then oldest=$2; fi ;;
    1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
    *) fail=$((fail + 1)) ;;
  esac
  return 0
}

# ---------------------------------------------------------------- mise, conda, Homebrew, nix

# mise keeps downloads and version lists in its cache folder; installed tools live elsewhere
# (~/.local/share/mise), so clearing it only costs re-downloads.
_clean_mise() {
  local dir="${MISE_CACHE_DIR:-$(mm_catalog_expand %CACHE%)/mise}"
  _clean_tool "mise cache" mise "${dir%/}" mise cache clear
}

# conda: package tarballs, the index cache and log files of every package cache it can write.
# Extracted packages, which environments hard-link to, stay. The dry-run figure counts exactly
# those entries; a real run is measured on the package caches.
_clean_conda() {
  local label="conda package cache" busy d est before after freed
  local -a dirs=() parts=()
  while IFS= read -r d; do
    [[ -d "$d" && -w "$d" ]] || continue
    if mm_whitelisted "$d"; then mm_skip "$label" "whitelisted"; return; fi
    dirs+=("$d")
  done < <(env -C / timeout 30 conda config --show pkgs_dirs 2>/dev/null | awk '/^[[:space:]]*- / { sub(/^[[:space:]]*- /, ""); print }')
  (( ${#dirs[@]} )) || return 0
  if busy=$(_clean_busy "conda mamba micromamba"); then mm_skip "$label" "$busy busy"; return; fi
  mapfile -d '' -t parts < <(find "${dirs[@]}" -mindepth 1 -maxdepth 1 \
    \( -name '*.tar.bz2' -o -name '*.conda' -o -name cache -o -name .logs \) -print0 2>/dev/null)
  est=$(mm_size "${parts[@]}")
  if (( est < _CLEAN_MIN_TOOL )); then mm_ok "$label" "nothing to clean ($(mm_human "$est"))"; return; fi
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    _clean_track "$est" 1; mm_ok "$label" "$(mm_human "$est") of tarballs, index cache and logs"; return
  fi
  before=$(mm_size "${dirs[@]}")
  mm_run "$label" env -C / conda clean --yes --index-cache --tarballs --logfiles || return 0
  after=$(mm_size "${dirs[@]}"); freed=$(( before > after ? before - after : 0 ))
  _clean_track "$freed" 1
  mm_ok "$label" "cleaned, $(mm_human "$freed")"
}

# Homebrew (on Linux, linuxbrew): old versions of installed formulae and downloads older than 30
# days. The dry-run figure is brew's own (`brew cleanup -n`); a real run is measured on the Cellar
# and the download cache.
_clean_brew() {
  local label="Homebrew cleanup" busy cache cellar size est before after freed
  local -a brew=(env -C / HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 timeout 300 brew)
  if busy=$(_clean_busy "brew f:Homebrew/brew\.(sh|rb)"); then mm_skip "$label" "$busy busy"; return; fi
  cache=$("${brew[@]}" --cache 2>/dev/null) cellar=$("${brew[@]}" --cellar 2>/dev/null)
  [[ "$cache" == /* && "$cellar" == /* ]] || { mm_skip "$label" "brew paths unknown"; return; }
  if mm_whitelisted "$cache" || mm_whitelisted "$cellar"; then mm_skip "$label" "whitelisted"; return; fi
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    # "This operation would free approximately 1.2GB of disk space." (binary units)
    size=$("${brew[@]}" cleanup --prune=30 -n 2>/dev/null | grep -oE 'free approximately [0-9.]+[KMGT]?B' | tail -1)
    size=${size##* }
    est=$(_clean_to_bytes "${size/B/iB}")
    if (( est < _CLEAN_MIN_TOOL )); then mm_ok "$label" "nothing to clean"; return; fi
    _clean_track "$est" 1; mm_ok "$label" "$(mm_human "$est") (brew's estimate)"; return
  fi
  before=$(mm_size "$cache" "$cellar")
  mm_run "$label" env -C / HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew cleanup --prune=30 || return 0
  after=$(mm_size "$cache" "$cellar"); freed=$(( before > after ? before - after : 0 ))
  _clean_track "$freed" 1
  mm_ok "$label" "cleaned, $(mm_human "$freed")"
}

# nix is opt-in (nix_gc = on in $MM_CONFIG_FILE): deleting profile generations removes rollback
# points, a choice only the user can make. With it on, generations older than 30 days go and the
# store paths nothing refers to any more are collected; nix reports what that freed (a dry run
# cannot know it).
_clean_nix_enabled() {
  local v
  v=$(mm_config nix_gc) || return 1
  [[ "${v,,}" == on || "${v,,}" == yes || "${v,,}" == true || "$v" == 1 ]]
}

_clean_nix() {
  local label="nix store" busy log out freed
  if ! _clean_nix_enabled; then mm_skip "$label" "opt-in: nix_gc = on in ${MM_CONFIG_FILE/#$HOME/\~}"; return; fi
  if busy=$(_clean_busy "nix nix-build nix-shell nix-env nix-store nix-instantiate nix-collect-garbage"); then
    mm_skip "$label" "$busy busy"; return
  fi
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    mm_ok "$label" "would delete generations older than 30 days and collect garbage (size known after the run)"; return
  fi
  log=$(mktemp -t marmot-nix.XXXXXX) || return 0
  if mm_run "nix-collect-garbage --delete-older-than 30d" env -C / bash -c \
       'set -o pipefail; nix-collect-garbage --delete-older-than 30d 2>&1 | tee "$1"' _ "$log"; then
    # "1234 store paths deleted, 567.89 MiB freed"
    out=$(grep -oE '[0-9.]+ (bytes|KiB|MiB|GiB|TiB) freed' "$log" | tail -1)
    freed=$(_clean_to_bytes "${out% freed}")
    _clean_track "$freed" 1
    mm_ok "$label" "collected, $(mm_human "$freed")"
  fi
  rm -f -- "$log" # SAFE: the mktemp copy of nix's output created above
}

# ---------------------------------------------------------------- agent browser profiles

# Persistent Chromium profiles that browser tools for agents keep in the home folder grow their
# HTTP, code and GPU caches without bound. Only those cache folders of the Default profile go;
# logins, cookies and site storage stay, and a profile a browser has open is skipped.
# chrome-devtools-mcp: <dir>/chrome-profile (stable) or chrome-profile-<channel>, in
# ~/.cache/chrome-devtools-mcp (MCP server) and ~/.cache/chrome-devtools-mcp-cli (its CLI).
# agent-browser keeps no profile here (temporary ones, or a path you choose with --profile), and
# profiles inside agent state (such as Antigravity's under ~/.gemini) stay protected.
_CLEAN_BROWSER_PROFILE_DIRS=("$HOME/.cache/chrome-devtools-mcp" "$HOME/.cache/chrome-devtools-mcp-cli")
_CLEAN_CHROMIUM_CACHES=(Cache "Code Cache" GPUCache DawnCache DawnGraphiteCache GrShaderCache "Service Worker/CacheStorage")

_clean_browser_profiles() {
  local base profile
  for base in "${_CLEAN_BROWSER_PROFILE_DIRS[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' profile; do
      _clean_browser_profile "$profile"
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d \( -name chrome-profile -o -name 'chrome-profile-*' \) -print0 2>/dev/null)
  done
  return 0
}

# _clean_browser_profile PROFILE — permanently remove the cache folders of PROFILE/Default.
_clean_browser_profile() {
  local profile="$1" label leaf why n=0 b=0 kept=0 fail=0
  label="Browser profile caches (${profile/#$HOME/\~})"
  if why=$(_clean_profile_open "$profile"); then mm_skip "$label" "$why"; return 0; fi
  for leaf in "${_CLEAN_CHROMIUM_CACHES[@]}"; do
    [[ -d "$profile/Default/$leaf" && ! -L "$profile/Default/$leaf" ]] || continue
    mm_rm "$profile/Default/$leaf" "$profile"
    case $? in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done
  (( n + kept + fail )) || return 0
  mm_ok "$label" "$(_clean_detail "$n" "cache folders" "$b" "$kept" "$fail")"
}

# _clean_profile_open PROFILE — print why a browser has PROFILE open: a process uses a file in it,
# a running process was started with it as --user-data-dir, or Chromium's SingletonLock
# ("<host>-<pid>") names a live process here or another host. 1 when it is free.
_clean_profile_open() {
  local p="$1" lock me=""
  if mm_in_use "$p"; then printf 'in use'; return 0; fi
  if mm_proc_match "" "--user-data-dir[= ]$(_clean_ere_quote "$p")/?( |\$)"; then printf 'browser running'; return 0; fi
  lock=$(readlink -- "$p/SingletonLock" 2>/dev/null) || return 1
  { IFS= read -r me </proc/sys/kernel/hostname; } 2>/dev/null
  if [[ "${lock%-*}" != "$me" || ! "${lock##*-}" =~ ^[0-9]+$ || -d "/proc/${lock##*-}" ]]; then
    printf 'browser running'; return 0
  fi
  return 1
}

# _clean_ere_quote STRING — STRING with ERE special characters escaped.
_clean_ere_quote() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in \[|\]|\\|.|\*|^|\$|+|\?|\(|\)|\{|\}|\|) out+=\\ ;; esac
    out+=$c
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------- 3. system

_clean_system() {
  _clean_cat "System"
  _clean_user_crash_reports
  if ! mm_can_sudo; then mm_skip "System cleanup" "needs sudo"; _clean_cat_end; return; fi
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
  _clean_rotated_logs
  _clean_crash_dumps
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

# ---------------------------------------------------------------- 3b. old logs and crash dumps
# Rotated logs and crash dumps lie in trees mm_rm never deletes in (/var/log, /var/crash,
# /var/lib), so they are removed as root by _CLEAN_ROOT_RM, a fixed script that re-checks every
# listed file right before deleting it. The roots are plain variables (tests point them at a
# sandbox after sourcing; nothing in the environment can change them).
_CLEAN_LOG_ROOT=/var/log
_CLEAN_CRASH_ROOTS=(/var/crash /var/lib/systemd/coredump)
_CLEAN_OLD_DAYS=7   # rotated logs and crash dumps last written longer ago than this are offered

# Run as root: print the target of every open file descriptor (NUL-separated), then "-" as an end
# marker. Without the marker the list is incomplete (sudo failed) and nothing may be deleted.
_CLEAN_OPEN_FDS='find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l -printf "%l\0" 2>/dev/null; printf -- "-\0"'

# Run as root with MINUTES, then DEV:INODE PATH pairs: delete each PATH that is still the same
# regular file, still unmodified for MINUTES, and open by no process.
_CLEAN_ROOT_RM='min=$1; shift; rc=0
declare -A open=()
while IFS= read -r -d "" t; do open[$t]=1; done < <(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l -printf "%l\0" 2>/dev/null)
while (( $# >= 2 )); do
  id=$1 p=$2; shift 2
  [[ -z ${open[$p]+x} ]] || continue
  [[ "$(find "$p" -maxdepth 0 -type f -mmin "+$min" -printf "%D:%i" 2>/dev/null)" == "$id" ]] || continue
  rm -f -- "$p" || rc=1 # SAFE: a listed, confirmed old log or dump, re-checked (same inode, still old, not open) just above
done
exit $rc'

# _clean_rotated_logs — rotated copies under /var/log (*.1, *.2.gz, *.gz, *.old) unmodified for
# 7+ days. Live logs never match (they are *.log or have no suffix), open files are kept, and the
# journal is left to journald's own vacuum above.
_clean_rotated_logs() {
  if mm_proc_running logrotate; then mm_skip "Rotated logs" "logrotate busy"; return 0; fi
  _clean_root_files "Rotated logs" "rotated logs" "" "$_CLEAN_LOG_ROOT" -- \
    -name journal -type d -prune -o \( -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.gz' -o -name '*.old' \)
}

# _clean_crash_dumps — apport reports and kernel dumps in /var/crash and systemd-coredump cores,
# unmodified for 7+ days (hidden files such as apport's lock are left alone).
_clean_crash_dumps() {
  local hint=""
  command -v coredumpctl >/dev/null && hint="inspect cores first with: coredumpctl list"
  _clean_root_files "Crash dumps" "crash dumps" "$hint" "${_CLEAN_CRASH_ROOTS[@]}" -- ! -name '.*'
}

# _clean_root_files LABEL NOUN HINT ROOT... -- FIND_EXPR... — regular files under the ROOTs (one
# filesystem, listed as root) that FIND_EXPR selects, unmodified for _CLEAN_OLD_DAYS days and open
# by no process: listed with count, size and the largest, confirmed on a terminal, then removed
# by _CLEAN_ROOT_RM. Sizes are allocated blocks, each inode counted once and only when every link
# to it goes; freed is measured afterwards from the files actually gone.
_clean_root_files() {
  local label="$1" noun="$2" hint="$3" min=$((_CLEAN_OLD_DAYS * 1440)) r rec id nl blk p rest
  local n=0 b=0 held=0 marker=0 top="" line removed=0 freed=0
  shift 3
  local -a roots=() pairs=() paths=() sizes=()
  local -A open=() isize=() nlink=() listed=() left=() gone=()
  while (( $# )) && [[ "$1" != -- ]]; do
    r=$(realpath -e -- "$1" 2>/dev/null) && [[ -d "$r" && "$r" != / ]] && roots+=("$r")
    shift
  done
  shift
  (( ${#roots[@]} )) || return 0
  while IFS= read -r -d '' p; do
    if [[ "$p" == - ]]; then marker=1; elif [[ -n "$p" ]]; then open[$p]=1; fi
  done < <(mm_sudo bash -c "$_CLEAN_OPEN_FDS" 2>/dev/null)
  (( marker )) || { mm_skip "$label" "cannot see which files are open"; return 0; }
  while IFS= read -r -d '' rec; do
    id=${rec%%$'\t'*} rest=${rec#*$'\t'}
    nl=${rest%%$'\t'*} rest=${rest#*$'\t'}
    blk=${rest%%$'\t'*} p=${rest#*$'\t'}
    [[ "$id" =~ ^[0-9]+:[0-9]+$ && "$nl" =~ ^[0-9]+$ && "$blk" =~ ^[0-9]+$ ]] || continue
    [[ "$p" == /* && "$p" != *[[:cntrl:]]* ]] || continue
    if [[ -n "${open[$p]+x}" ]]; then held=$((held + 1)); continue; fi
    pairs+=("$id" "$p") paths+=("$p") sizes+=("$((blk * 512))"$'\t'"$p")
    [[ -n "${isize[$id]+x}" ]] || { isize[$id]=$((blk * 512)) nlink[$id]=$nl listed[$id]=0; }
    listed[$id]=$(( ${listed[$id]} + 1 ))
  done < <(mm_sudo find "${roots[@]}" -xdev \( "$@" \) -type f -mmin "+$min" -printf '%D:%i\t%n\t%b\t%p\0' 2>/dev/null)
  n=${#paths[@]}
  for id in "${!isize[@]}"; do (( ${listed[$id]} >= ${nlink[$id]} )) && b=$((b + ${isize[$id]})); done
  local note=""
  (( held )) && note=", $held open kept"
  if (( n == 0 )); then mm_ok "$label" "nothing older than $_CLEAN_OLD_DAYS days$note"; return 0; fi
  while IFS= read -r line; do
    top+="${top:+, }${line#*$'\t'} ($(mm_human "${line%%$'\t'*}"))"
  done < <(printf '%s\n' "${sizes[@]}" | sort -rn | head -3)
  mm_act "$label: $n files older than $_CLEAN_OLD_DAYS days, $(mm_human "$b")$note; largest: $top"
  [[ -n "$hint" ]] && mm_info "  $hint"
  _clean_ask "$label" "Permanently delete $n $noun older than $_CLEAN_OLD_DAYS days ($(mm_human "$b"))?" || return 0
  if [[ "$MM_DRY_RUN" == 1 ]]; then
    _clean_track "$b" "$n"; mm_ok "$label" "$(_clean_detail "$n" files "$b")$note"; return 0
  fi
  mm_run "remove $n $noun" mm_sudo bash -c "$_CLEAN_ROOT_RM" _ "$min" "${pairs[@]}"
  while IFS= read -r -d '' p; do left[$p]=1; done < <(mm_sudo find "${paths[@]}" -maxdepth 0 -printf '%p\0' 2>/dev/null)
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    id=${pairs[i]} p=${pairs[i + 1]}
    [[ -z "${left[$p]+x}" ]] || continue
    removed=$((removed + 1)) gone[$id]=$(( ${gone[$id]:-0} + 1 ))
    mm_log remove "$p" "${isize[$id]}"
  done
  for id in "${!gone[@]}"; do (( ${gone[$id]} >= ${nlink[$id]} )) && freed=$((freed + ${isize[$id]})); done
  _clean_track "$freed" "$removed"
  mm_ok "$label" "$(_clean_detail "$removed" files "$freed" $((n - removed)))$note"
}

# _clean_user_crash_reports — the user's own apport reports (~/.local/share/apport): entries with
# nothing written for 7+ days, removed permanently through mm_rm after a confirmation.
_clean_user_crash_reports() {
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/apport" min=$((_CLEAN_OLD_DAYS * 1440)) e b n=0 freed=0 kept=0 fail=0
  local -a old=()
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' e; do
    [[ -z "$(find "$e" -mmin "-$min" -print -quit 2>/dev/null)" ]] && old+=("$e")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if (( ${#old[@]} == 0 )); then mm_ok "Your crash reports" "nothing older than $_CLEAN_OLD_DAYS days"; return 0; fi
  b=$(mm_size "${old[@]}")
  mm_act "Your crash reports: ${#old[@]} older than $_CLEAN_OLD_DAYS days, $(mm_human "$b") (${dir/#$HOME/\~})"
  _clean_ask "Your crash reports" "Permanently delete ${#old[@]} crash reports older than $_CLEAN_OLD_DAYS days ($(mm_human "$b"))?" || return 0
  for e in "${old[@]}"; do
    mm_rm "$e" "$dir"
    case $? in
      0) n=$((n + 1)) freed=$((freed + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done
  mm_ok "Your crash reports" "$(_clean_detail "$n" reports "$freed" "$kept" "$fail")"
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
  local row name dir p any=0 jb
  local -a roots
  jb="$(mm_catalog_expand %CACHE%)/JetBrains/RemoteDev/dist"
  for row in "${_CLEAN_EDITOR_SERVERS[@]}"; do [[ -d "${row#*|}" ]] && any=1; done
  [[ -d "$jb" ]] && any=1
  (( any )) || return 0
  _clean_cat "Editor servers"
  for row in "${_CLEAN_EDITOR_SERVERS[@]}"; do
    name=${row%%|*} dir=${row#*|}
    [[ -d "$dir" ]] || continue
    roots=("$dir/cli/servers" "$dir/bin")
    for p in "$dir/bin"/*/; do [[ -d "$p" ]] && roots+=("${p%/}"); done
    _clean_editor_builds "$name server builds" "${roots[@]}"
    _clean_editor_leftovers "$name" "$dir"
  done
  [[ -d "$jb" ]] && _clean_jetbrains_backends "JetBrains remote backends" "$jb"
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

# _clean_editor_leftovers NAME DIR — inside a VS Code-family server: extension folders it marked
# obsolete (uninstalled, or replaced by an update; listed in extensions/.obsolete and removed by
# the server only when it next starts), the VSIX packages it keeps after installing, and session
# logs last written 7+ days ago. Obsolete extensions wait while the server runs: its extension
# host may still load files from them.
_clean_editor_leftovers() {
  local name="$1" dir="$2" ext="$2/extensions" e label="$1 obsolete extensions" n=0 b=0 kept=0 fail=0
  if [[ -f "$ext/.obsolete" && ! -L "$ext/.obsolete" ]]; then
    if mm_in_use "$dir"; then
      mm_skip "$label" "server running"
    else
      while IFS= read -r e; do
        [[ "$e" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && -d "$ext/$e" && ! -L "$ext/$e" ]] || continue
        mm_rm "$ext/$e" "$ext"
        case $? in
          0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
          1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
          *) fail=$((fail + 1)) ;;
        esac
      done < <(_clean_obsolete_names "$ext/.obsolete")
      (( n + kept + fail )) && mm_ok "$label" "$(_clean_detail "$n" extensions "$b" "$kept" "$fail")"
    fi
  fi
  [[ -d "$dir/data/CachedExtensionVSIXs" ]] && _clean_contents "$name cached extension packages" "$dir/data/CachedExtensionVSIXs"
  [[ -d "$dir/data/logs" ]] && _clean_cloud_log_dir "$name server logs" "$dir/data/logs"
  return 0
}

# _clean_obsolete_names FILE — the folder names VS Code's .obsolete JSON map sets to true.
_clean_obsolete_names() {
  grep -oE '"[^"\\]+"[[:space:]]*:[[:space:]]*true' -- "$1" 2>/dev/null | sed -E 's/^"([^"]+)".*/\1/'
}

# _clean_jetbrains_backends LABEL ROOT — JetBrains Gateway unpacks one IDE backend per version into
# ~/.cache/JetBrains/RemoteDev/dist (<hash>_<product>-<build>). Keep the newest (by mtime) of each
# product and any backend in use; remove the rest.
_clean_jetbrains_backends() {
  local label="$1" root="$2" name prod total=0 n=0 b=0 kept=0 fail=0
  local -A newest=()
  local -a entries=()
  mapfile -t entries < <(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@\t%f\n' 2>/dev/null |
    sort -rn | cut -f2-)
  for name in "${entries[@]}"; do
    total=$((total + 1))
    prod=${name#*_}; prod=${prod%%-[0-9]*}
    if [[ -z "${newest[$prod]+x}" ]]; then newest[$prod]=$name; continue; fi
    mm_rm "$root/$name" "$root"
    case $? in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done
  (( total )) || return 0
  if (( n + kept + fail == 0 )); then mm_ok "$label" "only the current build of each IDE installed"; return; fi
  mm_ok "$label" "$(_clean_detail "$n" "old backends" "$b" "$kept" "$fail"), newest of each IDE kept"
}

# ---------------------------------------------------------------- automation-browser temp files

# The one exception to "never sweep /tmp": Playwright, Puppeteer and Chromium create these
# top-level entries for each browser they launch and delete them when it closes; a script that
# crashes or is killed leaves them behind. Only these names, only your own entries, only once
# nothing in them changed for 2 hours, never while a process uses them; they are regenerated on
# the next launch, so they are deleted for good. Chromium names its temp files and folders
# "[.]org.chromium.Chromium.<random>", Chrome-branded builds (Google Chrome, Chrome for Testing)
# "[.]com.google.Chrome.<random>" (base/files/file_util_posix.cc, FormatTemporaryFileName).
_CLEAN_BROWSER_TMP_NAMES=(playwright_chromiumdev_profile-* puppeteer_dev_chrome_profile-*
  playwright-artifacts-* '.org.chromium.Chromium.*' 'org.chromium.Chromium.*'
  '.com.google.Chrome.*' 'com.google.Chrome.*')
_CLEAN_BROWSER_TMP_IDLE=7200

# _clean_browser_tmp_root — the folder swept: /tmp. The test suite points MM_TEST_TMP_ROOT into its
# sandbox; that is honored only inside bats' per-test directory, and an override that is set but
# unusable fails instead of falling back to the real /tmp.
_clean_browser_tmp_root() {
  [[ -n "${MM_TEST_TMP_ROOT+x}" ]] || { echo /tmp; return 0; }
  local root box
  root=$(realpath -e -- "$MM_TEST_TMP_ROOT" 2>/dev/null) || return 1
  box=$(realpath -e -- "${BATS_TEST_TMPDIR:-/nonexistent}" 2>/dev/null) || return 1
  [[ "$root" == "$box"/?* ]] || return 1
  echo "$root"
}

# _clean_browser_tmp ROOT — remove ROOT's automation-browser leftovers (above) via mm_rm, with ROOT
# as the allowed root. Idle time is the newest mtime or ctime of anything inside the entry. The
# section is shown only when ROOT holds such entries.
_clean_browser_tmp() {
  local root="$1" label="Browser temp files in $1" e now newest rc n=0 b=0 kept=0 fail=0 recent=0 note=""
  local -a names=() found=()
  [[ -d "$root" ]] || return 0
  for e in "${_CLEAN_BROWSER_TMP_NAMES[@]}"; do
    (( ${#names[@]} )) && names+=(-o)
    names+=(-name "$e")
  done
  mapfile -d '' -t found < <(find "$root" -mindepth 1 -maxdepth 1 -uid "$EUID" \( -type d -o -type f \) \
    \( "${names[@]}" \) -print0 2>/dev/null)
  (( ${#found[@]} )) || return 0
  _clean_cat "Automation browsers"
  now=$(date +%s)
  for e in "${found[@]}"; do
    newest=$(find "$e" -printf '%T@\n%C@\n' 2>/dev/null | awk '$1 > m { m = $1 } END { printf "%.0f\n", m }')
    if (( newest == 0 || now - newest < _CLEAN_BROWSER_TMP_IDLE )); then recent=$((recent + 1)); continue; fi
    rc=0; mm_rm "$e" "$root" || rc=$?
    case $rc in
      0) n=$((n + 1)) b=$((b + MM_LAST_BYTES)) ;;
      1) [[ "$MM_SKIP_REASON" != missing ]] && kept=$((kept + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done
  (( recent )) && note=", $recent used in the last 2 hours kept"
  if (( n + kept + fail == 0 )); then
    mm_ok "$label" "nothing idle for 2 hours${note}"
  else
    mm_ok "$label" "$(_clean_detail "$n" items "$b" "$kept" "$fail")${note}"
  fi
  _clean_cat_end
}

_clean_browsers() {
  local root
  if root=$(_clean_browser_tmp_root); then _clean_browser_tmp "$root"; return; fi
  mm_section "Automation browsers"
  mm_skip "Browser temp files" "MM_TEST_TMP_ROOT is outside the test sandbox"
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

# Shared temp folders are never swept (automation-browser leftovers aside, see above): other
# programs keep runtime state there (sockets, locks, the working files of running builds and
# agents), and the OS ages them with systemd-tmpfiles. They are reported with their size and that
# policy. Directories in tmpfiles.d precedence order.
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
  _clean_agent_logs
  [[ -n "$sessions" ]] && _clean_sessions "$sessions" "$from"
  _clean_browsers
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
