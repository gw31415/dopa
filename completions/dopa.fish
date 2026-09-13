# fish completion for dopa.
# Mirrors Sources/DopaCLI/main.swift (Options.parse): options only, no
# positional arguments; nothing is completed after a bare "--".
#
# Exclusions (expressed via -n conditions):
#   - once --help/-h is on the line, no other options are offered
#   - once -d/--keep-display-on or -l/--stop-on-lid-close is on the line
#     (short clusters like -dl count), --help/-h is no longer offered
#   - each flag is offered at most once

# fish only completes options for tokens starting with "-", and dopa takes no
# file arguments; suppress the default file completion outright.
complete -c dopa -f

function __dopa_after_ddash
    # True once a bare "--" appears before the cursor.
    contains -- -- (commandline -opc)
end

function __dopa_flag_seen --argument-names short long
    # True when the long spelling is on the line, or any short-option
    # cluster ("-d", "-dl", ...) before the cursor contains the letter.
    for token in (commandline -opc)
        test "$token" = "$long"
        and return 0
        string match -q -- '-*' $token
        and not string match -q -- '--*' $token
        and string match -q -- "*$short*" $token
        and return 0
    end
    return 1
end

complete -c dopa -f \
    -n 'not __dopa_after_ddash; and not __dopa_flag_seen h --help; and not __dopa_flag_seen d --keep-display-on' \
    -s d -l keep-display-on -d 'Prevent idle display sleep (default: off)'
complete -c dopa -f \
    -n 'not __dopa_after_ddash; and not __dopa_flag_seen h --help; and not __dopa_flag_seen l --stop-on-lid-close' \
    -s l -l stop-on-lid-close -d 'End this session when the lid closes (default: off; also exits if already closed)'
complete -c dopa -f \
    -n 'not __dopa_after_ddash; and not __dopa_flag_seen h --help; and not __dopa_flag_seen d --keep-display-on; and not __dopa_flag_seen l --stop-on-lid-close' \
    -s h -l help -d 'Print help (no daemon connection required)'
