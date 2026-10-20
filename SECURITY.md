# Security policy

marmot deletes files, sometimes as root and sometimes unattended. A bug in what it deletes is a
security bug, and we treat it as one.

## Reporting a vulnerability

Report privately through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Do not open a public issue for a problem that is not fixed yet. There is no
security email address.

Please include:

- the marmot commit you installed from (`git log -1` in that checkout);
- the distribution and release, and whether it ran as root, with sudo, in a container or WSL2;
- the exact command, and the lines `mm history` shows for it;
- steps to reproduce, ideally a script that builds the files in a throwaway `HOME`.

We aim to acknowledge a report within a week. marmot is maintained by one person, so fixes take
the time they take; we will tell you what we found and agree on disclosure once a fix is out.

## What counts

- Deleting or trashing anything outside the folder a step was given, or a protected path.
- Getting past the in-use, reference, whitelist or credential checks.
- Symlink, mount or race tricks that make the deletion gate act on something it should refuse.
- Running anything with sudo beyond what the README documents.
- `install.sh` or `mm schedule` writing, removing or running more than documented.
- Outbound network access beyond the list in the README's "Network access" section.

## What does not

- Deleting something a documented rule says is regenerable (a cache, a build artifact, an old log).
- Something you confirmed at a prompt that named it, or picked in a picker.
- A root user deliberately bypassing the checks (editing marmot, calling `rm` themselves).

But: a rule that also matches things that are not regenerable, or a prompt that acts on items it
never showed, is a bug of the first kind. Report it.

## Threat model

marmot defends against mistakes: its own bugs, a user's typo, an agent running it unattended. It
does not defend against a hostile local root or a user who edits its code; such a user can delete
anything without marmot.

The lines it does not cross (`lib/core.sh`, `mm_rm`):

- Files are deleted or trashed by `mm_rm` (exceptions below), strictly inside the step's allowed
  root after resolving parent symlinks. A symlink is removed as a link; `rm` runs with
  `--one-file-system`.
- Never `/`, the home folder, `/home`, a home under `/home`, another account's home (also when a
  scan root points into it), `/tmp`, `/var/tmp` or `/var` itself; never anything inside the OS
  trees (`/etc`, `/usr`, `/boot`, `/var/lib`, `/var/log`, ...), `/opt`, `/srv`, `/mnt`,
  `/media`, `~/.ssh`, `~/.gnupg`, or `/root` unless `HOME` is `/root`.
- Never the built-in credential folders (`~/.aws`, `~/.kube`, `~/.docker`, `~/.netrc`, ...),
  `~/.config` or agent state, nor your whitelist, nor any folder above such an entry; all of
  them also behind symlinks, on the path as written and as resolved. Where a log or cache folder
  inside them is opened up, names that look like keys or tokens stay refused. An unreadable
  whitelist refuses everything; whitelist entries match as written and resolved, and entries
  that can match nothing are reported.
- Never what a process uses, a mount point or bind-mount source (spaces and other escapes
  decoded, other mount namespaces mapped in), or what a launcher, tool config, systemd unit,
  the crontab (including `cd DIR &&` and `WorkingDirectory=` forms) or a shell startup file
  names. No snapshot means everything counts as in use; a partial snapshot is warned; the check
  runs again right before each deletion.
- Never an item whose size cannot be read, or that changed (device, inode, ctime, location) while
  it was being sized. Trash moves are same-filesystem renames and never fall back to deletion.
- Without a terminal every prompt declines and every picker selects nothing. Prompts that remove
  packages, containers, images, worktrees or build artifacts name every item; bulk steps (Trash
  items, logs, crash dumps, sessions) state the count and the size. `mm schedule run` never uses
  sudo, and it touches the Trash and agent sessions only with their config opt-ins
  (`trash_keep_days`, `sessions_keep_days`).
- No environment variable switches a protection off.

Outside `mm_rm`, system state changes only through the owning tool (`apt-get`, `journalctl`,
`snap`, `docker`, `git worktree remove`, package managers' clean commands) via `mm_run`, never
in a mode that destroys data beyond the named target: apt removes and never purges wholesale,
snaps are snapshotted before removal, Docker items go by id after a listing, worktrees are
removed one at a time with their ignored files accounted for. Rotated logs and crash dumps
under `/var` are removed after you confirm by a fixed root script that re-checks each file
(same inode, still old, not open) and stops when it cannot read the open-file set. Every other
raw `rm` carries a `# SAFE:` reason; `tests/audit.bats` enforces the marker and the tool modes,
and `tests/personal.bats` holds a corpus of personal data that every unattended run must leave
byte for byte.

Known limit: a process that can write to an item's parent folder can still swap it between the
final identity check and the `rm`. That needs a hostile local user, which is outside this model.
