#compdef dopa-daemon
# zsh completion for dopa-daemon.
# Mirrors Sources/DopaDaemonCLI/main.swift (parse()).
#
# Exclusion groups / once-only rules:
#   - top level: subcommands are hidden once --help/-h is on the line
#   - after a subcommand, only that subcommand's options are offered
#   - install: --user and -h/--help are mutually exclusive (--user only once)
#   - status: --json and -h/--help are mutually exclusive (--json only once)
#   - uninstall/start/stop/restart/run: only -h/--help, once

_dopa_daemon() {
  local line state
  # Words before the one being completed (used at the top level).
  local -a prev
  prev=(${words[1,CURRENT-1]})

  _arguments -C \
    '(-h --help)'{-h,--help}'[print help]' \
    ':command:->command' \
    '*::argument:->argument'

  case $state in
    command)
      if (( ${prev[(I)--help]} || ${prev[(I)-h]} )); then
        return 0
      fi
      local -a commands
      commands=(
        'install:install or update the launchd-managed daemon'
        'uninstall:stop the daemon and remove its managed files'
        'start:start an installed daemon and wait until it is ready'
        'stop:restore active sessions and stop the daemon safely'
        'restart:safely stop, start, and verify the daemon'
        'status:show the daemon snapshot (--json emits one JSON object)'
        'run:run the foreground launchd service'
      )
      _describe -t commands 'dopa-daemon command' commands
      ;;
    argument)
      case $line[1] in
        install)
          _arguments \
            '(--user -h --help)--user=[run the daemon as this account name or UID]:account name or UID:_users' \
            '(-h --help --user)'{-h,--help}'[print help]'
          ;;
        status)
          _arguments \
            '(--json -h --help)--json[emit one JSON object]' \
            '(-h --help --json)'{-h,--help}'[print help]'
          ;;
        uninstall|start|stop|restart|run)
          _arguments \
            '(-h --help)'{-h,--help}'[print help]'
          ;;
      esac
      ;;
  esac
}

_dopa_daemon "$@"
