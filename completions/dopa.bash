# bash completion for dopa.
# Mirrors Sources/DopaCLI/main.swift (Options.parse): options only, no
# positional arguments; a bare "--" ends option parsing and every later
# argument is an error, so nothing is completed after it.
#
# Mutual exclusions offered here:
#   - once --help/-h is on the line, no other options are offered
#   - once -d/--keep-display-on (or -l/--stop-on-lid-close) is on the line,
#     --help/-h is no longer offered (short clusters like -dl count too)
#   - each flag is offered at most once

_dopa() {
  local cur i w typed
  cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  # Flags already present on the line (scanning stops at a bare "--").
  local seen_d=0 seen_l=0 seen_h=0
  for ((i = 1; i < COMP_CWORD; i++)); do
    w="${COMP_WORDS[i]}"
    case "$w" in
      --)
        return 0
        ;;
      --keep-display-on)
        seen_d=1
        ;;
      --stop-on-lid-close)
        seen_l=1
        ;;
      --help)
        seen_h=1
        ;;
      --*)
        # Unknown long option: the invocation is already an error.
        return 0
        ;;
      -[!-]*)
        # Short-option cluster (-d, -dl, -ld, ...). Only d, l and h are valid.
        case "${w#-}" in
          *[!dlh]*) return 0 ;;
        esac
        case "$w" in *d*) seen_d=1 ;; esac
        case "$w" in *l*) seen_l=1 ;; esac
        case "$w" in *h*) seen_h=1 ;; esac
        ;;
      *)
        # dopa accepts no positional arguments.
        return 0
        ;;
    esac
  done

  # Once --help/-h appears the CLI just prints help; offer nothing else.
  if (( seen_h )); then
    return 0
  fi

  local candidates=()
  case "$cur" in
    --*)
      # dopa only accepts exact long-option spellings.
      (( ! seen_d && ! seen_l )) && candidates+=(--help)
      (( ! seen_d )) && candidates+=(--keep-display-on)
      (( ! seen_l )) && candidates+=(--stop-on-lid-close)
      ;;
    -*)
      # Short-option cluster being typed: extend it with flags that are still
      # unused. Help is offered only while no -d/-l is on the line or typed.
      typed="${cur#-}"
      if [[ "$typed" != *[!dlh]* ]]; then
        if [[ "$typed" != *d* && "$typed" != *h* ]] && (( ! seen_d )); then
          candidates+=("-${typed}d")
        fi
        if [[ "$typed" != *l* && "$typed" != *h* ]] && (( ! seen_l )); then
          candidates+=("-${typed}l")
        fi
        if [[ "$typed" != *h* && "$typed" != *d* && "$typed" != *l* ]] \
          && (( ! seen_d && ! seen_l )); then
          candidates+=("-${typed}h")
        fi
      fi
      ;;
    *)
      # No positional arguments exist; only still-unused options remain.
      (( ! seen_d )) && candidates+=(-d --keep-display-on)
      (( ! seen_l )) && candidates+=(-l --stop-on-lid-close)
      (( ! seen_d && ! seen_l )) && candidates+=(-h --help)
      ;;
  esac

  if (( ${#candidates[@]} )); then
    COMPREPLY=( $(compgen -W "${candidates[*]}" -- "$cur") )
  fi
  return 0
}

complete -F _dopa dopa
