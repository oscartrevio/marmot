# Changelog

All notable changes to marmot are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- GPL-3.0 license.

### Changed

- CI runs once per pull request, as one job running the suite one file at a time; docs-only
  changes skip it.
- `install.sh` refuses to replace a git checkout or a foreign `mm`, and keeps a foreign `marmot`
  with a warning.
- `install.sh --uninstall` disables the schedule first, so no timer or cron line calls a removed
  launcher.

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
