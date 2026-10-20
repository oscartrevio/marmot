# Changelog

All notable changes to marmot are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- MIT license.
- `mm status`: a marmot peeks over the dashboard, its face summing up the health score, a busy
  CPU and whether an agent is at work; a short terminal drops it first.
- App icon: `assets/marmot.icon` (Icon Composer source) and its export `assets/logo.png`.
- `~/.config/marmot/agents`: add any coding agent or orchestrator in the same row format as the
  built-in table; its state is protected and its sessions show in `mm status`.
- Files that running processes, launchers in `~/.local/bin` and `$PATH` folders in your home,
  agent and MCP configs, systemd user units or the crontab point at are never deleted, nor any
  folder containing them; refusals name the source.
- `mm clean` lists the biggest folders in `~/.cache` that no catalog row covers, never deleting
  them, with the catalog row that would.
- `SECURITY.md`, `CONTRIBUTING.md` and `AGENTS.md`.
- `mm purge` keeps build folders holding a `*-keypair.json` (Solana/Anchor deploy keys).
- The operations log rotates to `operations.log.old` past 5 MB (`MM_LOG_MAX_BYTES`); `mm history`
  reads both.
- Every operations log row carries a run id; `mm history` groups rows by run with totals and
  `--json` includes `run`.

### Changed

- CI runs once per pull request, as one job running the suite one file at a time; docs-only
  changes skip it.
- `install.sh` refuses to replace a git checkout or a foreign `mm`, and keeps a foreign `marmot`
  with a warning.
- `install.sh --uninstall` disables the schedule first, so no timer or cron line calls a removed
  launcher.
- `install.sh` no longer needs git (only `mm update` does, and says so) and prints the exact
  line that puts the launcher folder on PATH.
- `mm history --help` and `mm update --help` list every option; `mm --help` says where to start.
- In-use detection reads `/proc` in a few batch passes instead of one `readlink` per open file:
  about 10x faster (4.7 s to 0.44 s on a machine with 240 processes).
- `mm purge` asks git once per repository for tracked files and reads every project's activity in
  one pass: about a third faster.
- `mm purge` counts unstaged edits and new files anywhere in a project as activity.
- `mm clean` reports the Go module cache instead of wiping it with `go clean -modcache`.
- `mm clean` keeps catalog cache entries used in the last 7 days: an MCP server launched with
  `npx -y` is no longer downloaded again after every run.
- `mm clean` runs `mise cache prune` (files not read for 30 days) instead of `mise cache clear`.
- `mm clean --help` lists every option, `--sessions N` included.
- `mm purge` keeps an artifact or worktree whose size can't be measured; it was counted as 0.
- `mm purge` probes activity again right before deleting: a project touched since the scan, or
  whose activity can't be read, keeps its artifacts.
- Sizes are measured with a time limit (`MM_SIZE_TIMEOUT`, 300 s). A size that times out or
  can't be measured is shown as unknown and the item is kept; it was counted as 0 before.
- `mm history -l N` counts runs, not rows (default 10).

## 0.2.0

### Added

- `mm clean`: remove caches, old builds, logs, and package and Docker leftovers from a catalog
  of known tool caches; personal files go to the Trash; `--whitelist` protects paths.
- `mm status`: a live health dashboard (`--once` for a snapshot, `--json`, `--agent`) with one
  row per AI coding agent session, its helpers, and the last scheduled cleanup.
- `mm analyze`: a disk overview with a read-only explorer.
- `mm optimize`: updates, trim, swap reset, orphaned agent helpers and headless browsers,
  pending reboot.
- `mm purge`: remove build artifacts (node_modules, .next, target, ...) from idle projects and
  abandoned git worktrees; `--yes` runs unattended.
- `mm uninstall`: remove apt, snap and global packages plus their leftovers.
- `mm schedule`: run a safe cleanup on a systemd user timer or a cron line.
- `mm history`: show what marmot changed (`--limit`, `--all`, `--json`).
- `mm update`: update marmot from the git checkout it was installed from.
- Every deletion goes through one gate that refuses protected, whitelisted and in-use paths.
- Container awareness, bash and zsh completion, and a per-user installer (`install.sh`).
