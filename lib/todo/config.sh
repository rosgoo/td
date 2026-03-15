#!/usr/bin/env bash
# config.sh — Settings, paths, colors, and symbols.
#
# Loads user settings from ~/.config/claude-todo/settings.json (if it exists),
# then falls back to env vars, then defaults. All other modules depend on the
# variables defined here.

# --- User settings (env vars take precedence over settings.json) ------------

TODO_SETTINGS="${TODO_SETTINGS:-${HOME}/.config/claude-todo/settings.json}"
if [[ -f "$TODO_SETTINGS" ]] && command -v jq &>/dev/null; then
    _s() { jq -r "$1 // empty" "$TODO_SETTINGS" 2>/dev/null | sed "s|^~|$HOME|"; }
    : "${TODO_DATA_DIR:=$(_s '.data_dir')}"
    : "${TODO_REPO:=$(_s '.repo')}"
    : "${TODO_EDITOR:=$(_s '.editor')}"
    : "${TODO_LINEAR_ORG:=$(_s '.linear_org')}"
    : "${TODO_WORKTREE_DIR:=$(_s '.worktree_dir')}"
    : "${TODO_BRANCH_PREFIX:=$(_s '.branch_prefix')}"
    unset -f _s
fi

# --- Paths ------------------------------------------------------------------

DATA_DIR="${TODO_DATA_DIR:-${HOME}/td}"
TODOS_FILE="${DATA_DIR}/todos.json"
NOTES_DIR="${DATA_DIR}/todo"
REPO_ROOT="${TODO_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [[ -n "${TODO_EDITOR:-}" ]]; then
    NOTES_EDITOR="$TODO_EDITOR"
elif command -v open &>/dev/null; then
    NOTES_EDITOR="open"
elif command -v xdg-open &>/dev/null; then
    NOTES_EDITOR="xdg-open"
else
    NOTES_EDITOR="vi"
fi

# _open_notes — Open a notes file (or directory) in the configured editor.
# When editor is "obsidian", uses the Obsidian URI scheme to open files
# directly in the vault derived from DATA_DIR.
_open_notes() {
    local target="$1"
    if [[ "$NOTES_EDITOR" == "obsidian" ]]; then
        local vault_name
        vault_name=$(basename "$DATA_DIR")
        # Get path relative to the vault root
        local rel_path="${target#$DATA_DIR/}"
        # URL-encode spaces
        rel_path="${rel_path// /%20}"
        open "obsidian://open?vault=${vault_name}&file=${rel_path}"
    else
        $NOTES_EDITOR "$target"
    fi
}
LINEAR_ORG="${TODO_LINEAR_ORG:-}"
WORKTREE_DIR="${TODO_WORKTREE_DIR:-.claude/worktrees}"
BRANCH_PREFIX="${TODO_BRANCH_PREFIX:-todo}"

# --- Terminal colors --------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
ITALIC='\033[3m'
RESET='\033[0m'

# --- Symbols ----------------------------------------------------------------

SYM_ARROW="›"
SYM_CHECK="✓"
SYM_DOT="·"
SYM_BRANCH=""
SYM_SESSION="◉"

# --- Output helpers ---------------------------------------------------------

_info() {
    [[ -n "${TODO_QUIET:-}" ]] && return
    echo -e "$@" >&2
}

# --- Platform helpers -------------------------------------------------------

_open_url() {
    if command -v open &>/dev/null; then
        open "$1"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$1"
    else
        echo -e "${RED}Cannot open URL:${RESET} $1" >&2
        echo "Install xdg-open or open the URL manually." >&2
        return 1
    fi
}
