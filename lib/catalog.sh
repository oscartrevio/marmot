# shellcheck shell=bash
# marmot catalog: the developer caches, tool builds and big data stores `mm clean` knows about,
# for any Ubuntu/Debian machine. Data first, then its parser. Rows whose path does not exist on a
# machine are simply ignored, so the table can name every common tool.
#
# Row fields, separated by '|' (blank lines and lines starting with # are ignored):
#   kind | label | path | busy | spec | hint
#
#   kind   cache      regenerable cache dir: its contents are removed permanently (the dir stays).
#                     Skipped while any busy process runs.
#          revisions  downloaded browser/tool builds: only the newest build per product is needed.
#                     spec = DEPTH:REGEX[:refs=playwright]. Entries DEPTH levels below path are
#                     matched (relative path) against REGEX; group 1 is the product, group 2 its
#                     version (compared with sort -V). The newest per product, anything in use,
#                     and (refs=playwright) every revision an installed playwright-core still
#                     lists through ms-playwright/.links are kept; older builds are removed.
#          report     never touched: shown with its size in "Kept for you to review", plus hint.
#                     spec = count: also count the entries directly inside (installed versions).
#   label  what the user sees.
#   path   ~ is $HOME; %CACHE% is $XDG_CACHE_HOME and %DATA% is $XDG_DATA_HOME (each only when
#          it is an absolute path inside $HOME, else ~/.cache and ~/.local/share); $VAR/... uses an
#          environment variable (row ignored when VAR is unset or not absolute).
#   busy   space-separated process names (exact name, or a script named so: see mm_proc_running);
#          f:REGEX matches against full command lines (e.g. Java daemons).
#   hint   for report rows: how to reclaim the space with the owning tool.
#
# Deliberately NOT listed as caches (they are what tools restore from, or hold user data):
#   ~/.m2/repository, ~/.nuget/packages, ~/.ivy2   dependency stores builds resolve from
#   ~/.cargo/registry/src, ~/.cargo/bin, ~/.rustup  extracted crate sources rust-analyzer reads,
#                                                   installed binaries and toolchains
#   ~/.gradle/caches/modules-2, ~/.gradle/wrapper   dependency store and Gradle distributions
#   %CACHE%/deno/location_data                      web storage of Deno programs
#   %CACHE%/pypoetry/virtualenvs                    live project virtualenvs
#   %CACHE%/huggingface, ~/.ollama                  downloaded models (reported instead)
#   every coding agent's state (lib/agents.sh)      settings, credentials, session transcripts
# npm, pnpm, yarn and bun caches are cleaned through their own tools by cmd/clean.sh.
#
# Users can add rows to $MM_CONFIG_DIR/catalog in the same format: cache rows only, and only for
# directories inside $HOME (other rows are rejected with a warning).

