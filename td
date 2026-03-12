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

_ensure_setup
_check_jq
_check_gum

case "${1:-}" in
    new)         shift; cmd_new "${*:-}" ;;
    done)        shift; cmd_done "${1:-}" ;;
    split)       shift; cmd_split "${1:-}" "${2:-}" ;;
    edit)        shift; cmd_edit "${1:-}" ;;
    link)        shift; cmd_link "${1:-}" "${2:-}" ;;
    open)        cmd_open ;;
    get)         shift; cmd_get "${1:-}" ;;
    note)        shift; cmd_note "${1:-}" "${2:-}" ;;
    show)        shift; cmd_show "${1:-}" ;;
    list|ls)     cmd_list ;;
    archive)     cmd_archive ;;
    rename|mv)   shift; cmd_rename "${1:-}" "${2:-}" ;;
    delete|rm)   shift; cmd_delete "${1:-}" "${2:-}" ;;
    version|--version|-v) echo "td ${TODO_VERSION}" ;;
    help|--help|-h) cmd_help ;;
    "")          cmd_picker ;;
    *)
        echo -e "${RED}Unknown command:${RESET} $1" >&2
        cmd_help
        exit 1
        ;;
esac
