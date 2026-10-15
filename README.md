# marmot

marmot (`mm`) cleans and monitors Debian and Ubuntu machines where coding agents run (Claude
Code, Codex, Cursor Agent, Gemini CLI, Copilot CLI, opencode, Aider, ...): cloud VMs,
devcontainers and Codespaces, WSL2, or your laptop, as root or as a normal user, with or without
sudo and systemd. It never deletes what an agent or tool still uses, and it asks before it touches
anything personal.

## Quick start

```sh
git clone https://github.com/oscartrevio/marmot.git && cd marmot && ./install.sh
mm clean --dry-run    # see what would go
mm clean              # caches, old builds, logs; asks before anything that can't be regenerated
mm status             # live health dashboard, agent sessions first
mm purge              # finished git worktrees, build artifacts of idle projects
mm schedule enable    # a safe part of clean and purge, daily, no prompts, no sudo
```

`install.sh` needs no root. It copies marmot to `~/.local/share/marmot`, links `mm` and `marmot`
into `~/.local/bin` and prints the lines that enable bash or zsh completion. It refuses to replace
an `mm` that is not marmot's, or a git checkout at the install folder. Every command takes
`--dry-run` (`-n`), `--help` and `--debug`. `mm` alone opens a command picker.

## What it deletes, and what it never deletes

| | |
|---|---|
| **Without asking** | developer caches (npm, pnpm, yarn, bun, uv, pip, Go build, Cargo downloads, Gradle, Deno, Prisma, ... and your own rows), thumbnails, old browser builds (Playwright, Puppeteer, Cypress), old agent CLI versions, old editor server builds, agent and cloud CLI logs older than 7 days, automation-browser leftovers in `/tmp`; with sudo the apt cache, the journal above 500 MB and old snap revisions; Docker dangling images and old build cache |
| **After asking on a terminal** | Trash items older than 7 days, crash reports and dumps, rotated system logs, autoremovable packages and old kernels, stopped Docker containers and unused images, git worktrees, build artifacts of idle projects, agent sessions (only if you opt in) |
| **Only reported** | model stores (Hugging Face, Ollama, torch), dependency repositories (Maven, the Go module cache, ...), Node versions, Docker volumes, agent state, the biggest unknown folders in `~/.cache`, `/tmp` and `/var/tmp` |
| **Never** | credentials (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.netrc`, keyrings, ...), `~/.config`, system folders, other users' homes (unless you name a folder in one, e.g. `mm purge /home/bob/src` as root), live or open logs, anything in use |

Personal things (uninstall leftovers, virtualenvs, agent sessions, what you pick in `mm analyze`)
go to `~/.local/share/Trash`; restore them with `trash-restore`. Regenerable caches, logs and build
artifacts are deleted for good. Without a terminal (cron, pipes, agents) every step that asks is
skipped.

How marmot decides something is still needed. It keeps a file, and every folder containing it,
when:

- a running process has it open, runs in it or names it in its arguments (read from `/proc`);
- a launcher in `~/.local/bin`, `~/bin` or a `$PATH` folder in your home points at it (symlink
  targets, paths inside wrapper scripts);
- an agent's config or any `*mcp*` JSON/TOML/YAML config names it, for any tool, listed or not
  (`node ~/src/my-mcp/dist/index.js` keeps `~/src/my-mcp`);
- a systemd user unit or your crontab names it;
- it is a project file git tracks (purge never removes an artifact holding one), or a worktree
  with uncommitted changes or commits on no branch or tag;
- it is a cache entry used in the last 7 days (such as the packages `npx -y` installs for MCP
  servers);
- it is in your whitelist, or it looks like a credential (`*token*`, `*secret*`, `*.pem`,
  `*.key`, `auth*.json`, ...).

A refusal names its reason (`used by ~/.cursor/mcp.json`). When a check fails, marmot keeps the
thing. Every deletion goes through one gate and is logged, refusals included: see `mm history`.

## Commands

### mm clean [--sessions N] [--whitelist]

Removes what the table above lists. Caches are skipped while a process that uses them runs;
npm, pnpm, yarn, bun, uv, mise, conda and Homebrew are cleaned with their own commands. For old
builds, the newest (and anything in use) stays; for agent CLIs, the active version and one
previous. `/tmp` and `/var/tmp` are not swept: marmot shows their size and how the OS ages them.
Agent sessions are kept unless you opt in: `--sessions N` for one run (asks first) or
`sessions_keep_days` in the config; then session files older than N days and not in use go to
the Trash. `--whitelist` edits your protected paths.

### mm purge [DIR...] [--days N] [--all] [--yes] [--paths]

1. **Git worktrees.** A linked worktree is offered when git reports it clean (untracked files
   included), it is not locked or in use, and every commit is on a branch or tag. Finished ones
   (merged, also squash- or rebase-merged; upstream branch deleted; or pull request merged or
   closed, via `gh`) after 1 idle hour, unmerged ones after 30 idle days. Removed with
   `git worktree remove` (never `--force`; the branch stays) after you confirm.
2. **Build artifacts** of projects idle longer than `--days` (14): `node_modules`, `.next`,
   `target`, `dist`, virtualenvs, `.build`, .NET `bin`/`obj`, `.nx/cache`, folders tagged with
   `CACHEDIR.TAG`, ... Folders like `target` or `vendor` count only next to the manifest that
   rebuilds them. Virtualenvs go to the Trash.

It looks in the DIRs given, else in `~/.config/marmot/purge_paths` (`--paths` edits it), else in
your home, your folders in `/workspaces` and `/workspace`, and agents' worktree folders. `--yes`
runs unattended and removes stale build artifacts only, never worktrees. `--all` also preselects
recent projects. Sizes count only what a delete really frees: files hard-linked from pnpm's store
stay, and marmot runs `pnpm store prune` afterwards.

### mm status [--once | --json | --agent] [--view compact|full] [--interval N]

Read-only dashboard, live on a terminal (`v` switches compact and full view, `q` quits). It shows
agent sessions (folder, age, busy or idle, CPU and memory including sub-processes, orphans whose
folder is gone) and their helper processes on a separate line, then CPU, memory, disk, inodes,
network and VPN, how you reach the machine (SSH, a relay, a local terminal) and your link's
latency, lingering dev servers and ports, updates, failed units, pending reboot, the last
scheduled run and a health score. `--agent` prints plain `key: value` text for coding agents,
problems first with the command that fixes each; it is the default when stdout is not a terminal.
`--json` needs jq.

### mm analyze [PATH] [--json]

Overview of home, dev caches, agent state, user data, `/tmp`, containers, `/usr`, logs and old
downloads, then a read-only ncdu explorer. For a folder of yours it offers to move picked items to
the Trash.

### mm optimize

Diagnoses load, pressure, swap and the biggest processes, then, each after you confirm: apt
upgrade (snap updates are only reported), swap reset when RAM allows, SIGTERM to processes
stranded in deleted folders and to orphaned headless browsers older than 1 hour, `fstrim /`
(unless run in the last 24 hours), DNS cache flush. It reports failed units and pending reboots
and never reboots.

### mm uninstall [NAME...] [--list] [--all]

Removes packages from apt, snap, `npm -g`, `bun -g`, pipx and `~/.local/bin`, plus leftovers with
the exact name (`~/.config/NAME`, `~/.cache/NAME`, `~/.local/share/NAME`, `~/.NAME`,
`~/snap/NAME`) to the Trash. apt removals are simulated first. The base system and cloud guest
agents are never offered; remote-access and VPN software only when you name it, with a separate
confirmation.

### mm schedule [status | enable [--daily | --weekly] | disable | run]

`enable` runs `mm schedule run` daily (or weekly) at 03:00 plus up to an hour of random delay,
through a systemd user timer when `systemctl --user` works, else a crontab line tagged
`# marmot`. `status` shows the next and last run and warns when linger is off (then
`sudo loginctl enable-linger $USER`). `disable` removes only what `enable` wrote.

