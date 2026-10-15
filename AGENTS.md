# marmot agent guide

The contract for AI agents working on this repository. Humans read
[CONTRIBUTING.md](CONTRIBUTING.md); the gate's promises are in [SECURITY.md](SECURITY.md).

marmot (`mm`) is a bash 5 cleaner and monitor for Debian 12+ and Ubuntu 22.04+ machines that run
coding agents. It must never delete what an agent or tool still uses.

## Repo map

- `marmot`: entry point; parses global options and dispatches to `cmd/<command>.sh`.
- `lib/core.sh`: UI, sizing, sudo, in-use snapshot and references, whitelist, the `mm_rm`
  deletion gate, `mm_run`, the operations log.
- `lib/catalog.sh`: the caches, builds and stores `mm clean` knows; format in its header.
- `lib/agents.sh`: known agents (state, sessions, versions, worktrees, logs, helpers); format in
  its header.
- `lib/schedule.sh`: shared facts of `mm schedule` for `mm status`.
- `cmd/*.sh`: one file per command (clean, purge, status, analyze, optimize, uninstall, schedule,
  history, update).
- `install.sh`, `completion/`: installer and bash/zsh completion.
- `tests/*.bats`: one file per command plus `core`, `references`, `agents`, `audit`, `cli`,
  `harness`, `install`; `tests/helpers/common.bash` is the sandbox; `tests/e2e/` the container run.

## Safety rules

- Delete only through `mm_rm PATH ALLOWED_ROOT` (`--trash` for anything personal), or a tool's
  own documented clean command through `mm_run`. Pass the narrowest allowed root.
- A raw `rm`, `rmdir`, `unlink` or `find -delete` needs `# SAFE: <reason>` on its line;
  `tests/audit.bats` enforces it. Do not add one to get around `mm_rm`.
- When unsure, keep the file. A failed probe, an unknown size, an unreadable whitelist or a
  missing in-use snapshot means "keep", never "nothing there" or 0 bytes.
- `--dry-run` changes nothing and reports the same items and numbers as a real run.
- Without a terminal, prompts decline and pickers select nothing. Keep it that way.
- Refusals name their reason (`used by ~/.claude.json`); a user must be able to act on it.
- Process checks read `/proc`; no `pgrep`, `pkill`, `fuser` (`tests/audit.bats` checks).

## Non-goals

- No global `--yes`: `marmot` rejects it for every command but `mm purge`, where it covers stale
  build artifacts only. `mm schedule run` has a fixed profile the README lists; do not widen it.
- No deleting agent state, sessions (unless the user opts in), credentials or `~/.config`.
- No option or variable that switches off the protected-path, in-use, reference, whitelist or
  credential checks.
- No network calls beyond the README's "Network access" list; no telemetry.
- Debian and Ubuntu only (including WSL2 and containers). No other distributions or macOS.

## Style

- `set -uo pipefail`, no `-e`; two-space indent; shellcheck clean with `.shellcheckrc`.
- `mm_` for library functions, `_<command>_` for a command's private ones, and a
  `# name ARGS — what it does` comment above each function.
- awk must work with mawk: print numbers handed back to bash with `printf "%.0f"`.
- Happy path first, guard clauses, no speculative options. Read the surrounding code and match it.

## Verifying a change

| Change | Run |
|---|---|
| `cmd/<command>.sh` | `tests/run.sh tests/<command>.bats` (`history` is in `tests/cli.bats`) |
| `lib/core.sh` gate, whitelist, sizing | `tests/run.sh tests/core.bats tests/references.bats` |
| `lib/catalog.sh` | `tests/run.sh tests/clean.bats` |
| `lib/agents.sh` | `tests/run.sh tests/agents.bats tests/status.bats` |
| `install.sh` | `tests/run.sh tests/install.bats` |
| a raw deletion or process call | `tests/run.sh tests/audit.bats` |
| what gets deleted | the above, then `tests/e2e/run.sh` (needs docker) |

`tests/run.sh` always runs shellcheck on every shell source first. Run the whole suite
(`tests/run.sh`) before you hand a change back. Tests assert behavior (files left, history rows,
exit codes, JSON fields), not wording. A new rule needs a test that fails without it.

CI runs `tests/run.sh` once per pull request (`.github/workflows/test.yml`); Markdown-only changes
skip it. It does not run the e2e scenario.

## Commits

`type(scope): summary`, lower case, imperative (`fix(clean): ...`, `perf(purge): ...`), then a
body wrapped at 100 columns that explains why. User-visible changes get a `CHANGELOG.md` line.
