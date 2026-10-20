```text
     _..--.._
  ()'        '()     marmot
   |  ^    ^  |      Keep the machines your coding agents
  .--.  \/  .--.     run on clean, fast and healthy.
--(mm)--UU--(mm)--------------------------------------------
```

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Debian 12+ · Ubuntu 22.04+](https://img.shields.io/badge/Debian%2012%2B%20%C2%B7%20Ubuntu%2022.04%2B-informational)
![bash 5](https://img.shields.io/badge/bash-5-informational)

Coding agents leave a lot behind: `node_modules` in every worktree, browser builds, package
caches, logs, old CLI versions, sessions, dev servers nobody stopped. marmot (`mm`) is a terminal
tool that cleans up after them on the Debian and Ubuntu machines they run on: cloud VMs,
devcontainers, Codespaces, WSL2, your laptop. It shows what is running, and it never deletes
anything an agent or tool still needs.

```text
$ mm purge --dry-run --yes ~/code

Purge Project Artifacts  (dry run: nothing will change)

⚙ Ubuntu 24.04.5 LTS · 8 cores · 31GB RAM | Free: 42.6GB | Up 3d 23h 45m
  Scanned ~/code in 0.0s · artifacts idle > 14d are stale

➤ In use
  ◎ ~/code/mcp-server · 1 artifact (node_modules) · skipped (used by ~/.cursor/mcp.json)

➤ Kept
  ◎ ~/code/vault/target · kept (holds a deploy keypair)

➤ Artifacts (3)
          SIZE      FREES   IDLE  PROJECT/ARTIFACT
  ●    362.4MB    362.4MB    40d  ~/code/web/node_modules
  ●    200.3MB    200.3MB    40d  ~/code/api/node_modules
  ●     85.8MB     85.8MB    40d  ~/code/web/.next

  ● stale (idle > 14d): 3 artifacts, frees 648.5MB
  ○ recent:               0 artifacts, frees 0B

➤ Would remove
  ✓ ~/code/web/node_modules · 362.4MB
  ✓ ~/code/api/node_modules · 200.3MB
  ✓ ~/code/web/.next · 85.8MB

======================================================================
Dry run complete
Would free: 648.5MB | Artifacts: 3 | Projects: 2
Free space: 42.6GB
Run without --dry-run to apply.
======================================================================
```

The MCP server that Cursor starts keeps its `node_modules`. The Solana program's `target/` holds
its deploy keypair, so it stays too.

## Install

```sh
git clone https://github.com/oscartrevio/marmot.git && cd marmot && ./install.sh
```

No root needed. The installer copies marmot to `~/.local/share/marmot`, links `mm` into
`~/.local/bin`, and prints the PATH and shell-completion lines if you need them. Update with
`mm update`. Remove with `./install.sh --uninstall`. marmot needs Debian 12+ or Ubuntu 22.04+
(WSL2 and containers included) and bash 5. See [Requirements](#requirements).

## Quick start

```sh
mm clean --dry-run    # preview: every command takes --dry-run (-n)
mm clean              # caches, old builds, logs; asks before anything that can't be regenerated
mm status             # live dashboard, agent sessions first
mm purge              # finished git worktrees and build artifacts of idle projects
mm schedule enable    # a safe part of clean and purge, daily, no prompts, no sudo
```

`mm` alone opens a command picker (with fzf) or prints the usage. `mm <command> --help` explains
each command.

## Commands

| Command | What it does |
|---|---|
| `mm clean` | Developer caches, old browser and agent CLI builds, logs, Trash, apt/journal/snap, kernels, Docker |
| `mm purge` | Finished or abandoned git worktrees, then build artifacts of idle projects |
| `mm status` | Live health dashboard: agent sessions, CPU, memory, disk, network, lingering dev servers |
| `mm analyze` | Disk overview, then a read-only explorer; move what you pick to the Trash |
| `mm optimize` | Upgrades, swap reset, stranded processes, orphaned headless browsers, TRIM, DNS |
| `mm uninstall` | apt, snap, npm, bun, pipx and `~/.local/bin` packages, plus their leftovers |
| `mm schedule` | Run a safe part of clean and purge daily or weekly |
| `mm history` | Everything marmot removed, moved to the Trash or refused, grouped by run |
| `mm update` | Update marmot from the git checkout it was installed from |

Details for each are in [Command reference](#command-reference).

## Safety

marmot deletes files, so it refuses rather than guesses.

- **Removed without asking:** developer caches (npm, pnpm, yarn, bun, uv, pip, Go build, Cargo,
  Gradle, Deno, ...), old browser builds (Playwright, Puppeteer, Cypress), old agent CLI and
  editor server versions, logs older than 7 days, browser leftovers in `/tmp`; with sudo the apt
  cache, the journal above 500 MB and old snap revisions; dangling Docker images and old build
  cache.
- **Removed after you confirm:** old Trash items, crash reports and dumps, rotated system logs,
  unused packages and old kernels, stopped containers and unused images, git worktrees, build
  artifacts, agent sessions (only if you opt in).
- **Only reported:** model stores (Hugging Face, Ollama, torch), dependency stores (Maven, the Go
  module cache, ...), Node versions, Docker volumes, agent state, unknown folders in `~/.cache`,
  `/tmp`.
- **Never:** credentials (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, keyrings, ...), `~/.config`,
  system folders, other users' homes (unless you name a folder there), anything in use.

A file is kept, with every folder that contains it, when:

- a running process has it open, runs in it, or names it in its arguments;
- a launcher in `~/.local/bin`, `~/bin` or a `$PATH` folder in your home points at it;
- an agent's config or any `*mcp*` JSON, TOML or YAML config names it, for any tool;
- a systemd user unit or your crontab names it;
- git tracks it, or it is in a worktree with uncommitted work or commits on no branch or tag;
- it is a cache entry used in the last 7 days, such as a package `npx -y` installed;
- its project was touched since the scan, or its size or activity can't be measured;
- it is in your whitelist, or its name looks like a credential (`*token*`, `*.pem`, ...).

Every refusal names its reason (`used by ~/.cursor/mcp.json`). Personal files (virtualenvs,
uninstall leftovers, agent sessions, what you pick in `mm analyze`) go to `~/.local/share/Trash`;
restore them with `trash-restore`. Without a terminal (cron, pipes, agents) every step that asks
is skipped. Every deletion goes through one gate and is logged: `mm history`. The threat model is
in [SECURITY.md](SECURITY.md).

## Works with any tool

marmot knows Claude Code, Codex, Cursor Agent, Gemini CLI, Copilot CLI, opencode, Aider, Amp,
Goose, Crush, Qwen Code, Cline and several orchestrators. Add your own in
`~/.config/marmot/agents`, one row per tool:

```text
# name | process names | state | sessions | versions dir | active symlink | worktrees | logs
My Tool|mytool|~/.mytool ~/.config/mytool|~/.mytool/sessions||||~/.mytool/logs
```

Its processes then show as sessions in `mm status`, its state is protected, its logs older than
7 days are cleaned, and its sessions only if you opt in. Paths must be inside your home; bad rows
are reported and ignored. A row named like a built-in one replaces it.

Caches marmot doesn't know go in `~/.config/marmot/catalog`, one per line:
`cache|My tool cache|~/.cache/mytool|mytool` (label, folder, process names that mean busy).
`mm clean` lists the biggest unknown folders in `~/.cache` so you know what to add.

## Command reference

<details>
<summary><b>mm clean</b> [--sessions N] [--whitelist]</summary>

Removes what [Safety](#safety) lists. A cache is skipped while a process that uses it
runs; npm, pnpm, yarn, bun, uv, mise, conda and Homebrew are cleaned with their own commands. Of
old builds, the newest and anything in use stay; of agent CLIs, the active version and one
previous. `/tmp` and `/var/tmp` are not swept: marmot shows their size and how the OS ages them.
Agent sessions are kept unless you opt in with `--sessions N` (one run, asks first) or
`sessions_keep_days` in the config. `--whitelist` edits your protected paths.

</details>

<details>
<summary><b>mm purge</b> [DIR...] [--days N] [--all] [--yes] [--paths]</summary>

1. **Git worktrees.** A linked worktree is offered when git reports it clean, it is not locked or
   in use, and every commit is on a branch or tag. Finished ones (merged, also squash- or
   rebase-merged; upstream branch deleted; pull request merged or closed, via `gh`) after an idle
   hour, unmerged ones after 30 idle days. Removed with `git worktree remove` (never `--force`;
   the branch stays) after you confirm.
2. **Build artifacts** of projects idle longer than `--days` (14): `node_modules`, `.next`,
   `target`, `dist`, virtualenvs, `.build`, .NET `bin`/`obj`, `.nx/cache`, folders tagged with
   `CACHEDIR.TAG`, ... Folders like `target` or `vendor` count only next to the manifest that
   rebuilds them. Activity includes unstaged edits anywhere in the project, and it is checked
   again right before deleting.

It looks in the DIRs given, else in `~/.config/marmot/purge_paths` (`--paths` edits it), else in
your home, your folders in `/workspaces` and `/workspace`, and agents' worktree folders. `--yes`
runs unattended and removes stale build artifacts only, never worktrees. Sizes count only what a
delete really frees: files hard-linked from pnpm's store stay, and marmot runs `pnpm store prune`
afterwards.

</details>

<details>
<summary><b>mm status</b> [--once | --json | --agent] [--view compact|full] [--interval N]</summary>

Read-only dashboard, live on a terminal (`v` switches the compact and full view, `q` quits).
Agent sessions come first (folder, age, busy or idle, CPU and memory with sub-processes, orphans
whose folder is gone), then their helper processes, CPU, memory, disk, inodes, network and VPN,
how you reach the machine and the link's latency, lingering dev servers and ports, updates,
failed units, pending reboot, the last scheduled run and a health score. A marmot peeks over the
dashboard, and its face sums up the machine: `x x` health below 60, `O O !` below 80, `> <` CPU
above 85%, `o o` any other health issue, `- - z Z` no agent at work, `^ ^` agents at work on a
healthy machine. `--agent` prints plain `key: value` text for coding agents, problems first with
the command that fixes each; it is the default when stdout is not a terminal. `--json` needs jq.

</details>

<details>
<summary><b>mm analyze</b> [PATH] [--json]</summary>

Overview of home, dev caches, agent state, user data, `/tmp`, containers, `/usr`, logs and old
downloads, then a read-only ncdu explorer. For a folder of yours it offers to move picked items to
the Trash.

</details>

<details>
<summary><b>mm optimize</b></summary>

Diagnoses load, memory pressure, swap and the biggest processes, then, each after you confirm:
apt upgrade (snap updates are only reported), swap reset when RAM allows, SIGTERM to processes
stranded in deleted folders and to orphaned headless browsers older than an hour, `fstrim /`
(unless run in the last 24 hours), DNS cache flush. It reports failed units and pending reboots
and never reboots.

</details>

<details>
<summary><b>mm uninstall</b> [NAME...] [--list] [--all]</summary>

Removes packages from apt, snap, `npm -g`, `bun -g`, pipx and `~/.local/bin`, and moves leftovers
with the exact name (`~/.config/NAME`, `~/.cache/NAME`, `~/.local/share/NAME`, `~/.NAME`,
`~/snap/NAME`) to the Trash. apt removals are simulated first. The base system and cloud guest
agents are never offered; remote-access and VPN software only when you name it, with a separate
confirmation.

</details>

<details>
<summary><b>mm schedule</b> [status | enable [--daily | --weekly] | disable | run]</summary>

`enable` runs `mm schedule run` daily (or weekly) at 03:00 plus up to an hour of random delay,
through a systemd user timer when `systemctl --user` works, else a crontab line tagged
`# marmot`. `status` shows the next and last run and warns when linger is off (then
`sudo loginctl enable-linger $USER`). `disable` removes only what `enable` wrote.

A run never asks and never uses sudo. It cleans Trash items older than 30 days, caches, old
browser builds and agent CLI versions, logs older than 7 days, `/tmp` browser leftovers, old
editor server builds, build artifacts of projects idle 14+ days, and agent sessions only with
`sessions_keep_days` set. It never touches Docker, worktrees, packages, processes or anything that
needs root. Each run's totals go to `~/.local/state/marmot/last-run.json`, shown by `mm status`.

</details>

<details>
<summary><b>mm history</b> [-l N | --all] [--json]</summary>

What marmot removed, moved to the Trash, refused or failed, grouped by run with totals; `-l N`
shows the newest N runs (10). The log is `~/.local/state/marmot/operations.log`; past 5 MB it
moves to `operations.log.old`, and both are read.

</details>

<details>
<summary><b>mm update</b> [--check]</summary>

Fetches the upstream of the checkout marmot was installed from, lists the new commits and, after
you confirm, fast-forwards it and re-runs `install.sh`. Uncommitted changes or diverging commits
are refused. `--check` (also the behavior without a terminal) only reports: exit 0 up to date, 10
update available, anything else an error. Needs git.

</details>

## Configuration

Everything lives in `~/.config/marmot/` (`$XDG_CONFIG_HOME/marmot`); state in
`~/.local/state/marmot/`.

| File | Purpose |
|---|---|
| `agents` | your own agents and tools ([Works with any tool](#works-with-any-tool)) |
| `catalog` | your own cache folders |
| `whitelist` | protected paths or globs, one per line (`mm clean --whitelist`) |
| `purge_paths` | project roots for `mm purge` (`mm purge --paths`) |
| `config` | settings, `key = value` |

Settings in `config`, both off by default:

```ini
sessions_keep_days = 30   # agent session files older than N days, not in use, go to the Trash
nix_gc = on               # nix generations older than 30 days, then garbage collection
```

<details>
<summary>Environment variables</summary>

| Variable | Effect |
|---|---|
| `MM_CONTAINER` | `1`/`0`: treat the machine as a container or not (default: detected) |
| `MM_DOCKER_PRUNE` | `1`: let `mm clean` prune a Docker daemon that is not this machine's own |
| `MM_STATUS_LINGER_AGE` | seconds before a dev process or listener counts as lingering (86400) |
| `MM_STATUS_VPN_IFACES` | VPN interface globs (`"tailscale* wg* tun* zt* nebula* netbird* wt*"`) |
| `MM_OPTIMIZE_ORPHAN_AGE` | minimum age in seconds of orphaned processes and browsers (3600) |
| `MM_ANALYZE_TIMEOUT` | seconds `mm analyze` spends sizing each location (20) |
| `MM_SIZE_TIMEOUT` | seconds one size measurement may take (300); past it the item is kept |
| `MM_LOG_MAX_BYTES` | size at which the operations log rotates (5242880) |
| `MARMOT_PREFIX`, `MARMOT_BIN` | `install.sh`: install folder and launcher folder |

</details>

## Containers

marmot detects containers (`/.dockerenv`, `/run/.containerenv`, cgroup hints, ...);
`MM_CONTAINER` overrides the detection. In a container `mm status` follows the cgroup CPU and
memory limits, `mm optimize` skips swap reset, TRIM and the reboot check, and `mm clean` offers no
kernels. Docker is cleaned only when the daemon is this machine's own: not through `DOCKER_HOST`,
another context or a mounted `docker.sock` (`MM_DOCKER_PRUNE=1` overrides). `mm purge` also scans
your folders in `/workspaces` and `/workspace`.

## Privacy

marmot has no telemetry. The only outbound calls it makes:

- `mm update`: `git fetch` from the checkout's upstream.
- `mm purge`: `gh pr view <branch>` for worktree branches, only when `gh` is installed and logged
  in. This sends branch names to GitHub.
- `mm optimize`: `apt-get update` (after you confirm, never in a dry run) and
  `snap refresh --list`.
- `mm clean`: tools' own clean commands (npm, yarn through Corepack, Homebrew, ...) may contact
  their registries.

## Requirements

Debian 12+ or Ubuntu 22.04+ (WSL2 and containers included), bash 5, coreutils, findutils, grep,
sed and awk (mawk works). git is needed only for `mm update`. Optional tools; each feature says
so when its tool is missing:

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

Safety checks read `/proc` directly and need neither procps nor psmisc.

## Uninstall

```sh
./install.sh --uninstall
```

It disables the schedule and removes the launchers and the installed copy, never a git
checkout. Your config, history and Trash stay.

## Contributing

```sh
tests/run.sh                    # shellcheck and the bats suite (bats-core 1.5+)
tests/run.sh tests/purge.bats   # one file
tests/e2e/run.sh                # a real run in a throwaway container; needs docker
```

Tests use a throwaway `HOME` and stub every command that changes the system. See
[CONTRIBUTING.md](CONTRIBUTING.md), and [AGENTS.md](AGENTS.md) if you work with a coding agent.
Report security problems privately as [SECURITY.md](SECURITY.md) describes.

## Acknowledgements

Thanks to [Mole](https://github.com/tw93/Mole) by tw93, the cleanup tool for macOS. Its care
about what is safe to delete set the bar for marmot, which brings that care to the Linux machines
coding agents run on.

## License

[MIT](LICENSE)
