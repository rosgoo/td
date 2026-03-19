#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install td (Python) and its dependencies

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

SKIP_HOOKS=false
for arg in "$@"; do
    case "$arg" in
        --no-hooks) SKIP_HOOKS=true ;;
    esac
done

BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/claude-todo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}Installing td${RESET}"
echo ""

# --- Dependencies -----------------------------------------------------------

echo "Dependencies:"

# Python 3.10+ (required)
if command -v python3 &>/dev/null; then
    PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    echo -e "  ${GREEN}✓${RESET} python3 (${PY_VER})"
else
    echo -e "  ${RED}✗${RESET} python3 not found. Install Python 3.10+" >&2
    exit 1
fi

# claude (optional but recommended)
if command -v claude &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} claude"
else
    echo -e "  ${RED}✗${RESET} claude (Claude Code) not found. Install: npm install -g @anthropic-ai/claude-code"
fi
echo ""

# --- Install Python package -------------------------------------------------

echo "Python package:"
if command -v pipx &>/dev/null; then
    # Prefer pipx for isolated install
    if pipx list 2>/dev/null | grep -q "td"; then
        pipx install --force "${SCRIPT_DIR}" 2>/dev/null
        echo -e "  ${GREEN}✓${RESET} Upgraded td via pipx"
    else
        pipx install "${SCRIPT_DIR}" 2>/dev/null
        echo -e "  ${GREEN}✓${RESET} Installed td via pipx"
    fi
elif command -v pip3 &>/dev/null; then
    pip3 install --user --break-system-packages "${SCRIPT_DIR}" 2>/dev/null || \
    pip3 install --user "${SCRIPT_DIR}" 2>/dev/null
    echo -e "  ${GREEN}✓${RESET} Installed td via pip3 --user"
else
    # Create a venv at ~/.local/share/td-venv and install there
    VENV_DIR="${HOME}/.local/share/td-venv"
    if [[ ! -d "$VENV_DIR" ]]; then
        python3 -m venv "$VENV_DIR"
    fi
    "${VENV_DIR}/bin/pip" install "${SCRIPT_DIR}" -q
    # Symlink the td binary
    mkdir -p "$BIN_DIR"
    ln -sf "${VENV_DIR}/bin/td" "${BIN_DIR}/td"
    echo -e "  ${GREEN}✓${RESET} Installed td in venv at ${VENV_DIR}"
fi
echo ""

# --- Hooks ------------------------------------------------------------------

_link_hook() {
    local name="$1"
    local src="${SCRIPT_DIR}/hooks/${name}"
    local dst="${BIN_DIR}/td-${name}"
    if [[ ! -f "$src" ]]; then
        echo -e "  ${DIM}Skipping hook ${name} (not found)${RESET}"
        return
    fi
    mkdir -p "$BIN_DIR"
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

# --- Claude Code commands ---------------------------------------------------

CLAUDE_COMMANDS_DIR="${HOME}/.claude/commands"
_link_command() {
    local name="$1"
    local src="${SCRIPT_DIR}/commands/${name}.md"
    local dst="${CLAUDE_COMMANDS_DIR}/${name}.md"
    if [[ ! -f "$src" ]]; then
        echo -e "  ${DIM}Skipping command ${name} (not found)${RESET}"
        return
    fi
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        echo -e "  ${GREEN}✓${RESET} ${dst} already linked"
    else
        mkdir -p "$CLAUDE_COMMANDS_DIR"
        ln -sf "$src" "$dst"
        echo -e "  ${GREEN}✓${RESET} Linked ${dst}"
    fi
}

echo "Claude Code commands:"
_link_command td
echo ""

# --- Settings ---------------------------------------------------------------

if [[ ! -f "${CONFIG_DIR}/settings.json" ]]; then
    if [[ -f "${SCRIPT_DIR}/settings.json" ]]; then
        mkdir -p "$CONFIG_DIR"
        cp "${SCRIPT_DIR}/settings.json" "${CONFIG_DIR}/settings.json"
        echo -e "${GREEN}✓${RESET} Created ${CONFIG_DIR}/settings.json"
    fi
else
    echo -e "${DIM}Settings already exist at ${CONFIG_DIR}/settings.json${RESET}"
fi

# --- PATH check -------------------------------------------------------------

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    echo ""
    echo -e "${BOLD}Add to your shell profile (~/.zshrc):${RESET}"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# --- Claude Code hooks ------------------------------------------------------

if [[ "$SKIP_HOOKS" == true ]]; then
    echo -e "${DIM}Skipping Claude Code hook configuration (--no-hooks)${RESET}"
    echo ""
else
    CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
    TD_HOOK='{"type":"command","command":"td-pre-compact","timeout":10}'

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

# --- Done -------------------------------------------------------------------

td help 2>/dev/null || echo -e "${GREEN}${BOLD}td installed.${RESET} Run 'td help' to get started."
