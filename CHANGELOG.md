# Changelog

All notable changes to marmot are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Safety

A data-loss audit (five adversarial reviews, ~48 reproduced cases) led to these rules. The
regression corpus is `tests/personal.bats`; the promises are in SECURITY.md.

- Unattended runs (`mm schedule run`, `mm purge --yes`, `mm clean` without a terminal) delete a
  build artifact only when a project of the matching type vouches for it: `node_modules` and
  bundler outputs need a `package.json` (or Deno manifest) next to them, `coverage` a project
  file and a git-ignore, `__pycache__` only compiled modules, toolchain caches their build file.
  A name alone no longer deletes `~/Documents/.../coverage`, a Go SDK's `src/internal/coverage`
  or a deployed `.output`.
- Folders that merely tag themselves `CACHEDIR.TAG`, and anything inside a Syncthing, Dropbox,
  Nextcloud or Resilio folder (deleting there deletes on every device), are offered only in the
  picker, never removed unattended or preselected.
- Artifacts holding a nested git repository, a deploy keypair or local Terraform state
  (`*.tfstate`) are kept; virtualenvs go to the Trash whatever they are called; activity counts
  edits anywhere in a project (git or not) and writes inside the artifact; every check runs
  again right before each deletion.
- `mm purge` keeps a worktree whose git-ignored files exist nowhere else (`.env`,
  `CLAUDE.local.md`, a database), that holds a nested repository or a deploy keypair, or whose
  HEAD reflog holds commits on no branch, tag or remote; what would go with a worktree is named
  in the prompt. Worktree records of absent folders are no longer pruned.
- Whitelist entries now protect what they name: `#` only comments at the start, `$HOME` and
  `~user` expand, brackets match literally, symlinked folders are resolved, a BOM is stripped,
  and entries that can match nothing are reported.
- Agent state, `~/.config`, `~/.ssh` and `~/.gnupg` stay protected when a dotfiles setup
  symlinks them; targets in another account's home are refused (`run marmot as alice`);
  exported `MM_KEEP_AGENT_STATE`/`MM_AGENT_WAIVER` are ignored; an unusable whitelist path
  protects everything.
- The in-use check reads paths with spaces correctly (mounts, maps, sockets), sees container
  bind mounts from other mount namespaces, runs as both root and the user (a scan that cannot
  read some processes is warned as partial), takes a last look right before each delete, and
  follows `cd DIR &&`, `WorkingDirectory=`, `%h`, system units and shell startup files
  (aliases, PATH exports) when collecting references.
- Cache entries holding a package that wrote its own data after install (an MCP server's
  `memory.jsonl`) are kept and listed for review; Deno's npm cache is reported, never deleted.
  Session retention (opt-in) touches only transcripts, never memory folders, agent worktrees or
  git checkouts. Corepack's `lastKnownGood.json`, oh-my-zsh's dotenv lists, Playwright MCP
  profiles and CLI versions pinned through `$PATH` are kept.
- The scheduled Trash sweep now needs `trash_keep_days = N` in the config, like session
  retention; without it, scheduled runs leave the Trash alone.
- `mm uninstall` removes apt packages instead of purging them and runs `autoremove` without
  `--purge`, so PostgreSQL clusters, `/var/lib/docker` volumes and edited `/etc` files survive;
  data notes cover every package apt would remove; a snap is snapshotted (`snap save`) before
  removal and the restore command is printed; only `~/.cache/NAME` is a preselected leftover,
  while `~/.NAME` and `~/.local/share/NAME` are app data behind the new `--app-data` flag, and
  anything recently changed or credential-like is always kept; `uv tool` installs are removed
  with `uv tool uninstall`.
- `mm clean` lists every container and image its Docker prompts act on (nothing hidden behind a
  count), asks before removing untagged images instead of pruning, keeps images no registry
  has, and purges removed packages' config files only when their purge script deletes no data.
- `mm optimize` lists what the picker returned and confirms before sending any signal.
- `mm schedule enable` carries this shell's config folders into the scheduled run (whitelist,
  `purge_paths`, Trash), refuses values a unit or crontab cannot carry, and removes only
  marmot's own crontab line; your lines ending in `# marmot` survive.
- `install.sh` records a manifest and removes only what it installed; it refuses a symlinked
  prefix or one inside a git work tree. `mm update` refuses to overwrite ignored local files
  that upstream starts tracking.
- The source audit (`tests/audit.bats`) also covers rm behind quotes, `find -exec rm` and
  `xargs rm`, and pins the tool modes above (no wholesale apt purge, no docker prune, no forced
  or record-pruning worktree removal, snap purge only after its snapshot).

### Added

- MIT license.
- `mm status`: a marmot peeks over the dashboard, its face summing up the health score, a busy
  CPU and whether an agent is at work; a short terminal drops it first.
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

### Fixed

- Sizes of 1000-1023 bytes print as `1KB`, not `0KB`, and KB sizes are rounded (1.9KB is `2KB`,
  not `1KB`); `mm history` uses the same formatter.
- `mm history --json` with nothing logged yet prints `[]` instead of a sentence (and no longer
  needs jq for that).
- `mm --yes purge` and `mm -n -y purge DIR` work: like the other global flags, `-y/--yes` may
  come before the command. It is still refused for every command but `mm purge`.
- Bare `mm` opens its command menu with fzf older than 0.34 (Ubuntu 22.04 ships 0.29); it
  quit without a word. The menu and the pickers share one fzf version check.
- `mm analyze PATH` without a terminal lists the largest entries under PATH instead of
  starting ncdu, which only complained that standard input is not a TTY.
- `mm history` accounts for every byte the closing summaries claim: the `run` rows of tool-driven
  cleans (npm, pnpm, apt, journal, snap revisions, Docker, ...), of `mm purge`'s pnpm store prune
  and of `mm uninstall`'s package removals carry what they freed, and each run's line and the
  all-time total (now "freed") count them with removed files and worktrees. A command that fails
  is logged as `failed` with its exit status and last line of output; it was not logged at all.
- sudo asks for your password at most once per run. `mm clean` (dry run included), `mm optimize`,
  `mm uninstall` (apt and snap packages) and `mm analyze` (a root-owned folder) ask up front,
  saying what needs root, and use sudo's credential cache after that; `mm clean` asks before the
  in-use check, which then sees every user's processes. Refused, failed or no sudo: the rest of
  the run asks nothing more and skips each root step with "needs sudo". It used to prompt again
  for every system step, up to `sudo: 3 incorrect password attempts` and beyond. Without a
  terminal, as root and with passwordless sudo nothing changes.

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
