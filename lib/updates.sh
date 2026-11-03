# shellcheck shell=bash
# How current the code on this machine is. Coding agents run with your credentials and execute
# what they read; their CLIs, the packages around them and the runtimes under them ship fixes,
# often for published exploits, every week, and a running session keeps the code it started with
# until it is restarted. Read-only facts shared by `mm status`, `mm optimize` and `mm agents`;
# nothing here contacts the network or changes anything:
#   - security updates apt knows about but has not installed, and how old apt's package lists
#     are (lists that old cannot know this week's fixes);
#   - what is installed outside apt and snap (mm_installs): agent CLIs and harnesses, global npm,
#     bun and pnpm packages, pipx and uv tools, cargo and go installs, Homebrew kegs, loose
#     binaries, and node and python runtimes, each with when it was installed and the command
#     that updates it;
#   - runtimes past their upstream end of life (no more security fixes);
#   - agent processes still running code an update replaced since they started.
# Age is all marmot can tell offline: "installed 40 days ago" says nothing about whether a newer
# release exists, so marmot never calls a package outdated, only old.

MM_TOOL_OLD_DAYS=30       # an agent CLI installed longer ago than this is reported as old
MM_APT_LISTS_OLD_DAYS=7   # package lists not refreshed for longer than this are reported
MM_FS=$'\x1f'            # field separator of mm_installs lines (the ASCII unit separator)

# Upstream end of life of runtime release lines (dates past are facts that do not change; a line
# missing here is not judged). nodejs.org/about/previous-releases, devguide.python.org/versions.
# Lines older than the oldest listed are past it too. A runtime apt installed is the
# distribution's, which patches it on its own schedule: never judged.
declare -gA MM_EOL_NODE=([14]=2023-04-30 [15]=2021-06-01 [16]=2023-09-11 [17]=2022-06-01 [18]=2025-04-30
  [19]=2023-06-01 [20]=2026-04-30 [21]=2024-06-01 [22]=2027-04-30 [23]=2025-06-01 [24]=2028-04-30
  [25]=2026-06-01)
declare -gA MM_EOL_PYTHON=([3.6]=2021-12-23 [3.7]=2023-06-27 [3.8]=2024-10-07 [3.9]=2025-10-31
  [3.10]=2026-10-31 [3.11]=2027-10-31 [3.12]=2028-10-31 [3.13]=2029-10-31 [3.14]=2030-10-31)

