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
  `harness`, `install`, `personal` (the unattended-safety corpus); `tests/helpers/common.bash`
  is the sandbox; `tests/e2e/` the container run.

## Safety rules

- Delete only through `mm_rm PATH ALLOWED_ROOT` (`--trash` for anything personal), or a tool's
  own documented clean command through `mm_run`. Pass the narrowest allowed root. Never a tool
  mode that destroys data beyond the named target (`--purge`, `prune`, `--force`);
  `tests/audit.bats` pins the allowed forms.
- A raw `rm`, `rmdir`, `unlink` or `find -delete` needs `# SAFE: <reason>` on its line;
  `tests/audit.bats` enforces it. Do not add one to get around `mm_rm`.
- Unattended deletion needs positive proof of regenerability: a manifest or tool marker next to
  the item, plus git-ignored for generic names. A name, a `CACHEDIR.TAG` or an age alone is
  only enough behind a picker. `tests/personal.bats` holds the corpus every unattended run must
  leave untouched; extend it with every new rule.
- When unsure, keep the file. A failed probe, an unknown size, an unreadable whitelist, a
  partial or missing in-use snapshot means "keep", never "nothing there" or 0 bytes.
- Protections compare the path as written and as resolved; a resolved path never grants what
  the literal lacked. Re-check at the sink, right before the deletion, not only at discovery.
- `--dry-run` changes nothing and reports the same items and numbers as a real run.
- Without a terminal, prompts decline and pickers select nothing. Prompts list every item they
  act on (no "+N more"), take whole-word answers, and anything unrecognized means no. Keep it
  that way.
- Refusals name their reason (`used by ~/.claude.json`); a user must be able to act on it.
- Process checks read `/proc`; no `pgrep`, `pkill`, `fuser` (`tests/audit.bats` checks).

## Non-goals

- No global `--yes`: `marmot` rejects it for every command but `mm purge`, where it covers stale
  build artifacts only. `mm schedule run` has a fixed profile the README lists; do not widen it.
- No deleting agent state, sessions or memory (unless the user opts in), credentials,
  `~/.config`, app data (`~/.NAME`, `~/.local/share/NAME`) without `--app-data`, the Trash
  without `trash_keep_days`, or anything in another account's home.
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
| what gets deleted | the above, then `tests/run.sh tests/personal.bats` and `tests/e2e/run.sh` (needs docker) |

`tests/run.sh` always runs shellcheck on every shell source first. Run the whole suite
(`tests/run.sh`) before you hand a change back. Tests assert behavior (files left, history rows,
exit codes, JSON fields), not wording. A new rule needs a test that fails without it.

CI runs `tests/run.sh` once per pull request (`.github/workflows/test.yml`); Markdown-only changes
skip it. It does not run the e2e scenario.

## Commits

`type(scope): summary`, lower case, imperative (`fix(clean): ...`, `perf(purge): ...`), then a
body wrapped at 100 columns that explains why. User-visible changes get a `CHANGELOG.md` line.
