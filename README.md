# marmot

Keep an agentic coding machine clean, fast and up to date. `mm` is a terminal tool for
Ubuntu/Debian dev boxes and VMs where people run coding agents (Claude Code, Codex, Cursor Agent,
Gemini CLI, Copilot CLI, opencode, Aider, ...), Node/Python/Go/Rust toolchains, Docker and lots
of git worktrees. Inspired by [Mole](https://github.com/tw93/Mole), which does this for Macs.

```text
mm clean       caches, old browser builds, old agent CLI versions, gcloud/Azure CLI logs,
               apt/snap/journal, old kernels, Docker leftovers, stale editor servers; reports /tmp
               and how the OS ages it
mm purge       abandoned git worktrees, then node_modules/.next/target/venv... in idle projects
mm status      live health dashboard, agent sessions first: CPU, memory, disk and inodes,
               network/VPN, your link's latency, lingering dev servers and ports, updates,
               pending reboot (`v` switches to the full panel view)
mm analyze     disk overview, then a read-only explorer; move what you pick to the Trash
mm optimize    upgrades, swap reset, stranded processes, SSD trim, DNS flush, reboot check
mm uninstall   apt/snap/npm/bun/pipx packages and ~/.local/bin tools, plus their leftovers
mm history     everything marmot changed, refused or moved to the Trash
```

Every command takes `--dry-run` (`-n`) to preview and `--help`.

Coding agents can check the machine too: `mm status --agent` (the default when the output is
not a terminal) prints a short plain-text snapshot, problems first, each with the marmot or
system command that addresses it. `mm status --json` has every number.

## Install

```sh
git clone https://github.com/oscartrevio/marmot.git && cd marmot && ./install.sh
```

No root needed: it installs to `~/.local/share/marmot` and links `mm` and `marmot` into
`~/.local/bin`. Requires bash 5, git and the usual coreutils/findutils. Recommended:
`sudo apt-get install fzf ncdu jq trash-cli` (pickers, disk explorer, JSON output, restoring
from the Trash). `./install.sh --uninstall` removes marmot but keeps your config, history and
anything in the Trash.

Start with a preview: `mm clean --dry-run`.

## Safety

marmot deletes files, so it is built to refuse rather than guess:

- **One gate.** Every deletion goes through one function that refuses paths outside the folder a
  step is cleaning, system folders (`/usr`, `/etc`, `/var/lib`, `/opt`, other disks, any user's
  home folder), names with control characters, anything protected (below), and anything a
  running process uses: open files, working directories, sockets, mounts. It re-checks that the
  target did not change while it was being measured.
- **Built-in protections** that cannot be edited away: `~/.ssh`, `~/.gnupg`, credentials
  (`~/.aws`, `~/.kube`, `~/.docker`, `~/.netrc`, ...), `~/.config`, and the state of every known
  coding agent (settings, credentials, session transcripts; see `lib/agents.sh`). Agent sessions
  are only reported unless you opt in to session retention (below); credentials inside agent
  state are never touched even then. Besides that, a short list of log folders inside these
  protections is open (`MM_CLEAN_CARVEOUTS` in `lib/core.sh`): `mm clean` deletes gcloud logs
  (`~/.config/gcloud/logs`, or `$CLOUDSDK_CONFIG/logs`) and Azure CLI logs (`~/.azure/logs`, or
  `$AZURE_CONFIG_DIR/logs`) older than 7 days. Inside them your whitelist and the in-use checks
  still apply, a symlinked folder gets no opening, and names that look like credentials (one
  list for agent state and log folders: `*credential*`, `*token*`, `*secret*`, `*.pem`, `*.key`,
  `auth*.json`, `configurations`, ...) are kept anyway. The AWS CLI writes no log files, and its
  caches hold credentials, so `~/.aws` stays closed.
- **Trash for anything personal.** Uninstall leftovers, Python virtualenvs and whatever you
  pick in `mm analyze` go to the standard Trash (`~/.local/share/Trash`) and can be restored
  with `trash-restore`. If the Trash is on another filesystem, the item is kept, never deleted
  instead. `mm clean` empties only Trash items deleted more than 7 days ago, after asking.
  Regenerable caches and build artifacts are deleted permanently.
- **Shared temp is the OS's job.** `/tmp` and `/var/tmp` hold other programs' sockets, locks and
  working files, so marmot never sweeps them; `mm clean` shows their size and the
  systemd-tmpfiles age that applies (and the `tmpfiles.d` line to add when nothing ages them).
- **Confirmations need a terminal.** Run without one (cron, pipes) and every step that asks is
  skipped. There is no global `--yes`; the only unattended deletions are `mm purge --yes`, which
  removes build artifacts of stale projects only, and a session retention you configured.
- **When unsure, keep.** A git check that fails keeps the folder; an agent version that can't be
  identified as active keeps all versions; a worktree with uncommitted or unreachable work is
  never offered; base-system packages, cloud guest agents and remote-access/VPN software are
  never offered for uninstall unless you name them (and VPNs need a separate confirmation).
- **Everything is logged** to `~/.local/state/marmot/operations.log`, including refusals and
  their reasons: `mm history`.

## Configuration

| File | Purpose |
|---|---|
| `~/.config/marmot/config` | settings, `key=value` per line, `#` comments (see below) |
| `~/.config/marmot/whitelist` | your own protected paths or globs (`mm clean --whitelist`) |
| `~/.config/marmot/catalog` | extra cache folders for `mm clean` (format in `lib/catalog.sh`) |
| `~/.config/marmot/purge_paths` | fixed project roots for `mm purge` instead of discovery (`mm purge --paths`) |

Settings in `~/.config/marmot/config` (`$XDG_CONFIG_HOME` is honored):

```ini
# Agent session retention, off by default. Session files of known agents (and rotated logs in
# their state) last written more than N days ago and not in use move to the Trash on every
# `mm clean`, also without a terminal. `mm clean --sessions N` does the same for one run.
sessions_keep_days = 30
```

Environment: `MM_STATUS_LINGER_AGE`, `MM_STATUS_VPN_IFACES`, `MM_OPTIMIZE_ORPHAN_AGE`,
`MM_ANALYZE_TIMEOUT` (see each command's `--help`). Known agents and cleanup targets live in
`lib/agents.sh` and `lib/catalog.sh`: adding a tool is adding a row.

## Development

```sh
sudo apt-get install bats shellcheck jq python3
tests/run.sh            # shellcheck + the whole bats suite
tests/run.sh tests/purge.bats
```

The suite needs bats-core 1.5 or newer. Ubuntu 22.04's package is older; `tests/run.sh` says so
and prints how to install a pinned release. CI runs the suite on the Ubuntu 24.04 runner and, as
a non-root user, in Debian 12 and Ubuntu 22.04 containers.

Tests never touch the real machine: each one gets a throwaway `HOME`, and commands that change
the system (`sudo`, apt, docker, snap, kill, swap, mount, package managers) are replaced by stubs
that fail the test if they are ever called for real. Every raw deletion outside the gate must
carry a `# SAFE: <reason>` comment (enforced by `tests/audit.bats`).