# _mm_test_path VAR DEFAULT — REPLY: the value of VAR when the test suite set it and every
# colon-separated entry lies inside its sandbox (BATS_TEST_TMPDIR), else DEFAULT. Tests point the
# apt folder, PATH's folders, /usr/local and the Homebrew prefix into the sandbox this way
# (MM_TEST_APT_DIR, MM_TEST_TOOL_PATH, MM_TEST_USR_LOCAL, MM_TEST_BREW_PREFIX); outside the
# suite the override does nothing.
_mm_test_path() {
  local v=${!1:-} box p
  REPLY=$2
  [[ -n "$v" && -n "${BATS_TEST_TMPDIR:-}" ]] || return 0
  box=$(realpath -e -- "$BATS_TEST_TMPDIR" 2>/dev/null) || return 0
  local -a parts=()
  IFS=: read -r -a parts <<<"$v"
  for p in "${parts[@]}"; do
    p=$(realpath -m -- "$p" 2>/dev/null)
    [[ "$p" == "$box"/* ]] || return 0
  done
  REPLY=$v
}

# mm_apt_lists_at — REPLY: when apt last refreshed its package lists (epoch), the newest file in
# its lists folder or its update-success stamp. apt dates each list by the server's
# Last-Modified, and the security archives publish several times a day, so a fresh refresh shows.
# Fails when no list was ever downloaded (container images often delete them): nothing is claimed.
mm_apt_lists_at() {
  local dir
  _mm_test_path MM_TEST_APT_DIR /var/lib/apt
  dir=$REPLY
  REPLY=$({
    find "$dir/lists" -maxdepth 1 -type f -name '*_*' -printf '%T@\n'
    find "$dir/periodic/update-success-stamp" -maxdepth 0 -type f -printf '%T@\n'
  } 2>/dev/null | awk '{ t = int($1) } t > m { m = t } END { if (m > 0) printf "%.0f\n", m }')
  [[ -n "$REPLY" ]]
}

# _mm_ctime PATH — REPLY: when PATH landed on disk (its ctime, epoch). Unlike mtime, which npm
# sets to 1985 and tar to the archive's dates, it cannot be set back.
_mm_ctime() { REPLY=$(stat -c %Z -- "$1" 2>/dev/null) && [[ "$REPLY" =~ ^[0-9]+$ ]]; }

# _mm_json_str FILE KEY — REPLY: the first "KEY": "value" string in FILE (package.json's version,
# pipx_metadata.json's package_version); empty when there is none.
_mm_json_str() {
  REPLY=$(grep -o -m1 "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" -- "$1" 2>/dev/null | head -1)
  REPLY=${REPLY%\"} REPLY=${REPLY##*\"}
}

# _mm_dist_version DIR NAME — REPLY: the version of python distribution NAME installed in the
# environment DIR (its NAME-VERSION.dist-info folder); empty when there is none.
_mm_dist_version() {
  local d base n=${2//-/_}
  REPLY=""
  for d in "$1"/lib/python*/site-packages/*.dist-info; do
    [[ -d "$d" ]] || continue
    d=${d##*/} d=${d%.dist-info} base=${d%%-*}
    [[ "${base,,}" == "${n,,}" ]] && { REPLY=${d#*-}; return 0; }
  done
  return 0
}

# _mm_uv_dir — REPLY: where uv keeps its tools.
_mm_uv_dir() { _mm_test_path MM_TEST_UV_TOOL_DIR "${UV_TOOL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"; }

# mm_install_of FILE [IDX] — the install FILE (a resolved path) belongs to, for agent IDX of
# lib/agents.sh when given. Sets MM_INST_HOW (native: an entry of the agent's versions dir; npm,
# bun, pnpm: a global package; package: a node package no global manager owns; pipx, uv, brew;
# binary: a lone executable), MM_INST_VERSION (when it is written down), MM_INST_AT (when it was
# installed: the ctime of its version entry, package.json, pipx or uv receipt, Cellar folder or
# binary), MM_INST_ROOT (that entry, package or environment folder, or the binary) and
# MM_INST_UPDATE (the command that updates it; empty when marmot knows none). Fails for files apt
# or snap own (they update with the system) and for what it cannot date, such as a launcher
# script.
mm_install_of() {
  local f=$1 i=${2:-} v rel name root magic uvdir own=""
  MM_INST_HOW="" MM_INST_VERSION="" MM_INST_AT="" MM_INST_UPDATE="" MM_INST_ROOT=""
  [[ -n "$i" ]] && own=${MM_AGENT_UPDATE[i]:-}
  case "$f" in
    /usr/local/*) ;;
    /usr/* | /bin/* | /sbin/* | /lib*/* | /snap/*) return 1 ;;
  esac
  if [[ -n "$i" && -n "${MM_AGENT_VERSIONS[i]:-}" ]] && v=$(realpath -e -- "${MM_AGENT_VERSIONS[i]}" 2>/dev/null) &&
    [[ "$f" == "$v"/?* ]]; then
    rel=${f#"$v"/}
    MM_INST_ROOT=$v/${rel%%/*}
    _mm_ctime "$MM_INST_ROOT" || return 1
    MM_INST_HOW=native MM_INST_VERSION=${rel%%/*} MM_INST_UPDATE=$own MM_INST_AT=$REPLY
    return 0
  fi
  _mm_uv_dir
  uvdir=$REPLY
  case "$f" in
    */node_modules/*)
      rel=${f##*/node_modules/} name=${rel%%/*}
      [[ "$name" == @* ]] && { rel=${rel#*/}; name+=/${rel%%/*}; }
      root=${f%/node_modules/*}/node_modules/$name
      _mm_ctime "$root/package.json" || return 1
      MM_INST_AT=$REPLY MM_INST_ROOT=$root
      _mm_json_str "$root/package.json" version
      MM_INST_VERSION=$REPLY
      case "$root" in
        "${BUN_INSTALL:-$HOME/.bun}"/install/global/node_modules/*) MM_INST_HOW=bun MM_INST_UPDATE="bun add -g $name@latest" ;;
        */pnpm/global/*/node_modules/*) MM_INST_HOW=pnpm MM_INST_UPDATE="pnpm add -g $name@latest" ;;
        */lib/node_modules/"$name") MM_INST_HOW=npm MM_INST_UPDATE="npm install -g $name@latest" ;;
        *) MM_INST_HOW=package MM_INST_UPDATE=$own ;;
      esac
      return 0 ;;
    */pipx/venvs/?*)
      rel=${f#*/pipx/venvs/} name=${rel%%/*} root=${f%%/pipx/venvs/*}/pipx/venvs/$name
      _mm_ctime "$root/pipx_metadata.json" || return 1
      MM_INST_AT=$REPLY MM_INST_ROOT=$root
      _mm_json_str "$root/pipx_metadata.json" package_version
      MM_INST_HOW=pipx MM_INST_VERSION=$REPLY MM_INST_UPDATE="pipx upgrade $name"
      return 0 ;;
    "$uvdir"/?*)
      rel=${f#"$uvdir"/} name=${rel%%/*} root=$uvdir/${rel%%/*}
      _mm_ctime "$root/uv-receipt.toml" || return 1
      MM_INST_AT=$REPLY MM_INST_ROOT=$root
      _mm_dist_version "$root" "$name"
      MM_INST_HOW=uv MM_INST_VERSION=$REPLY MM_INST_UPDATE="uv tool upgrade $name"
      return 0 ;;
    */Cellar/?*/?*/*)
      rel=${f##*/Cellar/} name=${rel%%/*} rel=${rel#*/}
      root=${f%/Cellar/*}/Cellar/$name/${rel%%/*}
      _mm_ctime "$root" || return 1
      MM_INST_HOW=brew MM_INST_AT=$REPLY MM_INST_ROOT=$root MM_INST_VERSION=${rel%%/*} MM_INST_UPDATE="brew upgrade $name"
      return 0 ;;
  esac
  # A lone executable (go install, a vendor's install script): dated by the binary itself. A
  # script launcher says nothing about the code it starts.
  [[ -f "$f" ]] || return 1
  LC_ALL=C read -r -n 4 magic 2>/dev/null <"$f"
  [[ "$magic" == $'\x7f'ELF ]] || return 1
  _mm_ctime "$f" || return 1
  MM_INST_HOW=binary MM_INST_AT=$REPLY MM_INST_ROOT=$f MM_INST_UPDATE=$own
  # Installers that keep one folder per release name it after the version
  # (~/.t3/runtime/versions/0.1.5/t3).
  [[ "$f" =~ /(versions|releases)/v?([0-9][^/]*)/ ]] && MM_INST_VERSION=${BASH_REMATCH[2]}
  return 0
}

# _mm_path_dirs — MM_PATH_DIRS: the folders programs are looked up in, PATH's order.
_mm_path_dirs() {
  _mm_test_path MM_TEST_TOOL_PATH "$PATH"
  MM_PATH_DIRS=()
  IFS=: read -r -a MM_PATH_DIRS <<<"$REPLY"
}

# _mm_which NAME — REPLY: the first executable NAME in MM_PATH_DIRS; fails when there is none.
_mm_which() {
  local d
  for d in "${MM_PATH_DIRS[@]}"; do
    [[ -n "$d" && -f "$d/$1" && -x "$d/$1" ]] && { REPLY=$d/$1; return 0; }
  done
  return 1
}

# _mm_runtime_eol KIND VERSION — REPLY: the end-of-life date of VERSION's release line when it is
# past (YYYY-MM-DD, or "before DATE" for a line older than the table); fails otherwise.
_mm_runtime_eol() {
  local line today oldest k major minor
  if [[ "$1" == python ]]; then local -n tbl=MM_EOL_PYTHON; else local -n tbl=MM_EOL_NODE; fi
  IFS=. read -r major minor _ <<<"$2"
  line=$major
  [[ "$1" == python ]] && line=$major.$minor
  printf -v today '%(%Y-%m-%d)T' "$(date +%s)"
  REPLY=${tbl[$line]:-}
  if [[ -z "$REPLY" ]]; then
    oldest=""
    for k in "${!tbl[@]}"; do
      [[ -z "$oldest" || "$(printf '%s\n%s\n' "$k" "$oldest" | sort -V | head -1)" == "$k" ]] && oldest=$k
    done
    [[ "$(printf '%s\n%s\n' "$line" "$oldest" | sort -V | head -1)" == "$line" && "$line" != "$oldest" ]] || return 1
    REPLY="before ${tbl[$oldest]}"
    return 0
  fi
  [[ ! "$REPLY" > "$today" ]]
}

# _mm_runtime NAME KIND — the runtime NAME (node, python3) first on PATH, when a version manager
# (nvm, fnm, volta, asdf, mise, pyenv, uv, conda, ...) installed it: a "runtime" line of
# mm_installs, its version read from its folder, its end of life when that is past.
_mm_runtime() {
  local real ver how eol=""
  _mm_which "$1" || return 0
  real=$(realpath -e -- "$REPLY" 2>/dev/null) || return 0
  case "$real" in /usr/local/*) ;; /usr/* | /bin/* | /snap/*) return 0 ;; esac
  [[ "$real" =~ [/-]v?([0-9]+\.[0-9]+(\.[0-9]+)?)[/-] ]] || return 0
  ver=${BASH_REMATCH[1]}
  case "$real" in
    */.nvm/*) how=nvm ;; */fnm/* | */.fnm/*) how=fnm ;; */.volta/*) how=volta ;;
    */.asdf/*) how=asdf ;; */mise/*) how=mise ;; */.pyenv/*) how=pyenv ;; */uv/python/*) how=uv ;;
    */conda/* | */miniconda*/* | */anaconda*/* | */miniforge*/*) how=conda ;; *) how=manual ;;
  esac
  _mm_runtime_eol "$2" "$ver" && eol=$REPLY
  _mm_ctime "$real" || return 0
  printf 'runtime\x1f%s\x1f%s\x1f%s\x1f\x1f%s\x1f\x1f%s\x1f%s\n' "$2" "$ver" "$REPLY" "$how" "$eol" "$real"
}

# _mm_go_bins FILE... — "path<TAB>module version" for go-built FILEs, from `go version -m` (reads
# each binary's build info; offline).
_mm_go_bins() {
  command -v go >/dev/null || return 0
  timeout 5 go version -m "$@" 2>/dev/null | awk '
    /^[^\t].*: go[0-9]/ { sub(/: go[0-9].*$/, ""); file = $0; next }
    $1 == "path" { p[file] = $2 }
    $1 == "mod" { v[file] = $3 }
    END { for (f in p) printf "%s\t%s\t%s\n", f, p[f], v[f] }'
}

# mm_installs — everything installed outside apt and snap that marmot can date, one line each,
# its fields separated by MM_FS (empty fields stay in place, which tabs would not under read):
#   kind name version installed update how agent eol path
# kind is agent (a CLI of lib/agents.sh; agent is its row), package (a global package, tool or
# loose binary) or runtime (node, python; eol is the past end-of-life date of its line). An
# install reached twice (a launcher and its package) is listed once, agents first. Order: agents,
# global node packages, pipx, uv, cargo, go, Homebrew, loose binaries in ~/.local/bin, ~/bin and
# /usr/local/bin, runtimes.
mm_installs() {
  local i name d f real p pfx line ver src bins n
  local -A seen=() found=()
  local -a cands=() roots=() gofiles=()
  _mm_path_dirs

  # _emit KIND NAME AGENT PATH — the MM_INST_* of the last mm_install_of, once per root.
  _emit() {
    [[ -z "${seen[$MM_INST_ROOT]:-}" ]] || return 0
    seen[$MM_INST_ROOT]=1
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f\x1f%s\n' "$1" "$2" "$MM_INST_VERSION" "$MM_INST_AT" \
      "$MM_INST_UPDATE" "$MM_INST_HOW" "$3" "$4"
  }

  for i in "${!MM_AGENT_NAME[@]}"; do
    cands=()
    for name in ${MM_AGENT_PROCS[i]}; do _mm_which "$name" && cands+=("$name"$'\t'"$REPLY"); done
    [[ -n "${MM_AGENT_ACTIVE[i]:-}" ]] && cands+=("${MM_AGENT_ACTIVE[i]##*/}"$'\t'"${MM_AGENT_ACTIVE[i]}")
    for f in "${cands[@]}"; do
      name=${f%%$'\t'*} f=${f#*$'\t'}
      real=$(realpath -e -- "$f" 2>/dev/null) || continue
      mm_install_of "$real" "$i" && _emit agent "$name" "$i" "$real" && found[$i]=1
    done
  done
  _mm_installs_running


  # Global node packages: the npm prefix of every PATH folder (nvm, fnm, volta, ~/.npm-global,
  # /usr/local), bun's and pnpm's global folders.
  for d in "${MM_PATH_DIRS[@]}"; do [[ "$d" == */bin ]] && roots+=("${d%/bin}/lib/node_modules"); done
  roots+=("${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules")
  roots+=("${PNPM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}"/global/*/node_modules)
  for d in "${roots[@]}"; do
    d=$(realpath -e -- "$d" 2>/dev/null) || continue
    [[ -z "${seen[dir:$d]:-}" ]] || continue
    seen[dir:$d]=1
    # bun and pnpm keep every dependency flat in their global node_modules: what you installed is
    # what their global package.json depends on. npm's global node_modules holds only those.
    local -a pkgs=()
    if [[ -f "${d%/node_modules}/package.json" && "$d" != */lib/node_modules ]]; then
      mapfile -t pkgs < <(awk '/"dependencies"[[:space:]]*:/ { d = 1; next } d && /}/ { exit }
        d && match($0, /"[^"]+"[[:space:]]*:/) { k = substr($0, RSTART + 1, RLENGTH - 1); sub(/"[[:space:]]*:$/, "", k); print k }' \
        "${d%/node_modules}/package.json" 2>/dev/null)
      pkgs=("${pkgs[@]/#/$d/}")
    else
      pkgs=("$d"/* "$d"/@*/*)
    fi
    for p in "${pkgs[@]}"; do
      # A linked package (npm link) is someone's checkout, not an install.
      [[ -f "$p/package.json" && ! -L "$p" ]] || continue
      name=${p#"$d"/}
      [[ "$name" == npm || "$name" == corepack || "$name" == .* ]] && continue
      mm_install_of "$p/package.json" && _emit package "$name" "" "$p"
    done
  done

  for d in "${PIPX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pipx}/venvs" "$HOME/.local/pipx/venvs"; do
    for p in "$d"/*/pipx_metadata.json; do
      [[ -f "$p" ]] || continue
      real=$(realpath -e -- "$p" 2>/dev/null) || continue
      f=${real%/*}
      mm_install_of "$real" && _emit package "${f##*/}" "" "$f"
    done
  done
  _mm_uv_dir
  for p in "$REPLY"/*/uv-receipt.toml; do
    [[ -f "$p" ]] && mm_install_of "$p" && _emit package "$(basename -- "${p%/*}")" "" "${p%/*}"
  done

  # cargo install: .crates.toml names each crate, its version and source, and its binaries.
  pfx=${CARGO_HOME:-$HOME/.cargo}
  if [[ -f "$pfx/.crates.toml" ]]; then
    while IFS=$'\t' read -r name ver src bins; do
      for f in $bins; do
        _mm_ctime "$pfx/bin/$f" || continue
        [[ -z "${seen[$pfx/bin/$f]:-}" ]] || continue 2
        MM_INST_HOW=cargo MM_INST_VERSION=$ver MM_INST_AT=$REPLY MM_INST_ROOT=$pfx/bin/$f MM_INST_UPDATE=""
        [[ "$src" == registry* ]] && MM_INST_UPDATE="cargo install $name"
        _emit package "$name" "" "$pfx/bin/$f"
        break
      done
    done < <(awk -F'"' '/^"/ { split($2, a, " "); b = ""
        for (i = 4; i <= NF; i += 2) b = b " " $i
        src = a[3]; gsub(/[()]/, "", src); printf "%s\t%s\t%s\t%s\n", a[1], a[2], src, b }' "$pfx/.crates.toml" 2>/dev/null)
  fi

  # go install: the binaries in GOBIN, named by their module (go version -m).
  d=${GOBIN:-${GOPATH:-$HOME/go}/bin}
  for f in "$d"/*; do
    [[ -f "$f" && -x "$f" && -z "${seen[$f]:-}" ]] && gofiles+=("$f")
  done
  if ((${#gofiles[@]})); then
    local -A gomod=()
    while IFS=$'\t' read -r f p ver; do gomod[$f]="$p"$'\t'"$ver"; done < <(_mm_go_bins "${gofiles[@]}")
    for f in "${gofiles[@]}"; do
      mm_install_of "$f" || continue
      MM_INST_HOW=go
      if [[ -n "${gomod[$f]:-}" ]]; then
        p=${gomod[$f]%%$'\t'*} ver=${gomod[$f]#*$'\t'}
        [[ "$ver" == "(devel)" ]] && ver=""
        MM_INST_VERSION=$ver MM_INST_UPDATE="go install $p@latest"
      fi
      _emit package "${f##*/}" "" "$f"
    done
  fi

  # Homebrew kegs: the newest version of each formula.
  _mm_test_path MM_TEST_BREW_PREFIX "${HOMEBREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
  for pfx in "$REPLY" "$HOME/.linuxbrew"; do
    [[ -d "$pfx/Cellar" ]] || continue
    for d in "$pfx/Cellar"/*; do
      ver=$(find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)
      [[ -n "$ver" ]] && mm_install_of "$d/$ver/." && _emit package "${d##*/}" "" "$d/$ver"
    done
  done

  # Loose binaries and whatever they lead to that the managers above did not list.
  _mm_test_path MM_TEST_USR_LOCAL /usr/local
  for d in "$HOME/.local/bin" "$HOME/bin" "$REPLY/bin"; do
    for f in "$d"/*; do
      [[ -f "$f" && -x "$f" ]] || continue
      real=$(realpath -e -- "$f" 2>/dev/null) || continue
      mm_install_of "$real" && _emit package "${f##*/}" "" "$real"
    done
  done

  _mm_runtime node node
  _mm_runtime python3 python
  unset -f _emit
}