A run never asks and never uses sudo. It cleans Trash items older than 30 days, caches, old
browser builds and agent CLI versions, logs older than 7 days, `/tmp` browser leftovers, old
editor server builds, build artifacts of projects idle 14+ days (as `mm purge --yes`), and agent
sessions only with `sessions_keep_days` set. It never touches Docker, worktrees, packages,
processes or anything that needs root. Results go to `~/.local/state/marmot/last-run.json`.

### mm history [-l N | --all] [--json]

What marmot removed, moved to the Trash, refused or failed, grouped by run with totals; `-l N`
shows the newest N runs (10). The log is `~/.local/state/marmot/operations.log`; past 5 MB it
moves to `operations.log.old` (both are read).

### mm update [--check]

Fetches the upstream of the checkout marmot was installed from, lists the new commits and, after
you confirm, fast-forwards it and re-runs `install.sh`. Uncommitted changes or diverging commits
are refused. `--check` (also the behavior without a terminal) only reports: exit 0 up to date, 10
update available, anything else an error.

## Extending

Configuration lives in `~/.config/marmot/` (`$XDG_CONFIG_HOME/marmot`), state in
`~/.local/state/marmot/`.

**Any agent or tool: `agents`.** One row per line in the format of `lib/agents.sh`:

```text
name | process names | state | sessions | versions dir | active symlink | worktrees | logs | helpers
My Tool|mytool mytool-cli|~/.mytool ~/.config/mytool|~/.mytool/sessions||||~/.mytool/logs
```

