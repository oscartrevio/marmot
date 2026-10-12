# marmot

Keep an agentic coding machine clean, fast and up to date. `mm` is a terminal tool for
Ubuntu/Debian dev boxes and VMs where people run coding agents (Claude Code, Codex, Cursor Agent,
Gemini CLI, Copilot CLI, opencode, Aider, ...), Node/Python/Go/Rust toolchains, Docker and lots
of git worktrees. Inspired by [Mole](https://github.com/tw93/Mole), which does this for Macs.

```text
mm clean       caches, old browser builds, old agent CLI versions, temp files, apt/snap/journal,
               old kernels, Docker leftovers, stale editor servers
mm purge       abandoned git worktrees, then node_modules/.next/target/venv... in idle projects
mm status      live health dashboard: CPU, memory, disk and inodes, network/VPN, agent sessions,
               lingering dev servers and ports, updates, pending reboot
mm analyze     disk overview, then a read-only explorer; move what you pick to the Trash
mm optimize    upgrades, swap reset, stranded processes, SSD trim, DNS flush, reboot check
mm uninstall   apt/snap/npm/bun/pipx packages and ~/.local/bin tools, plus their leftovers
mm history     everything marmot changed, refused or moved to the Trash
```

Every command takes `--dry-run` (`-n`) to preview and `--help`.

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
  are only ever reported.
- **Trash for anything personal.** Temp files, uninstall leftovers, Python virtualenvs and
  whatever you pick in `mm analyze` go to the standard Trash (`~/.local/share/Trash`) and can be
  restored with `trash-restore`. If the Trash is on another filesystem, the item is kept, never
  deleted instead. `mm clean` empties only Trash items deleted more than 7 days ago, after asking.
  Regenerable caches and build artifacts are deleted permanently.
- **Confirmations need a terminal.** Run without one (cron, pipes) and every step that asks is
  skipped. There is no global `--yes`; the only unattended deletion is `mm purge --yes`, which
  removes build artifacts of stale projects only.
- **When unsure, keep.** A git check that fails keeps the folder; an agent version that can't be
  identified as active keeps all versions; a worktree with uncommitted or unreachable work is
  never offered; base-system packages, cloud guest agents and remote-access/VPN software are
  never offered for uninstall unless you name them (and VPNs need a separate confirmation).
- **Everything is logged** to `~/.local/state/marmot/operations.log`, including refusals and
  their reasons: `mm history`.

## Configuration

| File | Purpose |
|---|---|
| `~/.config/marmot/whitelist` | your own protected paths or globs (`mm clean --whitelist`) |
| `~/.config/marmot/catalog` | extra cache folders for `mm clean` (format in `lib/catalog.sh`) |
| `~/.config/marmot/purge_paths` | fixed project roots for `mm purge` instead of discovery (`mm purge --paths`) |

Environment: `MM_STATUS_LINGER_AGE`, `MM_STATUS_VPN_IFACES`, `MM_OPTIMIZE_ORPHAN_AGE`,
`MM_ANALYZE_TIMEOUT` (see each command's `--help`). Known agents and cleanup targets live in
`lib/agents.sh` and `lib/catalog.sh`: adding a tool is adding a row.

## Development

```sh
sudo apt-get install bats shellcheck
tests/run.sh            # shellcheck + the whole bats suite
tests/run.sh tests/purge.bats
```

Tests never touch the real machine: each one gets a throwaway `HOME`, and commands that change
the system (`sudo`, apt, docker, snap, kill, swap, mount, package managers) are replaced by stubs
that fail the test if they are ever called for real. Every raw deletion outside the gate must
carry a `# SAFE: <reason>` comment (enforced by `tests/audit.bats`).