# _mm_installs_running — (mm_installs) the agents no launcher dated, such as pi behind its script
# launcher, dated by a running process of theirs (mm_agent_procs): the package of the script it
# runs, else its executable. Uses mm_installs' found, seen and _emit.
_mm_installs_running() {
  local i pid real
  while IFS=$'\t' read -r i pid; do
    [[ -z "${found[$i]:-}" ]] || continue
    # An interpreter's executable is the interpreter's install, not the agent's.
    if _mm_proc_script "$pid" && mm_install_of "$REPLY" "$i"; then real=$REPLY
    else
      real=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
      [[ "$real" != *" (deleted)" && ! "${real##*/}" =~ ^(node|nodejs|bun|deno|python[0-9.]*)$ ]] || continue
      mm_install_of "$real" "$i" || continue
    fi
    _emit agent "${MM_AGENT_PROCS[i]%% *}" "$i" "$real" && found[$i]=1
  done < <(mm_agent_procs)
  return 0
}

# mm_installs_agent_index LINES — sets MM_AGENT_INSTALL[idx]: the first "agent" line of LINES
# (mm_installs output) for each agent row.
mm_installs_agent_index() {
  local line kind idx
  declare -gA MM_AGENT_INSTALL=()
  while IFS= read -r line; do
    IFS=$MM_FS read -r kind _ _ _ _ _ idx _ <<<"$line"
    [[ "$kind" == agent && -z "${MM_AGENT_INSTALL[$idx]:-}" ]] && MM_AGENT_INSTALL[$idx]=$line
  done <<<"$1"
  return 0
}

