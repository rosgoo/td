#!/usr/bin/env bash
set -euo pipefail

# td — A TODO list with fzf for managing Claude Code sessions.
#
# Each todo has a plan.md file and can optionally have a Claude Code worktree
# session, a git branch, and a Linear ticket.
#
# Usage:
#   td              Open the fzf picker (create or select todos)
#   td new "title"  Create a new todo
#   td done         Mark a todo as done
#   td edit         Open plan.md in $EDITOR
#   td link [type]  Link a Linear ticket or branch
#   td open         Open Linear/GitHub links in browser
#   td list         List all active todos
#   td archive      Show completed todos
#   td help         Show this help
#
# Source modules live alongside this script in ../lib/todo/. See each file:
#   config.sh   — Settings, paths, colors, symbols
#   data.sh     — JSON CRUD, ID generation, notes
#   ui.sh       — fzf picker, gum wrappers, line formatting
#   git.sh      — Git repo/URL helpers, worktree validation
#   session.sh  — Worktree lifecycle, Claude session launching
#   commands.sh — All cmd_* user-facing commands

# --- Resolve library path (follows symlinks) --------------------------------

if [[ -z "${TODO_LIB:-}" ]]; then
    _self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")"
    _dir="$(dirname "$_self")"
    if [[ -d "${_dir}/lib/todo" ]]; then
        TODO_LIB="${_dir}/lib/todo"       # Running from repo root
    else
        TODO_LIB="${_dir}/../lib/todo"    # Installed to PREFIX/bin/
    fi
fi

# --- Version ----------------------------------------------------------------

_self="${_self:-$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")}"
_dir="${_dir:-$(dirname "$_self")}"
if [[ -f "${_dir}/VERSION" ]]; then
    TODO_VERSION="$(cat "${_dir}/VERSION")"
elif [[ -f "${_dir}/../VERSION" ]]; then
    TODO_VERSION="$(cat "${_dir}/../VERSION")"
else
    TODO_VERSION="dev"
fi

# --- Global flags (must run before sourcing modules) ------------------------

TODO_QUIET="${TODO_QUIET:-}"
for _arg in "$@"; do
    case "$_arg" in
        --no-color) export NO_COLOR=1 ;;
        -q|--quiet) TODO_QUIET=1 ;;
    esac
done

# --- Source modules (order matters: later modules depend on earlier ones) ----

source "${TODO_LIB}/config.sh"
source "${TODO_LIB}/data.sh"
source "${TODO_LIB}/ui.sh"
source "${TODO_LIB}/git.sh"
source "${TODO_LIB}/session.sh"
source "${TODO_LIB}/commands.sh"

# --- Main (skip when sourced for testing) -----------------------------------

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _ensure_setup
    return 0
fi

# Filter out global flags from positional args
_args=()
for _arg in "$@"; do
    case "$_arg" in
        --no-color|-q|--quiet) ;; # already handled above
        *) _args+=("$_arg") ;;
    esac
done
set -- "${_args[@]+"${_args[@]}"}"

_ensure_setup
_check_jq
_check_gum

_subcmd_usage() {
    local cmd="$1" usage="$2"
    echo -e "Usage: ${BOLD}td ${cmd}${RESET} ${usage}" >&2
    exit 0
}

case "${1:-}" in
    new)         shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "new" "[-b|--backlog] \"title\""; cmd_new "$@" ;;
    done)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "done" "[id]"; cmd_done "${1:-}" ;;
    try)         shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "try" "[id]"; cmd_try "${1:-}" ;;
    bump)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "bump" "[id]"; cmd_bump "${1:-}" ;;
    split)       shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "split" "[parent-id] [\"title\"]"; cmd_split "${1:-}" "${2:-}" ;;
    edit)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "edit" "[id]"; cmd_edit "${1:-}" ;;
    link)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "link" "[id] [url|path]"; cmd_link "${1:-}" "${2:-}" ;;
    open)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "open" ""; cmd_open ;;
    get)         shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "get" "<id>"; cmd_get "${1:-}" ;;
    note)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "note" "<id> \"text\""; cmd_note "${1:-}" "${2:-}" ;;
    show)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "show" "[id]"; cmd_show "${1:-}" ;;
    list|ls)     shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "list" "[--json]"; cmd_list "${1:-}" ;;
    archive)     shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "archive" ""; cmd_archive ;;
    browse)      shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "browse" ""; cmd_browse ;;
    rename|mv)   shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "rename" "[id] [\"new title\"]"; cmd_rename "${1:-}" "${2:-}" ;;
    delete|rm)   shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "delete" "[id] [--force]"; cmd_delete "${1:-}" "${2:-}" ;;
    find)        shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "find" "[query]"; cmd_find "${*:-}" ;;
    do)          shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "do" "[-n \"title\"]"; cmd_do "$@" ;;
    init)        shift; cmd_init ;;
    clean)       shift; [[ "${1:-}" == @(-h|--help) ]] && _subcmd_usage "clean" "[-n|--dry-run]"; cmd_clean "${1:-}" ;;
    settings)    shift; cmd_settings ;;
    update)      shift; cmd_update ;;
    version|--version|-v) echo "td ${TODO_VERSION}" ;;
    help|--help|-h) cmd_help ;;
    "")          cmd_picker ;;
    *)
        echo -e "${RED}Unknown command:${RESET} $1" >&2
        # Suggest closest match
        _cmds=(new done try bump split edit link open get note show list ls archive browse rename mv delete rm find do clean init settings update version help)
        _best="" _best_dist=999
        for _c in "${_cmds[@]}"; do
            # Simple: check prefix match or 1-char difference in length
            if [[ "$_c" == "$1"* || "$1" == "$_c"* ]]; then
                _best="$_c"; break
            fi
        done
        if [[ -n "$_best" ]]; then
            echo -e "  Did you mean ${CYAN}td ${_best}${RESET}?" >&2
        fi
        exit 1
        ;;
esac
