#!/usr/bin/env bats
# Source audits: every raw deletion outside mm_rm must say why it is safe, so a new `rm -rf "$x"`
# cannot slip in unreviewed.

setup() { load helpers/common; }

# Lines that delete: rm/rmdir/unlink/shred commands given a flag, quoted/variable or absolute
# argument (incl. `npm rm -g`, `docker rm "$id"`), also behind a quote or a backslash
# (`bash -c 'rm …'`, `\rm`), find -delete, find -exec rm and xargs rm. Comment lines are skipped.
_sinks() {
  grep -snHE "(^|[;&|({[:space:]'\"\\\\])(command[[:space:]]+)?(/usr)?(/bin/)?(rm|rmdir|unlink|shred)[[:space:]]+[-\"$/~]|[[:space:]]-delete([[:space:];)]|\$)|-exec[[:space:]]+(/bin/)?rm([[:space:]]|\$)|xargs([[:space:]]+-[^ ]+)*[[:space:]]+rm([[:space:]]|\$)" \
    "$MM_SRC/marmot" "$MM_SRC/install.sh" "$MM_SRC"/lib/*.sh "$MM_SRC"/cmd/*.sh |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

@test "every raw deletion carries a '# SAFE: <reason>' marker" {
  run bash -c "$(declare -f _sinks); MM_SRC='$MM_SRC'; _sinks | grep -v '# SAFE: [^ ]'"
  [ -z "$output" ] || { echo "unmarked deletions:"; echo "$output"; false; }
}

@test "the audit sees mm_rm's own sink (guards against a pattern that matches nothing)" {
  run bash -c "$(declare -f _sinks); MM_SRC='$MM_SRC'; _sinks"
  [[ "$output" == *"lib/core.sh"*"rm -rf --one-file-system"* ]]
}

@test "process checks read /proc, not procps or psmisc (missing from minimal images)" {
  run bash -c "grep -nE '(^|[^-[:alnum:]_./])(pgrep|pkill|pidof|fuser|killall|uptime)([^-[:alnum:]_.]|\$)' \
    '$MM_SRC/marmot' '$MM_SRC/install.sh' '$MM_SRC'/lib/*.sh '$MM_SRC'/cmd/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'"
  [ -z "$output" ] || { echo "procps/psmisc calls:"; echo "$output"; false; }
}

# Destructive modes of outside tools. The audit above covers raw deletions; these commands delete
# through a tool, where one flag turns "remove the package" into "remove its data too".
_tool_lines() {
  grep -snHE "$1" "$MM_SRC/marmot" "$MM_SRC/install.sh" "$MM_SRC"/lib/*.sh "$MM_SRC"/cmd/*.sh |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

@test "apt never purges wholesale: no 'autoremove --purge', no wildcard purge" {
  run _tool_lines 'autoremove[[:space:]]+--purge|purge[[:space:]]+.?~c'
  [ -z "$output" ] || { echo "wholesale apt purges:"; echo "$output"; false; }
}

@test "docker containers and images go by id after a listing, never by prune or force" {
  run _tool_lines 'docker[[:space:]]+(image[[:space:]]+|container[[:space:]]+|system[[:space:]]+|volume[[:space:]]+)?prune|docker[[:space:]]+(rm|rmi|image[[:space:]]+rm)[[:space:]]+(-f|--force)'
  [[ "$output" != *"image prune"* && "$output" != *"container prune"* && "$output" != *"system prune"* && "$output" != *"volume prune"* ]] ||
    { echo "unprompted docker prunes:"; echo "$output"; false; }
  # the one allowed prune: build cache older than 7 days, which no prompt can preview
  run _tool_lines 'docker[[:space:]]+builder[[:space:]]+prune'
  [[ "$output" == *"--filter until="* ]]
}

@test "git worktrees are removed one at a time, never forced, never pruned" {
  run _tool_lines 'worktree[[:space:]]+remove[[:space:]]+(-f|--force)|worktree[[:space:]]+prune'
  [ -z "$output" ] || { echo "forced or pruning worktree calls:"; echo "$output"; false; }
}

@test "a snap is purged only on the line after its snapshot is saved" {
  local hits
  hits=$(grep -snHE 'snap[[:space:]]+remove[[:space:]]+--purge' "$MM_SRC"/cmd/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#') || true
  [ -n "$hits" ]   # the uninstall path still uses --purge, behind snap save
  local line file no
  while IFS= read -r line; do
    file=${line%%:*}; no=${line#*:}; no=${no%%:*}
    sed -n "$((no - 3)),$((no))p" "$file" | grep -q 'snap save' ||
      { echo "snap remove --purge without a snap save just before: $line"; return 1; }
  done <<<"$hits"
}
