# bash completion for marmot (mm). Source from ~/.bashrc.
# Option lists follow each command's usage in cmd/*.sh; keep them in step with it.

_mm_commands="clean status analyze optimize purge uninstall schedule history update"

# _mm_find_command — sets _mm_cmd (analyse becomes analyze) and _mm_pos, the word index of the
# command: the first word after mm that is not a global flag. Empty when no command is typed yet.
_mm_find_command() {
  local i w
  _mm_cmd="" _mm_pos=0
  for (( i = 1; i < COMP_CWORD; i++ )); do
    w=${COMP_WORDS[i]}
    case "$w" in -n|--dry-run|--debug|-y|--yes) continue ;; esac
    _mm_cmd=$w _mm_pos=$i
    break
  done
  [[ "$_mm_cmd" == analyse ]] && _mm_cmd=analyze
  return 0
}

# _mm_reply WORDS — COMPREPLY: the WORDS that start with the current word.
_mm_reply() {
  mapfile -t COMPREPLY < <(compgen -W "$1" -- "$cur")
}

_mm() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]:-}
  local _mm_cmd _mm_pos opts="-n --dry-run --debug -h --help" sub
  _mm_find_command

  if [[ -z "$_mm_cmd" ]]; then
    if [[ "$cur" == -* ]]; then _mm_reply "-n --dry-run --debug -h --help -v --version"
    else _mm_reply "$_mm_commands"
    fi
    return
  fi

  case "$_mm_cmd" in
    help)
      (( COMP_CWORD == _mm_pos + 1 )) && _mm_reply "$_mm_commands"
      return ;;
    clean)     opts+=" --sessions --whitelist" ;;
    status)    opts+=" --once --json --agent --view --interval" ;;
    analyze)   opts+=" --json" ;;
    purge)     opts+=" --days --all -y --yes --paths" ;;
    uninstall) opts+=" --list -l --all -a --app-data" ;;
    history)   opts+=" --json --all --limit -l" ;;
    schedule)
      if (( COMP_CWORD == _mm_pos + 1 )) && [[ "$cur" != -* ]]; then
        _mm_reply "status enable disable run"
        return
      fi
      sub=${COMP_WORDS[_mm_pos+1]:-}
      [[ "$sub" == enable ]] && opts+=" --daily --weekly" ;;
    update)    opts+=" --check" ;;
    optimize)  ;;
    *)         return ;;
  esac

  if [[ "$cur" == -* ]]; then
    _mm_reply "$opts"
  elif [[ "$prev" == --view ]]; then
    _mm_reply "compact full"
  elif [[ "$_mm_cmd" == analyze || "$_mm_cmd" == purge ]]; then
    mapfile -t COMPREPLY < <(compgen -d -- "$cur")
  fi
}
complete -F _mm mm marmot
