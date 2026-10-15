# shellcheck shell=bash
# marmot catalog: the developer caches, tool builds and big data stores `mm clean` knows about,
# for any Ubuntu/Debian machine. Data first, then its parser. Rows whose path does not exist on a
# machine are simply ignored, so the table can name every common tool.
#
# Row fields, separated by '|' (blank lines and lines starting with # are ignored):
#   kind | label | path | busy | spec | hint
#
#   kind   cache      regenerable cache dir: its contents are removed permanently (the dir stays),
#                     except entries used in the last 7 days (see cmd/clean.sh _clean_contents).
#                     Skipped while any busy process runs. spec (optional) is either
#                     tool:CMD (while CMD is installed the row is skipped and cmd/clean.sh runs
#                     CMD's own clean instead) or space-separated name globs for the entries
#                     directly inside: GLOB keeps only matching entries as candidates, !GLOB
#                     leaves matching ones alone (e.g. "*.log", "!snapshot*").
#          revisions  downloaded browser/tool builds: only the newest build per product is needed.
#                     spec = DEPTH:REGEX[:refs=playwright][:files]. Entries DEPTH levels below
#                     path are matched (relative path) against REGEX; group 1 is the product,
#                     group 2 its version (compared with sort -V). Directories only, unless
#                     :files (tools that keep one file per version). The newest per product,
#                     anything in use, and (refs=playwright) every revision an installed
#                     playwright-core still lists through ms-playwright/.links are kept; older
#                     builds are removed.
#          report     never touched: shown with its size in "Kept for you to review", plus hint.
#                     spec = count: also count the entries directly inside (installed versions).
#   label  what the user sees.
#   path   ~ is $HOME; %CACHE% is $XDG_CACHE_HOME and %DATA% is $XDG_DATA_HOME (each only when
#          it is an absolute path inside $HOME, else ~/.cache and ~/.local/share); $VAR/... uses an
#          environment variable (row ignored when VAR is unset or not absolute). In built-in rows
#          a * in the path makes one row per matching directory (label gets the matched name).
#          Several rows may name the same folder ($VAR and its default): it is handled once.
#   busy   space-separated process names (exact name, or a script named so: see mm_proc_running);
#          f:REGEX matches against full command lines (e.g. Java daemons).
#   hint   for report rows: how to reclaim the space with the owning tool.
#
# Deliberately NOT listed as caches (they are what tools restore from, or hold user data):
#   ~/.m2/repository, ~/.nuget/packages, ~/.ivy2   dependency stores builds resolve from
#   ~/.sbt, ~/.pub-cache, the Go module cache       (these are reported instead)
#   (GOMODCACHE, ~/go/pkg/mod)
#   ~/.cargo/registry/src, ~/.cargo/bin, ~/.rustup  extracted crate sources rust-analyzer reads,
#                                                   installed binaries and toolchains
#   ~/.gradle/caches/modules-2, ~/.gradle/wrapper   dependency store and Gradle distributions
#   %CACHE%/deno/location_data                      web storage of Deno programs
#   %CACHE%/pypoetry/virtualenvs                    live project virtualenvs
#   %CACHE%/huggingface, ~/.ollama, %CACHE%/torch   downloaded models (reported instead)
#   %CACHE%/wandb, %DATA%/wandb                     W&B artifacts and uploads in flight (reported)
#   ~/.terraform.d/plugin-cache                     initialized projects symlink their providers
#                                                   into it (reported instead)
#   ~/.kube/cache/oidc-login and other plugin       login token caches next to kubectl's
#   caches                                          discovery/http caches
#   every coding agent's state (lib/agents.sh)      settings, credentials, session transcripts
# npm, pnpm, yarn, bun and uv (when installed) are cleaned through their own tools by
# cmd/clean.sh, like the mise, conda and Homebrew caches and (opt-in) the nix store.
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
cache|npm logs|~/.npm/_logs|npm npm-cli.js npx npx-cli.js||
cache|npm prebuilt binaries|~/.npm/_prebuilds|npm npm-cli.js npx npx-cli.js||
cache|opencode cache|%CACHE%/opencode|opencode|!snapshot*|
# ---- Python
cache|uv cache|%CACHE%/uv|uv uvx|tool:uv|
cache|pip cache|%CACHE%/pip|pip pip3||
cache|pipenv cache|%CACHE%/pipenv|pipenv||
cache|Poetry package cache|%CACHE%/pypoetry/cache|poetry||
cache|Poetry artifacts|%CACHE%/pypoetry/artifacts|poetry||
cache|pre-commit environments|%CACHE%/pre-commit|pre-commit||
cache|pyenv downloads|$PYENV_ROOT/cache|pyenv python-build||
cache|pyenv downloads|~/.pyenv/cache|pyenv python-build||
cache|Jupyter runtime files|%DATA%/jupyter/runtime|jupyter jupyter-lab jupyter-notebook jupyter-server f:ipykernel f:jupyter_server f:jupyterlab||
# ---- Ruby, PHP, Perl, Elixir, OCaml
cache|RubyGems spec cache|~/.gem/specs|gem bundle bundler||
cache|RubyGems spec cache|%CACHE%/gem/specs|gem bundle bundler||
cache|RubyGems downloads|~/.gem/ruby/*/cache|gem bundle bundler|*.gem|
cache|Bundler cache|~/.bundle/cache|bundle bundler||
cache|rbenv downloads|$RBENV_ROOT/cache|rbenv ruby-build||
cache|rbenv downloads|~/.rbenv/cache|rbenv ruby-build||
cache|Composer cache|$COMPOSER_CACHE_DIR|composer||
cache|Composer cache|%CACHE%/composer|composer||
cache|Composer cache|~/.composer/cache|composer||
cache|CPAN build folders|~/.cpan/build|cpan cpanp||
cache|Hex package downloads|$HEX_HOME/packages|mix f:/bin/mix||
cache|Hex package downloads|~/.hex/packages|mix f:/bin/mix||
cache|Hex package downloads|%CACHE%/hex/packages|mix f:/bin/mix||
cache|opam download cache|$OPAMROOT/download-cache|opam||
cache|opam download cache|~/.opam/download-cache|opam||
# ---- Go, Rust, JVM, others
cache|Go build cache|%CACHE%/go-build|go gopls||
cache|Cargo registry downloads|~/.cargo/registry/cache|cargo rustc rust-analyzer||
cache|rustup downloads|~/.rustup/downloads|rustup cargo||
cache|Gradle build cache|~/.gradle/caches/build-cache-1|gradle f:org\.gradle\.launcher\.daemon||
cache|Gradle daemon logs|~/.gradle/daemon/*|gradle f:org\.gradle\.launcher\.daemon|*.log|
cache|Gradle notifications|~/.gradle/notifications|gradle f:org\.gradle\.launcher\.daemon||
cache|Android SDK cache|~/.android/cache|sdkmanager avdmanager studio f:AndroidStudio f:org\.gradle\.launcher\.daemon||
cache|Android build cache|~/.android/build-cache|studio f:AndroidStudio f:org\.gradle\.launcher\.daemon||
cache|Bazel cache|%CACHE%/bazel|bazel bazelisk f:A-server\.jar||
cache|Zig cache|%CACHE%/zig|zig zls||
cache|GitHub CLI cache|%CACHE%/gh|gh||
cache|kubectl discovery cache|~/.kube/cache/discovery|kubectl k9s helm||
cache|kubectl HTTP cache|~/.kube/cache/http|kubectl k9s helm||
cache|oh-my-zsh cache|~/.oh-my-zsh/cache|||
# ---- downloaded browser and test-runner builds
revisions|Playwright browsers|%CACHE%/ms-playwright||1:^(.+)-([0-9]+)$:refs=playwright|
revisions|Puppeteer browsers|%CACHE%/puppeteer||2:^([^/]+)/[^/]*-([0-9][0-9.]*)$|
revisions|Cypress binaries|%CACHE%/Cypress|cypress Cypress|1:^()([0-9][0-9.]*)$|
revisions|Firebase emulators|$FIREBASE_EMULATORS_PATH|firebase|1:^(.+)-v?([0-9][0-9.]*)(\.[a-z]+)?$:files|
revisions|Firebase emulators|~/.cache/firebase/emulators|firebase|1:^(.+)-v?([0-9][0-9.]*)(\.[a-z]+)?$:files|
revisions|agent-browser Chrome builds|~/.agent-browser/browsers|agent-browser f:/agent-browser-linux|1:^(chrome)-([0-9][0-9.]*)$|
# ---- big stores: reported, never touched
report|Hugging Face models|%CACHE%/huggingface|||hf cache delete (or huggingface-cli delete-cache)
report|Ollama models|~/.ollama/models|||ollama list, then ollama rm <model>
report|Maven repository|~/.m2/repository|||restore target for Maven builds; prune with mvn dependency:purge-local-repository
report|NuGet packages|~/.nuget/packages|||dotnet nuget locals global-packages --clear
report|Go module cache|$GOMODCACHE|||restore target for Go builds (offline builds need it); go clean -modcache removes it all
report|Go module cache|$GOPATH/pkg/mod|||restore target for Go builds (offline builds need it); go clean -modcache removes it all
report|Go module cache|~/go/pkg/mod|||restore target for Go builds (offline builds need it); go clean -modcache removes it all
report|Gradle distributions|~/.gradle/wrapper/dists||count|remove versions no project uses
report|Rust toolchains|~/.rustup/toolchains||count|rustup toolchain list, then rustup toolchain uninstall <name>
report|Podman storage|%DATA%/containers|||podman system df, then podman system prune
report|Ivy cache|~/.ivy2|||resolve target for sbt and Ant builds; remove modules under ~/.ivy2/cache no project uses
report|sbt boot and launchers|~/.sbt|||remove versions under ~/.sbt/boot that no project uses
report|Dart/Flutter pub cache|$PUB_CACHE|||dart pub cache clean (or flutter pub cache clean); projects fetch again with pub get
report|Dart/Flutter pub cache|~/.pub-cache|||dart pub cache clean (or flutter pub cache clean); projects fetch again with pub get
report|PyTorch hub models|$TORCH_HOME|||downloaded model weights: remove the checkpoints under hub/ you no longer use
report|PyTorch hub models|%CACHE%/torch|||downloaded model weights: remove the checkpoints under hub/ you no longer use
report|W&B artifact cache|$WANDB_CACHE_DIR|||wandb artifact cache cleanup 1GB (keeps the most recently used 1GB)
report|W&B artifact cache|%CACHE%/wandb|||wandb artifact cache cleanup 1GB (keeps the most recently used 1GB)
report|W&B staged uploads|$WANDB_DATA_DIR|||files staged for upload; remove once your runs have synced (wandb sync)
report|W&B staged uploads|%DATA%/wandb|||files staged for upload; remove once your runs have synced (wandb sync)
report|Terraform plugin cache|$TF_PLUGIN_CACHE_DIR|||initialized projects link into it: remove old provider versions, then terraform init where needed
report|Terraform plugin cache|~/.terraform.d/plugin-cache|||initialized projects link into it: remove old provider versions, then terraform init where needed
report|fnm Node versions|$FNM_DIR/node-versions||count|fnm list, then fnm uninstall <version>
report|fnm Node versions|%DATA%/fnm/node-versions||count|fnm list, then fnm uninstall <version>
report|fnm Node versions|~/.fnm/node-versions||count|fnm list, then fnm uninstall <version>
report|nvm Node versions|$NVM_DIR/versions/node||count|nvm ls, then nvm uninstall <version>
report|nvm Node versions|~/.nvm/versions/node||count|nvm ls, then nvm uninstall <version>
report|Volta Node versions|$VOLTA_HOME/tools/image/node||count|volta list all, then remove unused versions
report|Volta Node versions|~/.volta/tools/image/node||count|volta list all, then remove unused versions
'

# Parsed rows, index-aligned.
MM_CAT_KIND=() MM_CAT_LABEL=() MM_CAT_PATH=() MM_CAT_BUSY=() MM_CAT_SPEC=() MM_CAT_HINT=()
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

# _mm_cat_add KIND LABEL PATH BUSY SPEC HINT
_mm_cat_add() {
  MM_CAT_KIND+=("$1") MM_CAT_LABEL+=("$2") MM_CAT_PATH+=("$3") MM_CAT_BUSY+=("$4")
  MM_CAT_SPEC+=("$5") MM_CAT_HINT+=("$6")
}

# _mm_cat_trim STRING — strip surrounding whitespace.
_mm_cat_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# _mm_cat_glob KIND LABEL PATTERN BUSY SPEC HINT — one built-in row per directory PATTERN matches;
# the label gets what each * matched ("RubyGems downloads (3.2.0)").
_mm_cat_glob() {
  local m tag i
  local -a segs=() ms=()
  IFS=/ read -r -a segs <<<"$3"
  while IFS= read -r m; do
    [[ -d "$m" ]] || continue
    IFS=/ read -r -a ms <<<"$m"
    tag=""
    for i in "${!segs[@]}"; do [[ "${segs[$i]}" == *'*'* ]] && tag+="${tag:+/}${ms[$i]}"; done
    _mm_cat_add "$1" "$2${tag:+ ($tag)}" "$m" "$4" "$5" "$6"
  done < <(compgen -G "$3" | LC_ALL=C sort)
}

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
      _mm_cat_add cache "$label" "$p" "$busy" "" ""
      continue
    fi
    p=$(mm_catalog_expand "$path") || continue
    if [[ "$p" == *'*'* ]]; then _mm_cat_glob "$kind" "$label" "$p" "$busy" "$spec" "$hint"; continue; fi
    _mm_cat_add "$kind" "$label" "$p" "$busy" "$spec" "$hint"
  done
}

# mm_catalog_load — fill MM_CAT_* from the built-in table, the user's catalog file, and every
# agent in lib/agents.sh that keeps one directory per installed version (kind "versions":
# path = versions dir, spec = active-version symlink).
mm_catalog_load() {
  MM_CAT_KIND=() MM_CAT_LABEL=() MM_CAT_PATH=() MM_CAT_BUSY=() MM_CAT_SPEC=() MM_CAT_HINT=()
  MM_CAT_REJECTED=()
  _mm_cat_parse builtin <<<"$MM_CATALOG_TABLE"
  local user="$MM_CONFIG_DIR/catalog" i
  [[ -f "$user" && -r "$user" ]] && _mm_cat_parse "${user/#$HOME/\~}" <"$user"
  for i in "${!MM_AGENT_NAME[@]}"; do
    [[ -n "${MM_AGENT_VERSIONS[$i]}" ]] || continue
    _mm_cat_add versions "${MM_AGENT_NAME[$i]}" "${MM_AGENT_VERSIONS[$i]}" "" "${MM_AGENT_ACTIVE[$i]}" ""
  done
}
