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
- `mm status` names the command for a full disk, full inodes or swap in its compact and full views,
  the same line `--agent` prints.
- `mm update` and `mm update --check` list the CHANGELOG bullets the incoming commits add, in
  place of the commit subjects (which they list when CHANGELOG.md gains no bullet).
- `install.sh` ends a fresh install with three next steps (`mm clean --dry-run` as a preview,
  `mm status`, `mm schedule enable`), printed only, then the shell completion line for a shell
  whose rc file does not load it yet, and names the apt packages for the optional tools it lacks.
- Shell completion (bash and zsh) offers `-h` and `-v` with `--help` and `--version` at the top level.
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
- A mistyped command suggests the one probably meant (`mm cleen`: `Did you mean clean?`), and
  `mm help COMMAND` shows that command's help.
- The `mm` menu shows the highlighted command's `--help` in a preview below the list (fzf 0.29
  included).
- `mm clean` names why it kept items (`2 kept (used by ~/.claude.json)`), the most common reason
  of that step with a pointer to `mm history` when there are others; it used to print a guess,
  `(in use/whitelisted)`.
- A spinner on the terminal while marmot checks what is in use and while `mm purge` scans; the
  `mm analyze` overview names the folder it is still measuring. Never on stdout, without a
  terminal, or with `--json`.
- `mm history` ends with the story so far: `Since 2026-10-12: 7 runs · 4.2GB freed · 300.0MB to
  Trash · 2 refused`, then the three biggest single wins. It replaces the "All-time" total, which
  was wrong once the log had rotated twice.
- Closing banners name the run's biggest win (`Biggest win: Developer caches, 2.1GB`) and say
  when it brought the root disk back under a health threshold (`Disk 91% → 84%: back under
  90%`); the 80/90% thresholds live in one place in core, shared with `mm status`. The
  uninformative `Categories: N` is gone.
- A run with nothing to do ends as the success it is (`✓ Nothing to clean: this machine is
  already tidy.`) with when the next scheduled cleanup is due, or how to schedule one, instead of
  a banner of zeros; `mm purge` likewise. Section headings with nothing under them are no longer
  printed.
- The first terminal run after scheduled cleanups says what they did, once: `While you were
  away: 3 scheduled runs freed 4.2GB` (plus the Trash and failures, pointing at `mm schedule
  status`). Dry runs and runs without a terminal leave it for later.
- A real terminal run that carries marmot's lifetime freed total (as `mm history` counts it)
  across 10, 50, 100, 250 or 500 GB or 1 TB says so in its banner, once per milestone. The banner
  also celebrates marmot's first cleanup on a machine, its 10th, 100th and 1000th, a new record
  for one run (1GB or more), and, on their day, the anniversary of its first run and last year's
  review in the first week of January; each once.
- `mm status`: the marmot has more moods, still health first: `- o` with a mug of coffee beside its
  paw on the night shift (an agent busy between midnight and 6:00), `= =` tired (an agent session
  busy for over 12 hours), `^ ^ +*` proud the day after a cleanup that freed 1GB or more ("freed
  4.2GB last night" beside the title), and stuffed cheeks when a full disk is why it is alert or
  dizzy. It wears a hard hat (a dome with a ridge and a brim) while a marmot cleanup runs. In the
  live view it blinks like something alive: 2 to 8 s apart at random, closing and opening through a
  half lid in under 200 ms, now and then twice; a blink repaints only the eyes' row.
- The marmot keeps a calendar (`lib/mascot.sh`): a party hat (a pointed, starred cone on the top of
  its head) and fireworks at New Year, a Santa hat (a solid red cap whose tip curls over and drops
  its pom-pom just under the crease, on a fur band between the ears) at Christmas, snow on the rule
  all winter, vampire fangs and a spider's web in Halloween week (on the 31st a jack-o'-lantern
  beside its head and `∆ ∆` eyes), papel picado, marigolds and calavera eyes on Día de Muertos
  remembering the biggest item it ever freed, a lightsaber in its paw on May 4, a tree on Earth Day,
  Thanksgiving's total, last year's review in the first week of January, the anniversary of its
  first run here, and about twenty more (Pi Day, Towel Day, Sysadmin Day, the 256th day, Debian Day,
  Linux's birthday, World Backup Day, Ada Lovelace Day, Friday the 13th, a round Unix time...). Tall
  decorations get a sky row above its head. Decorations never replace a face that reports a problem.
  They show in the `mm status` header, after `mm --version` on a terminal, on the line of a run with
  nothing to do, and in `install.sh`'s closing art. Everything the marmot draws is printable ASCII
  plus `∆` (one column, not an emoji, in the common monospace fonts): no emoji, no glyph from a
  fallback font.
- `festive = off` in `~/.config/marmot/config` turns the marmot's calendar off (seasons,
  holidays, anniversaries, the year in review); its moods, the milestones and the easter eggs
  stay. Default on.
