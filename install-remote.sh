#!/usr/bin/env bash
set -euo pipefail

# install-remote.sh — Install td without cloning the repo.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash -s -- --version v0.4.0
#   curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash -s -- --no-hooks

REPO="rosgoo/td"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/claude-todo"

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

SKIP_HOOKS=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --no-hooks) SKIP_HOOKS=true ;;
        --version)  :;; # next arg is version
        v*)         VERSION="$arg" ;;
    esac
done

# Resolve version: use arg, or fetch latest from GitHub
if [[ -z "$VERSION" ]]; then
    echo -e "${DIM}Fetching latest version...${RESET}"
    VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')
    if [[ -z "$VERSION" ]]; then
        echo -e "${RED}✗${RESET} Could not determine latest version" >&2
        exit 1
    fi
fi

echo -e "${BOLD}Installing td ${VERSION}${RESET}"
echo ""

# --- Check Python -----------------------------------------------------------

if ! command -v python3 &>/dev/null; then
    echo -e "${RED}✗${RESET} python3 not found. Install Python 3.10+" >&2
    exit 1
fi

# --- Download & extract -----------------------------------------------------

TARBALL_URL="https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo -e "${DIM}Downloading ${TARBALL_URL}...${RESET}"
if ! curl -fsSL "$TARBALL_URL" | tar xz -C "$TMP_DIR"; then
    echo -e "${RED}✗${RESET} Download failed. Check that version ${VERSION} exists." >&2
    exit 1
fi

SRC_DIR="${TMP_DIR}/td-${VERSION#v}"
if [[ ! -d "$SRC_DIR" ]]; then
    SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d ! -name "$(basename "$TMP_DIR")" | head -1)
fi

# --- Dependencies -----------------------------------------------------------

echo "Dependencies:"

if command -v claude &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} claude"
else
    echo -e "  ${RED}✗${RESET} claude (Claude Code) not found. Install: npm install -g @anthropic-ai/claude-code"
fi
echo ""

# --- Install Python package -------------------------------------------------

echo "Python package:"
if command -v pipx &>/dev/null; then
    if pipx list 2>/dev/null | grep -q "td"; then
        pipx install --force "${SRC_DIR}" 2>/dev/null
        echo -e "  ${GREEN}✓${RESET} Upgraded td via pipx"
    else
        pipx install "${SRC_DIR}" 2>/dev/null
        echo -e "  ${GREEN}✓${RESET} Installed td via pipx"
    fi
elif command -v pip3 &>/dev/null; then
    pip3 install --user --break-system-packages "${SRC_DIR}" 2>/dev/null || \
    pip3 install --user "${SRC_DIR}" 2>/dev/null
    echo -e "  ${GREEN}✓${RESET} Installed td via pip3 --user"
else
    VENV_DIR="${HOME}/.local/share/td-venv"
    if [[ ! -d "$VENV_DIR" ]]; then
        python3 -m venv "$VENV_DIR"
    fi
    "${VENV_DIR}/bin/pip" install "${SRC_DIR}" -q
    mkdir -p "$BIN_DIR"
    ln -sf "${VENV_DIR}/bin/td" "${BIN_DIR}/td"
    echo -e "  ${GREEN}✓${RESET} Installed td in venv at ${VENV_DIR}"
fi
echo ""

# --- Hooks ------------------------------------------------------------------

echo "Hooks:"
if [[ -f "${SRC_DIR}/hooks/pre-compact" ]]; then
    mkdir -p "$BIN_DIR"
    cp "${SRC_DIR}/hooks/pre-compact" "${BIN_DIR}/td-pre-compact"
    chmod +x "${BIN_DIR}/td-pre-compact"
    echo -e "  ${GREEN}✓${RESET} Installed ${BIN_DIR}/td-pre-compact"
else
    echo -e "  ${DIM}Skipping pre-compact hook (not in release)${RESET}"
fi
echo ""

# --- Claude Code commands ---------------------------------------------------

CLAUDE_COMMANDS_DIR="${HOME}/.claude/commands"
echo "Claude Code commands:"
if [[ -f "${SRC_DIR}/commands/td.md" ]]; then
    mkdir -p "$CLAUDE_COMMANDS_DIR"
    cp "${SRC_DIR}/commands/td.md" "${CLAUDE_COMMANDS_DIR}/td.md"
    echo -e "  ${GREEN}✓${RESET} Installed ${CLAUDE_COMMANDS_DIR}/td.md"
else
    echo -e "  ${DIM}Skipping td command (not in release)${RESET}"
fi
echo ""

# --- Settings ---------------------------------------------------------------

if [[ ! -f "${CONFIG_DIR}/settings.json" ]]; then
    if [[ -f "${SRC_DIR}/settings.json" ]]; then
        mkdir -p "$CONFIG_DIR"
        cp "${SRC_DIR}/settings.json" "${CONFIG_DIR}/settings.json"
        echo -e "${GREEN}✓${RESET} Created ${CONFIG_DIR}/settings.json"
    fi
else
    echo -e "${DIM}Settings already exist at ${CONFIG_DIR}/settings.json${RESET}"
fi

# --- Claude Code hooks ------------------------------------------------------

if [[ "$SKIP_HOOKS" == true ]]; then
    echo -e "${DIM}Skipping Claude Code hook configuration (--no-hooks)${RESET}"
    echo ""
else
    CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

    _has_td_hook() {
        python3 -c "
import json, sys
try:
    d = json.load(open('$CLAUDE_SETTINGS'))
    hooks = d.get('hooks', {}).get('PreCompact', [])
    for group in hooks:
        for h in group.get('hooks', []):
            if h.get('command') == 'td-pre-compact':
                sys.exit(0)
    sys.exit(1)
except: sys.exit(1)
" 2>/dev/null
    }

    echo "Claude Code hooks:"
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if _has_td_hook; then
            echo -e "  ${GREEN}✓${RESET} PreCompact hook already configured"
        else
            python3 -c "
import json
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
d.setdefault('hooks', {}).setdefault('PreCompact', []).append({
    'hooks': [{'type': 'command', 'command': 'td-pre-compact', 'timeout': 10}]
})
with open('$CLAUDE_SETTINGS', 'w') as f:
    json.dump(d, f, indent=2)
"
            echo -e "  ${GREEN}✓${RESET} Added PreCompact hook to ${CLAUDE_SETTINGS}"
        fi
    else
        mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
        python3 -c "
import json
d = {'hooks': {'PreCompact': [{'hooks': [{'type': 'command', 'command': 'td-pre-compact', 'timeout': 10}]}]}}
with open('$CLAUDE_SETTINGS', 'w') as f:
    json.dump(d, f, indent=2)
"
        echo -e "  ${GREEN}✓${RESET} Created ${CLAUDE_SETTINGS} with PreCompact hook"
    fi
    echo ""
fi

# --- PATH check -------------------------------------------------------------

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    echo -e "${BOLD}Add to your shell profile (~/.zshrc):${RESET}"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# --- Done -------------------------------------------------------------------

echo -e "${GREEN}${BOLD}td ${VERSION#v} installed.${RESET}"
echo -e "${DIM}Run 'td help' to get started.${RESET}"
