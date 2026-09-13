#compdef dopa
# zsh completion for dopa.
# Mirrors Sources/DopaCLI/main.swift (Options.parse): options only, no
# positional arguments, so no "*:" spec is defined and nothing is completed
# after a bare "--".
#
# Exclusion groups implement the mutual exclusions:
#   - -d/--keep-display-on is not offered again once used, and not offered
#     after --help/-h is on the line
#   - -l/--stop-on-lid-close likewise
#   - -h/--help is offered only once and never alongside -d or -l

_dopa() {
  # After a bare "--" every further argument is an error for dopa, so offer
  # nothing once it appears before the word being completed.
  if (( ${words[(i)--]} < CURRENT )); then
    return 0
  fi
  _arguments \
    '(-d --keep-display-on -h --help)'{-d,--keep-display-on}'[prevent idle display sleep (default: off)]' \
    '(-l --stop-on-lid-close -h --help)'{-l,--stop-on-lid-close}'[end this session when the lid closes (default: off)]' \
    '(-h --help -d --keep-display-on -l --stop-on-lid-close)'{-h,--help}'[print help (no daemon connection required)]'
}

_dopa "$@"
