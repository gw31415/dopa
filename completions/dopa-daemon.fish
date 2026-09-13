# fish completion for dopa-daemon.
# Mirrors Sources/DopaDaemonCLI/main.swift (parse()).
#
# Exclusions (expressed via -n conditions):
#   - top level: subcommands are hidden once --help/-h is on the line
#   - once a subcommand is entered, only its own options are offered
#   - install: --user and -h/--help are mutually exclusive and each is
#     offered only once; a dangling "--user" or a "--user=" prefix completes
#     account names only
#   - status: --json and -h/--help are mutually exclusive, --json only once
#   - uninstall/start/stop/restart/run: only -h/--help, once
#   - like the parser, once an unknown argument makes the invocation an
#     error, nothing more is offered

# fish only completes options for tokens starting with "-", and dopa-daemon
# takes no file arguments; suppress the default file completion outright.
complete -c dopa-daemon -f

function __dopa_daemon_subcommand
    # Print the subcommand token if one has been entered before the cursor.
    set -l tokens (commandline -opc)
    if set -q tokens[2]
        and not string match -q -- '-*' $tokens[2]
        printf '%s\n' $tokens[2]
        return 0
    end
    return 1
end

function __dopa_daemon_no_subcommand
    not __dopa_daemon_subcommand >/dev/null
end

function __dopa_daemon_using --argument-names wanted
    set -l current (__dopa_daemon_subcommand)
    test "$current" = "$wanted"
end

function __dopa_daemon_help_seen
    # True when -h/--help appears before the cursor. A token consumed as the
    # value of "--user TOKEN" is skipped, like the parser does.
    set -l tokens (commandline -opc)
    set -e tokens[1]
    set -l skip_next 0
    for token in $tokens
        if test $skip_next -eq 1
            set skip_next 0
            continue
        end
        if test "$token" = --user
            set skip_next 1
            continue
        end
        if test "$token" = --help; or test "$token" = -h
            return 0
        end
    end
    return 1
end

function __dopa_daemon_user_seen
    # True when a complete --user spec is on the line: "--user VALUE" or
    # "--user=VALUE" (non-empty). A trailing "--user" still awaits a value.
    set -l tokens (commandline -opc)
    set -e tokens[1]
    set -e tokens[1]
    set -l skip_next 0
    for token in $tokens
        if test $skip_next -eq 1
            return 0
        end
        if test "$token" = --user
            set skip_next 1
        else if string match -q -- '--user=?*' $token
            return 0
        end
    end
    return 1
end

function __dopa_daemon_awaiting_user
    # The word before the cursor is a "--user" still missing its value.
    set -l tokens (commandline -opc)
    test "$tokens[-1]" = --user
end

function __dopa_daemon_args_all_help
    # True when every token after the subcommand is --help or -h: the only
    # non-erroring arguments of the argument-less subcommands.
    set -l tokens (commandline -opc)
    set -e tokens[1]
    set -e tokens[1]
    for token in $tokens
        if test "$token" = --help; or test "$token" = -h
            continue
        end
        return 1
    end
    return 0
end

function __dopa_daemon_install_args_valid
    # True when every install token is --help, -h, "--user VALUE" or
    # "--user=VALUE"; anything else makes the invocation an error.
    set -l tokens (commandline -opc)
    set -e tokens[1]
    set -e tokens[1]
    set -l skip_next 0
    for token in $tokens
        if test $skip_next -eq 1
            set skip_next 0
            continue
        end
        if test "$token" = --user
            set skip_next 1
            continue
        end
        if test "$token" = --help; or test "$token" = -h
            continue
        end
        if string match -q -- '--user=?*' $token
            continue
        end
        return 1
    end
    return 0
end

# Top level: subcommands plus help; nothing once --help/-h is on the line.
complete -c dopa-daemon -f \
    -n '__dopa_daemon_no_subcommand; and not __dopa_daemon_help_seen' \
    -a 'install\t"Install or update the launchd-managed daemon" uninstall\t"Stop the daemon and remove its managed files" start\t"Start an installed daemon and wait until it is ready" stop\t"Restore active sessions and stop the daemon safely" restart\t"Safely stop, start, and verify the daemon" status\t"Show the daemon snapshot (--json emits one JSON object)" run\t"Run the foreground launchd service"'
complete -c dopa-daemon -f \
    -n '__dopa_daemon_no_subcommand; and not __dopa_daemon_help_seen' \
    -s h -l help -d 'Print help'

# install [--user NAME|UID]
complete -c dopa-daemon -f \
    -n '__dopa_daemon_using install; and not __dopa_daemon_help_seen; and not __dopa_daemon_user_seen; and not __dopa_daemon_awaiting_user; and __dopa_daemon_install_args_valid' \
    -s h -l help -d 'Print help'
complete -c dopa-daemon -f \
    -n '__dopa_daemon_using install; and not __dopa_daemon_help_seen; and not __dopa_daemon_user_seen; and __dopa_daemon_install_args_valid' \
    -l user -x -a '(__fish_complete_users)' -d 'Run the daemon as this account name or UID'

# status [--json]
complete -c dopa-daemon -f \
    -n '__dopa_daemon_using status; and not __dopa_daemon_help_seen; and not __fish_contains_opt json; and __dopa_daemon_args_all_help' \
    -l json -d 'Emit one JSON object'
complete -c dopa-daemon -f \
    -n '__dopa_daemon_using status; and not __dopa_daemon_help_seen; and not __fish_contains_opt json; and __dopa_daemon_args_all_help' \
    -s h -l help -d 'Print help'

# uninstall/start/stop/restart/run: help only, once.
for cmd in uninstall start stop restart run
    complete -c dopa-daemon -f \
        -n "__dopa_daemon_using $cmd; and not __dopa_daemon_help_seen; and __dopa_daemon_args_all_help" \
        -s h -l help -d 'Print help'
end