# _mm_proc_script PID — REPLY: the resolved script an interpreter process runs (its first argument
# that is no option), relative paths taken from its working directory; fails without one.
_mm_proc_script() {
  local a cwd
  local -a argv=()
  REPLY=""
  mapfile -d '' -t -n 8 argv 2>/dev/null <"/proc/$1/cmdline" || return 1
  for a in "${argv[@]:1}"; do
    [[ "$a" == -* || -z "$a" ]] && continue
    if [[ "$a" != /* ]]; then cwd=$(readlink "/proc/$1/cwd" 2>/dev/null) || return 1; a=$cwd/$a; fi
    REPLY=$(realpath -e -- "$a" 2>/dev/null) && [[ -f "$REPLY" ]]
    return
  done
  return 1
}

# mm_proc_outdated PID IDX — 0 with the reason in REPLY when PID, a process of agent IDX, runs code
# an update has replaced since it started: its executable is gone from disk ("runs a replaced
# build"), it runs another entry of the versions dir than the active one ("runs 2.1.3, 2.1.5
# installed"), or the package its script belongs to was reinstalled after it started ("predates
# the update to 0.5.0"). 1 when it is current or marmot cannot tell.
mm_proc_outdated() {
  local pid=$1 i=$2 exe ran a real age now
  REPLY=""
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
  if [[ "$exe" == *" (deleted)" ]]; then REPLY="runs a replaced build"; return 0; fi
  if mm_install_of "$exe" "$i" && [[ "$MM_INST_HOW" == native ]]; then
    ran=$MM_INST_VERSION
    for a in ${MM_AGENT_ACTIVE[i]:-}; do
      real=$(realpath -e -- "$a" 2>/dev/null) || continue
      if mm_install_of "$real" "$i" && [[ "$MM_INST_HOW" == native && "$MM_INST_VERSION" != "$ran" ]]; then
        REPLY="runs $ran, $MM_INST_VERSION installed"
        return 0
      fi
    done
    return 1
  fi
  _mm_proc_script "$pid" || return 1
  mm_install_of "$REPLY" "$i" || return 1
  age=$(mm_proc_age "$pid") || return 1
  now=$(date +%s)
  # A second of slack: the process may start while its package is still being written.
  ((MM_INST_AT > now - age + 1)) || return 1
  REPLY="predates the update${MM_INST_VERSION:+ to $MM_INST_VERSION}"
}

# mm_days_ago EPOCH [NOW] — REPLY: whole days from EPOCH to NOW (default: the clock), 0 for the
# future.
mm_days_ago() {
  local now=${2:-}
  [[ -n "$now" ]] || now=$(date +%s)
  REPLY=$(((now - $1) / 86400))
  ((REPLY >= 0)) || REPLY=0
}
