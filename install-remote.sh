#!/usr/bin/env bash
set -euo pipefail

# install-remote.sh — Install td without cloning the repo.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash -s -- --version v0.2.0
#   curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash -s -- --no-hooks

REPO="rosgoo/td"
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/todo"
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

# --- Download & extract -------------------------------------------------------

TARBALL_URL="https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo -e "${DIM}Downloading ${TARBALL_URL}...${RESET}"
if ! curl -fsSL "$TARBALL_URL" | tar xz -C "$TMP_DIR"; then
    echo -e "${RED}✗${RESET} Download failed. Check that version ${VERSION} exists." >&2
    exit 1
fi

# GitHub tarballs extract to td-{version}/ (strip the v prefix from dir name)
SRC_DIR="${TMP_DIR}/td-${VERSION#v}"
if [[ ! -d "$SRC_DIR" ]]; then
    # Fallback: find the extracted directory
    SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d ! -name "$(basename "$TMP_DIR")" | head -1)
fi

# --- Check dependencies -------------------------------------------------------

echo "Dependencies:"
_install_dep() {
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

_install_dep jq stedolan/jq
_install_dep fzf junegunn/fzf
_install_dep gum charmbracelet/gum

if command -v claude &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} claude"
else
    echo -e "  ${RED}✗${RESET} claude (Claude Code) not found. Install: npm install -g @anthropic-ai/claude-code"
fi
echo ""

# --- Install files -------------------------------------------------------------

# Lib
mkdir -p "$LIB_DIR"
cp "${SRC_DIR}"/lib/todo/*.sh "$LIB_DIR/"
echo -e "${GREEN}✓${RESET} Installed lib to ${LIB_DIR}"

# Binary
mkdir -p "$BIN_DIR"
cp "${SRC_DIR}/td" "${BIN_DIR}/td"
chmod +x "${BIN_DIR}/td"
echo -e "${GREEN}✓${RESET} Installed ${BIN_DIR}/td"

# VERSION
cp "${SRC_DIR}/VERSION" "${HOME}/.local/VERSION"
echo -e "${GREEN}✓${RESET} Installed VERSION (${VERSION#v})"

# Hook scripts
echo "Hooks:"
if [[ -f "${SRC_DIR}/hooks/pre-compact" ]]; then
    cp "${SRC_DIR}/hooks/pre-compact" "${BIN_DIR}/td-pre-compact"
    chmod +x "${BIN_DIR}/td-pre-compact"
    echo -e "  ${GREEN}✓${RESET} Installed ${BIN_DIR}/td-pre-compact"
else
    echo -e "  ${DIM}Skipping pre-compact hook (not in release)${RESET}"
fi
echo ""

# Claude Code commands
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

# --- Settings ------------------------------------------------------------------

if [[ ! -f "${CONFIG_DIR}/settings.json" ]]; then
    if [[ -f "${SRC_DIR}/settings.json" ]]; then
        mkdir -p "$CONFIG_DIR"
        cp "${SRC_DIR}/settings.json" "${CONFIG_DIR}/settings.json"
        echo -e "${GREEN}✓${RESET} Created ${CONFIG_DIR}/settings.json"
    fi
else
    echo -e "${DIM}Settings already exist at ${CONFIG_DIR}/settings.json${RESET}"
fi

# --- Claude Code hooks ---------------------------------------------------------

if [[ "$SKIP_HOOKS" == true ]]; then
    echo -e "${DIM}Skipping Claude Code hook configuration (--no-hooks)${RESET}"
    echo ""
else
    CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
    TD_HOOK='{"type":"command","command":"td-pre-compact","timeout":10}'

    _has_td_hook() {
        jq -e '.hooks.PreCompact // [] | .. | select(.command? == "td-pre-compact")' \
            "$CLAUDE_SETTINGS" &>/dev/null
    }

    echo "Claude Code hooks:"
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if _has_td_hook; then
            echo -e "  ${GREEN}✓${RESET} PreCompact hook already configured"
        else
            tmp=$(mktemp)
            jq --argjson hook "$TD_HOOK" '
                .hooks //= {} |
                .hooks.PreCompact //= [] |
                .hooks.PreCompact += [{"hooks": [$hook]}]
            ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
            echo -e "  ${GREEN}✓${RESET} Added PreCompact hook to ${CLAUDE_SETTINGS}"
        fi
    else
        mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
        cat > "$CLAUDE_SETTINGS" <<-ENDJSON
{
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "td-pre-compact",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
ENDJSON
        echo -e "  ${GREEN}✓${RESET} Created ${CLAUDE_SETTINGS} with PreCompact hook"
    fi
    echo ""
fi

# --- PATH check ----------------------------------------------------------------

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    echo -e "${BOLD}Add to your shell profile (~/.zshrc):${RESET}"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# --- Done ----------------------------------------------------------------------

echo -e "${GREEN}${BOLD}td ${VERSION#v} installed.${RESET}"
echo -e "${DIM}Run 'td help' to get started. Run 'td update' to update later.${RESET}"