That row makes `mm status` show `mytool` processes as agent sessions, protects `~/.mytool` and
`~/.config/mytool`, lets `mm clean` remove its logs older than 7 days, and its sessions only if
you opt in. A versions dir and active symlink let `mm clean` prune old versions; worktree dirs
tell `mm purge` where to look. Paths must be inside your home. Bad rows are ignored with a
reason; a row named like a built-in one replaces it.

**Your caches: `catalog`.** `cache|My tool cache|~/.cache/mytool|mytool` (label, path inside your
home, process names that mean busy; format in `lib/catalog.sh`).

**`whitelist`**: protected paths or globs, one per line (`mm clean --whitelist`).
**`purge_paths`**: project roots for `mm purge` (`mm purge --paths`).

**`config`**, `key = value`, both off by default:

```ini
sessions_keep_days = 30   # agent session files older than N days, not in use, go to the Trash
nix_gc = on               # nix generations older than 30 days, then garbage collection
```

| Variable | Effect |
|---|---|
| `MM_CONTAINER` | `1`/`0`: treat the machine as a container or not (default: detected) |
| `MM_DOCKER_PRUNE` | `1`: let `mm clean` prune a Docker daemon that is not this machine's own |
| `MM_STATUS_LINGER_AGE` | seconds before a dev process or listener counts as lingering (86400) |
| `MM_STATUS_VPN_IFACES` | VPN interface globs (`"tailscale* wg* tun* zt* nebula* netbird* wt*"`) |
| `MM_OPTIMIZE_ORPHAN_AGE` | minimum age in seconds of orphaned processes and browsers (3600) |
| `MM_ANALYZE_TIMEOUT` | seconds `mm analyze` spends sizing each location (20) |
| `MM_SIZE_TIMEOUT` | seconds one size measurement may take (300); past it the size is unknown and the item is kept |
| `MM_LOG_MAX_BYTES` | size at which the operations log rotates (5242880) |
| `MARMOT_PREFIX`, `MARMOT_BIN` | `install.sh`: install folder and launcher folder |

## Containers

marmot detects containers (`/.dockerenv`, `/run/.containerenv`, cgroup hints, ...);
`MM_CONTAINER` overrides it. In a container `mm status` follows the cgroup v2 CPU and memory
limits, `mm optimize` skips swap reset, TRIM and the reboot check, and `mm clean` offers no
kernels. Docker is cleaned only when the daemon is this machine's own, not through `DOCKER_HOST`,
another context or a mounted `docker.sock` (set `MM_DOCKER_PRUNE=1` to override). `mm purge`
scans your folders in `/workspaces` and `/workspace`.

## Network access

marmot has no telemetry. It makes these outbound calls:

- `mm update`: `git fetch` from the checkout's upstream.
- `mm purge`: `gh pr view <branch>` for worktree branches, only when `gh` is installed and logged
  in. This sends branch names to GitHub.
- `mm optimize`: `apt-get update` (after you confirm, not in a dry run) and `snap refresh --list`.
- `mm clean`: tools' own clean commands (npm, yarn through Corepack, Homebrew, ...) may contact
  their registries.

## Requirements

Debian 12+ or Ubuntu 22.04+ (including WSL2 and containers), bash 5, git, coreutils, findutils,
grep, sed and awk (mawk works). Optional tools; each feature says so when its tool is missing:

| Tool | Used for |
|---|---|
| sudo (or root) | apt, kernels, journal, snaps, system logs, crash dumps |
| fzf | pickers in `purge`, `analyze`, `uninstall` and the `mm` menu |
| ncdu | the `mm analyze` explorer |
| jq | `--json` output of `status` and `history` |
| trash-cli | `trash-restore` |
| ss (iproute2) | ports and latency in `mm status` |
| systemd user instance or crontab | `mm schedule` |
| gh, logged in | pull request state in `mm purge` |
| docker, pnpm, uv, go, mise, conda, brew, nix, snap | cleaned with their own commands |

Safety checks read `/proc` and do not need procps, psmisc or iproute2.

## Uninstall

```sh
./install.sh --uninstall
```

It disables the schedule, removes the launchers and the installed copy (never a git checkout).
Your config, history and Trash stay.

## Development

```sh
tests/run.sh                    # shellcheck and the bats suite (bats-core 1.5+)
tests/run.sh tests/purge.bats   # one file
tests/e2e/run.sh [IMAGE] [--root] [--minimal]   # real run in a container; needs docker
```

Tests use a throwaway `HOME` and stub every command that changes the system. CI runs
`tests/run.sh` once per pull request. Run the end-to-end scenario before changing what gets
deleted.

See [CONTRIBUTING.md](CONTRIBUTING.md) (and [AGENTS.md](AGENTS.md) for coding agents). Report
security problems privately as [SECURITY.md](SECURITY.md) describes.

## License

GPL-3.0. marmot is inspired by [Mole](https://github.com/tw93/Mole) by tw93, which does this for
Macs, and parts of it are ported from Mole.
