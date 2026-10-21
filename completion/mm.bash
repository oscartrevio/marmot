# bash completion for marmot (mm). Source from ~/.bashrc.
_mm() {
  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]:-}
  if (( COMP_CWORD == 1 )); then
    mapfile -t COMPREPLY < <(compgen -W "clean status analyze optimize purge uninstall schedule history update -h --help -v --version" -- "$cur")
    return
  fi
  local opts="--dry-run -n --debug --help"
  case "$cmd" in
    clean)     opts+=" --sessions --whitelist" ;;
    status)    opts="--once --json --agent --view --interval --help"
               if [[ "${COMP_WORDS[COMP_CWORD-1]}" == --view ]]; then
                 mapfile -t COMPREPLY < <(compgen -W "compact full" -- "$cur"); return
               fi ;;
    analyze)   opts+=" --json" ;;
    purge)     opts+=" --yes -y --all --days --paths" ;;
    uninstall) opts+=" --list -l --all -a --app-data" ;;
    history)   opts="--json --all --limit -l --help" ;;
    schedule)
      if (( COMP_CWORD == 2 )) && [[ "$cur" != -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "status enable disable run" -- "$cur"); return
      fi
      opts="--dry-run -n --help"
      [[ "${COMP_WORDS[2]:-}" == enable ]] && opts+=" --daily --weekly" ;;
    update)    opts+=" --check" ;;
  esac
  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
  elif [[ "$cmd" == analyze || "$cmd" == purge ]]; then
    mapfile -t COMPREPLY < <(compgen -d -- "$cur")
  fi
}
complete -F _mm mm marmot
