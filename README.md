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

Purge project artifacts  (dry run: nothing will change)

⚙ Ubuntu 24.04.5 LTS · 2 cores · 4GB RAM | Free: 89.2GB | Up 2d 16h 33m
  Scanned ~/code in 0.0s · artifacts idle > 14d are stale

➤ In use
  ◎ ~/code/mcp-server · 1 artifact (node_modules) · skipped (used by ~/.cursor/mcp.json)

➤ Kept
  ◎ ~/code/vault/target · kept (holds a deploy keypair)

➤ Artifacts (3)
          SIZE      FREES   IDLE  PROJECT/ARTIFACT
  ●    362.0MB    362.0MB    40d  ~/code/web/node_modules
  ●    200.0MB    200.0MB    40d  ~/code/api/node_modules
  ●     86.0MB     86.0MB    40d  ~/code/web/.next

  ● stale (idle > 14d): 3 artifacts, frees 648.0MB
  ○ recent:               0 artifacts, frees 0B

➤ Would remove
  ✓ ~/code/web/node_modules · 362.0MB
  ✓ ~/code/api/node_modules · 200.0MB
  ✓ ~/code/web/.next · 86.0MB

======================================================================
Dry run complete
Would free: 648.0MB | Artifacts: 3 | Projects: 2
Free space: 89.2GB now, ~89.8GB after
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
`~/.local/bin`, and ends with three first steps (a preview, the dashboard, the schedule) and the
completion line for your shell. Update with `mm update`, which shows the CHANGELOG entries it
brings. `./install.sh --uninstall` turns off the schedule and removes only what the installer
put in place. Your config, history and Trash stay.

## Quick start

```sh
mm clean --dry-run    # preview: every command takes --dry-run (-n)
mm clean              # caches, old builds, logs; asks before anything that can't be regenerated
mm status             # live dashboard, agent sessions first
mm purge              # finished git worktrees and build artifacts of idle projects
mm schedule enable    # a safe part of clean and purge, daily, no prompts, no sudo
```

| Command | What it does |
|---|---|
| `mm clean` | Caches, old browser and agent CLI builds, logs, the Trash, apt, journal, snaps, kernels, Docker |
| `mm purge` | Finished git worktrees, then build artifacts of idle projects |
| `mm status` | Live dashboard: agent sessions, CPU, memory, disk, network, lingering dev servers |
| `mm analyze` | Disk overview, then a read-only explorer. Moves what you pick to the Trash |
| `mm optimize` | Upgrades, swap reset, stranded processes, orphaned headless browsers, TRIM, DNS |
| `mm uninstall` | apt, snap, npm, bun, pipx, uv and `~/.local/bin` packages, with their caches |
| `mm schedule` | The safe part of clean and purge, daily or weekly |
| `mm history` | What marmot removed, moved to the Trash or refused, run by run |
| `mm update` | Updates marmot from the git checkout it was installed from |

`mm help <command>` (or `mm <command> --help`) explains each command and its options. `mm` alone
opens a command picker that previews each command's help.

Steps that need root ask for your password once, up front, and say what for. Decline, and the
rest of the run skips those steps instead of asking again.

### The marmot

A marmot peeks over `mm status`. Its face is the health score at a glance, health first: `x x`
below 60, `O O !` below 80 (cheeks stuffed when a full disk is why), `> <` CPU above 85% for a
while, `o o` any other health reason, `- o` with a steaming mug on the night shift (an agent
busy between midnight and 6:00), `= =` tired (an agent session busy for over 12 hours), `^ ^ +*`
proud the day after a cleanup that freed 1GB or more, `^ ^` agents at work on a healthy machine,
`- - z Z` nobody busy. It wears a hard hat while a marmot cleanup runs and, in the live view,
blinks every few seconds.