MM_CATALOG_TABLE='
# ---- JavaScript / TypeScript
cache|npx package cache|~/.npm/_npx|npm npm-cli.js npx npx-cli.js||
cache|Corepack cache|%CACHE%/node/corepack|corepack pnpm yarn||
cache|TypeScript cache|%CACHE%/typescript|tsserver||
cache|node-gyp headers|%CACHE%/node-gyp|node-gyp npm||
cache|node-gyp headers (legacy)|~/.node-gyp|node-gyp npm||
cache|Prisma engines|%CACHE%/prisma|prisma||
cache|Electron downloads|%CACHE%/electron|electron-builder electron-forge||
cache|electron-builder cache|%CACHE%/electron-builder|electron-builder||
cache|Deno module cache|%CACHE%/deno/deps|deno||
cache|Deno compiled cache|%CACHE%/deno/gen|deno||
cache|Deno npm cache|%CACHE%/deno/npm|deno||
# ---- Python
cache|uv cache|%CACHE%/uv|uv uvx||
cache|pip cache|%CACHE%/pip|pip pip3||
cache|pipenv cache|%CACHE%/pipenv|pipenv||
cache|Poetry package cache|%CACHE%/pypoetry/cache|poetry||
cache|Poetry artifacts|%CACHE%/pypoetry/artifacts|poetry||
cache|pre-commit environments|%CACHE%/pre-commit|pre-commit||
# ---- Go, Rust, JVM, others
cache|Go build cache|%CACHE%/go-build|go gopls||
cache|Cargo registry downloads|~/.cargo/registry/cache|cargo rustc rust-analyzer||
cache|rustup downloads|~/.rustup/downloads|rustup cargo||
cache|Gradle build cache|~/.gradle/caches/build-cache-1|gradle f:org\.gradle\.launcher\.daemon||
cache|Bazel cache|%CACHE%/bazel|bazel bazelisk f:A-server\.jar||
cache|Zig cache|%CACHE%/zig|zig zls||
cache|GitHub CLI cache|%CACHE%/gh|gh||
# ---- downloaded browser and test-runner builds
revisions|Playwright browsers|%CACHE%/ms-playwright||1:^(.+)-([0-9]+)$:refs=playwright|
revisions|Puppeteer browsers|%CACHE%/puppeteer||2:^([^/]+)/[^/]*-([0-9][0-9.]*)$|
revisions|Cypress binaries|%CACHE%/Cypress|cypress Cypress|1:^()([0-9][0-9.]*)$|
# ---- big stores: reported, never touched
report|Hugging Face models|%CACHE%/huggingface|||hf cache delete (or huggingface-cli delete-cache)
report|Ollama models|~/.ollama/models|||ollama list, then ollama rm <model>
report|Maven repository|~/.m2/repository|||restore target for Maven builds; prune with mvn dependency:purge-local-repository
report|NuGet packages|~/.nuget/packages|||dotnet nuget locals global-packages --clear
report|Gradle distributions|~/.gradle/wrapper/dists||count|remove versions no project uses
report|Rust toolchains|~/.rustup/toolchains||count|rustup toolchain list, then rustup toolchain uninstall <name>
report|Podman storage|%DATA%/containers|||podman system df, then podman system prune
report|fnm Node versions|$FNM_DIR/node-versions||count|fnm list, then fnm uninstall <version>
report|fnm Node versions|%DATA%/fnm/node-versions||count|fnm list, then fnm uninstall <version>
report|fnm Node versions|~/.fnm/node-versions||count|fnm list, then fnm uninstall <version>
report|nvm Node versions|$NVM_DIR/versions/node||count|nvm ls, then nvm uninstall <version>
report|nvm Node versions|~/.nvm/versions/node||count|nvm ls, then nvm uninstall <version>
report|Volta Node versions|$VOLTA_HOME/tools/image/node||count|volta list all, then remove unused versions
report|Volta Node versions|~/.volta/tools/image/node||count|volta list all, then remove unused versions
'

# Parsed rows, index-aligned. ORIGIN is "builtin", "user:<line>" or "agent".
MM_CAT_KIND=() MM_CAT_LABEL=() MM_CAT_PATH=() MM_CAT_BUSY=() MM_CAT_SPEC=() MM_CAT_HINT=() MM_CAT_ORIGIN=()
MM_CAT_REJECTED=()   # "<file>:<line>: <reason>" for user rows that were not accepted

