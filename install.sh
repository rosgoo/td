#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install todo and its dependencies

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/todo"
CONFIG_DIR="${HOME}/.config/claude-todo"

echo -e "${BOLD}Installing todo${RESET}"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy lib files
mkdir -p "$LIB_DIR"
cp "${SCRIPT_DIR}"/lib/todo/*.sh "$LIB_DIR/"
echo -e "${GREEN}✓${RESET} Installed lib files to ${LIB_DIR}"

# Copy VERSION file
cp "${SCRIPT_DIR}/VERSION" "${HOME}/.local/VERSION"

# Symlink td binary
mkdir -p "$BIN_DIR"

if [[ -L "${BIN_DIR}/td" ]]; then
    existing=$(readlink "${BIN_DIR}/td")
    if [[ "$existing" == "${SCRIPT_DIR}/td" ]]; then
        echo -e "${GREEN}✓${RESET} ${BIN_DIR}/td already linked"
    else
        echo -e "${DIM}Updating symlink (was ${existing})${RESET}"
        ln -sf "${SCRIPT_DIR}/td" "${BIN_DIR}/td"
        echo -e "${GREEN}✓${RESET} Linked ${BIN_DIR}/td"
    fi
elif [[ -e "${BIN_DIR}/td" ]]; then
    echo -e "${RED}✗${RESET} ${BIN_DIR}/td already exists (not a symlink). Remove it first."
else
    ln -s "${SCRIPT_DIR}/td" "${BIN_DIR}/td"
    echo -e "${GREEN}✓${RESET} Linked ${BIN_DIR}/td"
fi

# Hook scripts
_link_hook() {
    local name="$1"
    local src="${SCRIPT_DIR}/hooks/${name}"
    local dst="${BIN_DIR}/td-${name}"
    if [[ ! -f "$src" ]]; then
        echo -e "  ${DIM}Skipping hook ${name} (not found)${RESET}"
        return
    fi
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        echo -e "  ${GREEN}✓${RESET} ${dst} already linked"
    else
        ln -sf "$src" "$dst"
        echo -e "  ${GREEN}✓${RESET} Linked ${dst}"
    fi
}

echo "Hooks:"
_link_hook pre-compact
echo ""

# Settings template
if [[ ! -f "${CONFIG_DIR}/settings.json" ]]; then
    mkdir -p "$CONFIG_DIR"
    cp "${SCRIPT_DIR}/settings.json" "${CONFIG_DIR}/settings.json"
    echo -e "${GREEN}✓${RESET} Created ${CONFIG_DIR}/settings.json"
else
    echo -e "${DIM}Settings already exist at ${CONFIG_DIR}/settings.json${RESET}"
fi

# Check PATH
if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    echo ""
    echo -e "${BOLD}Add to your shell profile (~/.zshrc):${RESET}"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# Remind about hooks config
echo ""
echo -e "${BOLD}Configure Claude Code hooks${RESET} in ~/.claude/settings.json:"
echo ""
echo '  "hooks": {'
echo '    "PreCompact": [{'
echo '      "hooks": [{'
echo '        "type": "command",'
echo '        "command": "td-pre-compact",'
echo '        "timeout": 10'
echo '      }]'
echo '    }]'
echo '  }'
echo ""

# Show help (includes logo)
"${SCRIPT_DIR}/td" help