It also knows what day it is: a party hat and fireworks at New Year, a Santa hat, snow on the
rule all winter, vampire fangs and a jack-o'-lantern in Halloween week, papel picado, marigolds
and calavera eyes on Día de Muertos, a lightsaber on May 4, a tree on Earth Day, its anniversary
on this machine, and some twenty more (the table is `MM_CALENDAR` in `lib/mascot.sh`, the art
`MM_PARTS`; all of it plain ASCII, so no terminal shows an emoji). The day never changes the face
that reports a problem, and `festive = off` in the config turns the calendar off. `mm --version`
and a run with nothing to do say the day's greeting too, and the closing banner of a real run
celebrates firsts, round run counts, records and anniversaries, each once.

## Safety

marmot deletes files, so it refuses rather than guesses.

- **Without asking.** Developer caches, old browser builds, old agent CLI and editor server
  versions, logs older than 7 days, browser leftovers in `/tmp`, and Docker build cache older
  than 7 days. With sudo, also the apt cache, the journal above 500 MB, and old snap revisions.
- **Build artifacts of idle projects.** Only next to the file that rebuilds them: `node_modules`
  next to a `package.json`, `target` next to a `Cargo.toml`, and so on. `mm purge` asks first.
  `mm purge --yes` and scheduled runs remove them without asking.
- **After you confirm.** Old Trash items, crash reports, rotated system logs, unused packages,
  old kernels, stopped containers, unused images, and finished git worktrees.
- **Only if you opt in.** Agent sessions, the app data of programs you uninstall, and old Trash
  items in scheduled runs.
- **Only reported.** Model and dependency stores, Node versions, Docker volumes, images no
  registry has, and unknown folders in `~/.cache`.
- **Never.** Credentials, `~/.config`, agent state, system folders, other accounts' homes, and
  anything in use.

marmot keeps a file, and every folder that contains it, when:

- a running process, a launcher, a tool or MCP config, a systemd unit, your crontab, or your
  shell startup files use or name it.
- git tracks it, or it sits in a git worktree with work that exists nowhere else.
- it holds what can't be rebuilt: a git repository, a deploy keypair, Terraform state, or data a
  program wrote into its own cache folder.
- it is in your whitelist, or its name looks like a credential.
- it was used recently, or marmot can't read its size, its activity, or its git state.

Personal files, such as virtualenvs and agent sessions, go to the Trash, and `trash-restore`
brings them back. Without a terminal (cron, pipes, agents), marmot skips every step that asks.
Every refusal names its reason, and `mm history` lists every change. `tests/personal.bats` fills
a test home with personal files that look like caches and build output, and fails if any
unattended run deletes one. [SECURITY.md](SECURITY.md) has the full rules.

## Scheduled runs

`mm schedule enable` runs `mm schedule run` daily, or weekly with `--weekly`, through a systemd
user timer, or through a crontab line when `systemctl --user` doesn't work. A run removes caches,
old browser and agent CLI builds, logs older than 7 days, `/tmp` browser leftovers, old editor
server builds, and build artifacts of projects idle 14+ days. It empties old Trash items only
with `trash_keep_days` set, and it moves old agent sessions to the Trash only with
`sessions_keep_days` set. It never asks, never uses sudo, and never touches Docker, worktrees,
packages, or processes. It reads the same config folder as the shell that enabled it, so your
whitelist applies.

## Configuration

marmot reads its files from `~/.config/marmot/` (`$XDG_CONFIG_HOME/marmot`) and keeps its state
and history in `~/.local/state/marmot/`.

| File | Purpose |
|---|---|
| `whitelist` | Paths or globs marmot never removes (`mm clean --whitelist`) |
| `purge_paths` | Project roots for `mm purge` (`mm purge --paths`) |
| `agents` | Coding agents marmot doesn't know yet |
| `catalog` | Cache folders marmot doesn't know yet |
| `config` | Settings, `key = value` |

Settings in `config`, all off by default but `festive`:

```ini
sessions_keep_days = 30   # agent session files older than 30 days, not in use, go to the Trash
trash_keep_days = 30      # scheduled runs delete Trash items trashed more than 30 days ago
nix_gc = on               # nix generations older than 30 days, then garbage collection
festive = off             # no seasons, holidays, anniversaries or year-in-review (default: on)
```

marmot knows Claude Code, Codex, Cursor Agent, Gemini CLI, Copilot CLI, opencode, Aider, Amp,
Goose, Crush, Qwen Code, Cline, Kimi CLI, OpenHands, oh-my-pi, and several orchestrators. Add
another with one row in `agents`:

```text
# name | process names | state | sessions | versions dir | active symlink | worktrees | logs
My Tool|mytool|~/.mytool ~/.config/mytool|~/.mytool/sessions||||~/.mytool/logs
```

marmot then protects its state, shows its sessions in `mm status`, and cleans its old logs. A
cache folder goes in `catalog` as `cache|My tool cache|~/.cache/mytool|mytool`: a label, the
folder, and the process names that mean it is in use.

<details>
<summary>Environment variables</summary>

| Variable | Effect |
|---|---|
| `MM_CONTAINER` | `1` or `0`: treat the machine as a container or not (default: detected) |
| `MM_DOCKER_PRUNE` | `1`: let `mm clean` clean a Docker daemon that is not this machine's own |
| `MM_STATUS_LINGER_AGE` | seconds before a dev process or listener counts as lingering (86400) |
| `MM_STATUS_VPN_IFACES` | VPN interface globs (`"tailscale* wg* tun* zt* nebula* netbird* wt*"`) |
| `MM_OPTIMIZE_ORPHAN_AGE` | minimum age in seconds of orphaned processes and browsers (3600) |
| `MM_ANALYZE_TIMEOUT` | seconds `mm analyze` spends sizing each location (20) |
| `MM_SIZE_TIMEOUT` | seconds one size measurement may take (300); past it the item is kept |
| `MM_LOG_MAX_BYTES` | size at which the operations log rotates (5242880) |
| `MARMOT_PREFIX`, `MARMOT_BIN` | `install.sh`: install folder and launcher folder |

</details>

## Network access

marmot sends no telemetry. It uses the network only in these cases:

- `mm update` runs `git fetch` on the checkout marmot was installed from.
- `mm purge` asks `gh` about the pull requests of worktree branches, when `gh` is installed and
  logged in. This sends branch names to GitHub.
- `mm optimize` runs `snap refresh --list`, and `apt-get update` after you confirm.
- `mm clean` runs tools' own clean commands, such as npm, yarn through Corepack, and Homebrew,
  which may contact their registries.

## Requirements

Debian 12+ or Ubuntu 22.04+ (WSL2 and containers included), bash 5, coreutils, findutils, grep,
sed, and awk (mawk works). Each optional tool below is needed only by the feature next to it,
and marmot says so when it is missing.

| Tool | Used for |
|---|---|
| sudo (or root) | apt, kernels, the journal, snaps, system logs, crash dumps, `mm optimize` |
| git | `mm update`, and the git checks in `mm purge` |
| fzf | pickers and the `mm` menu |
| ncdu | the `mm analyze` explorer |
| jq | `--json` output |
| trash-cli | `trash-restore` |
| ss (iproute2) | ports and latency in `mm status` |
| gh, logged in | pull request state in `mm purge` |
| systemd user instance or crontab | `mm schedule` |

In a container, `mm status` follows the cgroup CPU and memory limits, and `mm clean` and
`mm optimize` leave kernels, swap, and TRIM to the host. marmot cleans Docker only when the
daemon belongs to the container, and `mm purge` also scans your folders in `/workspaces` and
`/workspace`. Safety checks read `/proc` directly and need neither procps nor psmisc.

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

Thanks to [Mole](https://github.com/tw93/Mole) by tw93, the cleanup tool for macOS.

## License

[MIT](LICENSE)
