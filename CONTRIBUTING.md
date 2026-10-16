# Contributing to marmot

marmot is bash 5 for Debian 12+ and Ubuntu 22.04+. Read [AGENTS.md](AGENTS.md) for the repo map
and the rules below in short form, and [SECURITY.md](SECURITY.md) for what the deletion gate
promises.

## Setup

- bats-core 1.5 or newer. Debian 12 and Ubuntu 24.04 ship one (`apt-get install bats`); Ubuntu
  22.04 ships 1.2, so install a release: `tests/run.sh` prints the commands.
- shellcheck, jq and python3. Tests that need jq or python3 skip without them, so install them to
  run the whole suite.
- docker, for the end-to-end scenario only.

## Running the checks

```sh
tests/run.sh                    # shellcheck on every shell source, then the whole bats suite
tests/run.sh tests/purge.bats   # shellcheck, then one file
tests/e2e/run.sh [IMAGE] [--root] [--minimal]   # a real run in a throwaway container
```

Tests run in a throwaway `HOME` under `$BATS_TEST_TMPDIR`. Commands that change the machine (sudo,
apt, docker, npm, systemctl, ...) are replaced by stubs that fail the test when called; a test
that needs one installs a fake with `mm_test_fake` (`tests/helpers/common.bash`). Run the e2e
scenario before changing what gets deleted: it needs network access and touches nothing outside
the container.

## Deletion rules

- Every deletion goes through `mm_rm PATH ALLOWED_ROOT` (`--trash` for personal things), or
  through a tool's own documented clean command run by `mm_run`. Pass the narrowest root.
- A raw `rm`, `rmdir`, `unlink` or `find -delete` needs `# SAFE: <reason>` on the same line;
  `tests/audit.bats` fails without it. Keep it to marmot's own files (temp files, its units) and
  sets the user confirmed that are re-checked right before the `rm`.
- When a check cannot decide (a probe fails, a size is unknown, a file changed), keep the thing
  and say why. Refuse rather than guess.
- `--dry-run` changes nothing and reports the same items and byte counts a real run would.
- A new protection gets a line in `tests/fixtures/dangerous_paths.txt` or a test in
  `tests/core.bats` showing `mm_rm` refuses it.

## Adding a cache or an agent

- A cache: a row in the table in `lib/catalog.sh`; the header explains `cache`, `revisions` and
  `report` rows, the busy processes and the spec field, and lists stores that are deliberately
  not caches. Users add their own rows in `~/.config/marmot/catalog`.
- An agent or orchestrator: a row in `lib/agents.sh`; its header explains each field and cites
  where each logs dir is documented. Users add rows in `~/.config/marmot/agents`.
- Name only paths the tool documents, and add a test in `tests/clean.bats` or
  `tests/agents.bats` that builds the folder and checks what goes and what stays.

## Tests

Assert behavior: which files exist afterwards, what `mm history` recorded, the exit code, the
fields of `--json` output. Do not pin wording or layout unless the wording is the behavior (a
refusal reason a user acts on). A new test should fail without your change.

## Commits and pull requests

Commit messages follow the history: a conventional subject, `type(scope): summary` in the
imperative and lower case (`fix(clean): keep the Go module cache ...`, `perf(purge): ...`,
`docs: ...`; types `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `ci`). The body, wrapped at
100 columns, explains why: what went wrong or was missing, what changes for the user, and numbers
when you claim a speedup. User-visible changes also get a line in `CHANGELOG.md` under Unreleased.

CI runs `tests/run.sh` once per pull request on Ubuntu 24.04; changes to Markdown files only skip
it. It does not run the e2e scenario.

## License

marmot is MIT-licensed; your contribution is licensed the same way.
