# Tab completion for the test scripts. Bash.
#
#   source scripts/completions.bash          # this shell only
#
# or, to have it always:
#
#   mkdir -p ~/.local/share/bash-completion/completions
#   ln -s "$PWD/scripts/completions.bash" \
#         ~/.local/share/bash-completion/completions/run_tests.sh
#
# The block and variant lists are READ OUT OF run_tests.sh rather than repeated
# here. A completion that lists blocks which no longer exist -- or misses one
# that was just added -- is worse than no completion, because it is believed.

_uoe_scripts_dir() {
    # Where the scripts live, whether completing "./scripts/run_tests.sh",
    # "run_tests.sh" from inside scripts/, or an absolute path.
    local cmd="${COMP_WORDS[0]}"
    local dir
    dir="$(cd "$(dirname "$cmd")" 2>/dev/null && pwd)" || return 1
    [ -f "$dir/run_tests.sh" ] && { printf '%s' "$dir"; return 0; }
    return 1
}

_uoe_blocks() {
    local dir; dir="$(_uoe_scripts_dir)" || return
    # BLOCKS=( ... ) may wrap onto a second line
    sed -n '/^BLOCKS=(/,/)/p' "$dir/run_tests.sh" \
        | tr -d '\n' | sed 's/.*BLOCKS=(//; s/).*//'
}

_uoe_variants() {
    local dir; dir="$(_uoe_scripts_dir)" || return
    sed -n 's/^VARIANTS=(\(.*\))/\1/p' "$dir/run_tests.sh"
}

_uoe_complete() {
    local cur prev opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        -b) COMPREPLY=($(compgen -W "$(_uoe_blocks)" -- "$cur")); return ;;
        -t) COMPREPLY=($(compgen -W "$(_uoe_variants)" -- "$cur")); return ;;
    esac

    # which flags this script actually takes, from its own getopts string
    local dir script optstring
    dir="$(_uoe_scripts_dir)" || return
    script="$(basename "${COMP_WORDS[0]}")"
    optstring="$(sed -n 's/.*getopts "\(:\?[a-zA-Z:]*\)".*/\1/p' "$dir/$script" | head -1)"
    opts=""
    local i c
    for ((i = 0; i < ${#optstring}; i++)); do
        c="${optstring:i:1}"
        [ "$c" = ":" ] && continue
        opts="$opts -$c"
    done

    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
}

complete -F _uoe_complete run_tests.sh run_uoe_test.sh run_wave.sh
complete -F _uoe_complete ./scripts/run_tests.sh ./scripts/run_uoe_test.sh \
                          ./scripts/run_wave.sh