# _mm_cat_home_dir VAR DEFAULT — $VAR when it is an absolute path strictly inside $HOME, else DEFAULT.
_mm_cat_home_dir() {
  local v="${!1:-}"
  v="${v%/}"
  if [[ "$v" == "$HOME"/?* && "/$v/" != */../* ]]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# mm_catalog_expand PATH — expand ~, %CACHE%, %DATA% and $VAR; fails when $VAR is unusable.
mm_catalog_expand() {
  local p="$1" var val
  case "$p" in
    "~") p="$HOME" ;;
    \~/*) p="$HOME/${p#\~/}" ;;
    %CACHE%*) p="$(_mm_cat_home_dir XDG_CACHE_HOME "$HOME/.cache")${p#%CACHE%}" ;;
    %DATA%*) p="$(_mm_cat_home_dir XDG_DATA_HOME "$HOME/.local/share")${p#%DATA%}" ;;
    \$*)
      var=${p#\$}; var=${var%%/*}
      [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
      val="${!var:-}"; val="${val%/}"
      [[ "$val" == /?* ]] || return 1
      p="$val${p#\$"$var"}"
      ;;
  esac
  [[ "$p" == /* ]] || return 1
  printf '%s' "${p%/}"
}

# _mm_cat_add KIND LABEL PATH BUSY SPEC HINT ORIGIN
_mm_cat_add() {
  MM_CAT_KIND+=("$1") MM_CAT_LABEL+=("$2") MM_CAT_PATH+=("$3") MM_CAT_BUSY+=("$4")
  MM_CAT_SPEC+=("$5") MM_CAT_HINT+=("$6") MM_CAT_ORIGIN+=("$7")
}

# _mm_cat_trim STRING — strip surrounding whitespace.
_mm_cat_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# _mm_cat_parse ORIGIN — read rows from stdin and append them. User rows are validated.
_mm_cat_parse() {
  local origin="$1" line n=0 kind label path busy spec hint p real
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=$(_mm_cat_trim "$line")
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS='|' read -r kind label path busy spec hint <<<"$line"
    kind=$(_mm_cat_trim "$kind") label=$(_mm_cat_trim "$label") path=$(_mm_cat_trim "$path")
    busy=$(_mm_cat_trim "$busy") spec=$(_mm_cat_trim "$spec") hint=$(_mm_cat_trim "$hint")
    if [[ "$origin" != builtin ]]; then
      local where="$origin:$n"
      if [[ "$kind" != cache ]]; then MM_CAT_REJECTED+=("$where: only cache rows can be added (got '$kind')"); continue; fi
      [[ -n "$label" ]] || label=$path
      if ! p=$(mm_catalog_expand "$path"); then MM_CAT_REJECTED+=("$where: path '$path' does not expand"); continue; fi
      if [[ "/$p/" == */../* || "/$p/" == */./* || "$p" == *[[:cntrl:]]* ]]; then
        MM_CAT_REJECTED+=("$where: path '$path' has . or .. segments"); continue
      fi
      # Inside $HOME both as written and once symlinks are resolved; never $HOME itself.
      real=$(realpath -m -- "$p" 2>/dev/null)
      if [[ "$p" != "$HOME"/?* || "$real" != "$HOME"/?* ]]; then
        MM_CAT_REJECTED+=("$where: '$path' is not inside your home folder"); continue
      fi
      _mm_cat_add cache "$label" "$p" "$busy" "" "" "$origin:$n"
      continue
    fi
    p=$(mm_catalog_expand "$path") || continue
    _mm_cat_add "$kind" "$label" "$p" "$busy" "$spec" "$hint" builtin
  done
}

# mm_catalog_load — fill MM_CAT_* from the built-in table, the user's catalog file, and every
# agent in lib/agents.sh that keeps one directory per installed version (kind "versions":
# path = versions dir, spec = active-version symlink).
mm_catalog_load() {
  MM_CAT_KIND=() MM_CAT_LABEL=() MM_CAT_PATH=() MM_CAT_BUSY=() MM_CAT_SPEC=() MM_CAT_HINT=() MM_CAT_ORIGIN=()
  MM_CAT_REJECTED=()
  _mm_cat_parse builtin <<<"$MM_CATALOG_TABLE"
  local user="$MM_CONFIG_DIR/catalog" i
  [[ -f "$user" && -r "$user" ]] && _mm_cat_parse "${user/#$HOME/\~}" <"$user"
  for i in "${!MM_AGENT_NAME[@]}"; do
    [[ -n "${MM_AGENT_VERSIONS[$i]}" ]] || continue
    _mm_cat_add versions "${MM_AGENT_NAME[$i]}" "${MM_AGENT_VERSIONS[$i]}" "" "${MM_AGENT_ACTIVE[$i]}" "" agent
  done
}
