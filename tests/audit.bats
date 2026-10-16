#!/usr/bin/env bats
# Source audits: every raw deletion outside mm_rm must say why it is safe, so a new `rm -rf "$x"`
# cannot slip in unreviewed.

setup() { load helpers/common; }

# Lines that delete: rm/rmdir/unlink/shred commands given a flag, quoted/variable or absolute
# argument (incl. `npm rm -g`, `docker rm "$id"`), and find -delete. Comment lines are skipped.
_sinks() {
  grep -snHE '(^|[;&|({[:space:]])(command[[:space:]]+)?(/usr)?(/bin/)?(rm|rmdir|unlink|shred)[[:space:]]+[-"$/~]|[[:space:]]-delete([[:space:];)]|$)' \
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
