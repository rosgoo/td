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
    unset -f _s
fi

# --- Paths ------------------------------------------------------------------

DATA_DIR="${TODO_DATA_DIR:-${HOME}/.claude-todos}"
TODOS_FILE="${DATA_DIR}/todos.json"
NOTES_DIR="${DATA_DIR}/notes"
REPO_ROOT="${TODO_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
NOTES_EDITOR="${TODO_EDITOR:-${VISUAL:-${EDITOR:-open}}}"

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