- A few easter eggs, in neither the help nor the completion: `--force` is refused with a wink
  (marmot has none; nothing runs), `mm 42`, `mm make me a sandwich` (xkcd 149: root gets one),
  and the live `mm status` raises a paw beside its face on `w`.

### Changed

- Times read like speech, the same everywhere: `mm schedule status` says the next run as `in 9h
  (03:27)` instead of systemd's timestamp, a weekly crontab line runs `on Sunday` (not `day 0`),
  durations read `12m 34s` (not `754s`), and anything under a minute ago is `just now` (not
  `0m`). One family of formatters in core (`mm_ago`, `mm_dur`, `mm_when`) serves `mm status`,
  `mm schedule`, `mm optimize` and the banners.
- Colors follow each stream: an error redirected to a file (`2>log`) carries no escape codes
  even when the screen gets color, and `TERM=dumb` turns colors off like `NO_COLOR`.
- `mm status` prints sizes like the rest of marmot (`705.0MB`, `3.4GB`), not `705 MB`.
- Every usage error points at the command's help, `mm history` included (`unknown option: -x
  (see mm history --help)`).
- `mm clean`'s "Kept for you to review" list marks entries with `◎`, the symbol marmot uses for
  everything it leaves alone, instead of a one-off `◦`.
- One tagline everywhere: `mm --help` and the entry point say what the README says ("the
  machines your coding agents run on, clean, fast and healthy").
- Titles and banner titles are in sentence case everywhere (`Clean your system`, `Dry run
  complete`, `Optimization complete`).
- Closing banners share one shape: what was (or would be) freed, `Moved to Trash` only when
  something went there (`mm uninstall` printed `Moved to Trash: 0B`), the command's counts, and a
  free-space change signed the same way everywhere (`mm purge` and `mm uninstall` clamped it to
  `+`); every dry run ends with `Free space: X now, ~Y after`.
- CI runs once per pull request, as one job; `tests/run.sh` runs bats with `--jobs $(nproc)` when
  GNU parallel is installed (as on the runner), files that set `BATS_NO_PARALLELIZE_WITHIN_FILE`
  staying serial inside. Docs-only changes skip it.
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
- Shell completion (bash and zsh) completes after global flags (`mm -n clean --`), offers each
  command's options, `help` topics, `analyze` for `analyse`, and `schedule` subcommands.

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
  in-use check, which then sees every user's processes. The session stays alive for the whole run,
  like Mole's: a background `sudo -n -v` refreshes sudo's cache, so a run longer than the cache
  does not fail its later root steps. Refused, failed or no sudo: the rest of the run asks nothing
  more and skips each root step with "needs sudo". It used to prompt again
  for every system step, up to `sudo: 3 incorrect password attempts` and beyond. Without a
  terminal, as root and with passwordless sudo nothing changes.
- `mm clean` empties bun's cache again: bun 1.3 refuses `bun pm cache rm` from `/` ("No
  package.json was found"), so the step failed while its dry run promised the whole cache. bun
  now runs from a folder marmot makes with an empty `package.json`, which no project's
  `bunfig.toml` can redirect, and the `bun x` packages that command also clears are counted.
- Dry runs of the steps marmot hands to a tool (npm, bun, yarn, pnpm, uv, conda, Homebrew, nix)
  ask the tool the same read-only question a real run does, from the same folder with the same
  environment. When it fails, the dry run shows the step failing with the tool's message and counts
  nothing, as the real run does, instead of guessing a cache folder and promising its size. A
  prune no tool can preview (uv, mise, pnpm, and `mm schedule`'s pnpm store prune after a purge)
  shows "up to" or "about" and counts nothing. Real runs count what actually went: `mm uninstall`
  measures each npm, bun, pipx and uv package's folder (and runs those tools from `/`, so a
  project's `.npmrc` or `bunfig.toml` cannot change the target), `docker image rm` counts the
  untagged images it removed when others fail, and `docker builder prune` counts docker's own
  "Total reclaimed space". Sizes that are only estimates (dpkg's Installed-Size, `docker builder
  du`) say "about".
- The in-use check works on a full disk. With no room left in the temp folder, a snapshot over
  64 KiB (a machine with many processes) stopped `mm clean` and `mm purge` with "could not list
  in-use paths", and a lookup in one already taken answered "not in use": bash kept those long
  strings in temp files. They now go through pipes.

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
