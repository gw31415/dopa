# bash completion for dopa-daemon.
# Mirrors Sources/DopaDaemonCLI/main.swift (parse()).
#
# Mutual exclusions / once-only rules offered here:
#   - top level: with --help/-h as the first token, nothing else is offered
#   - once a subcommand is entered, other subcommands are not offered
#   - install: --user and --help/-h are mutually exclusive; --user (either
#     "--user VALUE" or "--user=VALUE" spelling) is offered only once; the
#     word after a dangling "--user" completes account names only
#   - status: --json and --help/-h are mutually exclusive; --json only once
#   - uninstall/start/stop/restart/run: only --help/-h (while absent)

_dopa_daemon() {
  local cur i w
  cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  if (( COMP_CWORD <= 1 )); then
    # Completing the first token: a subcommand or top-level help.
    local top="install uninstall start stop restart status run --help -h"
    COMPREPLY=( $(compgen -W "$top" -- "$cur") )
    return 0
  fi

  local subcommand="${COMP_WORDS[1]}"
  case "$subcommand" in
    install|uninstall|start|stop|restart|status|run) ;;
    *) return 0 ;;  # --help/-h first token or unknown command: nothing more
  esac

  local help_seen=0 user_seen=0 user_pending=0 json_seen=0
  i=2
  while (( i < COMP_CWORD )); do
    w="${COMP_WORDS[i]}"
    case "$subcommand" in
      install)
        case "$w" in
          --help|-h)
            help_seen=1
            ;;
          --user)
            if (( i + 1 < COMP_CWORD )); then
              user_seen=1
              i=$((i + 1))  # the token after --user is its value
            else
              user_pending=1  # the word being completed is the value
            fi
            ;;
          --user=*)
            [ -n "${w#--user=}" ] && user_seen=1
            ;;
          *)
            return 0  # unknown install argument: already an error
            ;;
        esac
        ;;
      status)
        case "$w" in
          --help|-h) help_seen=1 ;;
          --json) json_seen=1 ;;
          *) return 0 ;;
        esac
        ;;
      *)
        case "$w" in
          --help|-h) help_seen=1 ;;
          *) return 0 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done

  local candidates=()
  case "$subcommand" in
    install)
      case "$cur" in
        --user=*)
          # Value part of the "--user=VALUE" spelling.
          if (( ! user_seen )); then
            local user
            for user in $(compgen -u -- "${cur#--user=}" | sort -u); do
              COMPREPLY+=("--user=$user")
            done
          fi
          return 0
          ;;
      esac
      if (( user_pending )); then
        # The value of a dangling "--user": account names only.
        COMPREPLY=( $(compgen -u -- "$cur" | sort -u) )
        return 0
      fi
      if (( ! user_seen && ! help_seen )); then
        candidates+=(--user --help -h)
      fi
      ;;
    status)
      if (( ! json_seen && ! help_seen )); then
        candidates+=(--json --help -h)
      fi
      ;;
    uninstall|start|stop|restart|run)
      if (( ! help_seen )); then
        candidates+=(--help -h)
      fi
      ;;
  esac

  if (( ${#candidates[@]} )); then
    COMPREPLY+=( $(compgen -W "${candidates[*]}" -- "$cur") )
  fi
  return 0
}

complete -F _dopa_daemon dopa-daemon
