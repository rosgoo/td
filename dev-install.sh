#!/usr/bin/env bash
set -euo pipefail

# dev-install.sh — Set up local dev environment for td
#
# After running this:
#   td       → Python dev version (from .venv, editable install)
#   td-prod  → Bash production version (original td script)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${SCRIPT_DIR}/.venv"

echo "Setting up td dev environment..."

# Create/update venv
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    echo "✓ Created venv at ${VENV_DIR}"
fi

"${VENV_DIR}/bin/pip" install -e "${SCRIPT_DIR}" -q
"${VENV_DIR}/bin/pip" install pytest -q
echo "✓ Installed td-cli (editable) + pytest"

# td → Python dev version
mkdir -p "$BIN_DIR"
ln -sf "${VENV_DIR}/bin/td" "${BIN_DIR}/td"
echo "✓ td → Python dev (${VENV_DIR}/bin/td)"

# td-prod → Bash production version
ln -sf "${SCRIPT_DIR}/td" "${BIN_DIR}/td-prod"
echo "✓ td-prod → Bash production (${SCRIPT_DIR}/td)"

echo ""
echo "Done. Test with:"
echo "  td version        # Python dev"
echo "  td-prod version   # Bash production"
echo "  make test          # Run all tests"
