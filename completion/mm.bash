# bash completion for marmot (mm). Source from ~/.bashrc.
_mm() {
  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]:-}
  if (( COMP_CWORD == 1 )); then
    mapfile -t COMPREPLY < <(compgen -W "clean status analyze optimize purge uninstall history --help --version" -- "$cur")
    return
  fi
  local opts="--dry-run -n --debug --help"
  case "$cmd" in
    clean)     opts+=" --days --whitelist" ;;
    status)    opts="--once --json --interval --help" ;;
    analyze)   opts+=" --json" ;;
    purge)     opts+=" --yes -y --all --days --paths" ;;
    history)   opts="--json --all --limit -l --help" ;;
  esac
  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
  elif [[ "$cmd" == analyze || "$cmd" == purge ]]; then
    mapfile -t COMPREPLY < <(compgen -d -- "$cur")
  fi
}
complete -F _mm mm marmot
