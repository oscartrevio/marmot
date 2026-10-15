# marmot

Keep an agentic coding machine clean, fast and up to date. `mm` is a terminal tool for
Ubuntu/Debian machines where people run coding agents (Claude Code, Codex, Cursor Agent, Gemini
CLI, Copilot CLI, opencode, Aider, ...): cloud VMs, devcontainers and Codespaces, WSL2, as root or
as a normal user, with or without sudo and systemd. Inspired by
[Mole](https://github.com/tw93/Mole), which does this for Macs.

```text
mm clean       caches, old tool and agent builds, logs, Trash, apt/journal/snap, kernels, Docker
mm purge       finished or abandoned git worktrees, then build artifacts of idle projects
mm status      live health dashboard, agent sessions first (also --agent and --json snapshots)
mm analyze     disk overview, then a read-only explorer; move what you pick to the Trash
mm optimize    upgrades, swap reset, stranded processes, orphaned headless browsers, TRIM, DNS
mm uninstall   apt/snap/npm/bun/pipx packages and ~/.local/bin tools, plus their leftovers
mm schedule    a safe part of clean and purge on a daily or weekly timer, no prompts, no sudo
mm history     everything marmot changed, refused or moved to the Trash
mm update      update marmot from the git checkout it was installed from
```

Every command takes `--dry-run` (`-n`) and `--help`; `--debug` logs more. `mm` alone opens a
command picker (with fzf on a terminal) or prints the usage. Start with `mm clean --dry-run`.

## Install

```sh
git clone https://github.com/oscartrevio/marmot.git && cd marmot && ./install.sh
```

No root needed. It copies marmot to `~/.local/share/marmot` (`MARMOT_PREFIX`), links `mm` and
`marmot` into `~/.local/bin` (`MARMOT_BIN`), records the checkout and commit it came from (for
`mm update`; `mm --version` shows the commit) and prints the lines that enable completion:

```sh
echo 'source ~/.local/share/marmot/completion/mm.bash' >> ~/.bashrc         # bash
echo 'fpath=(~/.local/share/marmot/completion $fpath)' >> ~/.zshrc          # zsh, before compinit
```

`./install.sh --uninstall` removes the launchers and the installed copy; your config, history and
the Trash stay.

**Supported:** Debian 12+ and Ubuntu 22.04+ (including WSL2 and containers), bash 5.
**Required:** git, coreutils, findutils, grep, sed, awk (mawk is fine).
**Optional,** each feature degrades with a note when its tool is missing:

| Tool | Used for |
|---|---|
| sudo (or running as root) | apt, kernels, journal, snaps, system logs and crash dumps, root-owned sizes |
| fzf | pickers in `purge`, `analyze`, `uninstall`, the `mm` menu |
| ncdu | `mm analyze PATH` explorer (else the largest entries are listed) |
| jq | `mm status --json`, `mm history --json` (jq 1.6 works) |
| trash-cli | `trash-restore` to get Trash items back |
| ss (iproute2) | ports and link latency panels in `mm status` |
| systemd user instance, or crontab | `mm schedule` |
| gh, logged in | `mm purge` asks whether a worktree's pull request is merged or closed |
| docker, pnpm, uv, go, mise, conda, brew, nix, snap | cleaned with their own commands when installed |

procps, psmisc and iproute2 are not needed for safety: process, open-file and lock checks read
`/proc`.

## What each command does

### mm clean

Deletes regenerable data. Rows whose path does not exist are ignored, so the lists below name
every supported tool, not what a machine must have.

- **Developer caches** (deleted without asking, regenerated on next use): the cache rows of
  `lib/catalog.sh` (npx, Corepack, TypeScript, pip, Cargo downloads, Gradle build cache and daemon
  logs, Deno, Bazel, Zig, Prisma, Electron, pyenv, RubyGems, Bundler, Composer, CPAN, Hex, opam,
  Android, kubectl discovery/HTTP caches, Jupyter runtime files when no Jupyter runs, ...),
  thumbnails, and the caches of npm, pnpm, yarn, bun, uv, mise, conda and Homebrew
  through their own clean commands. A cache is skipped while a process that uses it runs. nix
  garbage collection only with `nix_gc = on` (see Configuration).
- **Old builds**: Playwright/Puppeteer/Cypress browser builds, Firebase emulators and
  agent-browser Chrome builds (the newest per product, and anything in use, stay); old versions of
  coding-agent CLIs that keep every version (the active one and one previous stay); editor server
  builds in `~/.vscode-server`, `~/.vscode-server-insiders`, `~/.vscodium-server`,
  `~/.cursor-server`, `~/.windsurf-server` (the newest stays) with their obsolete extensions,
  cached VSIX packages and logs older than 7 days; JetBrains remote backends (the newest per IDE
  stays); Chromium cache folders inside agent browser profiles while no browser has them open.
- **Logs**: coding agents' own `*.log` files (and rotations) in the logs folder each agent
  documents (`lib/agents.sh`), gcloud logs (`~/.config/gcloud/logs` or `$CLOUDSDK_CONFIG/logs`)
  and Azure CLI logs (`~/.azure/logs` or `$AZURE_CONFIG_DIR/logs`): last written more than 7 days
  ago and not in use.
- **Automation-browser leftovers in /tmp**: `playwright_chromiumdev_profile-*`,
  `puppeteer_dev_chrome_profile-*`, `playwright-artifacts-*`, `.org.chromium.Chromium.*`,
  `.com.google.Chrome.*`; only your own, untouched for 2 hours and not in use.
- **System and Docker, without asking**: with sudo, the apt package cache, the journal above
  500 MB (vacuumed to 300 MB) and disabled snap revisions; Docker dangling images and build cache
  older than 7 days (see Containers for whose daemon).
- **After asking on a terminal**: Trash items deleted more than 7 days ago; your apport crash
  reports older than 7 days; with sudo, autoremovable packages, residual configs, old kernels
  (the running and the newest stay; not in containers), rotated system logs (`/var/log/**`
  rotations, never live or open logs, never the journal) and crash dumps (`/var/crash`,
  systemd-coredump) older than 7 days; Docker stopped containers and images no container uses
  that were pulled or built 30+ days ago.
- **Agent sessions**: kept unless you opt in (`--sessions N` for one run, or `sessions_keep_days`).
  Then session files and rotated logs in agent state last written more than N days ago and not in
  use move to the Trash; empty folders are removed afterwards.
- **Reported only** under "Kept for you to review", with their size and the command that reclaims
  them: model stores (Hugging Face, Ollama, torch), dependency repositories (`~/.m2`, `~/.ivy2`,
  sbt, pub, NuGet, the Go module cache), Node versions, Docker volumes, W&B, the Terraform plugin cache, agent state.
- **Never swept**: `/tmp` and `/var/tmp` beyond the browser leftovers above. They hold other
  programs' sockets and locks, and the OS ages them; marmot shows their size and the
  systemd-tmpfiles age that applies (or the `tmpfiles.d` line to add when nothing ages them).

`mm clean --whitelist` edits your protected paths. Without a terminal, every step that asks is
skipped and reported; caches are still cleaned, and agent sessions move to the Trash only when
`sessions_keep_days` is set.

### mm purge [DIR...]

1. **Git worktrees.** A linked worktree is offered only when git reports it clean (untracked files
   included), not locked, not in use by a process, and every commit is reachable from a branch or
   tag. A **finished** one (its branch is merged into the default branch, also squash- or
   rebase-merged; or its upstream branch was deleted; or its pull request is merged or closed, via
   `gh`) is offered once idle 1 hour; an unmerged one after 30 idle days. Removed with
   `git worktree remove` (never `--force`; the branch stays), only after you confirm on a terminal.
2. **Build artifacts** of projects idle longer than `--days` (default 14): `node_modules`,
   `.next`, `target`, `dist`, virtualenvs, SwiftPM `.build`, .NET `bin`/`obj`, `bower_components`,
   `.nx/cache`, `.docusaurus`, a project's `.pnpm-store`, folders tagged with `CACHEDIR.TAG`, ...
   Folders like `target`, `build`, `dist`, `vendor`, `bin`/`obj` count only next to the manifest
   that rebuilds them. Never touched: anything git tracks, projects
   whose git state can't be read, projects with a running process inside. Virtualenvs go to the
   Trash, the rest is deleted permanently. `--all` also preselects recent projects (terminal
   only).

Where it looks: the DIRs given; else the roots in `~/.config/marmot/purge_paths` (`mm purge
--paths` edits it); else your home folder, your folders in `/workspaces` and `/workspace`, every
worktree registered to a repository found there, and the worktree folders of known agents and
orchestrators (`lib/agents.sh`).

`mm purge --yes` (`-y`) is unattended: it removes the stale build artifacts only, never worktrees.

**Sizes.** Every size marmot reports as freed counts only files whose every hard link is inside
what is deleted, so a pnpm `node_modules` shows e.g. `1.4GB (frees 70MB; rest shared with the pnpm
store)`. After removing pnpm-installed artifacts or worktrees, marmot runs `pnpm store prune`
(unless pnpm is running) and reports what that freed. A dry run reports the same numbers a real
run frees.

### mm status

Read-only dashboard. Views:

- `mm status` on a terminal: live, refreshed every `--interval` seconds (default 2). The
  **compact** view (default) shows agent sessions first, then one line per resource; `v` or
  `--view full` switches to every panel; `q` quits.
- `mm status --once`: one snapshot for people.
- `mm status --agent`: plain `key: value` text for AI coding agents, problems first, each with the
  command that addresses it. The default when stdout is not a terminal.
- `mm status --json`: every number (needs jq).

It shows agent sessions (folder, age, busy/idle, CPU and proportional memory including
sub-processes; orphans whose folder was deleted) and, on a line of their own, the agents' helper
processes (language-server hubs, daemons: the `helpers` field in `lib/agents.sh`), CPU, memory,
disk and inodes, network/VPN, how you reach the machine (the program hosting your terminal: SSH,
a direct connection, a relay such as a tunnel, or a local terminal; when you last typed; the
latency of your link where it can be measured), lingering dev servers and ports, updates,
failed units, pending reboot, the scheduled cleanup and its last run, and a health score.

### mm analyze [PATH] · mm optimize · mm uninstall [NAME...] · mm history

- `mm analyze`: overview of home, dev caches, agent state, user data, `/tmp`, containers, `/usr`,
  logs and old downloads (`--json` prints it), then a read-only ncdu explorer. For a folder of
  yours it offers to move picked items to the Trash.
- `mm optimize`: diagnosis, then, each after confirming on a terminal: apt upgrade, swap reset
  when RAM allows, SIGTERM to processes stranded in deleted folders and to orphaned headless
  browsers (Playwright, Puppeteer, agent Chromium whose script is gone; older than 1 hour),
  `fstrim /` (unless trimmed in the last 24 h), DNS cache flush. Reports failed units and pending
  reboots; never reboots.
- `mm uninstall`: packages from apt, snap, `npm -g`, `bun -g`, pipx and `~/.local/bin`, plus
  leftovers matched by exact name (`~/.config/NAME`, `~/.cache/NAME`, `~/.local/share/NAME`,
  `~/.NAME`, `~/snap/NAME`) to the Trash. `-l`/`--list` lists, `-a`/`--all` adds manually
  installed libraries. The base system and cloud guest agents are never offered;
  remote-access/VPN software only when named, with a separate confirmation.
- `mm history [-l N | --all] [--json]`: the operations log.

### mm schedule [status | enable [--daily | --weekly] | disable | run]

`mm schedule enable` runs `mm schedule run` daily (or `--weekly`, Sundays) at 03:00 plus a random
delay of up to an hour. It writes a systemd user timer (`marmot-schedule.timer` in
`~/.config/systemd/user`, catches up on runs missed while the machine was off) when
`systemctl --user` answers, else a crontab line ending in `# marmot`, else explains why it can't.
`mm schedule status` (the default) shows what is scheduled, the next and the last run, and warns
when linger is off: a user timer then runs only while you are logged in, and
`sudo loginctl enable-linger $USER` fixes that. `mm schedule disable` removes only what enable
wrote.

A run asks nothing and never runs sudo. It cleans: Trash items deleted more than 30 days ago,
thumbnails, regenerable caches (catalog rows and the tools' own cleans), old browser builds and
agent CLI versions, agent and gcloud/Azure CLI logs older than 7 days, automation-browser
leftovers in `/tmp`, old editor server builds and their leftovers, build artifacts of projects
idle 14+ days (as `mm purge --yes`), and agent sessions only with `sessions_keep_days` set. It
never touches anything that needs root, Docker, git worktrees, packages, processes or upgrades.
Two runs never overlap; changes are logged under `schedule` in `mm history`; each run's totals,
skips and errors go to `~/.local/state/marmot/last-run.json`, which `mm status` shows.

### mm update [--check]

Fetches the upstream of the checkout `install.sh` recorded, lists the new commits and, after you
confirm on a terminal, runs `git pull --ff-only` there and re-runs its `install.sh`. A checkout
with uncommitted changes or diverging local commits is refused with the reason. `--check` (also
what `mm update` does without a terminal or with `--dry-run`) only reports: exit 0 up to date, 10
update available, anything else an error or refusal. One update runs at a time (lock in
`~/.local/state/marmot/`).

## Safety

marmot deletes files, so it refuses rather than guesses:

- **One gate.** Every deletion goes through one function (or a tool's own documented clean
  command). It refuses paths outside the folder a step cleans, system folders (`/usr`, `/etc`,
  `/var/lib`, `/opt`, other disks, other users' homes), names with control characters, anything
  protected, and anything a running process uses (open files, working directories, sockets,
  mounts), and re-checks that the target did not change while it was measured. As root with
  `HOME=/root`, `/root` follows the same rules as any home.
- **Anything a tool still needs is kept**, for any tool, listed or not: a file named by a running
  process's arguments, by a launcher in `~/.local/bin`, `~/bin` or a `$PATH` folder in your home
  (symlink targets, paths inside wrapper scripts), by a coding agent's config or any `*mcp*`
  JSON/TOML/YAML config in a dot-folder (MCP servers such as `node ~/src/my-mcp/dist/index.js`),
  by a systemd user unit or by your crontab keeps itself and every folder containing it. Only
  files count: a config that lists project folders does not freeze them. The refusal names the
  source (`used by ~/.cursor/mcp.json`).
- **Built-in protections** that cannot be edited away: `~/.ssh`, `~/.gnupg`, credentials
  (`~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.netrc`, `~/.git-credentials`, keyrings,
  ...), `~/.config`, and the state of every known coding agent and orchestrator (`lib/agents.sh`).
  A few log and cache folders inside them are open (gcloud and Azure CLI logs, kubectl's
  `~/.kube/cache/discovery` and `~/.kube/cache/http`; `MM_CLEAN_CARVEOUTS` in `lib/core.sh`), and
  even there names that look like credentials (`*credential*`, `*token*`, `*secret*`, `*.pem`,
  `*.key`, `auth*.json`, ...) are kept.
- **Trash for anything personal.** Uninstall leftovers, virtualenvs, agent sessions and what you
  pick in `mm analyze` go to `~/.local/share/Trash` (restore with `trash-restore`). If the Trash
  is on another filesystem the item is kept, not deleted. Regenerable caches, logs and build
  artifacts are deleted permanently.
- **Confirmations need a terminal.** Without one (cron, pipes, agents) every step that asks is
  skipped. There is no global `--yes`; `mm purge --yes` (stale build artifacts) and
  `mm schedule run` (the fixed list above) are the only unattended runs of steps that otherwise
  ask.
- **When unsure, keep.** A git check that fails keeps the folder; an agent version that can't be
  identified as active keeps all versions; a worktree with uncommitted or unreachable work is
  never offered.
- **Everything is logged** to `~/.local/state/marmot/operations.log`, refusals with their reason:
  `mm history`.

## Containers

marmot detects a container from `/.dockerenv`, `/run/.containerenv`, `/run/systemd/container`,
`$container`, cgroup hints or an overlay root; `MM_CONTAINER=1` or `0` overrides it. In a
container:

- `mm status` says so in the header and measures CPU and memory against the cgroup v2 limits
  (`cpu.max`, `memory.max`) when set; load, uptime, reboot and kernel checks belong to the host.
- `mm optimize` skips the swap reset, TRIM and reboot check; `mm clean` offers no old kernels.
- Docker is cleaned only when the daemon is this machine's own: not when `DOCKER_HOST` or the
  docker context points elsewhere, and not through a mounted `docker.sock` from inside a container
  (that is the host's daemon) unless dockerd runs in the container. `MM_DOCKER_PRUNE=1` cleans
  that daemon anyway.
- `mm purge` also scans the folders you own in `/workspaces` and `/workspace` (devcontainers,
  Codespaces, Gitpod, Coder).

## Configuration

All under `~/.config/marmot/` (`$XDG_CONFIG_HOME/marmot` when set); state under
`~/.local/state/marmot/` (`$XDG_STATE_HOME`).

| File | Purpose |
|---|---|
| `config` | settings, `key = value` per line, `#` comments |
| `whitelist` | your protected paths or globs, one per line, `~` expands (`mm clean --whitelist`) |
| `catalog` | extra cache folders inside your home for `mm clean`, one row per line: `cache\|My tool cache\|~/.cache/mytool\|mytool` (label, path, process names that mean busy; format in `lib/catalog.sh`) |
| `purge_paths` | project roots for `mm purge` instead of discovery (`mm purge --paths`) |
| state: `operations.log` | everything changed or refused (`mm history`) |
| state: `last-run.json` | the last `mm schedule run` |

Settings in `config`, both off by default:

```ini
# Agent session retention: on every `mm clean` (also without a terminal) and every scheduled
# run, session files older than N days and not in use move to the Trash.
sessions_keep_days = 30
# nix: delete profile generations older than 30 days and collect unreferenced store paths.
nix_gc = on
```

Environment variables:

| Variable | Effect |
|---|---|
| `MM_CONTAINER` | `1`/`0`: treat this machine as a container or not (default: detected) |
| `MM_DOCKER_PRUNE` | `1`: let `mm clean` prune a Docker daemon that is not this machine's own |
| `MM_STATUS_LINGER_AGE` | seconds before a dev process or listener counts as lingering (86400) |
| `MM_STATUS_VPN_IFACES` | VPN interface globs for `mm status` (`"tailscale* wg* tun* zt* nebula* netbird* wt*"`) |
| `MM_OPTIMIZE_ORPHAN_AGE` | minimum age in seconds of orphaned processes and browsers (3600) |
| `MM_ANALYZE_TIMEOUT` | seconds `mm analyze` spends sizing each location (20) |
| `MARMOT_PREFIX`, `MARMOT_BIN` | `install.sh`: install folder and launcher folder |

Known agents, orchestrators and cleanup targets live in `lib/agents.sh` and `lib/catalog.sh`:
adding a tool is adding a row.

## Development

```sh
sudo apt-get install bats shellcheck jq python3
tests/run.sh                    # shellcheck + the whole bats suite
tests/run.sh tests/purge.bats   # one file
```

The suite needs bats-core 1.5 or newer; Ubuntu 22.04's package is older, and `tests/run.sh` says
so and prints how to install a pinned release. Tests never touch the real machine: each gets a
throwaway `HOME`, and commands that change the system (`sudo`, apt, docker, snap, kill, swap,
mount, package managers) are stubs that fail the test if called for real. Every raw deletion
outside the gate carries a `# SAFE: <reason>` comment (enforced by `tests/audit.bats`).

End to end: `tests/e2e/run.sh [IMAGE] [--root] [--minimal]` (needs docker and network access)
builds a realistic agent machine in a container (default image `debian:12`): real npm and pnpm
installs, git worktrees, caches, old Trash items, agent sessions, a whitelisted folder. It runs
marmot for real, through a pty where a confirmation is needed, measures the home folder and disk
before and after, and checks the minimum reclaim and that protected items survived. It runs as a
normal user with sudo, as root with `--root`, and without procps, psmisc, iproute2 and sudo with
`--minimal`. The scenario itself is `tests/e2e/agent-vm.sh`.

CI runs `tests/run.sh` once per pull request on the Ubuntu 24.04 runner (skipped for docs-only
changes). Run the end-to-end scenario locally before changes to what gets deleted, and the suite
in a `debian:12` or `ubuntu:22.04` container before changes that may depend on older mawk or jq.
