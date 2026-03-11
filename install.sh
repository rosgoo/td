#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install claude-todo and its dependencies

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/claude-todo"

echo -e "${BOLD}Installing claude-todo${RESET}"
echo ""

# Check for Homebrew (macOS)
install_dep() {
    local cmd="$1" pkg="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} ${cmd}"
    else
        echo -e "  ${DIM}Installing ${cmd}...${RESET}"
        if command -v brew &>/dev/null; then
            brew install "$pkg"
        else
            echo -e "  ${RED}✗${RESET} ${cmd} not found. Install it manually: https://github.com/${pkg}" >&2
            return 1
        fi
    fi
}

echo "Dependencies:"
install_dep jq stedolan/jq
install_dep fzf junegunn/fzf
install_dep gum charmbracelet/gum

if command -v claude &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} claude"
else
    echo -e "  ${RED}✗${RESET} claude (Claude Code) not found. Install: npm install -g @anthropic-ai/claude-code"
fi
echo ""

# Symlink
mkdir -p "$BIN_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -L "${BIN_DIR}/todo" ]]; then
    existing=$(readlink "${BIN_DIR}/todo")
    if [[ "$existing" == "${SCRIPT_DIR}/todo" ]]; then
        echo -e "${GREEN}✓${RESET} ${BIN_DIR}/todo already linked"
    else
        echo -e "${DIM}Updating symlink (was ${existing})${RESET}"
        ln -sf "${SCRIPT_DIR}/todo" "${BIN_DIR}/todo"
        echo -e "${GREEN}✓${RESET} Linked ${BIN_DIR}/todo"
    fi
elif [[ -e "${BIN_DIR}/todo" ]]; then
    echo -e "${RED}✗${RESET} ${BIN_DIR}/todo already exists (not a symlink). Remove it first."
else
    ln -s "${SCRIPT_DIR}/todo" "${BIN_DIR}/todo"
    echo -e "${GREEN}✓${RESET} Linked ${BIN_DIR}/todo"
fi

# Settings template
if [[ ! -f "${CONFIG_DIR}/settings.sh" ]]; then
    mkdir -p "$CONFIG_DIR"
    cp "${SCRIPT_DIR}/settings.sh" "${CONFIG_DIR}/settings.sh"
    echo -e "${GREEN}✓${RESET} Created ${CONFIG_DIR}/settings.sh"
else
    echo -e "${DIM}Settings already exist at ${CONFIG_DIR}/settings.sh${RESET}"
fi

# Check PATH
if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    echo ""
    echo -e "${BOLD}Add to your shell profile (~/.zshrc):${RESET}"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

echo ""
echo -e "${GREEN}Done.${RESET} Run ${BOLD}todo${RESET} to get started."
